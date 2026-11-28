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
#   sleep=N stall before answering (uses FAKE_CLOCK when set)
#   stall=1 stall until the case releases it ($ST/release), having dropped
#           the event $ST/stalled.N: the request is in flight (see "Signals")
#   emit=NAME   drop $ST/ev.NAME right after writing the response
#   after=NAME  wait until $ST/ev.NAME exists before writing the response
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
REAL_DATE=$(command -v date); REAL_SLEEP=$(command -v sleep)
cat > "$BIN/curl" <<EOF
#!/bin/sh
ST="\${S3_STUB_ST:-$ST}"
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
etag=; clen=; short=; slp=; stall=; emit=; after=; norange=; r412=; bad=; badlen=; lie=; append=; grow=; meta=; xh=; flip=
for kv in "\$@"; do
  case "\$kv" in
    etag=*) etag=\${kv#etag=} ;; clen=*) clen=\${kv#clen=} ;;
    short=*) short=\${kv#short=} ;; sleep=*) slp=\${kv#sleep=} ;; stall=*) stall=1 ;;
    emit=*) emit=\${kv#emit=} ;; after=*) after=\${kv#after=} ;;
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
if [ -n "\$stall" ]; then
  : > "\$ST/stalled.\$n"
  # Gone with the test's directory too, so no stub outlives a test that died.
  until [ -e "\$ST/release" ] || [ ! -d "\$ST" ]; do $REAL_SLEEP 0.1; done
fi
if [ -n "\$after" ]; then
  until [ -e "\$ST/ev.\$after" ] || [ ! -d "\$ST" ]; do $REAL_SLEEP 0.1; done
fi
done_exit() { [ -z "\$emit" ] || : > "\$ST/ev.\$emit"; exit "\$rc"; }
[ "\$etag" != auto ] || etag=\$(md5sum < "\$body" | cut -d' ' -f1)
[ "\$etag" != up ] || etag=\$(md5sum < "\$up" | cut -d' ' -f1)
[ "\$meta" != auto ] || meta=\$(md5sum < "\$body" | cut -d' ' -f1)
if [ -n "\$range" ] && [ "\$status" = 200 ] && [ -z "\$norange" ]; then
  if [ -n "\$r412" ]; then
    printf 'HTTP/1.1 412 X\r\nContent-Length: 0\r\n\r\n' > "\$hdr"; done_exit
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
  done_exit
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
done_exit
EOF
chmod +x "$BIN/curl"
# A fake clock for the cases about time. With FAKE_CLOCK naming a file,
# `date +%s` reads it and `sleep N` (s3.sh's backoff, the stub's sleep=N) adds
# N to it instead of sleeping, so what such a case asserts is decided by what
# s3.sh does, never by how fast the runner is. FAKE_SLEEP_LATE=N makes every
# such sleep end N s late, as a sleep does on a loaded box. Without FAKE_CLOCK
# both are the real commands. The stub sleep and tick (below) write the clock
# file whole (a new file renamed over it), so a reader never finds it empty.
# Neither variable comes from the runner's environment: only the cases that
# need them set them.
unset FAKE_CLOCK FAKE_SLEEP_LATE
cat > "$BIN/date" <<EOF
#!/bin/sh
if [ -n "\${FAKE_CLOCK:-}" ] && [ "\$*" = +%s ]; then cat "\$FAKE_CLOCK"; exit 0; fi
exec $REAL_DATE "\$@"
EOF
cat > "$BIN/sleep" <<EOF
#!/bin/sh
if [ -n "\${FAKE_CLOCK:-}" ]; then
  echo \$(( \$(cat "\$FAKE_CLOCK") + \$1 + \${FAKE_SLEEP_LATE:-0} )) > "\$FAKE_CLOCK.\$\$" && mv -f "\$FAKE_CLOCK.\$\$" "\$FAKE_CLOCK"; exit 0
fi
exec $REAL_SLEEP "\$@"
EOF
chmod +x "$BIN/date" "$BIN/sleep"

SECRET='s3cr3t"with\quote'
plan() { : > "$ST/plan"; for l in "$@"; do printf '%s\n' "$l" >> "$ST/plan"; done
         rm -f "$ST/hint" "$ST/calls.log" "$ST/argv.log" "$ST/stdin.log" "$ST/uploaded" "$ST/uploaded.all" "$ST/posted"
         rm -f "$ST/release" "$ST/mktemp.held" "$ST/gpid" "$ST"/stalled.* "$ST"/ev.*
         rm -rf "$ST"/req.*; }
ncalls() { [ -f "$ST/calls.log" ] && wc -l < "$ST/calls.log" | tr -d ' ' || echo 0; }
# s3 VERB ARGS... — the script under test against the stub, no real sleeps.
# One-stream downloads unless PARALLEL says otherwise: the cases below count
# requests, and the ranged path (HEAD first) has its own section.
# Each call is bounded. A stub answers at once and no case sleeps for real,
# so an s3.sh still running after S3T_LIMIT seconds has hung: timeout
# (BusyBox's or coreutils') sends it TERM, and KILL 10 s later. The call then
# returns 124, which no case expects, and $T/err says why: a hang is a FAIL
# row and the suite goes on, where an unbounded call held the step until
# CI's own clock ended it, with no row to say where. S3_TEST_CALL_LIMIT sets
# the bound (seconds, default 300). The cases below that run s3.sh
# themselves run it under the same timeout, and none expects the code a
# killed call ends with (124, 137 or 143). Only those that need s3.sh to be
# the process they exec are not: the signal cases, where await_exit bounds
# it, and the caller's-job case, a stat that starts nothing. The live part
# talks to a real store, and s3.sh's own curl timeouts bound it there.
S3T_LIMIT=${S3_TEST_CALL_LIMIT:-300}
command -v timeout > /dev/null 2>&1 || { echo "s3-test.sh needs timeout (BusyBox or coreutils)"; exit 1; }
s3() {
  _s3t0=$(date +%s)
  PATH="$BIN:$PATH" MINIO_ENDPOINT="${EP:-http://store.test:9001}" MINIO_ACCESS_KEY=ak \
    MINIO_SECRET_KEY="$SECRET" S3_RETRY_DELAY=0 S3_RETRIES="${RETRIES:-3}" \
    S3_PARALLEL="${PARALLEL:-1}" S3_PARALLEL_MIN_BYTES="${PARALLEL_MIN:-33554432}" \
    S3_PART_BYTES="${PART:-33554432}" S3_MAX_PUT_BYTES="${MAXPUT:-5368709120}" \
    S3_PUT_PART_BYTES="${PUTPART:-268435456}" \
    timeout -k 10 "$S3T_LIMIT" "$S3RUN" "$S3SH" "$@" > "$T/out" 2> "$T/err"
  _s3rc=$?
  [ $(( $(date +%s) - _s3t0 )) -lt "$S3T_LIMIT" ] && return "$_s3rc"
  echo "s3-test: s3.sh $1 had not ended after $S3T_LIMIT s and was killed" >> "$T/err"
  return 124
}
# A file with no temp siblings left behind by s3.sh.
no_temps() { for _f in "$1"/.s3tmp.*; do [ -e "$_f" ] && return 1; done; return 0; }

# ---- Signals, judged by events, never by a guessed time
# A case that signals s3.sh in the middle of its work waits until the stubs
# say the work is there (the curl stub's stalled.N for each request in flight,
# the mktemp stub's mktemp.held) and only then sends the signal: a sleep
# before the kill let a loaded runner reach it before s3.sh had sent a single
# request, and the case passed without testing anything. Every process s3.sh
# starts inherits fd 9, the write end of the FIFO $T/life, which a reader
# drains: the read ends only once the last of them has exited. So "s3.sh's
# background work was stopped" is: after s3.sh has exited and the stalls are
# released (a part still running would answer then, and write its files),
# the reader ends at once, and the case's directories are empty.
life_start() {
  rm -f "$T/life"; mkfifo "$T/life"
  cat "$T/life" > /dev/null &
  LIFE_RDR=$!
}
# running PID: not kill -0, which a child that has ended passes until it is
# waited for (a zombie). Reads /proc/PID/stat whole so a newline in comm
# cannot shift the state field.
running() {
  _rs=$(cat "/proc/$1/stat" 2>/dev/null) || return 1
  case "$_rs" in *") "*) ;; *) return 1 ;; esac
  case "${_rs##*) }" in Z*|X*|"") return 1 ;; *) return 0 ;; esac
}
life_open() { running "$LIFE_RDR"; }
# await_pid_gone SEC PID: wait until PID is gone or a zombie, bounded by SEC.
await_pid_gone() {
  # shellcheck disable=SC2016 # expanded by the inner sh
  timeout "$1" sh -c '
    while st=$(cat "/proc/$1/stat" 2>/dev/null); do
      case "$st" in *") "*) ;; *) exit 0 ;; esac
      case "${st##*) }" in Z*|X*|"") exit 0 ;; esac
      sleep 0.1
    done
  ' _ "$2"
}
# await_exit PID: s3.sh's exit status in rc, within 120 s of the signal. Past
# that s3.sh never acted on it: it is killed, and rc says so.
await_exit() {
  if ! await_pid_gone 120 "$1"; then
    kill -KILL "$1" 2>/dev/null; wait "$1" 2>/dev/null; rc="no exit within 120 s"; return 1
  fi
  wait "$1"; rc=$?
}
# life_end: 0 once no process holds fd 9 any more, within 120 s. Past that the
# case has failed, and what still holds it (s3.sh's, by that fd and FIFO, and
# nothing else) is killed, so no failed case leaves a process behind.
life_end() {
  if ! await_pid_gone 120 "$LIFE_RDR"; then
    _lp="$(cd "$T" && pwd -P)/life"
    for _ld in /proc/[0-9]*; do
      [ "$(readlink "$_ld/fd/9" 2>/dev/null)" != "$_lp" ] || kill -KILL "${_ld#/proc/}" 2>/dev/null
    done
    kill "$LIFE_RDR" 2>/dev/null; wait "$LIFE_RDR" 2>/dev/null
    return 1
  fi
  wait "$LIFE_RDR" 2>/dev/null
  return 0
}
events() { _ec=0; for _ef in "$ST"/$1; do [ -e "$_ef" ] && _ec=$((_ec + 1)); done; echo "$_ec"; }
# await_events N GLOB: until N of the stubs' events ($ST/GLOB) are there, within
# 300 s; false at once if s3.sh's processes have all ended first.
await_events() {
  # shellcheck disable=SC2016 # expanded by the inner sh
  timeout 300 sh -c '
    while :; do
      c=0; for f in "$1"/$3; do [ -e "$f" ] && c=$((c + 1)); done
      [ "$c" -lt "$2" ] || exit 0
      st=$(cat "/proc/$4/stat" 2>/dev/null) || exit 1
      case "$st" in *") "*) ;; *) exit 1 ;; esac
      case "${st##*) }" in Z*|X*|"") exit 1 ;; esac
      sleep 0.1
    done
  ' _ "$ST" "$1" "$2" "$LIFE_RDR"
}
# await_file SEC PATH WATCH_PID: until PATH exists (or is non-empty when
# mode=-s), failing at once if WATCH_PID is gone or a zombie.
await_file() {
  # shellcheck disable=SC2016 # expanded by the inner sh
  timeout "$1" sh -c '
    while :; do
      if [ "$2" = -s ]; then [ ! -s "$3" ] || exit 0; else [ ! -e "$3" ] || exit 0; fi
      st=$(cat "/proc/$4/stat" 2>/dev/null) || exit 1
      case "$st" in *") "*) ;; *) exit 1 ;; esac
      case "${st##*) }" in Z*|X*|"") exit 1 ;; esac
      sleep 0.05
    done
  ' _ "$1" "$2" "$3" "$4"
}
release() { : > "$ST/release"; }

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
# Interrupted mid-transfer: SIGTERM while curl is stalled. One stream: curl is
# s3.sh's foreground command, and a shell runs a trap only once that is done,
# so here the stall is released after the signal, not after s3.sh has exited.
echo old > "$T/dl/keep4"
plan "0 200 $T/obj etag=auto stall=1"
life_start
( PATH="$BIN:$PATH" MINIO_ENDPOINT=http://store.test:9001 MINIO_ACCESS_KEY=ak MINIO_SECRET_KEY=x \
    S3_PARALLEL=1 exec "$S3RUN" "$S3SH" get woodpecker/a/obj "$T/dl/keep4" ) 9> "$T/life" 2>/dev/null &
