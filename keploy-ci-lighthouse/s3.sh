#!/bin/sh
# s3.sh — the one client every Keploy CI lane uses for the CI object store.
#
# The store behind MINIO_ENDPOINT is SeaweedFS 4.47 (it replaced MinIO on
# 2026-09-25), and only its S3 port is reachable from runners. MinIO's `mc`
# client is gone from CI: MinIO withdrew its distribution, so every download of
# it is one upstream decision away from breaking every lane at once. This script
# speaks plain S3 with the curl every lane image already has (--aws-sigv4, curl
# >= 7.75; the oldest image in use ships 7.88.1), plus sh and coreutils/busybox.
# Nothing is downloaded.
#
# Usage (POSIX sh; the lanes run it as `sh .ci/scripts/s3.sh ...`):
#
#   s3.sh put  FILE|-     BUCKET/KEY   upload (single PUT, `-` spools stdin first)
#   s3.sh get  BUCKET/KEY FILE         download, verify, then rename into FILE
#   s3.sh stat BUCKET/KEY              print "SIZE ETAG"; exit 3 if it is absent
#   s3.sh copy BUCKET/KEY BUCKET/KEY   server-side copy, verified against the source
#   s3.sh cat  BUCKET/KEY              verified download, then written to stdout
#   s3.sh ls   BUCKET [PREFIX]         every object key under PREFIX, one per line
#   s3.sh rm   BUCKET/KEY              delete; succeeds if the object is gone
#   s3.sh presign BUCKET/KEY [SECONDS] print a presigned GET URL (default 7 days)
#
# Exit codes (the lanes branch on these; keep them stable):
#   0  success
#   1  any other failure (unexpected HTTP answer, missing bucket, local I/O)
#   2  usage error / missing configuration
#   3  the object does not exist (404 NoSuchKey)
#   4  the store refused the credentials or the request (401/403)
#   5  transport or server failure that outlasted every retry
#   6  integrity failure (size/checksum mismatch) that outlasted every retry
#
# What every transfer guarantees, so a lane gets either the complete verified
# bytes or a loud failure:
#   put   One PUT, never multipart: the object appears whole or not at all (an
#         interrupted PUT leaves nothing on SeaweedFS). Content-MD5 is sent, so
#         the store rejects bytes that changed on the way (400 BadDigest); the
#         returned ETag and a HEAD afterwards (size + ETag) must both match the
#         local file. Objects over 5 GiB (S3's single-PUT limit) are refused
#         before a byte is sent.
#   get   Written to a temp file beside FILE, then renamed over it, so FILE is
#         never partial and an old FILE survives a failed download. Before the
#         rename the byte count must equal Content-Length, and the MD5 must
#         equal the ETag when the ETag is a plain MD5 (every object this script
#         writes). A multipart ETag ("<md5>-<parts>", written by another client)
#         is not an MD5 of the bytes; such objects are checked by size and the
#         log says so. A large object comes down as fixed-size byte ranges,
#         several at once, each pinned to the ETag seen first (If-Match), so
#         ranges of two different versions can never be stitched together: an
#         overwrite mid-download is a 412 and the whole download is retried.
#   copy  x-amz-copy-source, then HEAD on both sides: same size and ETag.
#   Retries: only transient failures (connection refused/reset, DNS, timeouts
#   and stalls, 5xx, 408/429, S3's RequestTimeout/BadDigest/IncompleteBody,
#   integrity mismatches), with exponential backoff. A 403 or a 404 is final on
#   the first answer.
#   Timeouts: connect timeout, plus stall detection (the transfer is aborted
#   when it moves less than S3_LOW_SPEED_LIMIT bytes/s for S3_LOW_SPEED_TIME
#   seconds). A per-attempt ceiling (S3_MAX_TIME) is the last resort only; it
#   is sized so a slow but moving multi-GiB transfer is never cut off.
#
# Configuration (the same Woodpecker secrets the lanes had for mc):
#   MINIO_ENDPOINT     http(s)://host:port; without a scheme, MINIO_USE_SSL
#                      (true/1/yes/on) picks https, anything else http
#   MINIO_ACCESS_KEY   access key
#   MINIO_SECRET_KEY   secret key; handed to curl on stdin, never in argv, and
#                      never printed (xtrace is switched off below)
#   S3_REGION          SigV4 region (us-east-1; SeaweedFS accepts any)
#   S3_RETRIES         attempts per operation (5)
#   S3_RETRY_DELAY     first backoff in seconds, doubled per retry, capped at
#                      S3_RETRY_MAX_DELAY (2, 30)
#   S3_CONNECT_TIMEOUT seconds (10)
#   S3_LOW_SPEED_LIMIT / S3_LOW_SPEED_TIME   stall detection (32 KiB/s, 60 s)
#   S3_MAX_TIME        per-attempt ceiling in seconds, 0 = none (3600)
#   S3_MAX_PUT_BYTES   largest single PUT (5 GiB)
#   S3_LS_PAGE         keys per ListObjectsV2 page (the store's default, 1000)
#   S3_PARALLEL        byte ranges fetched at once for a large get (4; 1 = one
#                      stream); S3_PARALLEL_MIN_BYTES is "large" (32 MiB), and
#                      S3_PART_BYTES the size of each range (32 MiB, rounded up
#                      to whole MiB)
#
# Addressing is path-style (endpoint/bucket/key), which is what SeaweedFS and
# the old mc aliases used. There is no alias step any more: the first argument
# that used to read "myminio/$BUCKET/$KEY" is now "$BUCKET/$KEY".

# Never trace this script: the secret is in its variables.
set +x
set -eu

S3_PROG=s3.sh
S3_REGION="${S3_REGION:-us-east-1}"
S3_RETRIES="${S3_RETRIES:-5}"
S3_RETRY_DELAY="${S3_RETRY_DELAY:-2}"
S3_RETRY_MAX_DELAY="${S3_RETRY_MAX_DELAY:-30}"
S3_CONNECT_TIMEOUT="${S3_CONNECT_TIMEOUT:-10}"
S3_LOW_SPEED_LIMIT="${S3_LOW_SPEED_LIMIT:-32768}"
S3_LOW_SPEED_TIME="${S3_LOW_SPEED_TIME:-60}"
S3_MAX_TIME="${S3_MAX_TIME:-3600}"
S3_MAX_PUT_BYTES="${S3_MAX_PUT_BYTES:-5368709120}"
S3_PARALLEL="${S3_PARALLEL:-4}"
S3_PARALLEL_MIN_BYTES="${S3_PARALLEL_MIN_BYTES:-33554432}"
S3_PART_BYTES="${S3_PART_BYTES:-33554432}"

