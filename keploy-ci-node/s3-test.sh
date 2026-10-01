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
#      S3_TEST_VIRTUAL_ENDPOINT, when set, is an endpoint that serves
#      virtual-host addressing (bucket.host), e.g. SeaweedFS run with
#      -s3.domainName=localhost at http://localhost:8333: the round trip is
#      repeated there with S3_ADDRESSING=virtual.
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
#   bad=START  corrupt the first byte of the range that starts at START (a
#              byte other than the one there, whatever the random data holds)
#   badlen=START    answer that range one byte short, and say so in Content-Length
#   lie=START       answer that range one byte short, claiming the full length
#   append=1        after taking an upload, append a byte to the local file
#                   (the file changed while it was being sent)
#   grow=PATH       after taking this request, append a byte to PATH (the
#                   source of a multipart upload changed under it)
#   flip=PATH@N     after taking this request, overwrite byte N of PATH (same
#                   size, different content)
#   etag=up         the ETag is the MD5 of the uploaded body (a multipart part)
#   meta=HEX|auto   send x-amz-meta-s3sh-md5 (auto = MD5 of BODY)
#   hdr=NAME:VALUE  send one more response header (repeatable)
# `curl --version` answers "curl $STUB_CURL_VERSION" (8.14.1) and is not a request.
BIN="$T/bin"; ST="$T/state"
mkdir -p "$BIN" "$ST"
cat > "$BIN/curl" <<EOF
#!/bin/sh
ST="$ST"
if [ "\${1:-}" = --version ]; then echo "curl \${STUB_CURL_VERSION:-8.14.1} (x86_64-pc-linux-gnu) stub"; exit 0; fi
# Parallel range requests arrive at once: each takes the next plan line by
# creating the lowest-numbered claim directory still free (mkdir is atomic).
# No lock: s3.sh TERMs its in-flight fetches after a failure, and a request
# killed while holding a lock left it behind, so the next case hung forever.
# Starting at the last claim seen only skips slots that are already taken.
n=\$(cat "\$ST/hint" 2>/dev/null || echo 0); n=\$((\${n:-0} + 1))
until mkdir "\$ST/req.\$n" 2>/dev/null; do n=\$((n + 1)); done
echo "\$n" > "\$ST/hint"
printf '%s\n' "\$*" >> "\$ST/argv.log"
cat >> "\$ST/stdin.log"
hdr=; out=; method=GET; url=; up=; headers=; range=; post=
while [ \$# -gt 0 ]; do
  case "\$1" in
    --dump-header) hdr=\$2; shift ;;
    --output) out=\$2; shift ;;
    --head) method=HEAD ;;
    --request) method=\$2; shift ;;
    --upload-file) method=PUT; up=\$2; shift ;;
    --header) headers="\$headers|\$2"; shift ;;
    --range) range=\$2; shift ;;
    --data-binary) post=\${2#@}; shift ;;
    --config|--aws-sigv4|--connect-timeout|--speed-limit|--speed-time|--max-time|--cacert) shift ;;
    -*) ;;
    *) url=\$1 ;;
  esac
  shift