pid=$!
premise=ok; await_events 1 'stalled.*' || premise="no request in flight"
kill -TERM "$pid" 2>/dev/null; release; await_exit "$pid"
gone=ok; life_end || gone="still running"
[ "$premise" = ok ] && [ "$rc" = 143 ] && [ "$gone" = ok ] && [ "$(cat "$T/dl/keep4")" = old ] && no_temps "$T/dl" \
  && pass "get: killed mid-transfer (SIGTERM) -> exit 143, the old file kept, no temp" \
  || fail "get sigterm: premise=$premise rc=$rc gone=$gone keep=$(cat "$T/dl/keep4") $(ls -A "$T/dl")"
# s3_mktemp. A mktemp stub, ahead of the real one on PATH: for a template in
# MKTEMP_FAIL_IN it fails; for one in MKTEMP_HOLD_IN it makes the file, drops
# mktemp.held and exits only once released.
REAL_MKTEMP=$(command -v mktemp)
mkdir -p "$T/mkstub"
cat > "$T/mkstub/mktemp" <<EOF
#!/bin/sh
case "\$1" in "\${MKTEMP_FAIL_IN:-/nonexistent}"/*) echo "mktemp: stub refuses \$1" >&2; exit 1 ;; esac
f=\$($REAL_MKTEMP "\$@") || exit
case "\$1" in
  "\${MKTEMP_HOLD_IN:-/nonexistent}"/*)
    : > "$ST/mktemp.held"
    until [ -e "$ST/release" ] || [ ! -d "$ST" ]; do $REAL_SLEEP 0.1; done ;;
esac
printf '%s\n' "\$f"
EOF
chmod +x "$T/mkstub/mktemp"
# SIGTERM while mktemp makes the download's temp file: mktemp has made it
# before the shell has its name, so a signal handled before s3.sh registers
# it would leave it behind, in the directory the download was going to. s3.sh
# is signalled while the stub holds, under each shell the lanes run it with,
# each into a directory of its own: what one leaves cannot fail another.
for msh in sh dash bash; do
  command -v "$msh" > /dev/null 2>&1 || continue
  mshl=$msh; [ "$msh" != sh ] || mshl="sh = $(readlink -f "$(command -v sh)")"
  d="$T/dlm-$msh"; mkdir -p "$d"; echo old > "$d/keep"
  plan "0 200 $T/obj etag=auto"
  life_start
  ( PATH="$T/mkstub:$BIN:$PATH" MKTEMP_HOLD_IN="$d" MINIO_ENDPOINT=http://store.test:9001 MINIO_ACCESS_KEY=ak \
      MINIO_SECRET_KEY=x S3_PARALLEL=1 exec "$msh" "$S3SH" get woodpecker/a/obj "$d/keep" ) 9> "$T/life" 2>/dev/null &
  pid=$!
  premise=ok; await_events 1 mktemp.held || premise="mktemp never reached"
  kill -TERM "$pid" 2>/dev/null; release; await_exit "$pid"
  gone=ok; life_end || gone="still running"
  [ "$premise" = ok ] && [ "$rc" = 143 ] && [ "$gone" = ok ] && [ "$(ncalls)" -eq 0 ] \
    && [ "$(cat "$d/keep")" = old ] && no_temps "$d" \
    && pass "get ($mshl): SIGTERM while mktemp makes the temp file -> exit 143 before any request, no temp left" \
    || fail "get ($mshl) sigterm in mktemp: premise=$premise rc=$rc gone=$gone calls=$(ncalls) keep=$(cat "$d/keep") left: $(find "$d" -name '.s3tmp.*' | tr '\n' ' ')"
done
# Process-group SIGTERM while mktemp holds (as GNU timeout or ^C sends it):
# the stub dies with the group after creating the file and before printing its
# name, so s3.sh never sees the path and must still remove the file by its
# per-run prefix.
for msh in sh dash bash; do
  command -v "$msh" > /dev/null 2>&1 || continue
  mshl=$msh; [ "$msh" != sh ] || mshl="sh = $(readlink -f "$(command -v sh)")"
  d="$T/dlg-$msh"; td="$T/dlgt-$msh"; mkdir -p "$d" "$td"; echo old > "$d/keep"
  plan "0 200 $T/obj etag=auto"
  life_start
  # shellcheck disable=SC2016 # expanded by the inner sh
  ( PATH="$T/mkstub:$BIN:$PATH" MKTEMP_HOLD_IN="$d" TMPDIR="$td" MINIO_ENDPOINT=http://store.test:9001 MINIO_ACCESS_KEY=ak \
      MINIO_SECRET_KEY=x S3_PARALLEL=1 \
      exec setsid sh -c 'echo "$$" > "$1"; shift; exec "$@"' _ "$ST/gpid" "$msh" "$S3SH" get woodpecker/a/obj "$d/keep" ) 9> "$T/life" 2>/dev/null &
  pid=$!
  premise=ok; await_events 1 mktemp.held || premise="mktemp never reached"
  gpid=$(cat "$ST/gpid" 2>/dev/null || true)
  if [ "$premise" = ok ]; then
    [ "$gpid" = "$pid" ] || premise="pgid $gpid != pid $pid"
  fi
  if [ "$premise" = ok ]; then
    kill -TERM "-$gpid" 2>/dev/null || premise="group kill failed"
  fi
  await_exit "$pid"
  release
  gone=ok; life_end || gone="still running"
  [ "$premise" = ok ] && [ "$rc" = 143 ] && [ "$gone" = ok ] && [ "$(ncalls)" -eq 0 ] \
    && [ "$(cat "$d/keep")" = old ] && no_temps "$d" && no_temps "$td" \
    && pass "get ($mshl): process-group SIGTERM while mktemp holds -> exit 143 before any request, no temp left" \
    || fail "get ($mshl) group sigterm in mktemp: premise=$premise rc=$rc gone=$gone calls=$(ncalls) keep=$(cat "$d/keep") left: $(find "$d" "$td" -name '.s3tmp.*' | tr '\n' ' ')"
done
# Non-TERM signals (HUP, PIPE) while mktemp holds: each exits with its own
# signal code and leaves no temp behind.
for msig in HUP:129 PIPE:141; do
  sig=${msig%%:*}; sigrc=${msig#*:}
  d="$T/dls-$sig"; td="$T/dlst-$sig"; mkdir -p "$d" "$td"; echo old > "$d/keep"
  plan "0 200 $T/obj etag=auto"
  life_start
  ( PATH="$T/mkstub:$BIN:$PATH" MKTEMP_HOLD_IN="$d" TMPDIR="$td" MINIO_ENDPOINT=http://store.test:9001 MINIO_ACCESS_KEY=ak \
      MINIO_SECRET_KEY=x S3_PARALLEL=1 exec "$S3RUN" "$S3SH" get woodpecker/a/obj "$d/keep" ) 9> "$T/life" 2>/dev/null &
  pid=$!
  premise=ok; await_events 1 mktemp.held || premise="mktemp never reached"
  kill -"$sig" "$pid" 2>/dev/null; release; await_exit "$pid"
  gone=ok; life_end || gone="still running"
  [ "$premise" = ok ] && [ "$rc" = "$sigrc" ] && [ "$gone" = ok ] && [ "$(ncalls)" -eq 0 ] \
    && [ "$(cat "$d/keep")" = old ] && no_temps "$d" && no_temps "$td" \
    && pass "get: SIG$sig while mktemp holds -> exit $sigrc before any request, no temp left" \
    || fail "get sig$sig in mktemp: premise=$premise rc=$rc gone=$gone calls=$(ncalls) keep=$(cat "$d/keep") left: $(find "$d" "$td" -name '.s3tmp.*' | tr '\n' ' ')"
done
# SIGINT while mktemp holds: exit 130, no temp left. A non-interactive shell
# ignores SIGINT for async (&) commands, so run s3.sh in the foreground and
# send SIGINT from a background watcher. When this suite itself was launched
# asynchronously with SIGINT ignored, reset SIGINT via env/python3/perl when
# available so s3.sh can trap it.
_int_ign=$(( 0x$(sed -n 's/^SigIgn:[[:space:]]*//p' /proc/$$/status 2>/dev/null || echo 0) & 2 ))
_int_mode=direct
if [ "$_int_ign" -ne 0 ]; then
  if env --default-signal=INT true 2>/dev/null; then _int_mode=envdef
  elif command -v python3 > /dev/null 2>&1; then _int_mode=py
  elif command -v perl > /dev/null 2>&1; then _int_mode=perl
  else _int_mode=none
  fi
fi
if [ "$_int_mode" != none ]; then
  d="$T/dls-INT"; td="$T/dlst-INT"; mkdir -p "$d" "$td"; echo old > "$d/keep"
  plan "0 200 $T/obj etag=auto"
  life_start
  rm -f "$ST/int.premise"
  (
    # shellcheck disable=SC2016 # expanded by the inner sh
    if ! timeout 300 sh -c '
      until [ -e "$1" ] && [ -s "$2" ]; do
        st=$(cat "/proc/$3/stat" 2>/dev/null) || exit 1
        case "$st" in *") "*) ;; *) exit 1 ;; esac
        case "${st##*) }" in Z*|X*|"") exit 1 ;; esac
        sleep 0.1
      done
    ' _ "$ST/mktemp.held" "$ST/gpid" "$LIFE_RDR"; then
      echo "mktemp never reached" > "$ST/int.premise"; exit 0
    fi
    _ig=$(cat "$ST/gpid" 2>/dev/null || true)
    _ig_ign=$(( 0x$(sed -n 's/^SigIgn:[[:space:]]*//p' "/proc/$_ig/status" 2>/dev/null || echo 2) & 2 ))
    if [ "$_ig_ign" -ne 0 ]; then
      echo "SIGINT ignored in s3.sh" > "$ST/int.premise"
      kill -TERM "-$_ig" 2>/dev/null || kill -TERM "$_ig" 2>/dev/null || true
    else
      echo ok > "$ST/int.premise"
      kill -INT "-$_ig" 2>/dev/null || true
    fi
  ) &
  _int_w=$!
  rc=0
  # shellcheck disable=SC2016 # expanded by the inner sh
  case "$_int_mode" in
    direct)
      ( PATH="$T/mkstub:$BIN:$PATH" MKTEMP_HOLD_IN="$d" TMPDIR="$td" MINIO_ENDPOINT=http://store.test:9001 MINIO_ACCESS_KEY=ak \
          MINIO_SECRET_KEY=x S3_PARALLEL=1 \
          exec setsid sh -c 'echo "$$" > "$1"; shift; exec "$@"' _ "$ST/gpid" "$S3RUN" "$S3SH" get woodpecker/a/obj "$d/keep" ) 9> "$T/life" 2>/dev/null || rc=$? ;;
    envdef)
      ( PATH="$T/mkstub:$BIN:$PATH" MKTEMP_HOLD_IN="$d" TMPDIR="$td" MINIO_ENDPOINT=http://store.test:9001 MINIO_ACCESS_KEY=ak \
          MINIO_SECRET_KEY=x S3_PARALLEL=1 \
          exec env --default-signal=INT setsid sh -c 'echo "$$" > "$1"; shift; exec "$@"' _ "$ST/gpid" "$S3RUN" "$S3SH" get woodpecker/a/obj "$d/keep" ) 9> "$T/life" 2>/dev/null || rc=$? ;;
    py)
      ( PATH="$T/mkstub:$BIN:$PATH" MKTEMP_HOLD_IN="$d" TMPDIR="$td" MINIO_ENDPOINT=http://store.test:9001 MINIO_ACCESS_KEY=ak \
          MINIO_SECRET_KEY=x S3_PARALLEL=1 \
          exec python3 -c 'import os,signal,sys; signal.signal(signal.SIGINT,signal.SIG_DFL); os.execvp(sys.argv[1],sys.argv[1:])' \
          setsid sh -c 'echo "$$" > "$1"; shift; exec "$@"' _ "$ST/gpid" "$S3RUN" "$S3SH" get woodpecker/a/obj "$d/keep" ) 9> "$T/life" 2>/dev/null || rc=$? ;;
    perl)
      ( PATH="$T/mkstub:$BIN:$PATH" MKTEMP_HOLD_IN="$d" TMPDIR="$td" MINIO_ENDPOINT=http://store.test:9001 MINIO_ACCESS_KEY=ak \
          MINIO_SECRET_KEY=x S3_PARALLEL=1 \
          exec perl -e '$SIG{INT}="DEFAULT"; exec @ARGV' \
          setsid sh -c 'echo "$$" > "$1"; shift; exec "$@"' _ "$ST/gpid" "$S3RUN" "$S3SH" get woodpecker/a/obj "$d/keep" ) 9> "$T/life" 2>/dev/null || rc=$? ;;
  esac
  release
  wait "$_int_w" 2>/dev/null || true
  premise=$(cat "$ST/int.premise" 2>/dev/null || echo "watcher failed")
  gone=ok; life_end || gone="still running"
  [ "$premise" = ok ] && [ "$rc" = 130 ] && [ "$gone" = ok ] && [ "$(ncalls)" -eq 0 ] \
    && [ "$(cat "$d/keep")" = old ] && no_temps "$d" && no_temps "$td" \
    && pass "get: process-group SIGINT while mktemp holds -> exit 130 before any request, no temp left" \
    || fail "get sigINT in mktemp: premise=$premise rc=$rc gone=$gone calls=$(ncalls) keep=$(cat "$d/keep") left: $(find "$d" "$td" -name '.s3tmp.*' | tr '\n' ' ')"
