#!/bin/sh
#
# s3-test.sh — tests for s3.sh, the CI object-store client.
#
# Two parts:
#
#   1. Hermetic (always). curl is a stub on PATH that answers from a per-case
#      plan and logs every request, so what runs is s3.sh's own logic: SigV4
#      presigning and HMAC against published test vectors, the exit-code
#      contract the lanes branch on, which failures are retried and which are
#      not, that a download is verified before it replaces anything, that
#      nothing partial is left behind, and that the secret never reaches argv
#      or the log.
#
#   2. Live (S3_TEST_LIVE=1). The real curl against a real S3 store (the
#      ci-scripts-test lane runs SeaweedFS 4.47, the CI store's version, as a
#      service), with MINIO_ENDPOINT / MINIO_ACCESS_KEY / MINIO_SECRET_KEY set
#      and S3_TEST_BUCKET naming a throwaway bucket this test may create. Never
#      point it at the real CI store: it creates and deletes objects.
#      S3_TEST_LARGE_MB sizes the streamed large-object case (default 64).
#
# POSIX sh; CI runs it under both bash and /bin/sh, like retry-test.sh.
#
#   sh   .ci/scripts/s3-test.sh
#   TEST_S3_SHELL=bash bash .ci/scripts/s3-test.sh

# SC2015: `A && pass || fail` is safe here, pass() cannot fail.
# SC2031: the vector helper's subshell assignments are meant to stay there.
# shellcheck disable=SC2015,SC2030,SC2031
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
S3SH="$HERE/s3.sh"
# The shell s3.sh itself runs under. The lanes run it with `sh` (dash or
# busybox); CI's bash run sets TEST_S3_SHELL=bash so s3.sh is exercised under
# bash too, not only this test's own code.
S3RUN=${TEST_S3_SHELL:-sh}

fails=0
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; fails=$((fails + 1)); }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
trap 'rm -rf "$T"; exit 130' INT
trap 'rm -rf "$T"; exit 143' TERM

echo "== s3.sh (shell: ${TEST_SHELL_LABEL:-$0}) =="

# ------------------------------------------------------------ vectors
# The signing code, sourced without running a command.
vec() {
  (
    MINIO_ENDPOINT=$1 MINIO_ACCESS_KEY=$2 MINIO_SECRET_KEY=$3 S3_PRESIGN_DATE=$4
    S3_SH_SOURCE_ONLY=1
    export MINIO_ENDPOINT MINIO_ACCESS_KEY MINIO_SECRET_KEY S3_PRESIGN_DATE S3_SH_SOURCE_ONLY
    # shellcheck source=/dev/null
    . "$S3SH"
    s3_config
    shift 4
    "$@"
  )
}

# RFC 4231 test case 2, and case 6: a 131-byte key, longer than the block, which
# HMAC must hash first.
got=$(printf 'what do ya want for nothing?' | vec http://h k s 20130524T000000Z s3_hmac 4a656665)
[ "$got" = 5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843 ] \
  && pass "HMAC-SHA256 matches RFC 4231 case 2" || fail "HMAC case 2: got $got"
key6=$(i=0; while [ $i -lt 131 ]; do printf aa; i=$((i + 1)); done)
got=$(printf 'Test Using Larger Than Block-Size Key - Hash Key First' | vec http://h k s 20130524T000000Z s3_hmac "$key6")
[ "$got" = 60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54 ] \
  && pass "HMAC-SHA256 matches RFC 4231 case 6 (key longer than a block)" || fail "HMAC case 6: got $got"

# The presigned-URL example from the AWS SigV4 documentation ("Authenticating
# Requests: Using Query Parameters"): GET examplebucket/test.txt, 86400 s.
got=$(vec https://examplebucket.s3.amazonaws.com AKIAIOSFODNN7EXAMPLE \
  wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY 20130524T000000Z s3_presign_url GET /test.txt 86400)
want='https://examplebucket.s3.amazonaws.com/test.txt?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential=AKIAIOSFODNN7EXAMPLE%2F20130524%2Fus-east-1%2Fs3%2Faws4_request&X-Amz-Date=20130524T000000Z&X-Amz-Expires=86400&X-Amz-SignedHeaders=host&X-Amz-Signature=aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404'
[ "$got" = "$want" ] && pass "presign matches the AWS SigV4 documentation example" \
  || fail "presign: got $got"

got=$(vec http://h k s 20130524T000000Z s3_uriencode 'a b/c+d=e~_.-(1)&é' /)
[ "$got" = 'a%20b/c%2Bd%3De~_.-%281%29%26%C3%A9' ] && pass "URI encoding keeps unreserved and /, encodes the rest" \
  || fail "uriencode: got $got"
got=$(vec http://h k s 20130524T000000Z s3_uriencode 'a/b')
[ "$got" = 'a%2Fb' ] && pass "URI encoding of a query value encodes /" || fail "uriencode query: got $got"

# ------------------------------------------------------------ stub curl
# The plan: one line per request, consumed in order (the last line repeats):
#   RC STATUS BODY [key=value ...]
#   RC      curl's exit code        STATUS  HTTP status, or - for no answer
#   BODY    file served as the body, or - for none
#   etag=   ETag to send (auto = MD5 of BODY)   clen= Content-Length to send
#   short=N serve only the first N bytes of BODY
#   sleep=N stall before answering
# A --range request against a 200 line is answered 206 with that slice, unless:
#   norange=1  answer 200 with the whole body (a store that ignores Range)
#   r412=1     answer 412 (the object changed since the If-Match ETag)
#   bad=START  flip the first byte of the range that starts at START
#   badlen=START    answer that range one byte short, and say so in Content-Length
#   lie=START       answer that range one byte short, claiming the full length
#   append=1        after taking an upload, append a byte to the local file
#                   (the file changed while it was being sent)
BIN="$T/bin"; ST="$T/state"
mkdir -p "$BIN" "$ST"
cat > "$BIN/curl" <<EOF
#!/bin/sh
ST="$ST"
# Parallel range requests arrive at once: take the plan line under a lock.
until mkdir "\$ST/lock" 2>/dev/null; do sleep 0.01 2>/dev/null || sleep 1; done
n=\$(cat "\$ST/n" 2>/dev/null || echo 0); n=\$((n + 1)); echo "\$n" > "\$ST/n"
rmdir "\$ST/lock"
printf '%s\n' "\$*" >> "\$ST/argv.log"
cat >> "\$ST/stdin.log"
hdr=; out=; method=GET; url=; up=; headers=; range=
while [ \$# -gt 0 ]; do
  case "\$1" in
    --dump-header) hdr=\$2; shift ;;
    --output) out=\$2; shift ;;
    --head) method=HEAD ;;
    --request) method=\$2; shift ;;
    --upload-file) method=PUT; up=\$2; shift ;;
    --header) headers="\$headers|\$2"; shift ;;
    --range) range=\$2; shift ;;
    --config|--aws-sigv4|--connect-timeout|--speed-limit|--speed-time|--max-time) shift ;;
    -*) ;;
    *) url=\$1 ;;
  esac
  shift