s3_log() { printf '%s: %s\n' "$S3_PROG" "$*" >&2; }
s3_die() { _s3_rc=$1; shift; s3_log "$*"; exit "$_s3_rc"; }
s3_usage() {
  sed -n '/^# Usage/,/^# Exit codes/p' "$0" 2>/dev/null | sed '$d; s/^# \{0,1\}//' >&2 || true
  exit 2
}

for _s3_n in "$S3_RETRIES" "$S3_RETRY_DELAY" "$S3_RETRY_MAX_DELAY" "$S3_CONNECT_TIMEOUT" \
             "$S3_LOW_SPEED_LIMIT" "$S3_LOW_SPEED_TIME" "$S3_MAX_TIME" "$S3_MAX_PUT_BYTES" "${S3_LS_PAGE:-1}" \
             "$S3_PARALLEL" "$S3_PARALLEL_MIN_BYTES" "$S3_PART_BYTES"; do
  case "$_s3_n" in ''|*[!0-9]*) s3_die 2 "S3_* tunables must be non-negative integers (got '$_s3_n')" ;; esac
done
[ "$S3_RETRIES" -ge 1 ] || S3_RETRIES=1
[ "$S3_PARALLEL" -ge 1 ] || S3_PARALLEL=1
[ "$S3_PART_BYTES" -ge 1 ] || S3_PART_BYTES=1

# ---------------------------------------------------------------- utilities

# Newline-separated, so a destination directory with spaces in its name
# still gets its temp file removed.
S3_TMPFILES=
s3_cleanup() {
  [ -n "$S3_TMPFILES" ] || return 0
  printf '%s\n' "$S3_TMPFILES" | while IFS= read -r _s3_f; do
    [ -z "$_s3_f" ] || rm -f "$_s3_f" 2>/dev/null || true
  done
}
s3_register() { S3_TMPFILES="$S3_TMPFILES
$1"; }
# A ranged download's parts run in the background; on a signal they are
# stopped (whole process trees: each part is a curl | dd pipeline) before the
# temp files go, so none of them re-creates a file after the cleanup.
S3_PART_PIDS=
s3_kill_tree() {
  if command -v pgrep >/dev/null 2>&1; then
    for _s3_c in $(pgrep -P "$1" 2>/dev/null); do s3_kill_tree "$_s3_c"; done
  fi
  kill -TERM "$1" 2>/dev/null || true
}
s3_stop_parts() {
  for _s3_p in $S3_PART_PIDS; do s3_kill_tree "$_s3_p"; done
  S3_PART_PIDS=
}
trap 's3_cleanup' EXIT
trap 's3_stop_parts; s3_cleanup; exit 130' INT
trap 's3_stop_parts; s3_cleanup; exit 143' TERM
trap 's3_stop_parts; s3_cleanup; exit 129' HUP

# s3_mktemp VAR DIR: create a temp file in DIR, store its path in VAR and
# register it for cleanup. Not `VAR=$(s3_mktemp)`: a command substitution is a
# subshell, and the registration would be lost with it.
s3_mktemp() {
  _s3_t=$(mktemp "$2/.s3tmp.XXXXXXXX") || s3_die 1 "cannot create a temp file in $2"
  s3_register "$_s3_t"
  eval "$1=\$_s3_t"
}

s3_size() { # byte size of a regular file
  stat -c %s "$1" 2>/dev/null || wc -c < "$1" | tr -d ' '
}

# Lowercase hex bytes, one per line, from stdin.
s3_hexbytes() { od -An -v -tx1 | tr -s ' ' '\n' | sed '/^$/d'; }

# Binary bytes on stdout from lowercase hex on stdin (two digits per byte).
# printf is a shell builtin here, so the bytes never pass through argv.
s3_hex2bin() {
  sed 's/../& /g' | tr ' ' '\n' | sed '/^$/d' | while read -r _s3_b; do
    _s3_v=$(( 0x$_s3_b ))
    # shellcheck disable=SC2059 # an octal escape built from arithmetic
    printf "\\$(( _s3_v / 64 ))$(( _s3_v / 8 % 8 ))$(( _s3_v % 8 ))"
  done
}

s3_sha256_hex() { sha256sum | cut -d' ' -f1; } # stdin -> hex

# HMAC-SHA256 (RFC 2104) from sha256sum alone. $1 = key as hex, message on
# stdin, hex digest out. The key only ever travels through pipes and builtins.
s3_hmac() {
  _s3_k=$1
  if [ "${#_s3_k}" -gt 128 ]; then
    _s3_k=$(printf '%s' "$_s3_k" | s3_hex2bin | s3_sha256_hex)
  fi
  _s3_msg=$(cat; printf x); _s3_msg=${_s3_msg%x}
  _s3_ipad=; _s3_opad=
  for _s3_b in $(printf '%s' "$_s3_k" | sed 's/../& /g'); do
    _s3_i=$(( 0x$_s3_b ^ 54 )); _s3_o=$(( 0x$_s3_b ^ 92 ))
    _s3_ipad="$_s3_ipad\\$(( _s3_i / 64 ))$(( _s3_i / 8 % 8 ))$(( _s3_i % 8 ))"
    _s3_opad="$_s3_opad\\$(( _s3_o / 64 ))$(( _s3_o / 8 % 8 ))$(( _s3_o % 8 ))"
  done
  _s3_n=$(( ${#_s3_k} / 2 ))
  while [ "$_s3_n" -lt 64 ]; do
    _s3_ipad="$_s3_ipad\\066"; _s3_opad="$_s3_opad\\134"; _s3_n=$(( _s3_n + 1 ))
  done
  # shellcheck disable=SC2059 # the pads are octal escapes by construction
  { printf "$_s3_opad"
    { printf "$_s3_ipad"; printf '%s' "$_s3_msg"; } | s3_sha256_hex | s3_hex2bin
  } | s3_sha256_hex
}

# Percent-encode per SigV4 (RFC 3986 unreserved kept). $2 = "/" keeps slashes.
s3_uriencode() {
  printf '%s' "$1" | s3_hexbytes | awk -v keep="${2:-}" '
    BEGIN { hex = "0123456789abcdef" }
    {
      n = (index(hex, substr($0, 1, 1)) - 1) * 16 + index(hex, substr($0, 2, 1)) - 1
      if ((n >= 48 && n <= 57) || (n >= 65 && n <= 90) || (n >= 97 && n <= 122) ||
          n == 45 || n == 46 || n == 95 || n == 126 || (keep == "/" && n == 47))
        printf "%c", n
      else
        printf "%%%s", toupper($0)
    }'
}

# ------------------------------------------------------------ configuration

s3_config() {
  _s3_ep="${MINIO_ENDPOINT:-}"
  [ -n "$_s3_ep" ] || s3_die 2 "MINIO_ENDPOINT is not set"
  [ -n "${MINIO_ACCESS_KEY:-}" ] || s3_die 2 "MINIO_ACCESS_KEY is not set"
  [ -n "${MINIO_SECRET_KEY:-}" ] || s3_die 2 "MINIO_SECRET_KEY is not set"
  case "$_s3_ep" in
    http://*|https://*) ;;
    *) case "${MINIO_USE_SSL:-false}" in
         [Tt][Rr][Uu][Ee]|1|[Yy][Ee][Ss]|[Oo][Nn]) _s3_ep="https://$_s3_ep" ;;
         *) _s3_ep="http://$_s3_ep" ;;
       esac ;;
  esac
  while :; do case "$_s3_ep" in */) _s3_ep=${_s3_ep%/} ;; *) break ;; esac; done
  S3_SCHEME=${_s3_ep%%://*}
  S3_HOST=${_s3_ep#*://}
  case "$S3_HOST" in
    ''|*/*|*'?'*|*'#'*|*@*|*' '*) s3_die 2 "MINIO_ENDPOINT must be scheme://host[:port] with no path (got '$MINIO_ENDPOINT')" ;;
  esac
  S3_BASE="$S3_SCHEME://$S3_HOST"
  # curl reads the credentials from a config on stdin: nothing secret in argv.
  # Inside a quoted config value only \ and " need escaping.
  S3_CURL_USER=$(printf '%s:%s' "$MINIO_ACCESS_KEY" "$MINIO_SECRET_KEY" | sed 's/[\\"]/\\&/g')
}

# "bucket/key" -> S3_BUCKET, S3_KEY (key may be empty only if $2 = allow-empty)
s3_split() {
  case "$1" in
    */*) S3_BUCKET=${1%%/*}; S3_KEY=${1#*/} ;;
    *) S3_BUCKET=$1; S3_KEY= ;;
  esac
  case "$S3_BUCKET" in
    ''|*[!a-z0-9.-]*) s3_die 2 "invalid bucket in '$1' (want BUCKET/KEY, with no alias in front)" ;;
  esac
  if [ "${2:-}" != allow-empty ]; then
    case "$S3_KEY" in
      '') s3_die 2 "missing object key in '$1' (want BUCKET/KEY)" ;;
      */) s3_die 2 "object key in '$1' ends in /: name the object, not a folder" ;;
    esac
  fi
  S3_PATH="/$S3_BUCKET/$(s3_uriencode "$S3_KEY" /)"
  [ -n "$S3_KEY" ] || S3_PATH="/$S3_BUCKET"
}