else
  echo "  NOTE: skipped SIGINT row (caller ignored SIGINT and no helper to reset it is installed)"
fi
# Process-group SIGTERM during a later TMPDIR mktemp, with a space in the
# destination directory name and another run's .s3tmp.* sibling in the same
# directory: both of this run's temp files (dst and TMPDIR) are removed, while
# the other run's sibling is untouched.
d="$T/dl space"; td="$T/dl space tmp"; mkdir -p "$d" "$td"; echo old > "$d/keep"; echo sibling > "$d/.s3tmp.other-run.keepme"
plan "0 200 $T/obj etag=auto"
life_start
# shellcheck disable=SC2016 # expanded by the inner sh
( PATH="$T/mkstub:$BIN:$PATH" MKTEMP_HOLD_IN="$td" TMPDIR="$td" MINIO_ENDPOINT=http://store.test:9001 MINIO_ACCESS_KEY=ak \
    MINIO_SECRET_KEY=x S3_PARALLEL=1 \
    exec setsid sh -c 'echo "$$" > "$1"; shift; exec "$@"' _ "$ST/gpid" "$S3RUN" "$S3SH" get woodpecker/a/obj "$d/keep" ) 9> "$T/life" 2>/dev/null &
pid=$!
premise=ok; await_events 1 mktemp.held || premise="TMPDIR mktemp never reached"
gpid=$(cat "$ST/gpid" 2>/dev/null || true)
if [ "$premise" = ok ]; then
  [ "$gpid" = "$pid" ] || premise="pgid $gpid != pid $pid"
fi
if [ "$premise" = ok ]; then
  kill -TERM "-$gpid" 2>/dev/null || premise="group kill failed"
fi
await_exit "$pid"
release
gone=ok; life_end || gone="still running"
[ "$premise" = ok ] && [ "$rc" = 143 ] && [ "$gone" = ok ] && [ "$(ncalls)" -eq 0 ] \
  && [ "$(cat "$d/keep")" = old ] && [ "$(cat "$d/.s3tmp.other-run.keepme" 2>/dev/null)" = sibling ] \
  && [ "$(find "$d" -name '.s3tmp.*' | wc -l | tr -d ' ')" -eq 1 ] && no_temps "$td" \
  && pass "get: process-group SIGTERM in TMPDIR mktemp (dir with space) -> removes own dst and TMPDIR temps, keeps other run's sibling" \
  || fail "get tmpdir group sigterm: premise=$premise rc=$rc gone=$gone calls=$(ncalls) keep=$(cat "$d/keep") dst=$(find "$d" -name '.s3tmp.*' | tr '\n' ' ') tmp=$(find "$td" -name '.s3tmp.*' | tr '\n' ' ')"
# Real concurrent runs into one spaced directory: pins that two live runs get
# distinct S3_RUN_IDs (a constant-id mutant lets B's exit delete A's in-flight
# temp file even though A's retry would still make A exit 0).
d="$T/dl conc dir"; tdA="$T/conc-tdA"; tdB="$T/conc-tdB"; tdC="$T/conc-tdC"
stA="$T/conc-stA"; stB="$T/conc-stB"; stC="$T/conc-stC"
mkdir -p "$d" "$tdA" "$tdB" "$tdC" "$stA" "$stB" "$stC"
printf '%s\n' "0 200 $T/obj etag=auto stall=1" > "$stA/plan"
printf '%s\n' "0 200 $T/obj etag=auto" > "$stB/plan"
printf '%s\n' "0 200 $T/obj etag=auto stall=1" > "$stC/plan"
rm -f "$T/lifeA"; mkfifo "$T/lifeA"; cat "$T/lifeA" > /dev/null & lifeA=$!
( PATH="$BIN:$PATH" S3_STUB_ST="$stA" TMPDIR="$tdA" MINIO_ENDPOINT=http://store.test:9001 MINIO_ACCESS_KEY=ak \
    MINIO_SECRET_KEY=x S3_PARALLEL=1 exec "$S3RUN" "$S3SH" get woodpecker/a/obj "$d/fa" ) 9> "$T/lifeA" 2>/dev/null &
pidA=$!
premise=ok
await_file 300 -e "$stA/stalled.1" "$lifeA" || premise="A never in flight"
a_tmp=$(find "$d" -maxdepth 1 -name '.s3tmp.*' | head -n 1)
[ -n "$a_tmp" ] && [ -e "$a_tmp" ] || premise="A temp file missing before B"
# Run B completes normally beside A in the same directory.
PATH="$BIN:$PATH" S3_STUB_ST="$stB" TMPDIR="$tdB" MINIO_ENDPOINT=http://store.test:9001 MINIO_ACCESS_KEY=ak \
  MINIO_SECRET_KEY=x S3_PARALLEL=1 timeout -k 10 "$S3T_LIMIT" "$S3RUN" "$S3SH" get woodpecker/a/obj "$d/fb" > /dev/null 2>&1; b_rc=$?
a_after_b=no; [ -n "$a_tmp" ] && [ -e "$a_tmp" ] && a_after_b=yes
# Run C is killed with process-group SIGTERM beside A in the same directory.
life_start
# shellcheck disable=SC2016 # expanded by the inner sh
( PATH="$BIN:$PATH" S3_STUB_ST="$stC" TMPDIR="$tdC" MINIO_ENDPOINT=http://store.test:9001 MINIO_ACCESS_KEY=ak \
    MINIO_SECRET_KEY=x S3_PARALLEL=1 \
    exec setsid sh -c 'echo "$$" > "$1"; shift; exec "$@"' _ "$stC/gpid" "$S3RUN" "$S3SH" get woodpecker/a/obj "$d/fc" ) 9> "$T/life" 2>/dev/null &
pidC=$!
await_file 300 -e "$stC/stalled.1" "$LIFE_RDR" || premise="C never in flight"
gpidC=$(cat "$stC/gpid" 2>/dev/null || true)
[ "$gpidC" = "$pidC" ] || premise="C pgid $gpidC != pid $pidC"
kill -TERM "-$gpidC" 2>/dev/null || true
await_exit "$pidC"; c_rc=$rc; : > "$stC/release"
c_gone=ok; life_end || c_gone="C still running"
a_after_c=no; [ -n "$a_tmp" ] && [ -e "$a_tmp" ] && a_after_c=yes
c_cnt=$(find "$d" -maxdepth 1 -name '.s3tmp.*' | wc -l | tr -d ' ')
# Release A and let it finish cleanly.
: > "$stA/release"; await_exit "$pidA"; a_rc=$rc
a_gone=ok
if ! await_pid_gone 120 "$lifeA"; then
  kill "$lifeA" 2>/dev/null; a_gone="A still running"
fi
wait "$lifeA" 2>/dev/null || true
[ "$premise" = ok ] && [ "$b_rc" -eq 0 ] && [ "$a_after_b" = yes ] && [ "$c_rc" = 143 ] && [ "$c_gone" = ok ] \
  && [ "$a_after_c" = yes ] && [ "$c_cnt" -eq 1 ] && [ "$a_rc" = 0 ] && [ "$a_gone" = ok ] \
  && cmp -s "$T/obj" "$d/fa" && cmp -s "$T/obj" "$d/fb" && [ ! -e "$d/fc" ] && no_temps "$d" && no_temps "$tdA" && no_temps "$tdB" && no_temps "$tdC" \
  && pass "get: concurrent runs in one spaced dir have distinct run IDs (normal exit and group SIGTERM leave A's temp intact)" \
  || fail "get concurrent runs: premise=$premise b_rc=$b_rc a_after_b=$a_after_b c_rc=$c_rc c_gone=$c_gone a_after_c=$a_after_c c_cnt=$c_cnt a_rc=$a_rc a_gone=$a_gone left=$(find "$d" "$tdA" "$tdB" "$tdC" -name '.s3tmp.*' | tr '\n' ' ')"
# mktemp failing: exit 1, said, before any request. In the download's
# directory (inside a command), and in TMPDIR at startup for S3_OP_TIMEOUT's
# progress file.
plan "0 200 $T/obj etag=auto"
mkdir -p "$T/dlf"; echo old > "$T/dlf/keep"
PATH="$T/mkstub:$BIN:$PATH" MKTEMP_FAIL_IN="$T/dlf" MINIO_ENDPOINT=http://store.test:9001 MINIO_ACCESS_KEY=ak \
  MINIO_SECRET_KEY=x S3_PARALLEL=1 timeout -k 10 "$S3T_LIMIT" "$S3RUN" "$S3SH" get woodpecker/a/obj "$T/dlf/keep" > /dev/null 2> "$T/err"; rc=$?
[ "$rc" -eq 1 ] && [ "$(ncalls)" -eq 0 ] && grep -q "cannot create a temp file in $T/dlf\$" "$T/err" && [ "$(cat "$T/dlf/keep")" = old ] \
  && pass "get: mktemp failing in the destination's directory -> exit 1 before any request, said, the old file kept" \
  || fail "get mktemp fails: rc=$rc calls=$(ncalls) err=$(cat "$T/err")"
mkdir -p "$T/mkfail"
plan "0 200 $T/obj etag=auto"
PATH="$T/mkstub:$BIN:$PATH" MKTEMP_FAIL_IN="$T/mkfail" TMPDIR="$T/mkfail" S3_OP_TIMEOUT=60 MINIO_ENDPOINT=http://store.test:9001 \
  MINIO_ACCESS_KEY=ak MINIO_SECRET_KEY=x timeout -k 10 "$S3T_LIMIT" "$S3RUN" "$S3SH" stat woodpecker/a/obj > /dev/null 2> "$T/err"; rc=$?
[ "$rc" -eq 1 ] && [ "$(ncalls)" -eq 0 ] && grep -q "cannot create a temp file in $T/mkfail\$" "$T/err" \
  && pass "S3_OP_TIMEOUT: mktemp failing in TMPDIR -> exit 1 before any request, said" \
  || fail "op timeout mktemp fails: rc=$rc calls=$(ncalls) err=$(cat "$T/err")"

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
# ncalls is 3 (HEAD + both initial workers' part GETs) OR 2 (HEAD + one): the two
# workers start concurrently, and whether the second reads its part before the
# first's 403 sets $S3_ABORT (checked at s3_get_worker's loop top) is a race. The
# guarantee under test is that a failed part stops MORE parts from starting — i.e.
# no beyond-the-initial-batch part ever runs, so ncalls never reaches 4. Asserting
# exactly 3 made this flaky (CI saw 2); assert the real guarantee: 2 <= ncalls <= 3,
# exit 4, nothing written.
c=$(ncalls)
[ "$rc" -eq 4 ] && [ "$c" -ge 2 ] && [ "$c" -le 3 ] && [ ! -e "$T/dl/big2w403" ] && no_temps "$T/dl" \
  && pass "get large: a failed part stops the workers starting more (2 workers, 4 parts: HEAD + 1-2 part GETs then abort, exit 4)" \
  || fail "get ranged abort: rc=$rc calls=$c"
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
plan "0 200 $T/big etag=auto" "0 403 - after=503done" "0 503 - emit=503done"
PARALLEL=2 PARALLEL_MIN=1 s3 get woodpecker/a/big "$T/dl/bigmix"; rc=$?
[ "$rc" -eq 4 ] && [ "$(ncalls)" -eq 3 ] && [ -e "$ST/ev.503done" ] && ! grep -q retrying "$T/err" && [ ! -e "$T/dl/bigmix" ] \
  && pass "get large: a 403 on one part and a 503 on another -> the 403 wins: exit 4, no retry" \
  || fail "get ranged 403+503: rc=$rc calls=$(ncalls) ev=$([ -e "$ST/ev.503done" ] && echo ok || echo missing) err=$(cat "$T/err")"