done
echo "\$method \$url\$headers\${range:+|Range: \$range}" >> "\$ST/calls.log"
line=\$(sed -n "\${n}p" "\$ST/plan"); [ -n "\$line" ] || line=\$(tail -n 1 "\$ST/plan")
set -- \$line
rc=\$1; status=\$2; body=\$3; shift 3
etag=; clen=; short=; slp=; norange=; r412=; bad=; badlen=; lie=; append=; grow=; meta=; xh=; flip=
for kv in "\$@"; do
  case "\$kv" in
    etag=*) etag=\${kv#etag=} ;; clen=*) clen=\${kv#clen=} ;;
    short=*) short=\${kv#short=} ;; sleep=*) slp=\${kv#sleep=} ;;
    norange=*) norange=1 ;; r412=*) r412=1 ;; bad=*) bad=\${kv#bad=} ;;
    badlen=*) badlen=\${kv#badlen=} ;; lie=*) lie=\${kv#lie=} ;; append=*) append=1 ;;
    grow=*) grow=\${kv#grow=} ;; meta=*) meta=\${kv#meta=} ;; hdr=*) xh="\$xh \${kv#hdr=}" ;;
    flip=*) flip=\${kv#flip=} ;;
  esac
done
[ -z "\$up" ] || { cp "\$up" "\$ST/uploaded"; cat "\$up" >> "\$ST/uploaded.all"; }
[ -z "\$post" ] || cp "\$post" "\$ST/posted"
[ -z "\$up" ] || [ -z "\$append" ] || printf X >> "\$up"
[ -z "\$grow" ] || printf X >> "\$grow"
if [ -n "\$flip" ]; then
  # A byte other than the one there: the random data holds a Z one time in 256.
  # Compared by value: a NUL or newline would not survive \$(...) as a byte.
  fc=Z; [ "\$(tail -c +\$((\${flip#*@} + 1)) "\${flip%@*}" | head -c 1 | od -An -tu1 | tr -d ' ')" != 90 ] || fc=Y
  printf %s "\$fc" | dd of="\${flip%@*}" bs=1 seek="\${flip#*@}" conv=notrunc 2>/dev/null
fi
[ -z "\$slp" ] || sleep "\$slp"
[ "\$etag" != auto ] || etag=\$(md5sum < "\$body" | cut -d' ' -f1)
[ "\$etag" != up ] || etag=\$(md5sum < "\$up" | cut -d' ' -f1)
[ "\$meta" != auto ] || meta=\$(md5sum < "\$body" | cut -d' ' -f1)
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
  # The range goes where curl was told: stdout (get's dd) or a file (cat).
  emit() { if [ -n "\$out" ] && [ "\$out" != - ]; then cat > "\$out"; else cat; fi; }
  if [ "\$a" = "\$bad" ]; then
    # A byte other than the one there: the random data holds an X one time in
    # 256, and the range would then go out whole (pipeline 10085).
    bc=X; [ "\$(tail -c +\$((a + 1)) "\$body" | head -c 1 | od -An -tu1 | tr -d ' ')" != 88 ] || bc=Y
    { printf %s "\$bc"; tail -c +\$((a + 2)) "\$body" | head -c \$((b - a)); } | emit
  else
    tail -c +\$((a + 1)) "\$body" | head -c "\$send" | emit
  fi
  exit "\$rc"
fi
if [ "\$status" != - ]; then
  size=0; [ "\$body" = - ] || size=\$(wc -c < "\$body" | tr -d ' ')
  { printf 'HTTP/1.1 %s X\r\n' "\$status"
    printf 'Content-Length: %s\r\n' "\${clen:-\$size}"
    [ -z "\$etag" ] || printf 'ETag: "%s"\r\n' "\$etag"
    [ -z "\$meta" ] || printf 'X-Amz-Meta-S3sh-Md5: %s\r\n' "\$meta"
    for h in \$xh; do printf '%s: %s\r\n' "\${h%%:*}" "\${h#*:}"; done
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
         rm -f "$ST/hint" "$ST/calls.log" "$ST/argv.log" "$ST/stdin.log" "$ST/uploaded" "$ST/uploaded.all" "$ST/posted"
         rm -rf "$ST"/req.*; }
ncalls() { [ -f "$ST/calls.log" ] && wc -l < "$ST/calls.log" | tr -d ' ' || echo 0; }
# s3 VERB ARGS... — the script under test against the stub, no real sleeps.
# One-stream downloads unless PARALLEL says otherwise: the cases below count
# requests, and the ranged path (HEAD first) has its own section.
s3() {
  PATH="$BIN:$PATH" MINIO_ENDPOINT="${EP:-http://store.test:9001}" MINIO_ACCESS_KEY=ak \
    MINIO_SECRET_KEY="$SECRET" S3_RETRY_DELAY=0 S3_RETRIES="${RETRIES:-3}" \
    S3_PARALLEL="${PARALLEL:-1}" S3_PARALLEL_MIN_BYTES="${PARALLEL_MIN:-33554432}" \
    S3_PART_BYTES="${PART:-33554432}" S3_MAX_PUT_BYTES="${MAXPUT:-5368709120}" \
    S3_PUT_PART_BYTES="${PUTPART:-268435456}" "$S3RUN" "$S3SH" "$@" > "$T/out" 2> "$T/err"
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
plan "0 200 $T/obj etag=d41d8cd98f00b204e9800998ecf8427e-3 meta=auto"
s3 get woodpecker/a/obj "$T/dl/mpmeta"; rc=$?
[ "$rc" -eq 0 ] && cmp -s "$T/obj" "$T/dl/mpmeta" && grep -q "MD5 $OBJMD5 verified (x-amz-meta-s3sh-md5)" "$T/err" \
  && pass "get: a multipart object s3.sh wrote is MD5-verified against its x-amz-meta-s3sh-md5" \
  || fail "get multipart meta: rc=$rc err=$(cat "$T/err")"
plan "0 200 $T/obj etag=$OBJMD5 meta=ffffffffffffffffffffffffffffffff"
RETRIES=2 s3 get woodpecker/a/obj "$T/dl/badmeta"; rc=$?
[ "$rc" -eq 6 ] && [ ! -e "$T/dl/badmeta" ] && grep -q "want ffffffffffffffffffffffffffffffff (x-amz-meta-s3sh-md5; ETag $OBJMD5 differs)" "$T/err" \
  && pass "get: bytes that do not match x-amz-meta-s3sh-md5 -> exit 6, even with a matching ETag" \
  || fail "get bad meta: rc=$rc err=$(cat "$T/err")"
plan "0 200 $T/obj etag=0123456789abcdef0123456789abcdef hdr=x-amz-server-side-encryption:aws:kms"
s3 get woodpecker/a/obj "$T/dl/kms"; rc=$?
[ "$rc" -eq 0 ] && cmp -s "$T/obj" "$T/dl/kms" && grep -q 'size verified (SSE-KMS/SSE-C' "$T/err" \
  && pass "get: under SSE-KMS an MD5-shaped ETag is not taken for an MD5; size is verified and the log says so" \
  || fail "get sse-kms: rc=$rc err=$(cat "$T/err")"
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

# ---- cat: streamed as verified ranges; the last one waits for the MD5
mkdir -p "$T/tmpc"
cats() { TMPDIR="$T/tmpc" PARALLEL_MIN=1 s3 cat "$@"; }
plan "0 200 $T/big etag=auto"
PARALLEL=4 cats woodpecker/a/big; rc=$?
[ "$rc" -eq 0 ] && cmp -s "$T/big" "$T/out" && [ "$(ncalls)" -eq 5 ] \
  && [ "$(grep -c "If-Match: \"$BIGMD5\"" "$ST/calls.log")" -eq 4 ] && grep -q "MD5 $BIGMD5 verified, 4 ranges" "$T/err" \
  && [ -z "$(ls -A "$T/tmpc")" ] \
  && pass "cat: HEAD, then 4 If-Match-pinned ranges written in order, MD5-verified, no temp left" \
  || fail "cat ranged: rc=$rc calls=$(ncalls) err=$(cat "$T/err") tmp=$(ls -A "$T/tmpc")"
plan "0 200 $T/big etag=auto bad=1048576"
PARALLEL=2 cats woodpecker/a/big; rc=$?
[ "$rc" -eq 6 ] && [ "$(wc -c < "$T/out" | tr -d ' ')" -eq 3145728 ] && [ "$(ncalls)" -eq 5 ] \
  && grep -q 'its last 524293 bytes were not written' "$T/err" && [ -z "$(ls -A "$T/tmpc")" ] \
  && pass "cat: a corrupt range -> exit 6 with the last range withheld (the stream ends short, never whole)" \
  || fail "cat corrupt: rc=$rc out=$(wc -c < "$T/out") calls=$(ncalls) err=$(cat "$T/err")"
plan "0 200 $T/obj etag=0123456789abcdef0123456789abcdef"
cats woodpecker/a/obj; rc=$?
[ "$rc" -eq 6 ] && [ ! -s "$T/out" ] \
  && pass "cat: an object of one range whose MD5 is wrong -> exit 6 and not a byte written" \
  || fail "cat one-range md5: rc=$rc out=$(wc -c < "$T/out")"
plan "0 200 $T/big etag=auto" "0 200 $T/big etag=auto badlen=0" "0 200 $T/big etag=auto"
PARALLEL=1 cats woodpecker/a/big; rc=$?
[ "$rc" -eq 0 ] && cmp -s "$T/big" "$T/out" && [ "$(ncalls)" -eq 6 ] && grep -q 'bytes 0-1048575: .*attempt 1/3 failed' "$T/err" \
  && pass "cat: a short range is fetched again on its own before anything is written" \
  || fail "cat short range: rc=$rc calls=$(ncalls) err=$(cat "$T/err")"
plan "0 200 $T/big etag=auto" "0 200 $T/big etag=auto r412=1" "0 200 $T/big etag=auto"
PARALLEL=1 cats woodpecker/a/big; rc=$?
[ "$rc" -eq 0 ] && cmp -s "$T/big" "$T/out" && [ "$(grep -c '^HEAD ' "$ST/calls.log")" -eq 2 ] \
  && grep -q 'changed before the first byte was written' "$T/err" \
  && pass "cat: an overwrite (412) before the first byte -> starts over from a fresh HEAD" \
  || fail "cat 412 early: rc=$rc calls=$(cat "$ST/calls.log") err=$(cat "$T/err")"
plan "0 200 $T/big etag=auto" "0 200 $T/big etag=auto" "0 200 $T/big etag=auto" "0 200 $T/big etag=auto r412=1"
PARALLEL=1 cats woodpecker/a/big; rc=$?
[ "$rc" -eq 6 ] && [ "$(wc -c < "$T/out" | tr -d ' ')" -eq 2097152 ] && grep -q 'changed after 2097152 bytes had been written' "$T/err" \
  && pass "cat: an overwrite (412) mid-stream -> exit 6; ranges of two versions are never joined" \
  || fail "cat 412 late: rc=$rc out=$(wc -c < "$T/out") err=$(cat "$T/err")"
plan "0 404 -" "0 200 -"
cats woodpecker/a/nope; rc=$?
[ "$rc" -eq 3 ] && [ ! -s "$T/out" ] && pass "cat: missing object -> exit 3, nothing written" || fail "cat 404: rc=$rc"
plan "0 200 $T/big etag=auto" "0 403 -"
PARALLEL=2 cats woodpecker/a/big; rc=$?
[ "$rc" -eq 4 ] && [ ! -s "$T/out" ] && [ -z "$(ls -A "$T/tmpc")" ] \
  && pass "cat: a range refused (403) -> exit 4, nothing written, no temp left" || fail "cat 403: rc=$rc"
plan "0 200 $T/big etag=$MP"
cats woodpecker/a/big; rc=$?
[ "$rc" -eq 0 ] && cmp -s "$T/big" "$T/out" && grep -q 'size verified' "$T/err" \
  && pass "cat: a multipart ETag without metadata -> every range and the total checked by size, and the log says so" \
  || fail "cat multipart: rc=$rc err=$(cat "$T/err")"
plan "0 200 $T/big etag=$MP meta=auto"
cats woodpecker/a/big; rc=$?
[ "$rc" -eq 0 ] && cmp -s "$T/big" "$T/out" && grep -q "MD5 $BIGMD5 verified (x-amz-meta-s3sh-md5), 4 ranges" "$T/err" \
  && pass "cat: a multipart object s3.sh wrote -> MD5-verified against its metadata" \
  || fail "cat multipart meta: rc=$rc err=$(cat "$T/err")"
plan "0 200 $T/big etag=auto norange=1"
PARALLEL=2 cats woodpecker/a/big; rc=$?
[ "$rc" -eq 0 ] && cmp -s "$T/big" "$T/out" && grep -q 'ignores Range' "$T/err" && [ -z "$(ls -A "$T/tmpc")" ] \
  && pass "cat: a store that ignores Range -> one verified whole download, then written" \
  || fail "cat norange: rc=$rc err=$(cat "$T/err")"
: > "$T/empty"
plan "0 200 $T/empty etag=d41d8cd98f00b204e9800998ecf8427e"
cats woodpecker/a/empty; rc=$?
[ "$rc" -eq 0 ] && [ ! -s "$T/out" ] && [ "$(ncalls)" -eq 1 ] && pass "cat: an empty object -> nothing to fetch, MD5 of nothing verified" \
  || fail "cat empty: rc=$rc calls=$(ncalls) err=$(cat "$T/err")"
plan "0 200 $T/big etag=auto"
{ PATH="$BIN:$PATH" MINIO_ENDPOINT=http://store.test:9001 MINIO_ACCESS_KEY=ak MINIO_SECRET_KEY=x TMPDIR="$T/tmpc" \
    S3_PARALLEL=2 S3_PART_BYTES=1048576 "$S3RUN" "$S3SH" cat woodpecker/a/big 2> "$T/err"; echo $? > "$T/rc"; } | head -c 100 > /dev/null
rc=$(cat "$T/rc")
[ "$rc" -eq 1 ] && grep -q 'the reader went away' "$T/err" && [ -z "$(ls -A "$T/tmpc")" ] \
  && pass "cat: a reader that stops early -> exit 1, fetches stopped, no temp left" \
  || fail "cat reader gone: rc=$rc err=$(cat "$T/err") tmp=$(ls -A "$T/tmpc")"
plan "0 200 $T/big etag=auto" "0 200 $T/big etag=auto sleep=6"
( PATH="$BIN:$PATH" MINIO_ENDPOINT=http://store.test:9001 MINIO_ACCESS_KEY=ak MINIO_SECRET_KEY=x TMPDIR="$T/tmpc" \
    S3_PARALLEL=4 S3_PART_BYTES=1048576 exec "$S3RUN" "$S3SH" cat woodpecker/a/big ) > "$T/out" 2>/dev/null &
pid=$!
sleep 2; kill -TERM "$pid" 2>/dev/null; wait "$pid"; rc=$?
sleep 6
[ "$rc" -ne 0 ] && [ ! -s "$T/out" ] && [ -z "$(ls -A "$T/tmpc")" ] \
  && pass "cat: killed mid-stream (SIGTERM): fetches stopped, no temp anywhere" \
  || fail "cat sigterm: rc=$rc tmp=$(ls -A "$T/tmpc")"
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
plan "0 200 - etag=$OBJMD5" "0 200 $T/obj etag=$OBJMD5"
s3 put "$T/obj" woodpecker/a/obj; rc=$?
[ "$rc" -eq 0 ] && sed -n 1p "$ST/calls.log" | grep -q "|x-amz-meta-s3sh-md5: $OBJMD5|" \
  && pass "put: the file's MD5 travels as x-amz-meta-s3sh-md5 (what get verifies when the ETag cannot be)" \
  || fail "put meta: rc=$rc calls=$(cat "$ST/calls.log")"
plan "0 200 - etag=$OBJMD5" "0 200 $T/obj etag=$OBJMD5 meta=ffffffffffffffffffffffffffffffff"
RETRIES=1 s3 put "$T/obj" woodpecker/a/obj; rc=$?
[ "$rc" -eq 6 ] && grep -q 'read-back x-amz-meta-s3sh-md5 is ffff' "$T/err" \
  && pass "put: a read-back whose x-amz-meta-s3sh-md5 is not the file's -> exit 6" \
  || fail "put meta readback: rc=$rc err=$(cat "$T/err")"
# SSE-KMS: the store's ETag is not an MD5 of the bytes, whatever it looks like.
# Content-MD5 still makes the store check them; the read-back checks size and
# x-amz-meta-s3sh-md5 instead of the ETag.
KMS=hdr=x-amz-server-side-encryption:aws:kms
OPAQUE=0123456789abcdef0123456789abcdef
plan "0 200 - etag=$OPAQUE $KMS" "0 200 $T/obj etag=$OPAQUE $KMS meta=auto"
s3 put "$T/obj" woodpecker/a/obj; rc=$?
[ "$rc" -eq 0 ] && [ "$(ncalls)" -eq 2 ] && pass "put: under SSE-KMS the opaque ETag is not compared to the MD5; size and metadata are" \
  || fail "put sse-kms: rc=$rc calls=$(ncalls) err=$(cat "$T/err")"
plan "0 200 - etag=$OPAQUE hdr=x-amz-server-side-encryption-customer-algorithm:AES256" \
  "0 200 $T/obj etag=$OPAQUE hdr=x-amz-server-side-encryption-customer-algorithm:AES256 meta=auto"
s3 put "$T/obj" woodpecker/a/obj; rc=$?
[ "$rc" -eq 0 ] && pass "put: under SSE-C likewise" || fail "put sse-c: rc=$rc err=$(cat "$T/err")"

# ---- put, multipart: over S3_MAX_PUT_BYTES (1 MiB here, 5 GiB by default)
head -c 2621447 /dev/urandom > "$T/mpf"          # 2.5 MiB + 7: parts of 1, 1 and 0.5 MiB
MPMD5=$(md5sum < "$T/mpf" | cut -d' ' -f1)
mp_want() { # $1 = file: the ETag S3 gives it uploaded in 1 MiB parts
  _n=$(( ($(wc -c < "$1") + 1048575) / 1048576 ))
  _k=0; { while [ "$_k" -lt "$_n" ]; do
    dd if="$1" bs=1048576 skip="$_k" count=1 2>/dev/null | openssl dgst -md5 -binary; _k=$((_k + 1)); done
  } | openssl dgst -md5 -r | cut -d' ' -f1 | sed "s/\$/-$_n/"
}
WANTMP=$(mp_want "$T/mpf")
printf '<InitiateMultipartUploadResult><Bucket>woodpecker</Bucket><Key>a/mp</Key><UploadId>up+id/1=</UploadId></InitiateMultipartUploadResult>' > "$T/mpinit.xml"
printf '<CompleteMultipartUploadResult><ETag>&quot;%s&quot;</ETag></CompleteMultipartUploadResult>' "$WANTMP" > "$T/mpdone.xml"
EID='up%2Bid%2F1%3D'
mps() { MAXPUT=1048576 PUTPART=1048576 s3 "$@"; }
plan "0 200 $T/mpinit.xml" "0 200 - etag=up" "0 200 - etag=up" "0 200 - etag=up" "0 200 $T/mpdone.xml" \
  "0 200 $T/mpf etag=$WANTMP meta=auto"
mps put "$T/mpf" woodpecker/a/mp; rc=$?
p2=$(dd if="$T/mpf" bs=1048576 skip=1 count=1 2>/dev/null | openssl dgst -md5 -binary | base64)
[ "$rc" -eq 0 ] && [ "$(ncalls)" -eq 6 ] && cmp -s "$T/mpf" "$ST/uploaded.all" \
  && sed -n 1p "$ST/calls.log" | grep -q "^POST http://store.test:9001/woodpecker/a/mp?uploads=|.*x-amz-meta-s3sh-md5: $MPMD5" \
  && sed -n 3p "$ST/calls.log" | grep -q "^PUT http://store.test:9001/woodpecker/a/mp?partNumber=2&uploadId=$EID|Content-MD5: $p2|" \
  && sed -n 5p "$ST/calls.log" | grep -q "^POST http://store.test:9001/woodpecker/a/mp?uploadId=$EID|" \
  && [ "$(grep -o '<Part>' "$ST/posted" | wc -l | tr -d ' ')" -eq 3 ] && sed -n 6p "$ST/calls.log" | grep -q '^HEAD ' \
  && grep -q "put woodpecker/a/mp: 2621447 bytes in 3 parts, MD5 $MPMD5 verified" "$T/err" \
  && pass "put multipart: 3 parts with their own Content-MD5, the whole MD5 as metadata, the completed ETag and a HEAD checked" \
  || fail "put multipart: rc=$rc calls=$(cat "$ST/calls.log") err=$(cat "$T/err")"
plan "0 200 $T/mpinit.xml" "0 200 - etag=up" "0 500 $T/internal.xml" "0 200 - etag=up" "0 200 - etag=up" \
  "0 200 $T/mpdone.xml" "0 200 $T/mpf etag=$WANTMP meta=auto"
mps put "$T/mpf" woodpecker/a/mp; rc=$?
[ "$rc" -eq 0 ] && [ "$(grep -c 'partNumber=2&' "$ST/calls.log")" -eq 2 ] && [ "$(grep -c '?uploads=' "$ST/calls.log")" -eq 1 ] \
  && pass "put multipart: a part answered 500 is retried alone, in the same upload" \
  || fail "put multipart part retry: rc=$rc calls=$(cat "$ST/calls.log")"
plan "0 200 $T/mpinit.xml" "0 200 - etag=up" "0 403 -"
mps put "$T/mpf" woodpecker/a/mp; rc=$?
[ "$rc" -eq 4 ] && tail -n 1 "$ST/calls.log" | grep -q "^DELETE http://store.test:9001/woodpecker/a/mp?uploadId=$EID" \
  && pass "put multipart: a part refused (403) -> exit 4, and the upload is aborted" \
  || fail "put multipart abort: rc=$rc calls=$(cat "$ST/calls.log")"
plan "0 200 $T/mpinit.xml" "0 200 - etag=0123456789abcdef0123456789abcdef"
RETRIES=2 mps put "$T/mpf" woodpecker/a/mp; rc=$?
[ "$rc" -eq 6 ] && [ "$(grep -c '?uploads=' "$ST/calls.log")" -eq 1 ] && [ "$(grep -c 'partNumber=1&' "$ST/calls.log")" -eq 2 ] \
  && tail -n 1 "$ST/calls.log" | grep -q '^DELETE ' \
  && pass "put multipart: a part whose ETag is not its MD5 is retried, then exit 6 (aborted, not restarted)" \
  || fail "put multipart part etag: rc=$rc calls=$(cat "$ST/calls.log")"
cp "$T/mpf" "$T/mpsrc"; cp "$T/mpf" "$T/mpgrown"; printf X >> "$T/mpgrown"
WANTGROWN=$(mp_want "$T/mpgrown")
plan "0 200 $T/mpinit.xml" "0 200 - etag=up grow=$T/mpsrc" "0 200 - etag=up" "0 204 -" \
  "0 200 $T/mpinit.xml" "0 200 - etag=up" "0 200 - etag=up" "0 200 - etag=up" "0 200 -" \
  "0 200 $T/mpgrown etag=$WANTGROWN meta=auto"
mps put "$T/mpsrc" woodpecker/a/mp; rc=$?
[ "$rc" -eq 0 ] && [ "$(grep -c '?uploads=' "$ST/calls.log")" -eq 2 ] && sed -n 4p "$ST/calls.log" | grep -q '^DELETE ' \
  && [ "$(sed -n 5,8p "$ST/calls.log" | grep -c "^PUT ")" -eq 3 ] && grep -q 'changed size while it was being uploaded' "$T/err" \
  && grep -q "2621448 bytes in 3 parts, MD5 $(md5sum < "$T/mpgrown" | cut -d' ' -f1) verified" "$T/err" \
  && pass "put multipart: a file that grows mid-upload is caught, the upload aborted and sent again as it is now" \
  || fail "put multipart grow: rc=$rc calls=$(cat "$ST/calls.log") err=$(cat "$T/err")"
cp "$T/mpf" "$T/mpsrc"; cp "$T/mpf" "$T/mpflip"
# The byte the stub's flip= writes there: Z, or Y where the random data has a Z.
FLIPAT=2200000
fc=Z; [ "$(tail -c +$((FLIPAT + 1)) "$T/mpf" | head -c 1 | od -An -tu1 | tr -d ' ')" != 90 ] || fc=Y
printf %s "$fc" | dd of="$T/mpflip" bs=1 seek=$FLIPAT conv=notrunc 2>/dev/null
WANTFLIP=$(mp_want "$T/mpflip")
plan "0 200 $T/mpinit.xml" "0 200 - etag=up flip=$T/mpsrc@$FLIPAT" "0 200 - etag=up" "0 200 - etag=up" "0 204 -" \
  "0 200 $T/mpinit.xml" "0 200 - etag=up" "0 200 - etag=up" "0 200 - etag=up" "0 200 -" \
  "0 200 $T/mpflip etag=$WANTFLIP meta=auto"
mps put "$T/mpsrc" woodpecker/a/mp; rc=$?
[ "$rc" -eq 0 ] && [ "$(grep -c '?uploads=' "$ST/calls.log")" -eq 2 ] && sed -n 5p "$ST/calls.log" | grep -q '^DELETE ' \
  && grep -q 'changed while it was being uploaded (sent MD5' "$T/err" \
  && pass "put multipart: a file rewritten in place mid-upload (same size) is caught by the MD5 of what was sent" \
  || fail "put multipart flip: rc=$rc calls=$(cat "$ST/calls.log") err=$(cat "$T/err")"
printf '<CompleteMultipartUploadResult><ETag>&quot;ffffffffffffffffffffffffffffffff-3&quot;</ETag></CompleteMultipartUploadResult>' > "$T/mpbad.xml"
plan "0 200 $T/mpinit.xml" "0 200 - etag=up" "0 200 - etag=up" "0 200 - etag=up" "0 200 $T/mpbad.xml"
RETRIES=1 mps put "$T/mpf" woodpecker/a/mp; rc=$?
[ "$rc" -eq 6 ] && grep -q "complete answered ETag ffffffffffffffffffffffffffffffff-3; want $WANTMP" "$T/err" \
  && pass "put multipart: a completed ETag that is not the MD5 of the part MD5s -> exit 6" \
  || fail "put multipart final etag: rc=$rc err=$(cat "$T/err")"
printf '<Error><Code>InternalError</Code></Error>' > "$T/mperr.xml"
plan "0 200 $T/mpinit.xml" "0 200 - etag=up" "0 200 - etag=up" "0 200 - etag=up" "0 200 $T/mperr.xml" \
  "0 200 $T/mpdone.xml" "0 200 $T/mpf etag=$WANTMP meta=auto"
mps put "$T/mpf" woodpecker/a/mp; rc=$?
[ "$rc" -eq 0 ] && [ "$(grep -c '?uploadId=' "$ST/calls.log")" -eq 2 ] \
  && pass "put multipart: a complete answered 200 with an <Error> body is retried" \
  || fail "put multipart complete error: rc=$rc calls=$(cat "$ST/calls.log")"
plan "0 200 $T/mpinit.xml" "0 200 - etag=up" "0 200 - etag=up" "0 200 - etag=up" "0 404 $T/nosuchkey.xml" \
  "0 200 $T/mpf etag=$WANTMP meta=auto"
mps put "$T/mpf" woodpecker/a/mp; rc=$?
[ "$rc" -eq 0 ] && pass "put multipart: complete 404 (an earlier attempt completed it) is settled by the read-back" \
  || fail "put multipart complete 404: rc=$rc err=$(cat "$T/err")"
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

# ---- S3_OP_TIMEOUT: the whole command, retries included
plan "0 503 -"
t0=$(date +%s)
PATH="$BIN:$PATH" MINIO_ENDPOINT=http://store.test:9001 MINIO_ACCESS_KEY=ak MINIO_SECRET_KEY=x \
  S3_RETRIES=10 S3_RETRY_DELAY=1 S3_OP_TIMEOUT=3 "$S3RUN" "$S3SH" stat woodpecker/a/b > /dev/null 2> "$T/err"; rc=$?
el=$(( $(date +%s) - t0 ))
[ "$rc" -eq 5 ] && [ "$el" -le 3 ] && [ "$(ncalls)" -lt 10 ] && grep -q 'S3_OP_TIMEOUT=3s reached' "$T/err" \
  && sed -n 1p "$ST/argv.log" | grep -Eq -- '--max-time [123] ' \
  && pass "S3_OP_TIMEOUT: retries stop at the deadline (exit 5), and --max-time never outlives it" \
  || fail "op timeout: rc=$rc el=$el calls=$(ncalls) err=$(cat "$T/err") argv=$(sed -n 1p "$ST/argv.log")"
plan "0 200 $T/obj etag=$OBJMD5"
s3 stat woodpecker/a/b; sed -n 1p "$ST/argv.log" | grep -q -- '--max-time 3600 ' \
  && pass "no S3_OP_TIMEOUT: the per-attempt ceiling is S3_MAX_TIME" || fail "max-time default: $(sed -n 1p "$ST/argv.log")"

# ---- presign signs the Host a client sends: no default port
pre() { MINIO_ENDPOINT=$1 MINIO_ACCESS_KEY=AKIAIOSFODNN7EXAMPLE MINIO_SECRET_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY \
  S3_PRESIGN_DATE=20130524T000000Z S3_ADDRESSING=${2:-path} S3_REGION=${S3_REGION:-${3:-us-east-1}} PATH="$BIN:$PATH" \
  "$S3RUN" "$S3SH" presign examplebucket/test.txt 86400; }
[ "$(pre http://h:80)" = "$(pre http://h)" ] && [ "$(pre https://h:443)" = "$(pre https://h)" ] \
  && pre http://h:80 | grep -q '^http://h/examplebucket/test.txt?' && [ "$(pre http://h:8080)" != "$(pre http://h)" ] \
  && pre http://h:8080 | grep -q '^http://h:8080/' \
  && pass "presign: :80 on http and :443 on https are dropped from the signed Host (curl and browsers never send them)" \
  || fail "presign default port: $(pre http://h:80) vs $(pre http://h)"
[ "$(pre https://s3.amazonaws.com virtual)" = "$want" ] \
  && pass "presign, virtual-host addressing: the AWS SigV4 documentation example, end to end" \
  || fail "presign virtual: $(pre https://s3.amazonaws.com virtual)"

# ---- S3_ADDRESSING=auto / S3_REGION=auto: what mc and minio-go do by default
aws() { EP=$1 s3 stat "$2"; }
plan "0 200 $T/obj etag=$OBJMD5"
S3_ADDRESSING=auto S3_REGION=eu-west-1 aws https://s3.amazonaws.com woodpecker/a/b
auto1=$(sed -n 1p "$ST/calls.log")
plan "0 200 $T/obj etag=$OBJMD5"
S3_ADDRESSING=auto S3_REGION=eu-west-1 aws https://s3.amazonaws.com my.bucket/a/b
auto2=$(sed -n 1p "$ST/calls.log")
plan "0 200 $T/obj etag=$OBJMD5"
S3_ADDRESSING=auto S3_REGION=eu-west-1 aws http://store.test:9001 woodpecker/a/b
auto3=$(sed -n 1p "$ST/calls.log")
plan "0 200 $T/obj etag=$OBJMD5"
S3_ADDRESSING=auto S3_REGION=us-east1 aws https://storage.googleapis.com woodpecker/a/b
auto4=$(sed -n 1p "$ST/calls.log")
[ "$auto1" = "HEAD https://woodpecker.s3.amazonaws.com/a/b" ] && [ "$auto2" = "HEAD https://s3.amazonaws.com/my.bucket/a/b" ] \
  && [ "$auto3" = "HEAD http://store.test:9001/woodpecker/a/b" ] && [ "$auto4" = "HEAD https://woodpecker.storage.googleapis.com/a/b" ] \
  && pass "S3_ADDRESSING=auto: virtual-host for AWS and Google, path for a dotted bucket over https and for other stores" \
  || fail "addressing auto: $auto1 | $auto2 | $auto3 | $auto4"
for c in s3.ap-south-1.amazonaws.com:ap-south-1 s3-us-west-2.amazonaws.com:us-west-2 s3.dualstack.eu-west-3.amazonaws.com:eu-west-3 \
         s3-fips.us-gov-west-1.amazonaws.com:us-gov-west-1 s3.cn-north-1.amazonaws.com.cn:cn-north-1; do
  plan "0 200 $T/obj etag=$OBJMD5"
  S3_REGION=auto S3_ADDRESSING=auto aws "https://${c%%:*}" woodpecker/a/b
  if [ "$(ncalls)" -eq 1 ] && grep -q -- "--aws-sigv4 aws:amz:${c#*:}:s3 " "$ST/argv.log" \
     && grep -q "^HEAD https://woodpecker.${c%%:*}/a/b" "$ST/calls.log"; then
    pass "S3_REGION=auto: ${c%%:*} signs for ${c#*:}, no lookup"
  else fail "region from host ${c%%:*}: $(cat "$ST/argv.log") $(cat "$ST/calls.log")"; fi
done
printf '<?xml version="1.0"?><LocationConstraint xmlns="http://s3.amazonaws.com/doc/2006-03-01/">ap-southeast-2</LocationConstraint>' > "$T/loc.xml"
plan "0 200 $T/loc.xml" "0 200 $T/obj etag=$OBJMD5"
S3_REGION=auto s3 stat woodpecker/a/b; rc=$?
[ "$rc" -eq 0 ] && [ "$(sed -n 1p "$ST/calls.log")" = "GET http://store.test:9001/woodpecker?location=" ] \
  && sed -n 1p "$ST/argv.log" | grep -q -- '--aws-sigv4 aws:amz:us-east-1:s3 ' && sed -n 2p "$ST/argv.log" | grep -q -- '--aws-sigv4 aws:amz:ap-southeast-2:s3 ' \
  && grep -q "bucket 'woodpecker' is in ap-southeast-2" "$T/err" \
  && pass "S3_REGION=auto elsewhere: GetBucketLocation (path-style, signed for us-east-1), then signs for that region" \
  || fail "region lookup: rc=$rc calls=$(cat "$ST/calls.log") err=$(cat "$T/err")"
printf '<LocationConstraint/>' > "$T/loc0.xml"; printf '<LocationConstraint>EU</LocationConstraint>' > "$T/loceu.xml"
printf '<Error><Code>AuthorizationHeaderMalformed</Code><Region>eu-central-1</Region></Error>' > "$T/locerr.xml"
for c in "$T/loc0.xml:200:us-east-1" "$T/loceu.xml:200:eu-west-1" "$T/locerr.xml:400:eu-central-1" "$T/loc.xml:200:ap-southeast-2"; do
  f=${c%%:*}; r=${c##*:}; st=${c#*:}; st=${st%%:*}
  plan "0 $st $f"
  s3 location woodpecker; rc=$?
  [ "$rc" -eq 0 ] && [ "$(cat "$T/out")" = "$r" ] && pass "location: $(basename "$f") ($st) -> $r" || fail "location $f: rc=$rc out=$(cat "$T/out")"
done
plan "0 404 $T/nosuchkey.xml"
s3 location nobucket; rc=$?
[ "$rc" -eq 1 ] && grep -q "bucket 'nobucket' does not exist" "$T/err" && pass "location: a missing bucket -> exit 1" || fail "location 404: rc=$rc"
[ "$(pre https://s3.eu-west-1.amazonaws.com auto auto)" = "$(pre https://s3.eu-west-1.amazonaws.com virtual eu-west-1)" ] \
  && pre https://s3.eu-west-1.amazonaws.com auto auto | grep -q '^https://examplebucket.s3.eu-west-1.amazonaws.com/test.txt?.*%2Feu-west-1%2Fs3%2F' \
  && pass "presign with S3_ADDRESSING=auto and S3_REGION=auto from the host" || fail "presign auto: $(pre https://s3.eu-west-1.amazonaws.com auto auto)"

# ---- addressing, TLS options, curl floor, configuration errors
plan "0 404 -" "0 200 -"
S3_ADDRESSING=virtual s3 stat woodpecker/a/b; rc=$?
[ "$rc" -eq 3 ] && sed -n 1p "$ST/calls.log" | grep -q '^HEAD http://woodpecker.store.test:9001/a/b$' \
  && sed -n 2p "$ST/calls.log" | grep -q '^HEAD http://woodpecker.store.test:9001/$' \
  && pass "S3_ADDRESSING=virtual: bucket.host/key for the object, bucket.host/ for the bucket" \
  || fail "virtual stat: rc=$rc calls=$(cat "$ST/calls.log")"
plan "0 200 $T/ls2.xml"
S3_ADDRESSING=virtual s3 ls woodpecker p/; rc=$?
[ "$rc" -eq 0 ] && grep -q '^GET http://woodpecker.store.test:9001/?list-type=2&prefix=p%2F$' "$ST/calls.log" \
  && pass "S3_ADDRESSING=virtual: ls lists bucket.host/?list-type=2" || fail "virtual ls: rc=$rc calls=$(cat "$ST/calls.log")"
plan "0 200 $T/obj etag=$OBJMD5"
: > "$T/ca.pem"
S3_TLS_INSECURE=true S3_CA_FILE="$T/ca.pem" s3 stat woodpecker/a/b; rc=$?
[ "$rc" -eq 0 ] && grep -q -- '--insecure' "$ST/argv.log" && grep -q -- "--cacert $T/ca.pem" "$ST/argv.log" \
  && pass "S3_TLS_INSECURE / S3_CA_FILE reach curl as --insecure / --cacert" || fail "tls opts: $(cat "$ST/argv.log")"
plan "0 200 $T/obj etag=$OBJMD5"
s3 stat woodpecker/a/b; ! grep -q -- '--insecure\|--cacert' "$ST/argv.log" \
  && pass "by default the certificate is verified (no --insecure, no --cacert)" || fail "tls default: $(cat "$ST/argv.log")"
for case in "S3_CA_FILE=$T/no-such.pem|is not readable" "S3_ADDRESSING=dns|S3_ADDRESSING must be" \
            "MINIO_ENDPOINT=ftp://h:21|must be http:// or https://" "S3_OP_TIMEOUT=soon|non-negative integers" \
            "STUB_CURL_VERSION=7.81.0|curl 7.81.0 is too old: s3.sh needs 7.88.1 or newer" \
            "STUB_CURL_VERSION=7.88.0|curl 7.88.0 is too old"; do
  plan "0 200 $T/obj etag=$OBJMD5"
  env PATH="$BIN:$PATH" MINIO_ENDPOINT=http://store.test:9001 MINIO_ACCESS_KEY=ak MINIO_SECRET_KEY=x "${case%%|*}" \
    "$S3RUN" "$S3SH" stat woodpecker/a/b > /dev/null 2> "$T/err"; rc=$?
  [ "$rc" -eq 2 ] && [ "$(ncalls)" -eq 0 ] && grep -qF "${case#*|}" "$T/err" \
    && pass "configuration error -> exit 2, says why, no request: ${case%%|*}" \
    || fail "config '${case%%|*}': rc=$rc calls=$(ncalls) err=$(cat "$T/err")"
done
for v in 7.88.1 8.0.0 10.2.3; do
  plan "0 200 $T/obj etag=$OBJMD5"
  STUB_CURL_VERSION=$v s3 stat woodpecker/a/b; rc=$?
  [ "$rc" -eq 0 ] && pass "curl $v is accepted" || fail "curl $v: rc=$rc err=$(cat "$T/err")"
done

# ------------------------------------------------------------ live
if [ "${S3_TEST_LIVE:-}" = 1 ]; then
  echo "== live: $MINIO_ENDPOINT (curl $(curl --version | head -n 1 | cut -d' ' -f2)) =="
  B=${S3_TEST_BUCKET:?S3_TEST_BUCKET must name a throwaway bucket}
  P="s3-test-$$"
  L="$T/live"; mkdir -p "$L"
  S3_RETRY_DELAY=1; export S3_RETRY_DELAY
  # The test's own curl calls, credentials quoted for curl's config syntax
  # exactly as s3.sh does (a secret may hold " or \).
  S3T_USER=$(printf '%s:%s' "$MINIO_ACCESS_KEY" "$MINIO_SECRET_KEY" | sed 's/[\\"]/\\&/g')
  raw() { printf 'user = "%s"\n' "$S3T_USER" | \
            curl --config - -sS --aws-sigv4 aws:amz:us-east-1:s3 \
              --header 'x-amz-content-sha256: UNSIGNED-PAYLOAD' "$@"; }
  # Test setup only: lanes never create buckets.
  raw -o /dev/null -X PUT "${MINIO_ENDPOINT%/}/$B" || true
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
  "$S3RUN" "$S3SH" cat "$B/$P/big" 2> "$L/err" > "$L/big.out" && cmp -s "$L/big" "$L/big.out" \
    && grep -q "MD5 [0-9a-f]* verified, $parts ranges" "$L/err" \
    && pass "live ${mb} MiB cat: streamed as $parts If-Match-pinned ranges, MD5-verified" || fail "live cat: $(cat "$L/err")"
  rm -f "$L/big.out"
  # What the restores do: stream straight into tar, and trust the tree only if
  # s3.sh itself exited 0 (POSIX sh has no pipefail).
  mkdir -p "$L/tree/d" "$L/untar"; head -c 5000000 /dev/urandom > "$L/tree/d/x"; echo hi > "$L/tree/y"
  ( cd "$L" && tar -czf tree.tgz tree )
  "$S3RUN" "$S3SH" put "$L/tree.tgz" "$B/$P/tree.tgz" 2>/dev/null
  { "$S3RUN" "$S3SH" cat "$B/$P/tree.tgz" 2> "$L/err"; echo $? > "$L/rc"; } | tar -xzf - -C "$L/untar"; trc=$?
  [ "$(cat "$L/rc")" = 0 ] && [ "$trc" -eq 0 ] && cmp -s "$L/tree/d/x" "$L/untar/tree/d/x" && cmp -s "$L/tree/y" "$L/untar/tree/y" \
    && pass "live cat | tar -xz: the stream extracts to the same tree" || fail "live cat|tar: rc=$(cat "$L/rc") tar=$trc $(cat "$L/err")"
  # Over S3_MAX_PUT_BYTES (5 MiB here, S3's minimum part size): a multipart
  # upload s3.sh writes itself, with the whole MD5 as metadata.
  head -c 12582917 /dev/urandom > "$L/mpbig"
  mpmd5=$(md5sum < "$L/mpbig" | cut -d' ' -f1)
  S3_MAX_PUT_BYTES=5242880 S3_PUT_PART_BYTES=5242880 "$S3RUN" "$S3SH" put "$L/mpbig" "$B/$P/mpbig" 2> "$L/err" \
    && grep -q "12582917 bytes in 3 parts, MD5 $mpmd5 verified" "$L/err" \
    && pass "live multipart put: 3 parts, completed ETag and read-back verified" || fail "live multipart put: $(cat "$L/err")"
  case "$("$S3RUN" "$S3SH" stat "$B/$P/mpbig" 2>/dev/null)" in
    "12582917 "*-3) pass "live multipart put: the object's ETag is <md5>-3" ;;
    *) fail "live multipart stat: $("$S3RUN" "$S3SH" stat "$B/$P/mpbig" 2>&1)" ;;
  esac
  "$S3RUN" "$S3SH" get "$B/$P/mpbig" "$L/mpbig.out" 2> "$L/err" && cmp -s "$L/mpbig" "$L/mpbig.out" \
    && grep -q "MD5 $mpmd5 verified (x-amz-meta-s3sh-md5)" "$L/err" \
    && pass "live multipart object: get checks the whole MD5 through x-amz-meta-s3sh-md5" || fail "live multipart get meta: $(cat "$L/err")"
  S3_PART_BYTES=4194304 "$S3RUN" "$S3SH" cat "$B/$P/mpbig" 2> "$L/err" > "$L/mpbig.out" && cmp -s "$L/mpbig" "$L/mpbig.out" \
    && grep -q "MD5 $mpmd5 verified (x-amz-meta-s3sh-md5), 4 ranges" "$L/err" \
    && pass "live multipart object: cat checks it too" || fail "live multipart cat: $(cat "$L/err")"
  rm -f "$L/mpbig.out"
  # A store that is not answering at all: S3_OP_TIMEOUT ends it, not the
  # (longer) connect timeout times the retries.
  t0=$(date +%s)
  MINIO_ENDPOINT=http://10.255.255.1:9 S3_CONNECT_TIMEOUT=30 S3_OP_TIMEOUT=4 "$S3RUN" "$S3SH" stat "$B/$P/a" > /dev/null 2>&1; rc=$?
  el=$(( $(date +%s) - t0 ))
  [ "$rc" -eq 5 ] && [ "$el" -le 6 ] && pass "live S3_OP_TIMEOUT=4 against a black hole: exit 5 after ${el}s" \
    || fail "live op timeout: rc=$rc after ${el}s"
  # An object another client uploaded in parts (mc did, for anything over
  # 16 MiB): its ETag is "<md5>-<parts>", not an MD5, and every range of it is
  # pinned with If-Match on that ETag. Built with plain curl, as mc would. The
  # explicit UNSIGNED-PAYLOAD is what s3.sh sends too: curl 7.88 signs a POST
  # body's hash without sending x-amz-content-sha256, and SeaweedFS answers
  # SignatureDoesNotMatch. (raw is defined at the top of this section.)
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
    && cmp -s "$L/mp" "$L/mp.out" && grep -q 'size verified (ETag .*), 8 parts' "$L/err" \
    && pass "live multipart-uploaded object ($etag): ranged get pinned by If-Match on its ETag" \
    || fail "live multipart get: $(cat "$L/err")"
  # The pin the ranged download relies on: a range asked for under an ETag the
  # object no longer has must be refused, not served.
  code=$(raw -o /dev/null -w '%{http_code}' --range 0-9 \
    --header 'If-Match: "00000000000000000000000000000000"' "${MINIO_ENDPOINT%/}/$B/$P/mp")
  [ "$code" = 412 ] && pass "live: a range pinned to an ETag the object does not have -> 412" \
    || fail "live If-Match mismatch: HTTP $code"
  S3_PART_BYTES=1048576 "$S3RUN" "$S3SH" cat "$B/$P/mp" 2> "$L/err" > "$L/mp.out" && cmp -s "$L/mp" "$L/mp.out" \
    && grep -q 'size verified (ETag .*), 8 ranges' "$L/err" \
    && pass "live multipart object from another client: cat checks every range and the total by size" \
    || fail "live multipart cat: $(cat "$L/err")"
  [ "$("$S3RUN" "$S3SH" location "$B" 2>/dev/null)" = us-east-1 ] \
    && S3_REGION=auto S3_ADDRESSING=auto "$S3RUN" "$S3SH" get "$B/$P/a" "$L/auto.out" 2> "$L/err" && cmp -s "$L/a2" "$L/auto.out" \
    && grep -q "S3_REGION=auto: bucket '$B' is in us-east-1" "$L/err" \
    && pass "live location -> us-east-1; S3_REGION=auto / S3_ADDRESSING=auto resolve to it and path style" \
    || fail "live location/auto: $(cat "$L/err")"
  for k in a c big mp mpbig tree.tgz; do "$S3RUN" "$S3SH" rm "$B/$P/$k" 2>/dev/null; done
  if [ -n "${S3_TEST_VIRTUAL_ENDPOINT:-}" ]; then
    vs3() { MINIO_ENDPOINT=$S3_TEST_VIRTUAL_ENDPOINT S3_ADDRESSING=virtual "$S3RUN" "$S3SH" "$@"; }
    vs3 put "$L/a" "$B/$P/v/a" 2> "$L/err" && [ "$(vs3 stat "$B/$P/v/a")" = "300000 $(md5sum < "$L/a" | cut -d' ' -f1)" ] \
      && vs3 get "$B/$P/v/a" "$L/v.out" 2>> "$L/err" && cmp -s "$L/a" "$L/v.out" \
      && [ "$(vs3 cat "$B/$P/v/a" 2>> "$L/err" | md5sum | cut -d' ' -f1)" = "$(md5sum < "$L/a" | cut -d' ' -f1)" ] \
      && [ "$(vs3 ls "$B" "$P/v/")" = "$P/v/a" ] \
      && curl -sS -o "$L/v.pre" "$(vs3 presign "$B/$P/v/a" 60)" && cmp -s "$L/a" "$L/v.pre" \
      && vs3 rm "$B/$P/v/a" 2>> "$L/err" && { vs3 stat "$B/$P/v/a" >/dev/null 2>&1; [ $? -eq 3 ]; } \
      && pass "live virtual-host addressing ($S3_TEST_VIRTUAL_ENDPOINT): put/stat/get/cat/ls/presign/rm" \
      || fail "live virtual: $(cat "$L/err")"
  fi
fi

echo
if [ "$fails" -eq 0 ]; then echo "ALL PASS"; else echo "FAILED: $fails"; exit 1; fi