# ------------------------------------------------------------------- HTTP

# s3_curl OUTFILE HDRFILE [curl args...]: one request, body to OUTFILE ("-"
# for stdout), response headers to HDRFILE. Returns curl's exit code; the HTTP
# status is read back from HDRFILE with s3_status. The credentials go to curl
# as a config on stdin, so they never appear in argv.
s3_curl() {
  _s3_out=$1; _s3_hdr=$2; shift 2
  set -- --config - --silent --show-error --globoff \
    --aws-sigv4 "aws:amz:$S3_REGION:s3" \
    --connect-timeout "$S3_CONNECT_TIMEOUT" \
    --speed-limit "$S3_LOW_SPEED_LIMIT" --speed-time "$S3_LOW_SPEED_TIME" \
    --output "$_s3_out" --dump-header "$_s3_hdr" "$@"
  if [ "$S3_MAX_TIME" -gt 0 ]; then set -- --max-time "$S3_MAX_TIME" "$@"; fi
  : > "$_s3_hdr"
  printf 'user = "%s"\n' "$S3_CURL_USER" | curl "$@"
}

# The status of the last response in a header dump (a 100 Continue precedes
# the real answer to a PUT); 000 when no response arrived.
s3_status() {
  _s3_s=$(tr -d '\r' < "$1" | awk '/^HTTP\// { s = $2 } END { print s }')
  printf '%s\n' "${_s3_s:-000}"
}

s3_header() { # $1 = header dump, $2 = lowercase header name; last response wins
  tr -d '\r' < "$1" | awk -v h="$2" '
    /^HTTP\// { v = "" ; next }
    { i = index($0, ":"); if (i && tolower(substr($0, 1, i - 1)) == h) { v = substr($0, i + 1); sub(/^[ \t]+/, "", v); sub(/[ \t]+$/, "", v) } }
    END { print v }'
}

s3_error_code() { # S3 <Code> from an error body (only its head: never scan a payload)
  [ -s "$1" ] || return 0
  head -c 65536 "$1" | tr -d '\r\n' | sed -n 's:.*<Code>\([^<]*\)</Code>.*:\1:p' | head -n 1
}

# Sets S3_CLASS to ok | notfound | auth | transient | fatal, and S3_WHY.
s3_classify() { # $1 = curl rc, $2 = http status, $3 = body file
  _s3_code=
  case "$1:$2" in 0:2??) ;; *) _s3_code=$(s3_error_code "$3") ;; esac
  if [ "$1" -ne 0 ]; then
    S3_WHY="curl exit $1${_s3_code:+ ($_s3_code)}"
    case "$1" in
      5|6|7|16|18|28|35|52|55|56|92) S3_CLASS=transient ;;
      *) S3_CLASS=fatal ;;
    esac
    return 0
  fi
  S3_WHY="HTTP $2${_s3_code:+ $_s3_code}"
  case "$2" in
    2??) S3_CLASS=ok ;;
    404) S3_CLASS=notfound ;;
    401|403) S3_CLASS=auth ;;
    408|429|5??) S3_CLASS=transient ;;
    400) case "$_s3_code" in
           RequestTimeout|BadDigest|IncompleteBody|SlowDown|InternalError) S3_CLASS=transient ;;
           *) S3_CLASS=fatal ;;
         esac ;;
    *) S3_CLASS=fatal ;;
  esac
  return 0
}

s3_class_rc() {
  case "$S3_CLASS" in
    ok) echo 0 ;; notfound) echo 3 ;; auth) echo 4 ;; transient) echo 5 ;; integrity) echo 6 ;; *) echo 1 ;;
  esac
}