plan "0 200 $T/big etag=auto" "0 403 -"
PARALLEL=4 PARALLEL_MIN=1 s3 get woodpecker/a/big "$T/dl/big403"; rc=$?
c=$(ncalls)
[ "$rc" -eq 4 ] && [ "$c" -ge 2 ] && [ "$c" -le 5 ] && ! grep -q retrying "$T/err" && [ ! -e "$T/dl/big403" ] \
  && pass "get large: a 403 on a range is final (exit 4, one attempt)" || fail "get ranged 403: rc=$rc calls=$c"
echo old > "$T/dl/keep5"
mkdir -p "$T/tmpd"
# Killed runs go without pgrep, which an image without procps lacks and s3.sh
# must not need: one on PATH that finds nothing makes a return to it fail.
mkdir -p "$T/nopgrep"
printf '#!/bin/sh\nexit 1\n' > "$T/nopgrep/pgrep"; chmod +x "$T/nopgrep/pgrep"
# s3.sh is exec'd by a shell with a background job of its own, which becomes
# s3.sh's child but not its work: it must outlive s3.sh, killed or not.
alive() { [ -s "$1" ] && kill -0 "$(cat "$1")" 2>/dev/null; }
# The job keeps no fd 9: it is the caller's, not s3.sh's work.
plan "0 200 $T/big etag=auto" "0 200 $T/big etag=auto stall=1"
life_start
( sleep 3600 9>&- & echo $! > "$T/job"
  PATH="$T/nopgrep:$BIN:$PATH" MINIO_ENDPOINT=http://store.test:9001 MINIO_ACCESS_KEY=ak MINIO_SECRET_KEY=x TMPDIR="$T/tmpd" \
    S3_PARALLEL=4 S3_PARALLEL_MIN_BYTES=1 S3_PART_BYTES=1048576 exec "$S3RUN" "$S3SH" get woodpecker/a/big "$T/dl/keep5" ) 9> "$T/life" 2>/dev/null &
pid=$!
# All four parts in flight, then the signal.
premise=ok; await_events 4 'stalled.*' || premise="$(events 'stalled.*') of 4 parts in flight"
kill -TERM "$pid" 2>/dev/null; await_exit "$pid"
# The parts must be stopped with it: were any still running, it would answer
# once released, and write its header and status files into TMPDIR.
release
gone=ok; life_end || gone="still running"
job=ok; alive "$T/job" || job=gone; kill "$(cat "$T/job")" 2>/dev/null; wait "$(cat "$T/job")" 2>/dev/null || true
[ "$premise" = ok ] && [ "$rc" = 143 ] && [ "$gone" = ok ] && [ "$(cat "$T/dl/keep5")" = old ] && no_temps "$T/dl" \
  && [ -z "$(ls -A "$T/tmpd")" ] && [ "$job" = ok ] \
  && pass "get large: killed mid-transfer (SIGTERM) -> exit 143: parts stopped, old file kept, no temp anywhere, the caller's job left alone" \
  || fail "job=$job; get ranged sigterm: premise=$premise rc=$rc gone=$gone dl=$(ls -A "$T/dl") tmpd=$(ls -A "$T/tmpd")"

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
    S3_PARALLEL=2 S3_PART_BYTES=1048576 timeout -k 10 "$S3T_LIMIT" "$S3RUN" "$S3SH" cat woodpecker/a/big 2> "$T/err"; echo $? > "$T/rc"; } | head -c 100 > /dev/null
rc=$(cat "$T/rc")
[ "$rc" -eq 1 ] && grep -q 'the reader went away' "$T/err" && [ -z "$(ls -A "$T/tmpc")" ] \
  && pass "cat: a reader that stops early -> exit 1, fetches stopped, no temp left" \
  || fail "cat reader gone: rc=$rc err=$(cat "$T/err") tmp=$(ls -A "$T/tmpc")"
for sig in TERM PIPE; do
  case $sig in TERM) sigrc=143 ;; PIPE) sigrc=141 ;; esac
  plan "0 200 $T/big etag=auto" "0 200 $T/big etag=auto stall=1"
  life_start
  ( PATH="$T/nopgrep:$BIN:$PATH" MINIO_ENDPOINT=http://store.test:9001 MINIO_ACCESS_KEY=ak MINIO_SECRET_KEY=x TMPDIR="$T/tmpc" \
      S3_PARALLEL=4 S3_PART_BYTES=1048576 exec "$S3RUN" "$S3SH" cat woodpecker/a/big ) 9> "$T/life" > "$T/out" 2>/dev/null &
  pid=$!
  premise=ok; await_events 4 'stalled.*' || premise="$(events 'stalled.*') of 4 ranges in flight"
  kill -"$sig" "$pid" 2>/dev/null; await_exit "$pid"
  release
  gone=ok; life_end || gone="still running"
  [ "$premise" = ok ] && [ "$rc" = "$sigrc" ] && [ "$gone" = ok ] && [ ! -s "$T/out" ] && [ -z "$(ls -A "$T/tmpc")" ] \
    && pass "cat: killed mid-stream (SIG$sig) -> exit $sigrc: fetches stopped, no temp anywhere" \
    || fail "cat sig$sig: premise=$premise rc=$rc gone=$gone tmp=$(ls -A "$T/tmpc")"
done
# A command that finished leaves the caller's own job running too.
plan "0 200 $T/obj etag=$OBJMD5"
( sleep 3600 & echo $! > "$T/job"
  PATH="$BIN:$PATH" MINIO_ENDPOINT=http://store.test:9001 MINIO_ACCESS_KEY=ak MINIO_SECRET_KEY=x TMPDIR="$T/tmpc" \
    exec "$S3RUN" "$S3SH" stat woodpecker/a/obj ) > /dev/null 2>&1; rc=$?
job=ok; alive "$T/job" || job=gone; kill "$(cat "$T/job")" 2>/dev/null; wait "$(cat "$T/job")" 2>/dev/null || true
[ "$rc" -eq 0 ] && [ "$job" = ok ] && pass "stat: the caller's own background job outlives s3.sh's exit" \
  || fail "caller job on exit: rc=$rc job=$job"
unset PART
# What reaches a part's processes is s3_children. A script's process takes its
# file's name, and these three are named to pass for a child of pid 1 (which
# no process this test starts can be) by a ")", by a newline, and by both:
# s3_children must report each under its real parent, and none under pid 1.
# s3_kill_tree then ends each with its sleep, which outlasts life_end's bound:
# the scripts and their sleeps hold fd 9, and nothing else (their output goes
# to /dev/null, never to the pipe $(...) reads, which a process left behind
# would hold open), so a tree it did not end is a FAIL, and is killed.
mkdir -p "$T/names"
printf '#!/bin/sh\nsleep 600\n' > "$T/names/x"; chmod +x "$T/names/x"
nl='
'
n1='a) S 1 b'; n2="x${nl}1 (y"; n3="a) S 1 b${nl}c"
for n in "$n1" "$n2" "$n3"; do cp "$T/names/x" "$T/names/$n"; done
life_start
got=$(
  S3_SH_SOURCE_ONLY=1; export S3_SH_SOURCE_ONLY
  # shellcheck source=/dev/null
  . "$S3SH"
  # s3.sh turned set -e on: off again, so a step that fails is reported below
  # instead of ending this subshell without a word.
  set +e
  exec 9> "$T/life"
  "$T/names/$n1" > /dev/null 2>&1 & p1=$!
  "$T/names/$n2" > /dev/null 2>&1 & p2=$!
  "$T/names/$n3" > /dev/null 2>&1 & p3=$!
  exec 9>&-
  # Until each has exec'd its script and taken its name, within 300 s.
  named=ok
  # shellcheck disable=SC2016 # expanded by the inner sh
  timeout 300 sh -c '
    while [ "$(cat "/proc/$1/comm" 2>/dev/null)" != "$2" ] \
       || [ "$(cat "/proc/$3/comm" 2>/dev/null)" != "$4" ] \
       || [ "$(cat "/proc/$5/comm" 2>/dev/null)" != "$6" ]; do
      sleep 0.1
    done
  ' _ "$p1" "$n1" "$p2" "$n2" "$p3" "$n3" || named=no
  me=$(sed -n 's/^PPid:[[:space:]]*//p' "/proc/$p1/status")
  s3_children "$me" > "$T/names/kids"
  s3_children 1 > "$T/names/init"
  r=ok
  [ "$named" = ok ] || r="$r, a script never took its name"
  for p in $p1 $p2 $p3; do
    grep -qx "$p" "$T/names/kids" || r="$r, $p missing"
    ! grep -qx "$p" "$T/names/init" || r="$r, $p under pid 1"
    [ -n "$(s3_proc_id "$p")" ] || r="$r, $p proc_id empty before kill"
  done
  ! grep -qx 1 "$T/names/kids" || r="$r, 1 reported"
  for p in $p1 $p2 $p3; do
    s3_kill_tree "$p"
    [ -z "$(s3_proc_id "$p")" ] || r="$r, $p proc_id non-empty after kill"
  done
  echo "$r"
)
gone=ok; life_end || gone="still running"
[ "$got" = ok ] && [ "$gone" = ok ] \
  && pass "s3_children: a name holding \")\", a newline or both cannot move a process to another parent; s3_kill_tree ends each tree" \
  || fail "s3_children names: $got gone=$gone"
# s3_kill_tree must use SIGKILL (not SIGTERM): a newly forked worker subshell
# whose forkchild() has not yet cleared inherited traps can swallow SIGTERM
# and outlive s3_cleanup. Model that deterministically with trap "" TERM.
rm -f "$T/kt_ready" "$T/kt_surv" "$T/kt_gate"
mkfifo "$T/kt_gate"
# shellcheck disable=SC2016 # expanded by the inner sh
kt_rc=$(
  timeout -k 5 30 "$S3RUN" -c '
    S3_SH_SOURCE_ONLY=1; export S3_SH_SOURCE_ONLY
    . "$1"
    set +e
    sh -c '\''trap "" TERM; printf x > "$1"; cat "$2" > /dev/null; printf y > "$3"'\'' \
      _ "$2" "$3" "$4" > /dev/null 2>&1 &
    kp=$!
    timeout 10 sh -c '\''
      until [ -s "$1" ]; do
        st=$(cat "/proc/$2/stat" 2>/dev/null) || exit 1
        case "$st" in *") "*) ;; *) exit 1 ;; esac
        case "${st##*) }" in Z*|X*|"") exit 1 ;; esac
        sleep 0.05
      done
    '\'' _ "$2" "$kp" || true
    s3_kill_tree "$kp"
    ( : > "$3" ) 2>/dev/null &
    gp=$!
    wait "$kp" 2>/dev/null
    rc=$?
    kill -KILL "$gp" 2>/dev/null || true
    wait "$gp" 2>/dev/null || true
    echo "$rc"
  ' _ "$S3SH" "$T/kt_ready" "$T/kt_gate" "$T/kt_surv"
) || kt_rc="timeout:$?"
[ -s "$T/kt_ready" ] && [ ! -e "$T/kt_surv" ] && [ "$kt_rc" = 137 ] \
  && pass "s3_kill_tree: SIGKILL ends a worker even if SIGTERM is ignored or swallowed during forkchild" \
  || fail "s3_kill_tree sigkill: ready=$([ -s "$T/kt_ready" ] && echo yes || echo no) surv=$([ -e "$T/kt_surv" ] && echo yes || echo no) rc=$kt_rc"