done
echo "\$method \$url\$headers\${range:+|Range: \$range}" >> "\$ST/calls.log"
line=\$(sed -n "\${n}p" "\$ST/plan"); [ -n "\$line" ] || line=\$(tail -n 1 "\$ST/plan")
set -- \$line
rc=\$1; status=\$2; body=\$3; shift 3
etag=; clen=; short=; slp=; norange=; r412=; bad=; badlen=; lie=; append=
for kv in "\$@"; do
  case "\$kv" in
    etag=*) etag=\${kv#etag=} ;; clen=*) clen=\${kv#clen=} ;;
    short=*) short=\${kv#short=} ;; sleep=*) slp=\${kv#sleep=} ;;
    norange=*) norange=1 ;; r412=*) r412=1 ;; bad=*) bad=\${kv#bad=} ;;
    badlen=*) badlen=\${kv#badlen=} ;; lie=*) lie=\${kv#lie=} ;; append=*) append=1 ;;
  esac
done
[ -z "\$up" ] || cp "\$up" "\$ST/uploaded"
[ -z "\$up" ] || [ -z "\$append" ] || printf X >> "\$up"
[ -z "\$slp" ] || sleep "\$slp"
[ "\$etag" != auto ] || etag=\$(md5sum < "\$body" | cut -d' ' -f1)
if [ -n "\$range" ] && [ "\$status" = 200 ] && [ -z "\$norange" ]; then
  if [ -n "\$r412" ]; then
    printf 'HTTP/1.1 412 X\r\nContent-Length: 0\r\n\r\n' > "\$hdr"; exit "\$rc"
  fi
  a=\${range%-*}; b=\${range#*-}; len=\$((b - a + 1)); send=\$len
  [ "\$a" != "\$badlen" ] || { len=\$((len - 1)); send=\$len; }
  [ "\$a" != "\$lie" ] || send=\$((len - 1))
  { printf 'HTTP/1.1 206 X\r\n'
    printf 'Content-Length: %s\r\n' "\$len"
    printf 'Content-Range: bytes %s/%s\r\n' "\$range" "\$(wc -c < "\$body" | tr -d ' ')"
    printf '\r\n'; } > "\$hdr"
  if [ "\$a" = "\$bad" ]; then
    { printf X; tail -c +\$((a + 2)) "\$body" | head -c \$((b - a)); }
  else
    tail -c +\$((a + 1)) "\$body" | head -c "\$send"
  fi
  exit "\$rc"
fi
if [ "\$status" != - ]; then
  size=0; [ "\$body" = - ] || size=\$(wc -c < "\$body" | tr -d ' ')
  { printf 'HTTP/1.1 %s X\r\n' "\$status"
    printf 'Content-Length: %s\r\n' "\${clen:-\$size}"
    [ -z "\$etag" ] || printf 'ETag: "%s"\r\n' "\$etag"
    printf '\r\n'; } > "\$hdr"
  if [ "\$body" != - ] && [ "\$method" != HEAD ]; then
    if [ -n "\$short" ]; then src() { head -c "\$short" "\$body"; }; else src() { cat "\$body"; }; fi
    if [ "\$out" = - ]; then src; elif [ -n "\$out" ]; then src > "\$out"; fi
  fi
fi
exit "\$rc"
EOF
chmod +x "$BIN/curl"

SECRET='s3cr3t"with\quote'
plan() { : > "$ST/plan"; for l in "$@"; do printf '%s\n' "$l" >> "$ST/plan"; done
         rm -f "$ST/n" "$ST/calls.log" "$ST/argv.log" "$ST/stdin.log" "$ST/uploaded"; }
ncalls() { [ -f "$ST/calls.log" ] && wc -l < "$ST/calls.log" | tr -d ' ' || echo 0; }
# s3 VERB ARGS... — the script under test against the stub, no real sleeps.
# One-stream downloads unless PARALLEL says otherwise: the cases below count
# requests, and the ranged path (HEAD first) has its own section.
s3() {
  PATH="$BIN:$PATH" MINIO_ENDPOINT=http://store.test:9001 MINIO_ACCESS_KEY=ak \
    MINIO_SECRET_KEY="$SECRET" S3_RETRY_DELAY=0 S3_RETRIES="${RETRIES:-3}" \
    S3_PARALLEL="${PARALLEL:-1}" S3_PARALLEL_MIN_BYTES="${PARALLEL_MIN:-33554432}" \
    S3_PART_BYTES="${PART:-33554432}" "$S3RUN" "$S3SH" "$@" > "$T/out" 2> "$T/err"
}
# A file with no temp siblings left behind by s3.sh.
no_temps() { for _f in "$1"/.s3tmp.*; do [ -e "$_f" ] && return 1; done; return 0; }

printf 'payload-1\n' > "$T/obj"
OBJMD5=$(md5sum < "$T/obj" | cut -d' ' -f1)
printf '<?xml version="1.0"?><Error><Code>NoSuchKey</Code></Error>' > "$T/nosuchkey.xml"
printf '<Error><Code>BadDigest</Code></Error>' > "$T/baddigest.xml"
printf '<Error><Code>InvalidArgument</Code></Error>' > "$T/invalid.xml"
printf '<Error><Code>InternalError</Code></Error>' > "$T/internal.xml"

# ---- exit-code contract
plan "0 404 -" "0 200 -"
s3 stat woodpecker/a/b; rc=$?
[ "$rc" -eq 3 ] && [ "$(ncalls)" -eq 2 ] && [ ! -s "$T/err" ] \
  && pass "stat: missing object -> exit 3, not retried (object HEAD + bucket HEAD), nothing logged" \
  || fail "stat missing: rc=$rc calls=$(ncalls)"
plan "0 404 -" "0 404 -"
s3 stat woodpecker/a/b; rc=$?
[ "$rc" -eq 1 ] && grep -q "bucket 'woodpecker' does not exist" "$T/err" && pass "stat: missing bucket -> exit 1 (configuration), not 3" \
  || fail "stat missing bucket: rc=$rc err=$(cat "$T/err")"
plan "0 403 -"
s3 stat woodpecker/a/b; rc=$?
[ "$rc" -eq 4 ] && [ "$(ncalls)" -eq 1 ] && pass "stat: 403 -> exit 4 on the first answer, not retried" \
  || fail "stat 403: rc=$rc calls=$(ncalls)"
plan "0 503 -"
RETRIES=4 s3 stat woodpecker/a/b; rc=$?
[ "$rc" -eq 5 ] && [ "$(ncalls)" -eq 4 ] && pass "stat: 503 retried S3_RETRIES times, then exit 5" \
  || fail "stat 503: rc=$rc calls=$(ncalls)"
plan "7 - -" "28 - -" "0 200 $T/obj etag=$OBJMD5"
s3 stat woodpecker/a/b; rc=$?
[ "$rc" -eq 0 ] && [ "$(ncalls)" -eq 3 ] && [ "$(cat "$T/out")" = "10 $OBJMD5" ] \
  && pass "stat: connect failure and timeout retried to success; prints SIZE ETAG" \
  || fail "stat transient: rc=$rc calls=$(ncalls) out=$(cat "$T/out")"
plan "6 - -"
RETRIES=2 s3 stat woodpecker/a/b; rc=$?
[ "$rc" -eq 5 ] && [ "$(ncalls)" -eq 2 ] && pass "stat: DNS failure (curl 6) is transient -> exit 5" \
  || fail "stat dns: rc=$rc calls=$(ncalls)"
plan "0 400 $T/invalid.xml"
s3 stat woodpecker/a/b; rc=$?
[ "$rc" -eq 1 ] && [ "$(ncalls)" -eq 1 ] && pass "stat: other 4xx -> exit 1, not retried" \
  || fail "stat 400: rc=$rc calls=$(ncalls)"

# ---- get: verified, atomic, never partial
mkdir -p "$T/dl"
plan "0 200 $T/obj etag=auto"
s3 get woodpecker/a/obj "$T/dl/new/file"; rc=$?
[ "$rc" -eq 0 ] && cmp -s "$T/obj" "$T/dl/new/file" && no_temps "$T/dl/new" \
  && grep -q "MD5 $OBJMD5 verified" "$T/err" \
  && pass "get: MD5 verified against the ETag, parent dir created, no temp left" \
  || fail "get happy: rc=$rc err=$(cat "$T/err")"
[ "$(stat -c %a "$T/dl/new/file")" = "$(printf '%o' $(( 0666 & ~0$(umask) )))" ] \
  && pass "get: file gets the umask mode of a plain create, not mktemp's 0600" \
  || fail "get mode: $(stat -c %a "$T/dl/new/file")"
echo old > "$T/dl/keep"
plan "0 200 $T/obj etag=0123456789abcdef0123456789abcdef"
s3 get woodpecker/a/obj "$T/dl/keep"; rc=$?
[ "$rc" -eq 6 ] && [ "$(ncalls)" -eq 3 ] && [ "$(cat "$T/dl/keep")" = old ] && no_temps "$T/dl" \
  && pass "get: MD5 mismatch retried, then exit 6; the old file is untouched, no temp left" \
  || fail "get md5 mismatch: rc=$rc calls=$(ncalls) keep=$(cat "$T/dl/keep")"
plan "0 200 $T/obj etag=auto short=4" "0 200 $T/obj etag=auto"
s3 get woodpecker/a/obj "$T/dl/keep"; rc=$?
[ "$rc" -eq 0 ] && [ "$(ncalls)" -eq 2 ] && cmp -s "$T/obj" "$T/dl/keep" \
  && pass "get: a body shorter than Content-Length is retried, never kept" \
  || fail "get short: rc=$rc calls=$(ncalls)"
plan "18 200 $T/obj etag=auto short=4"
RETRIES=2 s3 get woodpecker/a/obj "$T/dl/keep2"; rc=$?
[ "$rc" -eq 5 ] && [ ! -e "$T/dl/keep2" ] && no_temps "$T/dl" \
  && pass "get: a transfer cut mid-body (curl 18) exits 5 with no file and no temp" \
  || fail "get cut: rc=$rc"
plan "0 200 $T/obj etag=d41d8cd98f00b204e9800998ecf8427e-3"
s3 get woodpecker/a/obj "$T/dl/mp"; rc=$?
[ "$rc" -eq 0 ] && cmp -s "$T/obj" "$T/dl/mp" && grep -q "size verified" "$T/err" \
  && pass "get: a multipart ETag is not treated as an MD5; size is verified and the log says so" \
  || fail "get multipart: rc=$rc err=$(cat "$T/err")"
echo old > "$T/dl/keep3"
plan "0 200 $T/obj etag=d41d8cd98f00b204e9800998ecf8427e-3 short=4"
s3 get woodpecker/a/obj "$T/dl/mpshort"; rc=$?
[ "$rc" -eq 6 ] && [ "$(ncalls)" -eq 3 ] && [ ! -e "$T/dl/mpshort" ] \
  && pass "get: a short body with a multipart ETag (no MD5 to check) is caught by the size check" \
  || fail "get multipart short: rc=$rc calls=$(ncalls)"
plan "0 404 $T/nosuchkey.xml" "0 200 -"
s3 get woodpecker/a/obj "$T/dl/keep3"; rc=$?
[ "$rc" -eq 3 ] && [ "$(cat "$T/dl/keep3")" = old ] && no_temps "$T/dl" \
  && grep -q 'get woodpecker/a/obj: no such object' "$T/err" \
  && pass "get: missing object -> exit 3, says so, destination untouched" \
  || fail "get 404: rc=$rc"
plan "0 403 -"
s3 get woodpecker/a/obj "$T/dl/x403"; rc=$?
[ "$rc" -eq 4 ] && [ "$(ncalls)" -eq 1 ] && [ ! -e "$T/dl/x403" ] && pass "get: 403 -> exit 4, not retried, nothing written" \
  || fail "get 403: rc=$rc calls=$(ncalls)"
mkdir -p "$T/dl/dir"
plan "0 200 $T/obj etag=auto"
s3 get woodpecker/a/obj.bin "$T/dl/dir"; rc=$?
[ "$rc" -eq 0 ] && cmp -s "$T/obj" "$T/dl/dir/obj.bin" && pass "get: into an existing directory lands at DIR/<key basename>" \
  || fail "get into dir: rc=$rc"
plan "0 200 $T/obj etag=auto"
s3 cat woodpecker/a/obj; rc=$?
[ "$rc" -eq 0 ] && cmp -s "$T/obj" "$T/out" && pass "cat: verified bytes on stdout" || fail "cat: rc=$rc"
# Interrupted mid-transfer: SIGTERM while curl is stalled.
echo old > "$T/dl/keep4"
plan "0 200 $T/obj etag=auto sleep=5"
( PATH="$BIN:$PATH" MINIO_ENDPOINT=http://store.test:9001 MINIO_ACCESS_KEY=ak MINIO_SECRET_KEY=x \
    S3_PARALLEL=1 exec "$S3RUN" "$S3SH" get woodpecker/a/obj "$T/dl/keep4" ) 2>/dev/null &
pid=$!
sleep 1; kill -TERM "$pid" 2>/dev/null; wait "$pid"; rc=$?
[ "$rc" -ne 0 ] && [ "$(cat "$T/dl/keep4")" = old ] && no_temps "$T/dl" \
  && pass "get: killed mid-transfer (SIGTERM) leaves the old file and no temp" \
  || fail "get sigterm: rc=$rc keep=$(cat "$T/dl/keep4") $(ls -A "$T/dl")"

# ---- get, large objects: fixed-size byte ranges pinned to one ETag
# Every case below uses 1 MiB parts (PART), so this object is four of them.
head -c 3670021 /dev/urandom > "$T/big"   # 3.5 MiB + 5: four 1 MiB-aligned ranges
BIGMD5=$(md5sum < "$T/big" | cut -d' ' -f1)
PART=1048576; export PART
plan "0 200 $T/big etag=auto"
PARALLEL=4 PARALLEL_MIN=1 s3 get woodpecker/a/big "$T/dl/big"; rc=$?
[ "$rc" -eq 0 ] && cmp -s "$T/big" "$T/dl/big" && [ "$(ncalls)" -eq 5 ] \
  && [ "$(grep -c "If-Match: \"$BIGMD5\"" "$ST/calls.log")" -eq 4 ] \
  && grep -q 'Range: 3145728-3670020' "$ST/calls.log" && grep -q '4 parts' "$T/err" && no_temps "$T/dl" \
  && pass "get large: HEAD, then 4 ranges each pinned by If-Match, assembled and MD5-verified" \
  || fail "get ranged: rc=$rc calls=$(ncalls) err=$(cat "$T/err")"
plan "0 200 $T/big etag=auto"
PARALLEL=3 PARALLEL_MIN=1 s3 get woodpecker/a/big "$T/dl/big3"; rc=$?
[ "$rc" -eq 0 ] && cmp -s "$T/big" "$T/dl/big3" && [ "$(ncalls)" -eq 5 ] && grep -q '4 parts' "$T/err" \
  && [ "$(grep -c 'Range: ' "$ST/calls.log")" -eq 4 ] \
  && pass "get large: more parts than workers (4 parts, 3 workers): each part fetched once, all assembled" \
  || fail "get ranged pool: rc=$rc calls=$(cat "$ST/calls.log") err=$(cat "$T/err")"
plan "0 200 $T/big etag=auto"
PART=1500000 PARALLEL=4 PARALLEL_MIN=1 s3 get woodpecker/a/big "$T/dl/big2"; rc=$?
[ "$rc" -eq 0 ] && cmp -s "$T/big" "$T/dl/big2" && grep -q 'Range: 2097152-3670020' "$ST/calls.log" \
  && grep -q '2 parts' "$T/err" \
  && pass "get large: a part size that is not whole MiB is rounded up (dd seeks in MiB blocks)" \
  || fail "get ranged part rounding: rc=$rc calls=$(cat "$ST/calls.log")"
plan "0 200 $T/big etag=auto" "0 403 -"
PARALLEL=2 PARALLEL_MIN=1 s3 get woodpecker/a/big "$T/dl/big2w403"; rc=$?
[ "$rc" -eq 4 ] && [ "$(ncalls)" -eq 3 ] && [ ! -e "$T/dl/big2w403" ] && no_temps "$T/dl" \
  && pass "get large: a failed part stops the workers starting more (2 workers, 4 parts: 2 requests, exit 4)" \
  || fail "get ranged abort: rc=$rc calls=$(ncalls)"
plan "0 200 $T/obj etag=auto"
PARALLEL=4 s3 get woodpecker/a/obj "$T/dl/small"; rc=$?
[ "$rc" -eq 0 ] && cmp -s "$T/obj" "$T/dl/small" && [ "$(ncalls)" -eq 2 ] && ! grep -q Range "$ST/calls.log" \
  && pass "get small (default settings): HEAD, then one streamed GET" || fail "get small default: rc=$rc calls=$(ncalls)"
echo old > "$T/dl/keepbig"
plan "0 200 $T/big etag=auto bad=1048576"
PARALLEL=4 PARALLEL_MIN=1 s3 get woodpecker/a/big "$T/dl/keepbig"; rc=$?
[ "$rc" -eq 6 ] && [ "$(cat "$T/dl/keepbig")" = old ] && no_temps "$T/dl" && [ "$(ncalls)" -eq 15 ] \
  && pass "get large: one corrupted range -> MD5 mismatch, retried, exit 6, old file kept" \
  || fail "get ranged corrupt: rc=$rc calls=$(ncalls)"
MP=d41d8cd98f00b204e9800998ecf8427e-7
plan "0 200 $T/big etag=$MP badlen=1048576"
PARALLEL=4 PARALLEL_MIN=1 RETRIES=2 s3 get woodpecker/a/big "$T/dl/mplen"; rc=$?
[ "$rc" -eq 6 ] && [ ! -e "$T/dl/mplen" ] && grep -q 'bytes 1048576-2097151: Content-Length 1048575' "$T/err" \
  && pass "get large, multipart ETag: a range answered with the wrong length is caught without an MD5" \
  || fail "get ranged badlen: rc=$rc err=$(cat "$T/err")"
plan "0 200 $T/big etag=$MP lie=3145728"
PARALLEL=4 PARALLEL_MIN=1 RETRIES=2 s3 get woodpecker/a/big "$T/dl/mplie"; rc=$?
[ "$rc" -eq 6 ] && [ ! -e "$T/dl/mplie" ] && grep -q 'assembled 3670020 bytes of 3670021' "$T/err" \
  && pass "get large, multipart ETag: an assembled file short of the object's size is never kept" \
  || fail "get ranged lie: rc=$rc err=$(cat "$T/err")"
plan "0 200 $T/big etag=auto" "0 200 $T/big etag=auto r412=1" "0 200 $T/big etag=auto r412=1" \
  "0 200 $T/big etag=auto r412=1" "0 200 $T/big etag=auto r412=1" "0 200 $T/big etag=auto"
PARALLEL=4 PARALLEL_MIN=1 s3 get woodpecker/a/big "$T/dl/big412"; rc=$?
[ "$rc" -eq 0 ] && cmp -s "$T/big" "$T/dl/big412" && grep -q 'changed while it was being downloaded' "$T/err" \
  && pass "get large: an overwrite mid-download (412) restarts the download from a fresh HEAD" \
  || fail "get ranged 412: rc=$rc err=$(cat "$T/err")"
plan "0 200 $T/big etag=auto" "0 200 $T/big etag=auto norange=1" "0 200 $T/big etag=auto norange=1" \
  "0 200 $T/big etag=auto norange=1" "0 200 $T/big etag=auto norange=1" "0 200 $T/big etag=auto"
PARALLEL=4 PARALLEL_MIN=1 s3 get woodpecker/a/big "$T/dl/bignr"; rc=$?
[ "$rc" -eq 0 ] && cmp -s "$T/big" "$T/dl/bignr" && [ "$(tail -n 1 "$ST/calls.log" | grep -c Range)" -eq 0 ] \
  && pass "get large: a store that ignores Range -> falls back to one stream" \
  || fail "get ranged norange: rc=$rc calls=$(cat "$ST/calls.log")"
plan "0 200 $T/big etag=auto" "0 403 - sleep=1" "0 503 -"
PARALLEL=2 PARALLEL_MIN=1 s3 get woodpecker/a/big "$T/dl/bigmix"; rc=$?
[ "$rc" -eq 4 ] && [ "$(ncalls)" -eq 3 ] && ! grep -q retrying "$T/err" && [ ! -e "$T/dl/bigmix" ] \
  && pass "get large: a 403 on one part and a 503 on another -> the 403 wins: exit 4, no retry" \
  || fail "get ranged 403+503: rc=$rc calls=$(ncalls) err=$(cat "$T/err")"
plan "0 200 $T/big etag=auto" "0 403 -"
PARALLEL=4 PARALLEL_MIN=1 s3 get woodpecker/a/big "$T/dl/big403"; rc=$?
[ "$rc" -eq 4 ] && [ "$(ncalls)" -eq 5 ] && [ ! -e "$T/dl/big403" ] \
  && pass "get large: a 403 on a range is final (exit 4, one attempt)" || fail "get ranged 403: rc=$rc calls=$(ncalls)"
echo old > "$T/dl/keep5"
mkdir -p "$T/tmpd"
plan "0 200 $T/big etag=auto" "0 200 $T/big etag=auto sleep=6"
( PATH="$BIN:$PATH" MINIO_ENDPOINT=http://store.test:9001 MINIO_ACCESS_KEY=ak MINIO_SECRET_KEY=x TMPDIR="$T/tmpd" \
    S3_PARALLEL=4 S3_PARALLEL_MIN_BYTES=1 S3_PART_BYTES=1048576 exec "$S3RUN" "$S3SH" get woodpecker/a/big "$T/dl/keep5" ) 2>/dev/null &
pid=$!
sleep 2; kill -TERM "$pid" 2>/dev/null; wait "$pid"; rc=$?
# The parts must be stopped with it: were they still running, they would write
# their header and status files into TMPDIR once their stall ends.
sleep 6
[ "$rc" -ne 0 ] && [ "$(cat "$T/dl/keep5")" = old ] && no_temps "$T/dl" && [ -z "$(ls -A "$T/tmpd")" ] \
  && pass "get large: killed mid-transfer (SIGTERM): parts stopped, old file kept, no temp anywhere" \
  || fail "get ranged sigterm: rc=$rc dl=$(ls -A "$T/dl") tmpd=$(ls -A "$T/tmpd")"
unset PART

# ---- put: Content-MD5, read-back, single PUT only
plan "0 200 - etag=$OBJMD5" "0 200 $T/obj etag=$OBJMD5"
s3 put "$T/obj" woodpecker/a/obj; rc=$?
b64=$(openssl dgst -md5 -binary "$T/obj" | base64)
[ "$rc" -eq 0 ] && [ "$(ncalls)" -eq 2 ] && cmp -s "$T/obj" "$ST/uploaded" \
  && grep -q "^PUT http://store.test:9001/woodpecker/a/obj|Content-MD5: $b64|" "$ST/calls.log" \
  && grep -q "x-amz-content-sha256: UNSIGNED-PAYLOAD" "$ST/calls.log" \
  && sed -n 2p "$ST/calls.log" | grep -q '^HEAD ' \
  && pass "put: one PUT with Content-MD5 of the file, then a HEAD read-back" \
  || fail "put happy: rc=$rc calls=$(cat "$ST/calls.log")"
plan "0 400 $T/baddigest.xml" "0 200 - etag=$OBJMD5" "0 200 $T/obj etag=$OBJMD5"
s3 put "$T/obj" woodpecker/a/obj; rc=$?
[ "$rc" -eq 0 ] && [ "$(ncalls)" -eq 3 ] && pass "put: 400 BadDigest (bytes changed in flight) is retried" \
  || fail "put baddigest: rc=$rc calls=$(ncalls)"
printf 'payload-1\n' > "$T/grow"; printf 'payload-1\nX' > "$T/grown"
GROWN=$(md5sum < "$T/grown" | cut -d' ' -f1)
plan "0 400 $T/baddigest.xml append=1" "0 200 - etag=$GROWN" "0 200 $T/grown etag=$GROWN"
s3 put "$T/grow" woodpecker/a/g; rc=$?
b64g=$(openssl dgst -md5 -binary "$T/grown" | base64)
[ "$rc" -eq 0 ] && [ "$(ncalls)" -eq 3 ] && sed -n 2p "$ST/calls.log" | grep -q "Content-MD5: $b64g|" \
  && pass "put: a file that changed under an attempt is re-hashed; the retry sends its current MD5" \
  || fail "put rehash: rc=$rc calls=$(cat "$ST/calls.log")"
plan "0 400 $T/invalid.xml"
s3 put "$T/obj" woodpecker/a/obj; rc=$?
[ "$rc" -eq 1 ] && [ "$(ncalls)" -eq 1 ] && pass "put: other 400 -> exit 1, not retried" \
  || fail "put 400: rc=$rc calls=$(ncalls)"
plan "0 200 - etag=ffffffffffffffffffffffffffffffff"
s3 put "$T/obj" woodpecker/a/obj; rc=$?
[ "$rc" -eq 6 ] && [ "$(ncalls)" -eq 3 ] && pass "put: an ETag that is not the file's MD5 -> retried, then exit 6" \
  || fail "put etag mismatch: rc=$rc calls=$(ncalls)"
plan "0 200 - etag=$OBJMD5" "0 200 $T/obj etag=$OBJMD5 clen=3"
RETRIES=1 s3 put "$T/obj" woodpecker/a/obj; rc=$?
[ "$rc" -eq 6 ] && grep -q "read-back is 3 bytes" "$T/err" && pass "put: a read-back of the wrong size -> exit 6" \
  || fail "put readback: rc=$rc err=$(cat "$T/err")"
plan "0 500 $T/internal.xml" "0 200 - etag=$OBJMD5" "0 200 $T/obj etag=$OBJMD5"
s3 put "$T/obj" woodpecker/a/obj; rc=$?
[ "$rc" -eq 0 ] && [ "$(ncalls)" -eq 3 ] && pass "put: 500 retried (a PUT of the same bytes is idempotent)" \
  || fail "put 500: rc=$rc calls=$(ncalls)"
plan "0 200 - etag=$OBJMD5"
S3_MAX_PUT_BYTES=4 s3 put "$T/obj" woodpecker/a/obj; rc=$?
[ "$rc" -eq 1 ] && [ "$(ncalls)" -eq 0 ] && pass "put: over S3_MAX_PUT_BYTES is refused before any request" \
  || fail "put too big: rc=$rc calls=$(ncalls)"
PIPEMD5=$(printf 'piped\n' | md5sum | cut -d' ' -f1)
printf 'piped\n' > "$T/piped"
plan "0 200 - etag=$PIPEMD5" "0 200 $T/piped etag=$PIPEMD5"
printf 'piped\n' | PATH="$BIN:$PATH" MINIO_ENDPOINT=http://store.test:9001 MINIO_ACCESS_KEY=ak \
  MINIO_SECRET_KEY="$SECRET" S3_RETRY_DELAY=0 "$S3RUN" "$S3SH" put - woodpecker/a/p > "$T/out" 2> "$T/err"; rc=$?
[ "$rc" -eq 0 ] && cmp -s "$T/piped" "$ST/uploaded" && pass "put -: stdin is spooled and sent as one verified PUT" \
  || fail "put stdin: rc=$rc"

# ---- copy / rm / ls
printf '<CopyObjectResult><ETag>"%s"</ETag></CopyObjectResult>' "$OBJMD5" > "$T/copyok.xml"
plan "0 200 $T/obj etag=$OBJMD5" "0 200 $T/copyok.xml" "0 200 $T/obj etag=$OBJMD5"
s3 copy woodpecker/a/obj woodpecker/b/obj; rc=$?
[ "$rc" -eq 0 ] && grep -q "x-amz-copy-source: /woodpecker/a/obj" "$ST/calls.log" \
  && pass "copy: server-side copy, verified by size and ETag" || fail "copy: rc=$rc calls=$(cat "$ST/calls.log")"
plan "0 200 $T/obj etag=$OBJMD5" "0 200 $T/copyok.xml" "0 200 $T/obj etag=$OBJMD5 clen=2"
RETRIES=1 s3 copy woodpecker/a/obj woodpecker/b/obj; rc=$?
[ "$rc" -eq 6 ] && pass "copy: a destination that differs from the source -> exit 6" || fail "copy mismatch: rc=$rc"
plan "0 200 $T/obj etag=$OBJMD5" "0 200 $T/internal.xml"
RETRIES=1 s3 copy woodpecker/a/obj woodpecker/b/obj; rc=$?
[ "$rc" -eq 5 ] && pass "copy: a 200 carrying an <Error> body is a failure (exit 5 for InternalError)" \
  || fail "copy 200-error: rc=$rc"
plan "0 404 -" "0 200 -"
s3 copy woodpecker/a/nope woodpecker/b/obj; rc=$?
[ "$rc" -eq 3 ] && grep -q 'copy woodpecker/a/nope: no such object' "$T/err" \
  && pass "copy: missing source -> exit 3, says so" || fail "copy missing: rc=$rc err=$(cat "$T/err")"
plan "0 204 -"
s3 rm woodpecker/a/obj; rc=$?
[ "$rc" -eq 0 ] && grep -q '^DELETE ' "$ST/calls.log" && pass "rm: DELETE" || fail "rm: rc=$rc"
plan "0 404 $T/nosuchkey.xml"
s3 rm woodpecker/a/obj; rc=$?
[ "$rc" -eq 0 ] && pass "rm: an already-absent object is success" || fail "rm absent: rc=$rc"
cat > "$T/ls1.xml" <<'X'
<ListBucketResult><IsTruncated>true</IsTruncated><Contents><Key>p/a&amp;b.tar</Key></Contents><Contents><Key>p/dir/</Key></Contents><Contents><Key>p/q&#34;&#39;&#x9;&lt;x&gt;</Key></Contents><NextContinuationToken>tok/+=&amp;1&#34;</NextContinuationToken></ListBucketResult>
X
cat > "$T/ls2.xml" <<'X'
<ListBucketResult><IsTruncated>false</IsTruncated><CommonPrefixes><Prefix>p/sub/</Prefix></CommonPrefixes><Contents><Key>p/z</Key></Contents></ListBucketResult>
X
plan "0 200 $T/ls1.xml" "0 200 $T/ls2.xml"
s3 ls woodpecker p/; rc=$?
want_ls=$(printf 'p/a&b.tar p/q"\047\t<x> p/z ')
[ "$rc" -eq 0 ] && [ "$(tr '\n' ' ' < "$T/out")" = "$want_ls" ] \
  && sed -n 2p "$ST/calls.log" | grep -q 'continuation-token=tok%2F%2B%3D%261%22&list-type=2&prefix=p%2F' \
  && pass "ls: follows continuation tokens, lists objects only (no folder markers or prefixes), decodes named and numeric XML entities" \
  || fail "ls: rc=$rc out=$(cat "$T/out") calls=$(cat "$ST/calls.log")"
plan "0 404 -"
s3 ls nobucket p/; rc=$?
[ "$rc" -eq 1 ] && pass "ls: missing bucket -> exit 1, never an empty listing" || fail "ls nobucket: rc=$rc"

# ---- secrets, configuration, usage
if ! grep -qF "$SECRET" "$ST/argv.log" 2>/dev/null && grep -qF 'user = "ak:s3cr3t\"with\\quote"' "$ST/stdin.log"; then
  pass "the secret never appears in curl's argv; it arrives on stdin, quoted for curl's config syntax"
else fail "secret handling: argv=$(grep -c . "$ST/argv.log") stdin=$(cat "$ST/stdin.log")"; fi
plan "0 403 -"
PATH="$BIN:$PATH" MINIO_ENDPOINT=http://store.test:9001 MINIO_ACCESS_KEY=ak MINIO_SECRET_KEY="$SECRET" \
  "$S3RUN" -x "$S3SH" stat woodpecker/a/b > "$T/out" 2> "$T/err"
! grep -qF "$SECRET" "$T/err" && pass "sh -x does not trace the secret (xtrace is switched off)" \
  || fail "secret leaked under sh -x"
plan "0 200 $T/obj etag=$OBJMD5"
PATH="$BIN:$PATH" MINIO_ENDPOINT=store.test:9001 MINIO_USE_SSL=true MINIO_ACCESS_KEY=ak MINIO_SECRET_KEY=x \
  "$S3RUN" "$S3SH" stat woodpecker/a/b > /dev/null 2>&1
grep -q '^HEAD https://store.test:9001/woodpecker/a/b' "$ST/calls.log" && pass "endpoint without a scheme + MINIO_USE_SSL=true -> https" \
  || fail "use_ssl: $(cat "$ST/calls.log")"
plan "0 200 $T/obj etag=$OBJMD5"
PATH="$BIN:$PATH" MINIO_ENDPOINT=store.test:9001/ MINIO_ACCESS_KEY=ak MINIO_SECRET_KEY=x \
  "$S3RUN" "$S3SH" stat woodpecker/a/b > /dev/null 2>&1
grep -q '^HEAD http://store.test:9001/woodpecker/a/b' "$ST/calls.log" && pass "endpoint without a scheme defaults to http; trailing / dropped" \
  || fail "no scheme: $(cat "$ST/calls.log")"
for bad in "put $T/obj woodpecker" "get woodpecker" "stat Woodpecker/x" "frob a b" "presign woodpecker/a 604801" \
           "put $T/obj woodpecker/prefix/" "copy woodpecker/a woodpecker/b/"; do
  plan "0 200 -"
  # shellcheck disable=SC2086 # word-split on purpose: one case per string
  s3 $bad; rc=$?
  [ "$rc" -eq 2 ] && [ "$(ncalls)" -eq 0 ] && pass "usage error -> exit 2, no request: $bad" || fail "usage '$bad': rc=$rc"
done
PATH="$BIN:$PATH" MINIO_ENDPOINT='' MINIO_ACCESS_KEY=ak MINIO_SECRET_KEY=x "$S3RUN" "$S3SH" stat woodpecker/a/b > /dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && pass "unset MINIO_ENDPOINT -> exit 2" || fail "no endpoint: rc=$rc"
PATH="$BIN:$PATH" MINIO_ENDPOINT=http://h/path MINIO_ACCESS_KEY=ak MINIO_SECRET_KEY=x "$S3RUN" "$S3SH" stat woodpecker/a/b > /dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && pass "an endpoint with a path -> exit 2" || fail "endpoint path: rc=$rc"

# ------------------------------------------------------------ live
if [ "${S3_TEST_LIVE:-}" = 1 ]; then
  echo "== live: $MINIO_ENDPOINT (curl $(curl --version | head -n 1 | cut -d' ' -f2)) =="
  B=${S3_TEST_BUCKET:?S3_TEST_BUCKET must name a throwaway bucket}
  P="s3-test-$$"
  L="$T/live"; mkdir -p "$L"
  S3_RETRY_DELAY=1; export S3_RETRY_DELAY
  # Test setup only: lanes never create buckets.
  printf 'user = "%s:%s"\n' "$MINIO_ACCESS_KEY" "$MINIO_SECRET_KEY" | \
    curl --config - -sS -o /dev/null --aws-sigv4 aws:amz:us-east-1:s3 -X PUT "${MINIO_ENDPOINT%/}/$B" || true
  head -c 300000 /dev/urandom > "$L/a"
  "$S3RUN" "$S3SH" put "$L/a" "$B/$P/a" 2> "$L/err" && pass "live put" || fail "live put: $(cat "$L/err")"
  out=$("$S3RUN" "$S3SH" stat "$B/$P/a") && [ "$out" = "300000 $(md5sum < "$L/a" | cut -d' ' -f1)" ] \
    && pass "live stat: SIZE and MD5 ETag" || fail "live stat: $out"
  "$S3RUN" "$S3SH" get "$B/$P/a" "$L/a.out" 2> "$L/err" && cmp -s "$L/a" "$L/a.out" && pass "live get: identical bytes" \
    || fail "live get: $(cat "$L/err")"
  head -c 1000 /dev/urandom > "$L/a2"
  "$S3RUN" "$S3SH" put "$L/a2" "$B/$P/a" 2>/dev/null && "$S3RUN" "$S3SH" get "$B/$P/a" "$L/a.out" 2>/dev/null \
    && cmp -s "$L/a2" "$L/a.out" && pass "live overwrite: the new bytes replace the old" || fail "live overwrite"
  "$S3RUN" "$S3SH" stat "$B/$P/missing" > /dev/null 2>&1; rc=$?
  [ "$rc" -eq 3 ] && pass "live stat missing -> 3" || fail "live stat missing: rc=$rc"
  echo old > "$L/keep"
  "$S3RUN" "$S3SH" get "$B/$P/missing" "$L/keep" 2> "$L/err"; rc=$?
  [ "$rc" -eq 3 ] && [ "$(cat "$L/keep")" = old ] && no_temps "$L" && grep -q 'no such object' "$L/err" \
    && pass "live get missing -> 3, says so, destination untouched" \
    || fail "live get missing: rc=$rc"
  "$S3RUN" "$S3SH" stat "s3-test-no-such-bucket-$$/x" > /dev/null 2>&1; rc=$?
  [ "$rc" -eq 1 ] && pass "live missing bucket -> 1" || fail "live missing bucket: rc=$rc"
  MINIO_SECRET_KEY=wrong "$S3RUN" "$S3SH" get "$B/$P/a" "$L/wrong" 2>/dev/null; rc=$?
  [ "$rc" -eq 4 ] && [ ! -e "$L/wrong" ] && pass "live wrong secret -> 4, nothing written" || fail "live wrong creds: rc=$rc"
  MINIO_ENDPOINT=http://127.0.0.1:9 S3_RETRIES=2 S3_CONNECT_TIMEOUT=2 "$S3RUN" "$S3SH" stat "$B/$P/a" > /dev/null 2>&1; rc=$?
  [ "$rc" -eq 5 ] && pass "live unreachable endpoint -> 5 after retries" || fail "live unreachable: rc=$rc"
  "$S3RUN" "$S3SH" copy "$B/$P/a" "$B/$P/c" 2>/dev/null && "$S3RUN" "$S3SH" get "$B/$P/c" "$L/c" 2>/dev/null && cmp -s "$L/a2" "$L/c" \
    && pass "live copy" || fail "live copy"
  printf 'piped\n' | "$S3RUN" "$S3SH" put - "$B/$P/sub/p" 2>/dev/null && [ "$("$S3RUN" "$S3SH" cat "$B/$P/sub/p" 2>/dev/null)" = piped ] \
    && pass "live put - / cat" || fail "live put -/cat"
  got=$(S3_LS_PAGE=1 "$S3RUN" "$S3SH" ls "$B" "$P/" | tr '\n' ' ')
  [ "$got" = "$P/a $P/c $P/sub/p " ] && pass "live ls (one key per page, continuation followed)" || fail "live ls: $got"
  url=$("$S3RUN" "$S3SH" presign "$B/$P/a" 60) && curl -sS -o "$L/pre" "$url" && cmp -s "$L/a2" "$L/pre" \
    && pass "live presigned GET serves the object without credentials" || fail "live presign"
  code=$(curl -s -o /dev/null -w '%{http_code}' "$(printf '%s' "$url" | sed 's/X-Amz-Expires=60/X-Amz-Expires=61/')")
  [ "$code" = 403 ] && pass "live presigned URL with a tampered query -> 403" || fail "live presign tamper: $code"
  "$S3RUN" "$S3SH" rm "$B/$P/sub/p" && "$S3RUN" "$S3SH" rm "$B/$P/sub/p" && [ "$("$S3RUN" "$S3SH" ls "$B" "$P/sub/")" = "" ] \
    && pass "live rm (twice) and ls of the emptied prefix lists no objects" || fail "live rm"
  mb=${S3_TEST_LARGE_MB:-64}
  parts=$(( (mb + 31) / 32 ))
  head -c $((mb * 1048576)) /dev/urandom > "$L/big"
  "$S3RUN" "$S3SH" put "$L/big" "$B/$P/big" 2> "$L/err" && "$S3RUN" "$S3SH" get "$B/$P/big" "$L/big.out" 2>> "$L/err" \
    && cmp -s "$L/big" "$L/big.out" && grep -q "MD5 [0-9a-f]* verified, $parts parts" "$L/err" \
    && pass "live ${mb} MiB round trip: one PUT, $parts If-Match-pinned 32 MiB parts, MD5-verified" \
    || fail "live large: $(cat "$L/err")"
  rm -f "$L/big.out"
  S3_PARALLEL=1 "$S3RUN" "$S3SH" get "$B/$P/big" "$L/big.out" 2> "$L/err" && cmp -s "$L/big" "$L/big.out" \
    && pass "live ${mb} MiB get as one stream, MD5 hashed on the fly" || fail "live large stream: $(cat "$L/err")"
  rm -f "$L/big.out"
  # An object another client uploaded in parts (mc did, for anything over
  # 16 MiB): its ETag is "<md5>-<parts>", not an MD5, and every range of it is
  # pinned with If-Match on that ETag. Built with plain curl, as mc would. The
  # explicit UNSIGNED-PAYLOAD is what s3.sh sends too: curl 7.88 signs a POST
  # body's hash without sending x-amz-content-sha256, and SeaweedFS answers
  # SignatureDoesNotMatch.
  raw() { printf 'user = "%s:%s"\n' "$MINIO_ACCESS_KEY" "$MINIO_SECRET_KEY" | \
            curl --config - -sS --aws-sigv4 aws:amz:us-east-1:s3 \
              --header 'x-amz-content-sha256: UNSIGNED-PAYLOAD' "$@"; }
  head -c 5242880 /dev/urandom > "$L/p1"; head -c 3000000 /dev/urandom > "$L/p2"; cat "$L/p1" "$L/p2" > "$L/mp"
  id=$(raw -X POST "${MINIO_ENDPOINT%/}/$B/$P/mp?uploads=" | tr -d '\r\n' | sed -n 's:.*<UploadId>\([^<]*\)</UploadId>.*:\1:p')
  eid=$(vec http://h k s 20130524T000000Z s3_uriencode "$id")
  e1=$(raw -D - -o /dev/null -T "$L/p1" "${MINIO_ENDPOINT%/}/$B/$P/mp?partNumber=1&uploadId=$eid" | tr -d '\r' | sed -n 's/^[Ee][Tt][Aa][Gg]: *//p')
  e2=$(raw -D - -o /dev/null -T "$L/p2" "${MINIO_ENDPOINT%/}/$B/$P/mp?partNumber=2&uploadId=$eid" | tr -d '\r' | sed -n 's/^[Ee][Tt][Aa][Gg]: *//p')
  printf '<CompleteMultipartUpload><Part><PartNumber>1</PartNumber><ETag>%s</ETag></Part><Part><PartNumber>2</PartNumber><ETag>%s</ETag></Part></CompleteMultipartUpload>' "$e1" "$e2" > "$L/complete.xml"
  raw -o /dev/null -X POST --data-binary @"$L/complete.xml" "${MINIO_ENDPOINT%/}/$B/$P/mp?uploadId=$eid"
  etag=$("$S3RUN" "$S3SH" stat "$B/$P/mp" 2>/dev/null | cut -d' ' -f2)
  case "$etag" in *-2) ;; *) fail "live multipart setup: ETag '$etag' (upload id '$id')" ;; esac
  S3_PARALLEL_MIN_BYTES=1 S3_PART_BYTES=1048576 "$S3RUN" "$S3SH" get "$B/$P/mp" "$L/mp.out" 2> "$L/err" \
    && cmp -s "$L/mp" "$L/mp.out" && grep -q 'size verified, 8 parts' "$L/err" \
    && pass "live multipart-uploaded object ($etag): ranged get pinned by If-Match on its ETag" \
    || fail "live multipart get: $(cat "$L/err")"
  # The pin the ranged download relies on: a range asked for under an ETag the
  # object no longer has must be refused, not served.
  code=$(raw -o /dev/null -w '%{http_code}' --range 0-9 \
    --header 'If-Match: "00000000000000000000000000000000"' "${MINIO_ENDPOINT%/}/$B/$P/mp")
  [ "$code" = 412 ] && pass "live: a range pinned to an ETag the object does not have -> 412" \
    || fail "live If-Match mismatch: HTTP $code"
  for k in a c big mp; do "$S3RUN" "$S3SH" rm "$B/$P/$k" 2>/dev/null; done
fi

echo
if [ "$fails" -eq 0 ]; then echo "ALL PASS"; else echo "FAILED: $fails"; exit 1; fi