s3_backoff() { # $1 = attempt that just failed (1-based)
  _s3_d=$S3_RETRY_DELAY; _s3_i=1
  while [ "$_s3_i" -lt "$1" ]; do
    _s3_d=$(( _s3_d * 2 )); _s3_i=$(( _s3_i + 1 ))
    [ "$_s3_d" -lt "$S3_RETRY_MAX_DELAY" ] || { _s3_d=$S3_RETRY_MAX_DELAY; break; }
  done
  printf '%s\n' "$_s3_d"
}

# s3_run DESCRIPTION FUNCTION [args]: call FUNCTION (one attempt; it sets
# S3_CLASS/S3_WHY) until it succeeds, fails for good, or runs out of attempts.
s3_run() {
  _s3_desc=$1; shift
  _s3_att=1
  while :; do
    S3_CLASS=fatal; S3_WHY="no attempt made"
    "$@"
    case "$S3_CLASS" in
      ok) return 0 ;;
      transient|integrity)
        if [ "$_s3_att" -ge "$S3_RETRIES" ]; then
          s3_log "$_s3_desc: failed after $_s3_att attempt(s): $S3_WHY"
          return "$(s3_class_rc)"
        fi
        _s3_wait=$(s3_backoff "$_s3_att")
        s3_log "$_s3_desc: attempt $_s3_att/$S3_RETRIES failed ($S3_WHY); retrying in ${_s3_wait}s"
        sleep "$_s3_wait"
        _s3_att=$(( _s3_att + 1 )) ;;
      notfound) return 3 ;;
      *) s3_log "$_s3_desc: $S3_WHY"; return "$(s3_class_rc)" ;;
    esac
  done
}

s3_now() { date +%s; }

# ------------------------------------------------------------------- verbs

# HEAD one object. Sets S3_HEAD_SIZE / S3_HEAD_ETAG (ETag without quotes).
s3_head_once() {
  S3_HEAD_SIZE=; S3_HEAD_ETAG=
  _s3_rc=0
  s3_curl /dev/null "$S3_HDR" --head "$S3_BASE$S3_PATH" || _s3_rc=$?
  _s3_st=$(s3_status "$S3_HDR")
  s3_classify "$_s3_rc" "$_s3_st" /dev/null
  if [ "$S3_CLASS" = ok ]; then
    S3_HEAD_SIZE=$(s3_header "$S3_HDR" content-length)
    S3_HEAD_ETAG=$(s3_header "$S3_HDR" etag | tr -d '"')
  fi
}

# After a 404 on an object, tell "no such key" (exit 3) from "no such bucket"
# (a configuration error, exit 1): HEAD carries no error body to read it from.
# Prints the exit code the command should end with. $2 = quiet: say nothing
# about a missing object (stat is the probe the lanes run to ask "is it
# there?"; get and copy need the object, so a miss is worth a line in the log).
s3_notfound_rc() { # $1 = description, $2 = quiet (optional)
  _s3_rc=0
  s3_curl /dev/null "$S3_HDR" --head "$S3_BASE/$S3_BUCKET" || _s3_rc=$?
  _s3_st=$(s3_status "$S3_HDR")
  if [ "$_s3_rc" -eq 0 ] && [ "$_s3_st" = 404 ]; then
    s3_log "$1: bucket '$S3_BUCKET' does not exist"
    echo 1
  else
    [ -n "${2:-}" ] || s3_log "$1: no such object"
    echo 3
  fi
}

s3_is_md5_etag() { case "$1" in *[!0-9a-f]*) return 1 ;; *) [ "${#1}" -eq 32 ] ;; esac; }

cmd_stat() {
  [ $# -eq 1 ] || s3_usage
  s3_split "$1"
  s3_mktemp S3_HDR "${TMPDIR:-/tmp}"
  _s3_r=0; s3_run "stat $1" s3_head_once || _s3_r=$?
  if [ "$_s3_r" -eq 3 ]; then return "$(s3_notfound_rc "stat $1" quiet)"; fi
  [ "$_s3_r" -eq 0 ] || return "$_s3_r"
  printf '%s %s\n' "$S3_HEAD_SIZE" "$S3_HEAD_ETAG"
}

s3_put_once() {
  # Sized and hashed on every attempt, not once: if the file changed under an
  # attempt, the store's BadDigest is retried against what the file holds now.
  # An oversized file is refused here, before its first byte is sent.
  S3_SIZE=$(s3_size "$S3_SRC")
  if [ "$S3_SIZE" -gt "$S3_MAX_PUT_BYTES" ]; then
    S3_CLASS=fatal; S3_WHY="$S3_SRC is $S3_SIZE bytes, over the $S3_MAX_PUT_BYTES-byte single-PUT limit"; return 0
  fi
  S3_MD5_HEX=$(md5sum < "$S3_SRC" | cut -d' ' -f1)
  if ! s3_is_md5_etag "$S3_MD5_HEX"; then S3_CLASS=fatal; S3_WHY="could not hash $S3_SRC"; return 0; fi
  S3_MD5_B64=$(printf '%s' "$S3_MD5_HEX" | s3_hex2bin | base64)
  _s3_rc=0
  s3_curl "$S3_BODY" "$S3_HDR" --upload-file "$S3_SRC" \
    --header "Content-MD5: $S3_MD5_B64" \
    --header 'Content-Type: application/octet-stream' \
    --header 'x-amz-content-sha256: UNSIGNED-PAYLOAD' \
    "$S3_BASE$S3_PATH" || _s3_rc=$?
  _s3_st=$(s3_status "$S3_HDR")
  s3_classify "$_s3_rc" "$_s3_st" "$S3_BODY"
  [ "$S3_CLASS" = ok ] || return 0
  _s3_etag=$(s3_header "$S3_HDR" etag | tr -d '"')
  if [ -n "$_s3_etag" ] && [ "$_s3_etag" != "$S3_MD5_HEX" ]; then
    S3_CLASS=integrity; S3_WHY="store answered ETag $_s3_etag for MD5 $S3_MD5_HEX"; return 0
  fi
  # Read it back: what a later get will see must be what was sent.
  s3_head_once
  case "$S3_CLASS" in
    ok) ;;
    notfound) S3_CLASS=integrity; S3_WHY="object missing right after a successful PUT"; return 0 ;;
    *) return 0 ;;
  esac
  if [ "$S3_HEAD_SIZE" != "$S3_SIZE" ] || [ "$S3_HEAD_ETAG" != "$S3_MD5_HEX" ]; then
    S3_CLASS=integrity
    S3_WHY="read-back is $S3_HEAD_SIZE bytes, ETag $S3_HEAD_ETAG; sent $S3_SIZE bytes, MD5 $S3_MD5_HEX"
  fi
}