# s3_kill_tree must wait until killed descendants (not only the top pid) are
# gone or zombies before returning, so no grandchild can write after s3_cleanup.
rm -f "$T/kt_gcpid"
kt_gc=$(
  S3_SH_SOURCE_ONLY=1; export S3_SH_SOURCE_ONLY
  # shellcheck source=/dev/null
  . "$S3SH"
  set +e
  # shellcheck disable=SC2016 # expanded by the inner sh
  sh -c 'sleep 600 & echo "$!" > "$1"; wait' _ "$T/kt_gcpid" > /dev/null 2>&1 &
  kp=$!
  await_file 10 -s "$T/kt_gcpid" "$kp" || true
  gcp=$(cat "$T/kt_gcpid" 2>/dev/null || true)
  st0=$(s3_proc_id "$gcp")
  s3_kill_tree "$kp"
  st1=$(s3_proc_id "$gcp")
  wait "$kp" 2>/dev/null || true
  printf '%s:%s:%s\n' "${gcp:-none}" "${st0:-none}" "${st1:-gone}"
)
case "$kt_gc" in
  *:*:*)
    _gc_p=${kt_gc%%:*}; _gc_r=${kt_gc#*:}; _gc_0=${_gc_r%%:*}; _gc_1=${_gc_r#*:}
    [ "$_gc_p" != none ] && [ "$_gc_0" != none ] && [ "$_gc_1" = gone ] \
      && pass "s3_kill_tree: waits until killed descendants are gone or zombies before returning" \
      || fail "s3_kill_tree descendant wait: $kt_gc" ;;
esac
# s3_kill_tree must wait until kill -STOP actually places the target in state
# T/t before calling s3_children, so an asynchronous SIGSTOP cannot let a
# worker fork a pipeline child after /proc is globbed and orphan it past
# s3_cleanup. Stub kill -STOP to defer the real SIGSTOP until s3_proc_info is
# polled: an implementation that skips waiting calls s3_children on state S.
rm -f "$T/kt_stop_seen" "$T/kt_stop_sent" "$T/kt_child_state"
# shellcheck disable=SC2016 # expanded by the inner sh
kt_stop_st=$(
  timeout -k 5 15 "$S3RUN" -c '
    S3_SH_SOURCE_ONLY=1; export S3_SH_SOURCE_ONLY
    . "$1"
    set +e
    kp_seen="$2_seen"; child_out="$3"; kp_sent="$4"
    sleep 600 > /dev/null 2>&1 & kp=$!
    kill() {
      if [ "${1:-}" = -STOP ] && [ "${2:-}" = "$kp" ]; then
        : > "$kp_seen"
        return 0
      fi
      command kill "$@"
    }
    s3_proc_info() {
      if [ "$1" = "$kp" ] && [ -e "$kp_seen" ] && [ ! -e "$kp_sent" ]; then
        : > "$kp_sent"
        command kill -STOP "$kp" 2>/dev/null || true
      fi
      (
        _ps=$(cat "/proc/$1/stat" 2>/dev/null) || exit 0
        case "$_ps" in *") "*) _ps=${_ps##*) } ;; *) exit 0 ;; esac
        unset IFS; set -f
        # shellcheck disable=SC2086
        set -- $_ps
        [ "${1:-}" != Z ] && [ "${1:-}" != X ] || exit 0
        printf "%s %s\n" "${1:-}" "${20:-}"
      )
    }
    s3_children() {
      if [ "$1" = "$kp" ]; then
        _cs=$(cat "/proc/$kp/stat" 2>/dev/null || true)
        printf "%s\n" "${_cs##*) }" > "$child_out"
      fi
    }
    s3_kill_tree "$kp"
    wait "$kp" 2>/dev/null || true
    cat "$child_out" 2>/dev/null
  ' _ "$S3SH" "$T/kt_stop" "$T/kt_child_state" "$T/kt_stop_sent"
) || kt_stop_st="timeout:$?"
case "$kt_stop_st" in
  "T "*|"t "*) [ -e "$T/kt_stop_sent" ] \
    && pass "s3_kill_tree: waits for target to reach state T before scanning s3_children" \
    || fail "s3_kill_tree stop wait: sent=no state=$kt_stop_st" ;;
  *) fail "s3_kill_tree stop wait: sent=$([ -e "$T/kt_stop_sent" ] && echo yes || echo no) state=$kt_stop_st" ;;
esac
# s3_cat_once and s3_mp_once must open their hasher FIFOs without blocking: if
# a process-group signal kills md5sum right after fork, a plain `exec 7> FIFO`
# or `exec 8> FIFO` deadlocks in fifo_open/wait_for_partner. Model that by
# having s3_track kill the hasher immediately and verify both return without
# hanging.
rm -f "$T/cf_rcf.fifo" "$T/cf_rcf.r.0" "$T/cf_sum" "$T/mp_fifo" "$T/mp_sum" "$T/mp_md5s" "$T/mp_xml" "$T/mp_part" "$T/mp_dummy"
printf 'x' > "$T/mp_dummy"
printf 'abc' > "$T/cf_rcf.r.0"
# shellcheck disable=SC2016 # expanded by the inner sh
cf_rc=$(
  timeout -k 5 10 "$S3RUN" -c '
    S3_SH_SOURCE_ONLY=1; export S3_SH_SOURCE_ONLY
    . "$1"
    set +e
    S3_HEAD_SIZE=2097152; S3_HEAD_ETAG=e; S3_HEAD_MD5=9dd4e461268c8034f5c8564e155c67a6
    S3_HEAD_MD5_FROM=etag; S3_HEAD_SSE_OPAQUE=0; S3_PART_BYTES=1048576; S3_PARALLEL=1
    S3_RCF="$2/cf_rcf"; S3_SUMF="$2/cf_sum"; S3_HDR="$2/cf_hdr"; S3_CAT_FIFO="$2/cf_rcf.fifo"; S3_CAT_OUT=0
    s3_track() { kill -KILL "$1" 2>/dev/null || true; wait "$1" 2>/dev/null || true; }
    s3_cat_start() { :; }
    s3_cat_wait() { :; }
    s3_cat_check() { if [ "$1" = 0 ]; then S3_CLASS=ok; else S3_CLASS=fatal; S3_WHY=stub; fi; }
    s3_cat_once >/dev/null 2>&1
    echo ok
  ' _ "$S3SH" "$T"
) || cf_rc="timeout:$?"
[ "$cf_rc" = ok ] \
  && pass "cat: hasher FIFO opens and streams via fd 7 without blocking when md5sum dies on signal" \
  || fail "cat fifo nonblocking: $cf_rc"
# shellcheck disable=SC2016 # expanded by the inner sh
mf_rc=$(
  timeout -k 5 10 "$S3RUN" -c '
    S3_SH_SOURCE_ONLY=1; export S3_SH_SOURCE_ONLY
    . "$1"
    set +e
    S3_SRC="$2/mp_dummy"; S3_PUT_PART_BYTES=1048576; S3_MP_ID=up1
    S3_MP_FIFO="$2/mp_fifo"; S3_MP_SUMF="$2/mp_sum"; S3_MP_MD5S="$2/mp_md5s"
    S3_MP_XML="$2/mp_xml"; S3_MP_PART="$2/mp_part"
    s3_run() { case "$2" in s3_mp_init_once) return 0 ;; *) return 1 ;; esac; }
    s3_mp_abort() { :; }
    s3_track() { kill -KILL "$1" 2>/dev/null || true; wait "$1" 2>/dev/null || true; }
    s3_mp_once "stub" >/dev/null 2>&1
    echo ok
  ' _ "$S3SH" "$T"
) || mf_rc="timeout:$?"
[ "$mf_rc" = ok ] \
  && pass "put multipart: hasher FIFO opens without blocking when md5sum dies on signal" \
  || fail "put multipart fifo nonblocking: $mf_rc"
# s3_on_signal and s3_finish must disable set -e before clearing EXIT and
# running cleanup: if a helper inside s3_stop_parts or s3_mp_abort returns
# non-zero (or bash 5.2 propagates a signal-interrupted pipeline's status
# into the trap under errexit), set -e must not abort before s3_mp_abort and
# s3_cleanup run.
mkdir -p "$T/sigerr" "$T/finerr"
rm -f "$T/sigerr.abort" "$T/sigerr.opts" "$T/finerr.abort"
sigerr_rc=0
# shellcheck disable=SC2016 # expanded by the inner sh
timeout -k 5 10 "$S3RUN" -c '
  S3_SH_SOURCE_ONLY=1; export S3_SH_SOURCE_ONLY
  . "$1"
  s3_mktemp S3_HDR "$2"
  _ab=$3
  trap "s3_finish" EXIT
  s3_stop_parts() { return 1; }
  s3_mp_abort() { : > "$_ab"; return 1; }
  s3_on_signal 143
' _ "$S3SH" "$T/sigerr" "$T/sigerr.abort" >/dev/null 2>&1 || sigerr_rc=$?
sigerr_opt_rc=0
# shellcheck disable=SC2016 # expanded by the inner sh
timeout -k 5 10 "$S3RUN" -c '
  S3_SH_SOURCE_ONLY=1; export S3_SH_SOURCE_ONLY
  . "$1"
  _opts=$2
  s3_finish() { printf "%s" "$-" > "$_opts"; }
  s3_on_signal 143
' _ "$S3SH" "$T/sigerr.opts" >/dev/null 2>&1 || sigerr_opt_rc=$?
sigerr_opts=$(cat "$T/sigerr.opts" 2>/dev/null || true)
case "$sigerr_opts" in *e*) sigerr_e=yes ;; *) sigerr_e=no ;; esac
[ "$sigerr_rc" -eq 143 ] && [ "$sigerr_opt_rc" -eq 143 ] && [ "$sigerr_e" = no ] \
  && [ -e "$T/sigerr.abort" ] && no_temps "$T/sigerr" \
  && pass "s3_on_signal: disables set -e before clearing EXIT so abort and cleanup finish and exit 143" \
  || fail "s3_on_signal errexit: rc=$sigerr_rc opt_rc=$sigerr_opt_rc e=$sigerr_e opts=$sigerr_opts abort=$([ -e "$T/sigerr.abort" ] && echo yes || echo no) left=$(find "$T/sigerr" -name '.s3tmp.*' | tr '\n' ' ')"
finerr_rc=0
# shellcheck disable=SC2016 # expanded by the inner sh
timeout -k 5 10 "$S3RUN" -c '
  S3_SH_SOURCE_ONLY=1; export S3_SH_SOURCE_ONLY
  . "$1"
  s3_mktemp S3_HDR "$2"
  _ab=$3
  trap "s3_finish" EXIT
  s3_stop_parts() { return 1; }
  s3_mp_abort() { : > "$_ab"; return 1; }
  exit 0
' _ "$S3SH" "$T/finerr" "$T/finerr.abort" >/dev/null 2>&1 || finerr_rc=$?
[ "$finerr_rc" -eq 0 ] && [ -e "$T/finerr.abort" ] && no_temps "$T/finerr" \
  && pass "s3_finish: disables set -e under EXIT trap so abort and cleanup finish despite failing helpers" \
  || fail "s3_finish errexit: rc=$finerr_rc abort=$([ -e "$T/finerr.abort" ] && echo yes || echo no) left=$(find "$T/finerr" -name '.s3tmp.*' | tr '\n' ' ')"

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

# ---- default single-PUT threshold (5 GiB), retry budget (~5 min jittered), and per-attempt error logging
got=$(
  S3_SH_SOURCE_ONLY=1; export S3_SH_SOURCE_ONLY
  # shellcheck source=/dev/null
  . "$S3SH"
  printf '%s %s %s %s %s\n' "$S3_MAX_PUT_BYTES" "$S3_PUT_PART_BYTES" "$S3_RETRIES" "$S3_RETRY_DELAY" "$S3_RETRY_MAX_DELAY"
)
[ "$got" = "5368709120 33554432 12 2 60" ] \
  && pass "defaults: 5 GiB single-PUT threshold, 32 MiB parts, 12 retries capped at 60s (~5 min jittered budget)" \
  || fail "defaults: got '$got'"
got=$(
  S3_SH_SOURCE_ONLY=1; export S3_SH_SOURCE_ONLY
  # shellcheck source=/dev/null
  . "$S3SH"
  set +e
  tot=0; bad=0; i=1
  while [ "$i" -lt "$S3_RETRIES" ]; do
    w=$(s3_backoff "$i")
    # Unjittered cap for attempt i: min(2^(i), 60), equal jitter in [ceil(d/2), d]
    d=2; k=1; while [ "$k" -lt "$i" ]; do d=$((d * 2)); [ "$d" -lt 60 ] || { d=60; break; }; k=$((k + 1)); done
    lo=$(((d + 1) / 2))
    if [ "$w" -lt "$lo" ] || [ "$w" -gt "$d" ]; then bad=$((bad + 1)); fi
    tot=$((tot + w))
    i=$((i + 1))
  done
  printf '%s %s\n' "$bad" "$tot"
)
bad_j=${got%% *}; tot_j=${got#* }
[ "$bad_j" -eq 0 ] && [ "$tot_j" -ge 211 ] && [ "$tot_j" -le 422 ] \
  && pass "s3_backoff: equal jitter stays in [ceil(d/2), d] with total budget ${tot_j}s in [211, 422]s" \
  || fail "s3_backoff jitter: bad=$bad_j tot=$tot_j"
printf '<Error><Code>InternalError</Code><Message>no free volumes</Message></Error>' > "$T/full.xml"
plan "0 500 $T/full.xml" "0 500 $T/full.xml" "0 200 - etag=$OBJMD5" "0 200 $T/obj etag=$OBJMD5"
RETRIES=4 s3 put "$T/obj" woodpecker/a/obj; rc=$?
[ "$rc" -eq 0 ] && grep -q 'attempt 1/4 failed (HTTP 500 InternalError: no free volumes)' "$T/err" \
  && grep -q 'attempt 2/4 failed (HTTP 500 InternalError: no free volumes)' "$T/err" \
  && pass "put: each retry attempt logs HTTP status, S3 Code and S3 Message" \
  || fail "put per-attempt error msg: rc=$rc err=$(cat "$T/err")"

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
# Signal while CreateMultipartUpload is in flight: S3_BODY is truncated and
# S3_MP_PENDING is set BEFORE the POST, so a signal handled after curl returns
# aborts this run's own upload from S3_BODY without ever listing or touching
# another run's upload of the same key.
for msh in sh dash bash; do
  command -v "$msh" > /dev/null 2>&1 || continue
  mshl=$msh; [ "$msh" != sh ] || mshl="sh = $(readlink -f "$(command -v sh)")"
  td="$T/mppi-$msh"; mkdir -p "$td"
  plan "0 200 $T/mpinit.xml stall=1 emit=init" "0 204 -"
  life_start
  ( PATH="$BIN:$PATH" TMPDIR="$td" MINIO_ENDPOINT=http://store.test:9001 MINIO_ACCESS_KEY=ak MINIO_SECRET_KEY=x \
      S3_MAX_PUT_BYTES=1048576 S3_PUT_PART_BYTES=1048576 S3_RETRY_DELAY=0 \
      exec "$msh" "$S3SH" put "$T/mpf" woodpecker/a/mp ) 9> "$T/life" 2>/dev/null &
  pid=$!
  premise=ok; await_events 1 'stalled.*' || premise="init never in flight"
  [ "$premise" != ok ] || head -n 1 "$ST/calls.log" | grep -q '^POST http://store.test:9001/woodpecker/a/mp?uploads=' \
    || premise="first call is not init: $(head -n 1 "$ST/calls.log")"
  kill -TERM "$pid" 2>/dev/null; release; await_exit "$pid"
  gone=ok; life_end || gone="still running"
  [ "$premise" = ok ] && [ "$rc" = 143 ] && [ "$gone" = ok ] && [ -e "$ST/ev.init" ] && [ "$(ncalls)" -eq 2 ] \
    && sed -n 2p "$ST/calls.log" | grep -q "^DELETE http://store.test:9001/woodpecker/a/mp?uploadId=$EID$" \
    && no_temps "$td" \
    && pass "put multipart ($mshl): SIGTERM while CreateMultipartUpload is in flight -> exit 143, aborts own upload from response body, no temp left" \
    || fail "put multipart ($mshl) pid sigterm in init: premise=$premise rc=$rc gone=$gone calls=$(cat "$ST/calls.log") left=$(find "$td" -name '.s3tmp.*' | tr '\n' ' ')"
done
# Process-group SIGTERM while CreateMultipartUpload is in flight: curl dies
# before writing S3_BODY, so this run cannot prove which UploadId on the key
# is its own. It must NOT call ListMultipartUploads or DELETE any foreign
# upload on the same key (cache/commit keys have concurrent writers).
cat > "$T/mpforeign.xml" <<'EOF'
<ListMultipartUploadsResult><Bucket>woodpecker</Bucket><Prefix>a/mp</Prefix><IsTruncated>false</IsTruncated><Upload><Key>a/mp</Key><UploadId>foreign-writer-id</UploadId></Upload></ListMultipartUploadsResult>
EOF
for msh in sh dash bash; do
  command -v "$msh" > /dev/null 2>&1 || continue
  mshl=$msh; [ "$msh" != sh ] || mshl="sh = $(readlink -f "$(command -v sh)")"
  td="$T/mpgi-$msh"; mkdir -p "$td"
  plan "0 200 $T/mpinit.xml stall=1 emit=init" "0 200 $T/mpforeign.xml" "0 204 -"
  life_start
  # shellcheck disable=SC2016 # expanded by the inner sh
  ( PATH="$BIN:$PATH" TMPDIR="$td" MINIO_ENDPOINT=http://store.test:9001 MINIO_ACCESS_KEY=ak MINIO_SECRET_KEY=x \
      S3_MAX_PUT_BYTES=1048576 S3_PUT_PART_BYTES=1048576 S3_RETRY_DELAY=0 \
      exec setsid sh -c 'echo "$$" > "$1"; shift; exec "$@"' _ "$ST/gpid" "$msh" "$S3SH" put "$T/mpf" woodpecker/a/mp ) 9> "$T/life" 2>/dev/null &
  pid=$!
  premise=ok; await_events 1 'stalled.*' || premise="init never in flight"
  gpid=$(cat "$ST/gpid" 2>/dev/null || true)
  if [ "$premise" = ok ]; then
    [ "$gpid" = "$pid" ] || premise="pgid $gpid != pid $pid"
  fi
  if [ "$premise" = ok ]; then
    kill -TERM "-$gpid" 2>/dev/null || premise="group kill failed"
  fi
  await_exit "$pid"
  release
  gone=ok; life_end || gone="still running"
  [ "$premise" = ok ] && [ "$rc" = 143 ] && [ "$gone" = ok ] && [ ! -e "$ST/ev.init" ] && [ "$(ncalls)" -eq 1 ] \
    && sed -n 1p "$ST/calls.log" | grep -q '^POST http://store.test:9001/woodpecker/a/mp?uploads=' \
    && no_temps "$td" \
    && pass "put multipart ($mshl): process-group SIGTERM during init -> exit 143, does not list or abort another run's upload on the same key, no temp left" \
    || fail "put multipart ($mshl) group sigterm in init: premise=$premise rc=$rc gone=$gone ev=$([ -e "$ST/ev.init" ] && echo yes || echo no) calls=$(tr '\n' ';' < "$ST/calls.log") left=$(find "$td" -name '.s3tmp.*' | tr '\n' ' ')"
done
# A second process-group SIGTERM while s3_mp_abort is in flight (e.g. double
# ^C or repeated group SIGTERM) must not kill curl or cut the abort DELETE
# short: s3_on_signal sets trap '' HUP INT PIPE TERM so its child inherits it.
td="$T/mp2term"; mkdir -p "$td"
plan "0 200 $T/mpinit.xml" "0 200 - etag=up stall=1" "0 204 - stall=1 emit=del"
life_start
# shellcheck disable=SC2016 # expanded by the inner sh
( PATH="$BIN:$PATH" TMPDIR="$td" MINIO_ENDPOINT=http://store.test:9001 MINIO_ACCESS_KEY=ak MINIO_SECRET_KEY=x \
    S3_MAX_PUT_BYTES=1048576 S3_PUT_PART_BYTES=1048576 S3_RETRY_DELAY=0 \
    exec setsid sh -c 'echo "$$" > "$1"; shift; exec "$@"' _ "$ST/gpid" "$S3RUN" "$S3SH" put "$T/mpf" woodpecker/a/mp ) 9> "$T/life" 2>/dev/null &
pid=$!
premise=ok; await_events 1 'stalled.2' || premise="part 1 never in flight"
gpid=$(cat "$ST/gpid" 2>/dev/null || true)
[ "$premise" != ok ] || [ "$gpid" = "$pid" ] || premise="pgid $gpid != pid $pid"
if [ "$premise" = ok ]; then
  kill -TERM "-$gpid" 2>/dev/null || premise="first group kill failed"
  await_events 1 'stalled.3' || premise="abort DELETE never in flight"
fi
if [ "$premise" = ok ]; then
  kill -TERM "-$gpid" 2>/dev/null || true
fi
release
await_exit "$pid"
gone=ok; life_end || gone="still running"
[ "$premise" = ok ] && [ "$rc" = 143 ] && [ "$gone" = ok ] && [ -e "$ST/ev.del" ] && [ "$(ncalls)" -eq 3 ] \
  && sed -n 3p "$ST/calls.log" | grep -q "^DELETE http://store.test:9001/woodpecker/a/mp?uploadId=$EID$" \
  && no_temps "$td" \
  && pass "put multipart: second group SIGTERM during s3_mp_abort does not cut or re-enter the abort DELETE" \
  || fail "put multipart second sigterm: premise=$premise rc=$rc gone=$gone ev=$([ -e "$ST/ev.del" ] && echo yes || echo no) calls=$(tr '\n' ';' < "$ST/calls.log") left=$(find "$td" -name '.s3tmp.*' | tr '\n' ' ')"
# Restarting a multipart upload must truncate S3_BODY before the new
# CreateMultipartUpload POST, so a group SIGTERM on the retry's init does not
# read the prior attempt's UploadId from S3_BODY and send a stale DELETE.
cp "$T/mpf" "$T/mpsrc"
td="$T/mpstale"; mkdir -p "$td"
plan "0 200 $T/mpinit.xml" "0 200 - etag=up grow=$T/mpsrc" "0 200 - etag=up" "0 204 -" "0 200 $T/mpinit.xml stall=1 emit=init2" "0 204 -"
life_start
# shellcheck disable=SC2016 # expanded by the inner sh
( PATH="$BIN:$PATH" TMPDIR="$td" MINIO_ENDPOINT=http://store.test:9001 MINIO_ACCESS_KEY=ak MINIO_SECRET_KEY=x \
    S3_MAX_PUT_BYTES=1048576 S3_PUT_PART_BYTES=1048576 S3_RETRY_DELAY=0 \
    exec setsid sh -c 'echo "$$" > "$1"; shift; exec "$@"' _ "$ST/gpid" "$S3RUN" "$S3SH" put "$T/mpsrc" woodpecker/a/mp ) 9> "$T/life" 2>/dev/null &
pid=$!
premise=ok; await_events 1 'stalled.5' || premise="retry init never in flight"
gpid=$(cat "$ST/gpid" 2>/dev/null || true)
[ "$premise" != ok ] || [ "$gpid" = "$pid" ] || premise="pgid $gpid != pid $pid"
if [ "$premise" = ok ]; then
  kill -TERM "-$gpid" 2>/dev/null || premise="group kill failed"
fi
await_exit "$pid"; release; gone=ok; life_end || gone="still running"
[ "$premise" = ok ] && [ "$rc" = 143 ] && [ "$gone" = ok ] && [ ! -e "$ST/ev.init2" ] && [ "$(ncalls)" -eq 5 ] \
  && no_temps "$td" \
  && pass "put multipart: retry truncates S3_BODY before init POST so group SIGTERM does not re-DELETE prior attempt's UploadId" \
  || fail "put multipart stale body on retry: premise=$premise rc=$rc gone=$gone calls=$(tr '\n' ';' < "$ST/calls.log")"
# A clean HTTP refusal on CreateMultipartUpload created no upload and must not
# trigger any abort call on exit.
plan "0 403 -"
mps put "$T/mpf" woodpecker/a/mp; rc=$?
[ "$rc" -eq 4 ] && [ "$(ncalls)" -eq 1 ] \
  && pass "put multipart: 403 on CreateMultipartUpload -> exit 4, no abort call on exit" \
  || fail "put multipart init 403: rc=$rc calls=$(cat "$ST/calls.log")"
# An unanswered CreateMultipartUpload (curl 28) followed by a successful retry
# must NOT list or sweep other runs' uploads of the same key on normal exit.
plan "28 - -" "0 200 $T/mpinit.xml" "0 200 - etag=up" "0 200 - etag=up" "0 200 - etag=up" \
  "0 200 $T/mpdone.xml" "0 200 $T/mpf etag=$WANTMP meta=auto"
mps put "$T/mpf" woodpecker/a/mp; rc=$?
[ "$rc" -eq 0 ] && [ "$(ncalls)" -eq 7 ] \
  && ! grep -q '^GET .*uploads=' "$ST/calls.log" \
  && ! grep -q '^DELETE ' "$ST/calls.log" \
  && pass "put multipart: unanswered init attempt (curl 28) + retry completes without listing or aborting foreign uploads" \
  || fail "put multipart unanswered init no sweep: rc=$rc calls=$(tr '\n' ';' < "$ST/calls.log") err=$(cat "$T/err")"
PIPEMD5=$(printf 'piped\n' | md5sum | cut -d' ' -f1)
printf 'piped\n' > "$T/piped"
plan "0 200 - etag=$PIPEMD5" "0 200 $T/piped etag=$PIPEMD5"
printf 'piped\n' | PATH="$BIN:$PATH" MINIO_ENDPOINT=http://store.test:9001 MINIO_ACCESS_KEY=ak \
  MINIO_SECRET_KEY="$SECRET" S3_RETRY_DELAY=0 timeout -k 10 "$S3T_LIMIT" "$S3RUN" "$S3SH" put - woodpecker/a/p > "$T/out" 2> "$T/err"; rc=$?
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
cat > "$T/ls3.xml" <<'X'
<ListBucketResult><IsTruncated>true</IsTruncated><Contents><Key>p/a</Key></Contents><NextContinuationToken>same</NextContinuationToken></ListBucketResult>
X
# Then a 404, so a listing that did not stop there ends anyway (the test
# never hangs on it).
plan "0 200 $T/ls3.xml" "0 200 $T/ls3.xml" "0 404 -"
s3 ls woodpecker p/; rc=$?
[ "$rc" -eq 1 ] && [ "$(ncalls)" -eq 2 ] && grep -q 'the listing does not advance' "$T/err" \
  && pass "ls: a store that answers with the token it was sent ends the listing (exit 1), never lists forever" \
  || fail "ls repeated token: rc=$rc calls=$(ncalls) err=$(cat "$T/err")"
# A cycle of two: t1, t2, then t1 again.
printf '<ListBucketResult><IsTruncated>true</IsTruncated><Contents><Key>p/a</Key></Contents><NextContinuationToken>t1</NextContinuationToken></ListBucketResult>' > "$T/ls4.xml"
printf '<ListBucketResult><IsTruncated>true</IsTruncated><Contents><Key>p/b</Key></Contents><NextContinuationToken>t2</NextContinuationToken></ListBucketResult>' > "$T/ls5.xml"
plan "0 200 $T/ls4.xml" "0 200 $T/ls5.xml" "0 200 $T/ls4.xml" "0 404 -"
s3 ls woodpecker p/; rc=$?
[ "$rc" -eq 1 ] && [ "$(ncalls)" -eq 3 ] && grep -q 'the listing does not advance' "$T/err" \
  && pass "ls: a store whose tokens go round in a cycle ends the listing (exit 1)" \
  || fail "ls token cycle: rc=$rc calls=$(ncalls) err=$(cat "$T/err")"
plan "0 404 -"
s3 ls nobucket p/; rc=$?
[ "$rc" -eq 1 ] && pass "ls: missing bucket -> exit 1, never an empty listing" || fail "ls nobucket: rc=$rc"

# ---- secrets, configuration, usage
if ! grep -qF "$SECRET" "$ST/argv.log" 2>/dev/null && grep -qF 'user = "ak:s3cr3t\"with\\quote"' "$ST/stdin.log"; then
  pass "the secret never appears in curl's argv; it arrives on stdin, quoted for curl's config syntax"
else fail "secret handling: argv=$(grep -c . "$ST/argv.log") stdin=$(cat "$ST/stdin.log")"; fi
plan "0 403 -"
PATH="$BIN:$PATH" MINIO_ENDPOINT=http://store.test:9001 MINIO_ACCESS_KEY=ak MINIO_SECRET_KEY="$SECRET" \
  timeout -k 10 "$S3T_LIMIT" "$S3RUN" -x "$S3SH" stat woodpecker/a/b > "$T/out" 2> "$T/err"
! grep -qF "$SECRET" "$T/err" && pass "sh -x does not trace the secret (xtrace is switched off)" \
  || fail "secret leaked under sh -x"
plan "0 200 $T/obj etag=$OBJMD5"
PATH="$BIN:$PATH" MINIO_ENDPOINT=store.test:9001 MINIO_USE_SSL=true MINIO_ACCESS_KEY=ak MINIO_SECRET_KEY=x \
  timeout -k 10 "$S3T_LIMIT" "$S3RUN" "$S3SH" stat woodpecker/a/b > /dev/null 2>&1
grep -q '^HEAD https://store.test:9001/woodpecker/a/b' "$ST/calls.log" && pass "endpoint without a scheme + MINIO_USE_SSL=true -> https" \
  || fail "use_ssl: $(cat "$ST/calls.log")"
plan "0 200 $T/obj etag=$OBJMD5"
PATH="$BIN:$PATH" MINIO_ENDPOINT=store.test:9001/ MINIO_ACCESS_KEY=ak MINIO_SECRET_KEY=x \
  timeout -k 10 "$S3T_LIMIT" "$S3RUN" "$S3SH" stat woodpecker/a/b > /dev/null 2>&1
grep -q '^HEAD http://store.test:9001/woodpecker/a/b' "$ST/calls.log" && pass "endpoint without a scheme defaults to http; trailing / dropped" \
  || fail "no scheme: $(cat "$ST/calls.log")"
for bad in "put $T/obj woodpecker" "get woodpecker" "stat Woodpecker/x" "frob a b" "presign woodpecker/a 604801" \
           "put $T/obj woodpecker/prefix/" "copy woodpecker/a woodpecker/b/"; do
  plan "0 200 -"
  # shellcheck disable=SC2086 # word-split on purpose: one case per string
  s3 $bad; rc=$?
  [ "$rc" -eq 2 ] && [ "$(ncalls)" -eq 0 ] && pass "usage error -> exit 2, no request: $bad" || fail "usage '$bad': rc=$rc"
done
PATH="$BIN:$PATH" MINIO_ENDPOINT='' MINIO_ACCESS_KEY=ak MINIO_SECRET_KEY=x timeout -k 10 "$S3T_LIMIT" "$S3RUN" "$S3SH" stat woodpecker/a/b > /dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && pass "unset MINIO_ENDPOINT -> exit 2" || fail "no endpoint: rc=$rc"
PATH="$BIN:$PATH" MINIO_ENDPOINT=http://h/path MINIO_ACCESS_KEY=ak MINIO_SECRET_KEY=x timeout -k 10 "$S3T_LIMIT" "$S3RUN" "$S3SH" stat woodpecker/a/b > /dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && pass "an endpoint with a path -> exit 2" || fail "endpoint path: rc=$rc"

# ---- S3_OP_TIMEOUT: time without progress, retries included
# On the fake clock (see the stubs): each case starts at 1000 and asserts the
# exact calls, never an elapsed time. Progress is a request answered in full
# (a 2xx, curl exit 0); each starts S3_OP_TIMEOUT again.
clk() { echo 1000 > "$T/clock"; }
# tick N: N s pass on the fake clock at once, written as the stub's sleep N
# writes them under FAKE_CLOCK (with no FAKE_SLEEP_LATE), for a case's own
# side of a pipe (stdin that arrives late, a reader that stops). Nothing
# waits: no real time is spent.
tick() { echo $(( $(cat "$T/clock") + $1 )) > "$T/clock.tick" && mv -f "$T/clock.tick" "$T/clock"; }
opt() { # opt VAR=VALUE... VERB ARGS...: s3.sh on the fake clock, stub curl
  _opt_env=
  while [ $# -gt 0 ]; do case $1 in *=*) _opt_env="$_opt_env $1"; shift ;; *) break ;; esac; done
  # shellcheck disable=SC2086 # one word per VAR=VALUE, none with a space
  FAKE_CLOCK=$T/clock PATH="$BIN:$PATH" MINIO_ENDPOINT=http://store.test:9001 MINIO_ACCESS_KEY=ak MINIO_SECRET_KEY=x \
    env $_opt_env timeout -k 10 "$S3T_LIMIT" "$S3RUN" "$S3SH" "$@"; }
# A store that answers nothing but 503, doubling backoff with equal jitter
# from 1 s: call 1 at 1000 (backoff 1 s, deterministic), call 2 at 1001; the
# next backoff is in [1, 2] s so it would start at >= 1002, the deadline:
# exit 5, saying so, long before S3_RETRIES runs out. The connect timeout is
# cut to what is left (2, then 1), a time the store has not answered in;
# nothing that bounds a transfer is: the stall window stays S3_LOW_SPEED_TIME
# and --max-time S3_MAX_TIME, so a transfer that moves is never cut.
clk; plan "0 503 -"
opt S3_RETRIES=10 S3_RETRY_DELAY=1 S3_OP_TIMEOUT=2 stat woodpecker/a/b > /dev/null 2> "$T/err"; rc=$?
[ "$rc" -eq 5 ] && [ "$(ncalls)" -eq 2 ] && grep -q 'S3_OP_TIMEOUT=2s reached without progress' "$T/err" \
  && sed -n 1p "$ST/argv.log" | grep -q -- '--connect-timeout 2 ' && sed -n 2p "$ST/argv.log" | grep -q -- '--connect-timeout 1 ' \
  && sed -n 2p "$ST/argv.log" | grep -q -- '--speed-time 60 ' && sed -n 2p "$ST/argv.log" | grep -q -- '--max-time 3600 ' \
  && pass "S3_OP_TIMEOUT: 503s stop at the deadline after exactly 2 calls (exit 5); the connect timeout is cut to what is left, never the stall window or the transfer" \
  || fail "op timeout: rc=$rc calls=$(ncalls) err=$(cat "$T/err") argv=$(cat "$ST/argv.log")"
# Its time starts at the first request: local work before it (here, stdin
# arriving 4 s late, longer than S3_OP_TIMEOUT) is not the store's to answer.
# The stdin side waits until s3.sh has set its deadline (its first temp file
# appears), then lets the fake clock pass it; or until s3.sh has exited, so a
# regression that ends it before then fails this case instead of hanging it.
# Only tick moves the clock here (the plan has no sleep=, and a backoff of
# S3_RETRY_DELAY=0 adds nothing), so it ends at 1004 exactly: a tick that
# moved it by anything else, or not at all, fails this case.
clk; plan "0 200 - etag=$OBJMD5" "0 200 $T/obj etag=$OBJMD5"; mkdir "$T/ptmp"; rm -f "$T/prc"
{ until [ -n "$(ls -A "$T/ptmp")" ] || [ -e "$T/prc" ]; do sleep 1; done; tick 4; cat "$T/obj"; } \
  | { rc=0; opt TMPDIR="$T/ptmp" S3_RETRIES=3 S3_RETRY_DELAY=0 S3_OP_TIMEOUT=3 put - woodpecker/a/obj > /dev/null 2> "$T/err" || rc=$?; echo "$rc" > "$T/prc"; }
rc=$(cat "$T/prc"); rm -rf "$T/ptmp" "$T/prc"
[ "$rc" -eq 0 ] && [ "$(ncalls)" -eq 2 ] && cmp -s "$T/obj" "$ST/uploaded" && [ "$(cat "$T/clock")" = 1004 ] \
  && pass "S3_OP_TIMEOUT: its time starts at the first request, not before (stdin 4 s late, OP=3)" \
  || fail "op timeout first request: rc=$rc calls=$(ncalls) clock=$(cat "$T/clock") err=$(cat "$T/err")"
# A 503 is not progress: with a constant 1 s backoff, calls at 1000, 1001 and
# 1002, then the deadline (were it progress, all 10 attempts would be made).
clk; plan "0 503 -"
opt S3_RETRIES=10 S3_RETRY_DELAY=1 S3_RETRY_MAX_DELAY=1 S3_OP_TIMEOUT=3 stat woodpecker/a/b > /dev/null 2> "$T/err"; rc=$?
[ "$rc" -eq 5 ] && [ "$(ncalls)" -eq 3 ] && pass "S3_OP_TIMEOUT: an error answer is not progress (3 calls at a constant backoff)" \
  || fail "op timeout 503 constant: rc=$rc calls=$(ncalls) err=$(cat "$T/err")"
# Once the deadline is reached, no request is made, whatever the retry gate
# saw before its wait. Here every backoff ends 2 s late, as on a loaded box:
# the 503 at 1000 is retried, its 1 s wait (to 1001, before the deadline,
# 1003) ends at 1003, and the second attempt is refused before any request,
# as curl's timeout (28): exit 5, one call, the clock at 1003.
clk; plan "0 503 -"
opt FAKE_SLEEP_LATE=2 S3_RETRIES=10 S3_RETRY_DELAY=1 S3_RETRY_MAX_DELAY=1 S3_OP_TIMEOUT=3 stat woodpecker/a/b > /dev/null 2> "$T/err"; rc=$?
[ "$rc" -eq 5 ] && [ "$(ncalls)" -eq 1 ] && [ "$(cat "$T/clock")" = 1003 ] \
  && grep -q 'gave up after 2 attempt(s), S3_OP_TIMEOUT=3s reached without progress before the next retry: curl exit 28$' "$T/err" \
  && pass "S3_OP_TIMEOUT: no request is made once the deadline is reached (a wait that ended late; exit 5)" \
  || fail "op timeout deadline reached: rc=$rc calls=$(ncalls) clock=$(cat "$T/clock") err=$(cat "$T/err")"
# One second less late, 1 s is left: the request is made, its connect timeout
# cut to that second.
clk; plan "0 503 -"
opt FAKE_SLEEP_LATE=1 S3_RETRIES=10 S3_RETRY_DELAY=1 S3_RETRY_MAX_DELAY=1 S3_OP_TIMEOUT=3 stat woodpecker/a/b > /dev/null 2> "$T/err"; rc=$?
[ "$rc" -eq 5 ] && [ "$(ncalls)" -eq 2 ] && [ "$(cat "$T/clock")" = 1002 ] \
  && sed -n 2p "$ST/argv.log" | grep -q -- '--connect-timeout 1 ' \
  && pass "S3_OP_TIMEOUT: with 1 s left a request is still made, its connect timeout cut to 1 s" \
  || fail "op timeout 1 s left: rc=$rc calls=$(ncalls) clock=$(cat "$T/clock") err=$(cat "$T/err") argv=$(cat "$ST/argv.log")"
# Nor is a 2xx whose body did not arrive whole: a 200 that stalls until 1003
# (curl 28) leaves no time for a retry.
clk; plan "28 200 $T/obj sleep=3"
opt S3_RETRIES=3 S3_RETRY_DELAY=0 S3_OP_TIMEOUT=3 S3_PARALLEL=1 get woodpecker/a/b "$T/progress.out" > /dev/null 2> "$T/err"; rc=$?
[ "$rc" -eq 5 ] && [ "$(ncalls)" -eq 1 ] && [ ! -e "$T/progress.out" ] \
  && pass "S3_OP_TIMEOUT: a 2xx whose body stalled is not progress (no retry past the deadline)" \
  || fail "op timeout stalled 2xx: rc=$rc calls=$(ncalls) err=$(cat "$T/err")"
# An answer in full is progress, even one that fails its MD5 check: the first
# 200 arrives at 1003, the deadline, and the retry is still made, and passes.
# S3_OP_TIMEOUT used to bound the whole command, and this gave up (exit 6)
# with the store answering, as a slow but moving transfer did on a loaded runner.
clk; plan "0 200 $T/obj etag=0123456789abcdef0123456789abcdef sleep=3" "0 200 $T/obj etag=$OBJMD5"
opt S3_RETRIES=3 S3_RETRY_DELAY=0 S3_OP_TIMEOUT=3 S3_PARALLEL=1 get woodpecker/a/b "$T/progress.out" > /dev/null 2> "$T/err"; rc=$?
[ "$rc" -eq 0 ] && [ "$(ncalls)" -eq 2 ] && cmp -s "$T/obj" "$T/progress.out" \
  && pass "S3_OP_TIMEOUT: an answer in full starts it again (a retry after a slow 200 is made, and passes)" \
  || fail "op timeout progress: rc=$rc calls=$(ncalls) err=$(cat "$T/err")"
rm -f "$T/progress.out"
# cat fetches each range in a process of its own, forked before the answers
# that came since: each range is answered a second later (1001..1004), so
# every one after the first starts past the HEAD's deadline (1002), and must
# see the progress made since and be made, with no retry.
head -c 4194304 /dev/urandom > "$T/big4"
clk; plan "0 200 $T/big4 etag=auto" "0 200 $T/big4 etag=auto sleep=1"
opt S3_RETRIES=3 S3_RETRY_DELAY=0 S3_OP_TIMEOUT=2 S3_PARALLEL=1 S3_PART_BYTES=1048576 cat woodpecker/a/b > "$T/cat.out" 2> "$T/err"; rc=$?
[ "$rc" -eq 0 ] && [ "$(ncalls)" -eq 5 ] && cmp -s "$T/big4" "$T/cat.out" && ! grep -q retrying "$T/err" \
  && pass "S3_OP_TIMEOUT: a range fetched in the background sees the progress made since it was forked" \
  || fail "op timeout cat ranges: rc=$rc calls=$(ncalls) err=$(cat "$T/err")"
# The reader taking a range is progress too: a reader that stops for 3 s, a
# whole S3_OP_TIMEOUT, while a range is written to it is not taken for a
# store that does not answer, and the next range is still fetched. As above,
# only the reader's tick moves the clock, so it ends at 1003 exactly.
clk; plan "0 200 $T/big4 etag=auto"
{ rc=0; opt S3_RETRIES=3 S3_RETRY_DELAY=0 S3_OP_TIMEOUT=2 S3_PARALLEL=1 S3_PART_BYTES=1048576 cat woodpecker/a/b 2> "$T/err" || rc=$?; echo "$rc" > "$T/rc"; } \
  | { dd bs=65536 count=4 2>/dev/null; tick 3; cat; } > "$T/cat.out"
rc=$(cat "$T/rc")
[ "$rc" -eq 0 ] && [ "$(ncalls)" -eq 5 ] && cmp -s "$T/big4" "$T/cat.out" && ! grep -qE 'retrying|gave up' "$T/err" \
  && [ "$(cat "$T/clock")" = 1003 ] \
  && pass "S3_OP_TIMEOUT: a slow reader is not taken for a store that does not answer" \
  || fail "op timeout slow reader: rc=$rc calls=$(ncalls) clock=$(cat "$T/clock") err=$(cat "$T/err")"
rm -f "$T/big4" "$T/cat.out"
# presign signs locally, so with S3_OP_TIMEOUT too it needs no temp file: it
# works where there is no temp directory to make one in.
PATH="$BIN:$PATH" TMPDIR=$T/no-such-dir MINIO_ENDPOINT=http://h MINIO_ACCESS_KEY=ak MINIO_SECRET_KEY=x S3_OP_TIMEOUT=5 \
  timeout -k 10 "$S3T_LIMIT" "$S3RUN" "$S3SH" presign woodpecker/a 60 > /dev/null 2> "$T/err"; rc=$?
[ "$rc" -eq 0 ] && pass "S3_OP_TIMEOUT: presign makes no progress file (it signs with no temp directory)" \
  || fail "presign op timeout: rc=$rc err=$(cat "$T/err")"
# A multipart upload's abort on the way to a restart is not progress: the
# source grows mid-upload (detected after part 2, at 1000), and the abort is
# answered at 1005, past the deadline (1003), so the restart is not made.
cp "$T/mpf" "$T/mpsrc"
clk; plan "0 200 $T/mpinit.xml" "0 200 - etag=up grow=$T/mpsrc" "0 200 - etag=up" "0 204 - sleep=5" \
  "0 200 $T/mpinit.xml" "0 200 - etag=up" "0 200 - etag=up" "0 200 - etag=up" "0 200 -" \
  "0 200 $T/mpgrown etag=$WANTGROWN meta=auto"
opt S3_MAX_PUT_BYTES=1048576 S3_PUT_PART_BYTES=1048576 S3_RETRIES=3 S3_RETRY_DELAY=0 S3_OP_TIMEOUT=3 put "$T/mpsrc" woodpecker/a/mp > /dev/null 2> "$T/err"; rc=$?
[ "$rc" -eq 6 ] && [ "$(ncalls)" -eq 4 ] && sed -n 4p "$ST/calls.log" | grep -q '^DELETE ' && grep -q 'S3_OP_TIMEOUT=3s reached' "$T/err" \
  && pass "S3_OP_TIMEOUT: a multipart abort's answer is not progress (no restart past the deadline)" \
  || fail "op timeout mp abort: rc=$rc calls=$(ncalls) err=$(cat "$T/err")"
plan "0 200 $T/obj etag=$OBJMD5"
s3 stat woodpecker/a/b; sed -n 1p "$ST/argv.log" | grep -q -- '--max-time 3600 ' && sed -n 1p "$ST/argv.log" | grep -q -- '--speed-time 60 ' \
  && pass "no S3_OP_TIMEOUT: the per-attempt ceiling is S3_MAX_TIME, the stall window S3_LOW_SPEED_TIME" || fail "max-time default: $(sed -n 1p "$ST/argv.log")"

# ---- presign signs the Host a client sends: no default port
pre() { MINIO_ENDPOINT=$1 MINIO_ACCESS_KEY=AKIAIOSFODNN7EXAMPLE MINIO_SECRET_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY \
  S3_PRESIGN_DATE=20130524T000000Z S3_ADDRESSING=${2:-path} S3_REGION=${S3_REGION:-${3:-us-east-1}} PATH="$BIN:$PATH" \
  timeout -k 10 "$S3T_LIMIT" "$S3RUN" "$S3SH" presign examplebucket/test.txt 86400; }
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
    timeout -k 10 "$S3T_LIMIT" "$S3RUN" "$S3SH" stat woodpecker/a/b > /dev/null 2> "$T/err"; rc=$?
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
  # Live foreign-upload survival against SeaweedFS 4.47: another writer opens a
  # multipart upload on the SAME key. s3_mp_abort with no response body (as on a
  # group signal during init) must leave the foreign upload intact; s3_mp_abort
  # with our own UploadId in S3_BODY must abort only our upload while the
  # foreign upload on the same key survives and remains open.
  foreign_uid=$(raw -X POST "${MINIO_ENDPOINT%/}/$B/$P/mp-shared?uploads=" | tr -d '\r\n' | sed -n 's:.*<UploadId>\([^<]*\)</UploadId>.*:\1:p')
  own_xml=$(raw -X POST "${MINIO_ENDPOINT%/}/$B/$P/mp-shared?uploads=")
  own_uid=$(printf '%s' "$own_xml" | tr -d '\r\n' | sed -n 's:.*<UploadId>\([^<]*\)</UploadId>.*:\1:p')
  (
    S3_SH_SOURCE_ONLY=1; export S3_SH_SOURCE_ONLY
    # shellcheck source=/dev/null
    . "$S3SH"
    s3_config
    s3_split "$B/$P/mp-shared"
    s3_mktemp S3_MP_HDR "$L"; s3_mktemp S3_BODY "$L"
    # shellcheck disable=SC2034 # consumed by s3_mp_abort in sourced s3.sh
    S3_MP_PENDING=1
    s3_mp_abort
    printf '%s' "$own_xml" > "$S3_BODY"
    # shellcheck disable=SC2034 # consumed by s3_mp_abort in sourced s3.sh
    S3_MP_PENDING=1
    s3_mp_abort
    s3_cleanup
  ) 2> "$L/err"
  rem=$(raw "${MINIO_ENDPOINT%/}/$B?prefix=$(vec http://h k s 20130524T000000Z s3_uriencode "$P/mp-shared")&uploads=")
  foreign_eid=$(vec http://h k s 20130524T000000Z s3_uriencode "$foreign_uid")
  fdel=$(raw -o /dev/null -w '%{http_code}' -X DELETE "${MINIO_ENDPOINT%/}/$B/$P/mp-shared?uploadId=$foreign_eid")
  if [ -n "$foreign_uid" ] && [ -n "$own_uid" ] \
     && printf '%s' "$rem" | grep -q "<UploadId>$foreign_uid</UploadId>" \
     && ! printf '%s' "$rem" | grep -q "<UploadId>$own_uid</UploadId>" \
     && [ "$fdel" = 204 ]; then
    pass "live multipart foreign-upload survival: own upload aborted from S3_BODY while another writer's upload on the same key survives"
  else
    fail "live multipart foreign-upload survival: foreign=$foreign_uid own=$own_uid fdel=$fdel remaining=$rem err=$(cat "$L/err")"
  fi
  # A store that is not answering at all: S3_OP_TIMEOUT ends it, not the
  # (longer) connect timeout times the retries.
  MINIO_ENDPOINT=http://10.255.255.1:9 S3_CONNECT_TIMEOUT=30 S3_OP_TIMEOUT=4 "$S3RUN" "$S3SH" stat "$B/$P/a" > /dev/null 2> "$L/err"; rc=$?
  [ "$rc" -eq 5 ] && grep -q 'S3_OP_TIMEOUT=4s reached' "$L/err" && pass "live S3_OP_TIMEOUT=4 against a black hole: exit 5, at the deadline" \
    || fail "live op timeout: rc=$rc err=$(cat "$L/err")"
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