cmd_put() {
  [ $# -eq 2 ] || s3_usage
  S3_SRC=$1
  s3_split "$2"
  _s3_dir=${TMPDIR:-/tmp}
  if [ "$S3_SRC" = - ]; then
    # Unknown length: spool, so the upload is still one verified PUT.
    s3_mktemp S3_SRC "$_s3_dir"
    cat > "$S3_SRC" || s3_die 1 "put $2: reading stdin failed"
  fi
  { [ -f "$S3_SRC" ] && [ -r "$S3_SRC" ]; } || s3_die 1 "put: '$S3_SRC' is not a readable regular file"
  s3_mktemp S3_HDR "$_s3_dir"; s3_mktemp S3_BODY "$_s3_dir"
  _s3_t0=$(s3_now)
  _s3_r=0; s3_run "put $1 -> $2" s3_put_once || _s3_r=$?
  if [ "$_s3_r" -eq 3 ]; then
    [ "$(s3_notfound_rc "put $2")" = 1 ] || s3_log "put $2: store answered 404"
    return 1
  fi
  [ "$_s3_r" -eq 0 ] || return "$_s3_r"
  s3_log "put $2: $S3_SIZE bytes, MD5 $S3_MD5_HEX verified, $(( $(s3_now) - _s3_t0 ))s"
}

# One attempt at a download. SeaweedFS serves a GET fast only while it is
# short: on the benchmark host (SeaweedFS 4.47) a 64 MiB range came at
# ~1.5 GiB/s, a 512 MiB range at ~290 MiB/s, and a whole 1.5 GiB object at
# ~85 MiB/s, whether one stream or four quarter-object ranges at once (11 s).
# The same object in 32 MiB parts, four at a time, took 0.9 s. So an object of
# S3_PARALLEL_MIN_BYTES or more is fetched as S3_PART_BYTES parts by
# S3_PARALLEL workers; a smaller one takes one streamed GET.
s3_get_once() {
  if [ "$S3_PARALLEL" -gt 1 ]; then
    s3_head_once
    [ "$S3_CLASS" = ok ] || return 0
    if [ -n "$S3_HEAD_SIZE" ] && [ "$S3_HEAD_SIZE" -ge "$S3_PARALLEL_MIN_BYTES" ]; then
      s3_get_ranged
      return 0
    fi
  fi
  s3_get_stream
}

# One byte range of the object into its place in the temp file; its curl and
# dd exit codes come back through files.
s3_get_part() { # $1 = part index, $2 = first byte, $3 = last byte
  { _s3_prc=0
    s3_curl - "$S3_HDR.$1" --range "$2-$3" --header "If-Match: \"$S3_HEAD_ETAG\"" \
      "$S3_BASE$S3_PATH" || _s3_prc=$?
    echo "$_s3_prc" > "$S3_RCF.$1"
  } | dd of="$S3_TMP" bs=1048576 seek=$(( $2 / 1048576 )) conv=notrunc 2>/dev/null
  echo "$?" > "$S3_SUMF.$1"
}

# A background worker: parts $1, $1+S3_PARALLEL, ... in turn. The first part
# that goes wrong (anywhere) voids the attempt, so every worker stops starting
# new parts once one of them has dropped the abort marker.
s3_get_worker() { # $1 = first part, $2 = part count, $3 = part size, $4 = object size
  _s3_wi=$1
  while [ "$_s3_wi" -lt "$2" ] && [ ! -e "$S3_ABORT" ]; do
    _s3_wo=$(( _s3_wi * $3 )); _s3_we=$(( _s3_wo + $3 - 1 ))
    [ "$_s3_we" -lt "$4" ] || _s3_we=$(( $4 - 1 ))
    s3_get_part "$_s3_wi" "$_s3_wo" "$_s3_we"
    if [ "$(cat "$S3_RCF.$_s3_wi" 2>/dev/null)" != 0 ] || [ "$(cat "$S3_SUMF.$_s3_wi" 2>/dev/null)" != 0 ] ||
       [ "$(s3_status "$S3_HDR.$_s3_wi")" != 206 ]; then
      : > "$S3_ABORT"
      break
    fi
    _s3_wi=$(( _s3_wi + S3_PARALLEL ))
  done
}

# The worse of two outcomes, for a download made of several requests: a
# final answer (auth, not found, fatal) beats a retryable one.
s3_worse() { # $1 = class so far, $2 = new class
  for _s3_c in auth notfound fatal transient integrity ok; do
    if [ "$1" = "$_s3_c" ] || [ "$2" = "$_s3_c" ]; then printf '%s\n' "$_s3_c"; return 0; fi
  done
}

s3_get_ranged() {
  _s3_size=$S3_HEAD_SIZE; _s3_etag=$S3_HEAD_ETAG
  # Part boundaries on MiB multiples: dd seeks in whole blocks.
  _s3_psz=$(( (S3_PART_BYTES + 1048575) / 1048576 * 1048576 ))
  _s3_n=$(( (_s3_size + _s3_psz - 1) / _s3_psz ))
  if ! : > "$S3_TMP"; then S3_CLASS=fatal; S3_WHY="cannot write $S3_TMP"; return 0; fi
  rm -f "$S3_ABORT"
  _s3_i=0
  while [ "$_s3_i" -lt "$_s3_n" ]; do
    s3_register "$S3_HDR.$_s3_i"; s3_register "$S3_RCF.$_s3_i"; s3_register "$S3_SUMF.$_s3_i"
    rm -f "$S3_RCF.$_s3_i" "$S3_SUMF.$_s3_i"
    _s3_i=$(( _s3_i + 1 ))
  done
  _s3_i=0
  while [ "$_s3_i" -lt "$S3_PARALLEL" ] && [ "$_s3_i" -lt "$_s3_n" ]; do
    s3_get_worker "$_s3_i" "$_s3_n" "$_s3_psz" "$_s3_size" &
    S3_PART_PIDS="$S3_PART_PIDS $!"
    _s3_i=$(( _s3_i + 1 ))
  done
  wait
  S3_PART_PIDS=
  _s3_all=ok; _s3_whys=; _s3_i=0; _s3_off=0; _s3_skipped=0
  while [ "$_s3_i" -lt "$_s3_n" ]; do
    _s3_end=$(( _s3_off + _s3_psz - 1 ))
    [ "$_s3_end" -lt "$_s3_size" ] || _s3_end=$(( _s3_size - 1 ))
    if [ ! -e "$S3_RCF.$_s3_i" ] && [ -e "$S3_ABORT" ]; then
      # Never started: another part had already voided this attempt.
      _s3_skipped=$(( _s3_skipped + 1 ))
      _s3_i=$(( _s3_i + 1 )); _s3_off=$(( _s3_end + 1 ))
      continue
    fi
    _s3_rc=$(cat "$S3_RCF.$_s3_i" 2>/dev/null || echo 1)
    _s3_st=$(s3_status "$S3_HDR.$_s3_i")
    # Error bodies went into the temp file; the attempt is void anyway.
    s3_classify "$_s3_rc" "$_s3_st" /dev/null
    if [ "$S3_CLASS" = ok ]; then
      _s3_len=$(s3_header "$S3_HDR.$_s3_i" content-length)
      if [ "$_s3_st" = 200 ]; then
        # The store ignored Range: the whole object went to this offset. Fall
        # back to one stream for the remaining attempts.
        S3_PARALLEL=1; S3_CLASS=transient; S3_WHY="store answered a ranged GET with the whole object"
      elif [ "$_s3_st" != 206 ]; then
        S3_CLASS=fatal; S3_WHY="unexpected HTTP $_s3_st for a ranged GET"
      elif [ "$(cat "$S3_SUMF.$_s3_i" 2>/dev/null || echo 1)" != 0 ]; then
        S3_CLASS=fatal; S3_WHY="writing bytes $_s3_off-$_s3_end of $S3_TMP failed"
      elif [ "$_s3_len" != $(( _s3_end - _s3_off + 1 )) ]; then
        S3_CLASS=integrity; S3_WHY="bytes $_s3_off-$_s3_end: Content-Length ${_s3_len:-absent}"
      fi
    elif [ "$_s3_st" = 412 ]; then
      S3_CLASS=transient; S3_WHY="the object changed while it was being downloaded (412)"
    fi
    if [ "$S3_CLASS" != ok ]; then _s3_whys="${_s3_whys:+$_s3_whys; }part $_s3_i: $S3_WHY"; fi
    _s3_all=$(s3_worse "$_s3_all" "$S3_CLASS")
    _s3_i=$(( _s3_i + 1 )); _s3_off=$(( _s3_end + 1 ))
  done
  S3_CLASS=$_s3_all; S3_WHY=$_s3_whys
  if [ "$S3_CLASS" = ok ] && [ "$_s3_skipped" -gt 0 ]; then
    S3_CLASS=integrity; S3_WHY="$_s3_skipped part(s) never ran"
  fi
  [ "$S3_CLASS" = ok ] || return 0
  _s3_have=$(s3_size "$S3_TMP")
  if [ "$_s3_have" != "$_s3_size" ]; then
    S3_CLASS=integrity; S3_WHY="assembled $_s3_have bytes of $_s3_size"; return 0
  fi
  if s3_is_md5_etag "$_s3_etag"; then
    _s3_md5=$(md5sum < "$S3_TMP" | cut -d' ' -f1)
    if [ "$_s3_md5" != "$_s3_etag" ]; then
      S3_CLASS=integrity; S3_WHY="assembled MD5 $_s3_md5, ETag $_s3_etag"; return 0
    fi
    S3_VERIFIED="MD5 $_s3_md5 verified, $_s3_n parts"
  else
    S3_VERIFIED="size verified, $_s3_n parts (ETag '${_s3_etag}' is not a plain MD5, e.g. a multipart upload)"
  fi
  S3_GOT=$_s3_have
}

s3_get_stream() {
  # The body streams through tee into md5sum while it lands in the temp file,
  # so verifying costs no second pass over a multi-GiB object. curl's exit
  # code comes back through a file: a POSIX pipeline only reports its last
  # command's.
  { _s3_rc=0
    s3_curl - "$S3_HDR" "$S3_BASE$S3_PATH" || _s3_rc=$?
    echo "$_s3_rc" > "$S3_RCF"
  } | tee "$S3_TMP" | md5sum > "$S3_SUMF" || true
  _s3_rc=$(cat "$S3_RCF" 2>/dev/null || echo 1)
  _s3_st=$(s3_status "$S3_HDR")
  s3_classify "$_s3_rc" "$_s3_st" "$S3_TMP"
  [ "$S3_CLASS" = ok ] || return 0
  if [ "$_s3_st" != 200 ]; then S3_CLASS=fatal; S3_WHY="unexpected HTTP $_s3_st"; return 0; fi
  _s3_want=$(s3_header "$S3_HDR" content-length)
  _s3_have=$(s3_size "$S3_TMP")
  if [ -z "$_s3_want" ] || [ "$_s3_have" != "$_s3_want" ]; then
    S3_CLASS=integrity; S3_WHY="received $_s3_have bytes, Content-Length ${_s3_want:-absent}"; return 0
  fi
  _s3_etag=$(s3_header "$S3_HDR" etag | tr -d '"')
  if s3_is_md5_etag "$_s3_etag"; then
    _s3_md5=$(cut -d' ' -f1 < "$S3_SUMF")
    if [ "$_s3_md5" != "$_s3_etag" ]; then
      S3_CLASS=integrity; S3_WHY="received MD5 $_s3_md5, ETag $_s3_etag"; return 0
    fi
    S3_VERIFIED="MD5 $_s3_md5 verified"
  else
    S3_VERIFIED="size verified (ETag '${_s3_etag}' is not a plain MD5, e.g. a multipart upload)"
  fi
  S3_GOT=$_s3_have
}

cmd_get() {
  [ $# -eq 2 ] || s3_usage
  s3_split "$1"
  _s3_dst=$2
  case "$_s3_dst" in */) _s3_dst="$_s3_dst${S3_KEY##*/}" ;; esac
  [ ! -d "$_s3_dst" ] || _s3_dst="$_s3_dst/${S3_KEY##*/}"
  _s3_dir=$(dirname "$_s3_dst")
  mkdir -p "$_s3_dir" || s3_die 1 "get $1: cannot create $_s3_dir"
  # Same directory as the destination, so the final rename is atomic.
  s3_mktemp S3_TMP "$_s3_dir"
  s3_mktemp S3_HDR "${TMPDIR:-/tmp}"
  s3_mktemp S3_RCF "${TMPDIR:-/tmp}"; s3_mktemp S3_SUMF "${TMPDIR:-/tmp}"
  S3_ABORT="$S3_RCF.abort"; s3_register "$S3_ABORT"
  S3_HEAD_ETAG=
  _s3_t0=$(s3_now)
  _s3_r=0; s3_run "get $1 -> $_s3_dst" s3_get_once || _s3_r=$?
  if [ "$_s3_r" -eq 3 ]; then return "$(s3_notfound_rc "get $1")"; fi
  [ "$_s3_r" -eq 0 ] || return "$_s3_r"
  # mktemp made it 0600; give it the mode a plain create would have had.
  _s3_um=$(umask)
  chmod "$(printf '%o' $(( 0666 & ~0$_s3_um )))" "$S3_TMP" 2>/dev/null || true
  mv -f "$S3_TMP" "$_s3_dst" || s3_die 1 "get $1: cannot rename into $_s3_dst"
  s3_log "get $1: $S3_GOT bytes, $S3_VERIFIED, $(( $(s3_now) - _s3_t0 ))s"
}

cmd_cat() {
  [ $# -eq 1 ] || s3_usage
  _s3_f=; s3_mktemp _s3_f "${TMPDIR:-/tmp}"
  _s3_r=0; cmd_get "$1" "$_s3_f" || _s3_r=$?
  [ "$_s3_r" -eq 0 ] || return "$_s3_r"
  cat "$_s3_f"
}

s3_copy_once() {
  _s3_rc=0
  s3_curl "$S3_BODY" "$S3_HDR" --request PUT \
    --header "x-amz-copy-source: $S3_COPY_SRC" \
    --header 'x-amz-content-sha256: UNSIGNED-PAYLOAD' \
    "$S3_BASE$S3_PATH" || _s3_rc=$?
  _s3_st=$(s3_status "$S3_HDR")
  s3_classify "$_s3_rc" "$_s3_st" "$S3_BODY"
  [ "$S3_CLASS" = ok ] || return 0
  # S3 may answer 200 and put the error in the body.
  if grep -q '<Error>' "$S3_BODY" 2>/dev/null; then
    s3_classify 0 500 "$S3_BODY"; S3_WHY="copy answered 200 with an error body: $S3_WHY"; return 0
  fi
  s3_head_once
  case "$S3_CLASS" in
    ok) ;;
    notfound) S3_CLASS=integrity; S3_WHY="destination missing right after a successful copy"; return 0 ;;
    *) return 0 ;;
  esac
  if [ "$S3_HEAD_SIZE" != "$S3_SRC_SIZE" ]; then
    S3_CLASS=integrity; S3_WHY="copy is $S3_HEAD_SIZE bytes, source $S3_SRC_SIZE"; return 0
  fi
  # A multipart source's ETag is not an MD5 of its bytes, and a store may give
  # the copy a fresh one; compare ETags only when both are plain MD5s.
  if s3_is_md5_etag "$S3_SRC_ETAG" && s3_is_md5_etag "$S3_HEAD_ETAG"; then
    if [ "$S3_HEAD_ETAG" != "$S3_SRC_ETAG" ]; then
      S3_CLASS=integrity; S3_WHY="copy has ETag $S3_HEAD_ETAG, source $S3_SRC_ETAG"; return 0
    fi
    S3_VERIFIED="size and MD5 ETag verified"
  else
    S3_VERIFIED="size verified (ETags '$S3_SRC_ETAG' / '$S3_HEAD_ETAG' are not both plain MD5s)"
  fi
}

cmd_copy() {
  [ $# -eq 2 ] || s3_usage
  s3_split "$2"   # validate both arguments before the first request
  s3_mktemp S3_HDR "${TMPDIR:-/tmp}"; s3_mktemp S3_BODY "${TMPDIR:-/tmp}"
  s3_split "$1"
  S3_COPY_SRC=$S3_PATH
  _s3_r=0; s3_run "copy: stat $1" s3_head_once || _s3_r=$?
  if [ "$_s3_r" -eq 3 ]; then return "$(s3_notfound_rc "copy $1")"; fi
  [ "$_s3_r" -eq 0 ] || return "$_s3_r"
  S3_SRC_SIZE=$S3_HEAD_SIZE; S3_SRC_ETAG=$S3_HEAD_ETAG
  s3_split "$2"
  _s3_r=0; s3_run "copy $1 -> $2" s3_copy_once || _s3_r=$?
  if [ "$_s3_r" -eq 3 ]; then s3_log "copy $1 -> $2: store answered 404"; return 1; fi
  [ "$_s3_r" -eq 0 ] || return "$_s3_r"
  s3_log "copy $1 -> $2: $S3_SRC_SIZE bytes, $S3_VERIFIED"
}

s3_rm_once() {
  _s3_rc=0
  s3_curl "$S3_BODY" "$S3_HDR" --request DELETE "$S3_BASE$S3_PATH" || _s3_rc=$?
  _s3_st=$(s3_status "$S3_HDR")
  s3_classify "$_s3_rc" "$_s3_st" "$S3_BODY"
  # Deleting what is already gone is success: the postcondition holds.
  [ "$S3_CLASS" != notfound ] || { s3_error_code "$S3_BODY" | grep -qx NoSuchBucket || S3_CLASS=ok; }
}

cmd_rm() {
  [ $# -eq 1 ] || s3_usage
  s3_split "$1"
  s3_mktemp S3_HDR "${TMPDIR:-/tmp}"; s3_mktemp S3_BODY "${TMPDIR:-/tmp}"
  _s3_r=0; s3_run "rm $1" s3_rm_once || _s3_r=$?
  if [ "$_s3_r" -eq 3 ]; then s3_log "rm $1: bucket '$S3_BUCKET' does not exist"; return 1; fi
  return "$_s3_r"
}

# awk functions: unesc() decodes XML text as S3 stores write it. SeaweedFS is
# Go, and Go's encoder writes " ' tab CR LF as &#34; &#39; &#x9; &#xD; &#xA;,
# not as the named entities other stores use; both forms are decoded.
S3_AWK_UNESC='
function s3hex(h,   i, n) {
  n = 0; h = tolower(h)
  for (i = 1; i <= length(h); i++) n = n * 16 + index("0123456789abcdef", substr(h, i, 1)) - 1
  return n
}
function unesc(s,   out, ent, n) {
  out = ""
  while (match(s, /&(lt|gt|quot|apos|amp|#[0-9]+|#[xX][0-9a-fA-F]+);/)) {
    ent = substr(s, RSTART + 1, RLENGTH - 2)
    out = out substr(s, 1, RSTART - 1)
    if (ent == "lt") out = out "<"
    else if (ent == "gt") out = out ">"
    else if (ent == "quot") out = out "\""
    else if (ent == "apos") out = out "\047"
    else if (ent == "amp") out = out "&"
    else {
      n = (substr(ent, 2, 1) ~ /[xX]/) ? s3hex(substr(ent, 3)) : substr(ent, 2) + 0
      out = out ((n > 0 && n < 128) ? sprintf("%c", n) : "&" ent ";")
    }
    s = substr(s, RSTART + RLENGTH)
  }
  return out s
}'

s3_ls_once() {
  _s3_rc=0
  s3_curl "$S3_BODY" "$S3_HDR" "$S3_BASE/$S3_BUCKET?$S3_QUERY" || _s3_rc=$?
  _s3_st=$(s3_status "$S3_HDR")
  s3_classify "$_s3_rc" "$_s3_st" "$S3_BODY"
}

cmd_ls() {
  { [ $# -ge 1 ] && [ $# -le 2 ]; } || s3_usage
  s3_split "$1" allow-empty
  [ -z "$S3_KEY" ] || s3_die 2 "ls takes BUCKET [PREFIX], not BUCKET/KEY"
  _s3_prefix=${2:-}
  s3_mktemp S3_HDR "${TMPDIR:-/tmp}"; s3_mktemp S3_BODY "${TMPDIR:-/tmp}"
  _s3_token=
  while :; do
    # Parameters in canonical (sorted) order, each value encoded once, so the
    # URL curl sends is already the SigV4 canonical query string.
    S3_QUERY=
    [ -z "$_s3_token" ] || S3_QUERY="continuation-token=$(s3_uriencode "$_s3_token")&"
    S3_QUERY="${S3_QUERY}list-type=2&"
    [ -z "${S3_LS_PAGE:-}" ] || S3_QUERY="${S3_QUERY}max-keys=$S3_LS_PAGE&"
    S3_QUERY="${S3_QUERY}prefix=$(s3_uriencode "$_s3_prefix")"
    _s3_r=0; s3_run "ls $S3_BUCKET/$_s3_prefix" s3_ls_once || _s3_r=$?
    if [ "$_s3_r" -eq 3 ]; then s3_log "ls: bucket '$S3_BUCKET' does not exist"; return 1; fi
    [ "$_s3_r" -eq 0 ] || return "$_s3_r"
    # Keys of objects only (<Contents>), never CommonPrefixes, and never a
    # directory marker ("key/"): SeaweedFS keeps listing an emptied "folder"
    # for a couple of minutes after its last object is deleted.
    tr -d '\r\n' < "$S3_BODY" | awk "$S3_AWK_UNESC"'
      BEGIN { RS = "<"; FS = ">" }
      $1 == "Contents" { inc = 1 }
      $1 == "/Contents" { inc = 0 }
      $1 == "Key" && inc { k = unesc($2); if (k !~ /\/$/) print k }'
    _s3_trunc=$(tr -d '\r\n' < "$S3_BODY" | sed -n 's:.*<IsTruncated>\([^<]*\)</IsTruncated>.*:\1:p')
    [ "$_s3_trunc" = true ] || break
    _s3_token=$(tr -d '\r\n' < "$S3_BODY" | awk "$S3_AWK_UNESC"'
      BEGIN { RS = "<"; FS = ">" }
      $1 == "NextContinuationToken" { print unesc($2); exit }')
    [ -n "$_s3_token" ] || s3_die 1 "ls: truncated listing without a continuation token"
  done
}

# SigV4 query-string presigning (the `mc share download` replacement).
# S3_PRESIGN_DATE (YYYYMMDDTHHMMSSZ) pins the clock for tests.
s3_presign_url() { # $1 = method, $2 = canonical path (encoded), $3 = expiry seconds
  _s3_amzdate=${S3_PRESIGN_DATE:-$(date -u +%Y%m%dT%H%M%SZ)}
  _s3_day=${_s3_amzdate%%T*}
  _s3_scope="$_s3_day/$S3_REGION/s3/aws4_request"
  _s3_q="X-Amz-Algorithm=AWS4-HMAC-SHA256"
  _s3_q="$_s3_q&X-Amz-Credential=$(s3_uriencode "$MINIO_ACCESS_KEY/$_s3_scope")"
  _s3_q="$_s3_q&X-Amz-Date=$_s3_amzdate&X-Amz-Expires=$3&X-Amz-SignedHeaders=host"
  _s3_creq=$(printf '%s\n%s\n%s\nhost:%s\n\nhost\nUNSIGNED-PAYLOAD' "$1" "$2" "$_s3_q" "$S3_HOST")
  _s3_sts=$(printf 'AWS4-HMAC-SHA256\n%s\n%s\n%s' "$_s3_amzdate" "$_s3_scope" \
    "$(printf '%s' "$_s3_creq" | s3_sha256_hex)")
  _s3_key=$(printf 'AWS4%s' "$MINIO_SECRET_KEY" | s3_hexbytes | tr -d '\n')
  _s3_key=$(printf '%s' "$_s3_day" | s3_hmac "$_s3_key")
  _s3_key=$(printf '%s' "$S3_REGION" | s3_hmac "$_s3_key")
  _s3_key=$(printf 's3' | s3_hmac "$_s3_key")
  _s3_key=$(printf 'aws4_request' | s3_hmac "$_s3_key")
  _s3_sig=$(printf '%s' "$_s3_sts" | s3_hmac "$_s3_key")
  printf '%s://%s%s?%s&X-Amz-Signature=%s\n' "$S3_SCHEME" "$S3_HOST" "$2" "$_s3_q" "$_s3_sig"
}

cmd_presign() {
  { [ $# -ge 1 ] && [ $# -le 2 ]; } || s3_usage
  _s3_exp=${2:-604800}
  case "$_s3_exp" in ''|*[!0-9]*) s3_die 2 "presign: expiry must be seconds" ;; esac
  { [ "$_s3_exp" -ge 1 ] && [ "$_s3_exp" -le 604800 ]; } || s3_die 2 "presign: expiry must be 1..604800 seconds (SigV4 maximum)"
  s3_split "$1"
  s3_presign_url GET "$S3_PATH" "$_s3_exp"
}

# -------------------------------------------------------------------- main

# s3-test.sh sources the functions without running a command.
if [ -n "${S3_SH_SOURCE_ONLY:-}" ]; then
  # shellcheck disable=SC2317 # reached when executed rather than sourced
  return 0 2>/dev/null || exit 0
fi

[ $# -ge 1 ] || s3_usage
_s3_verb=$1; shift
case "$_s3_verb" in
  put|get|stat|copy|cat|ls|rm|presign) ;;
  -h|--help|help) s3_usage ;;
  *) s3_log "unknown command '$_s3_verb'"; s3_usage ;;
esac
command -v curl >/dev/null 2>&1 || s3_die 2 "curl is not installed"
s3_config
_s3_rc=0
"cmd_$_s3_verb" "$@" || _s3_rc=$?
exit "$_s3_rc"
