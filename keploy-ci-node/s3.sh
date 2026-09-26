#!/bin/sh
# s3.sh — the one client every Keploy CI lane uses for the CI object store.
#
# The store behind MINIO_ENDPOINT is SeaweedFS 4.47 (it replaced MinIO on
# 2026-09-25), and only its S3 port is reachable from runners. MinIO's `mc`
# client is gone from CI: MinIO withdrew its distribution, so every download of
# it is one upstream decision away from breaking every lane at once. This script
# speaks plain S3 with the curl every lane image already has (--aws-sigv4), plus
# sh and coreutils/busybox. Nothing is downloaded.
#
# curl 7.88.1 or newer (checked; exit 2 otherwise). Tested on 7.88.1 (the
# go-build image), 8.14.1 and 8.18.0. curl 7.81.0 (Ubuntu 22.04) does not work:
# SeaweedFS 4.47 answers even its plain bucket PUT with SignatureDoesNotMatch,
# and it signs only host, x-amz-date and content-type, so the
# x-amz-content-sha256, Content-MD5, If-Match and x-amz-meta-* headers this
# script sends would travel unsigned (AWS refuses unsigned x-amz-* headers).
#
# Usage (POSIX sh; the lanes run it as `sh .ci/scripts/s3.sh ...`):
#
#   s3.sh put  FILE|-     BUCKET/KEY   upload (`-` spools stdin first)
#   s3.sh get  BUCKET/KEY FILE         download, verify, then rename into FILE
#   s3.sh stat BUCKET/KEY              print "SIZE ETAG"; exit 3 if it is absent
#   s3.sh copy BUCKET/KEY BUCKET/KEY   server-side copy, verified against the source
#   s3.sh cat  BUCKET/KEY              stream to stdout as verified byte ranges
#   s3.sh ls   BUCKET [PREFIX]         every object key under PREFIX, one per line
#   s3.sh rm   BUCKET/KEY              delete; succeeds if the object is gone
#   s3.sh presign BUCKET/KEY [SECONDS] print a presigned GET URL (default 7 days)
#   s3.sh location BUCKET              print the bucket's region (GetBucketLocation)
#
# Exit codes (the lanes branch on these; keep them stable):
#   0  success
#   1  any other failure (unexpected HTTP answer, missing bucket, local I/O)
#   2  usage error / missing configuration / curl too old
#   3  the object does not exist (404 NoSuchKey)
#   4  the store refused the credentials or the request (401/403)
#   5  transport or server failure that outlasted every retry (or S3_OP_TIMEOUT)
#   6  integrity failure (size/checksum mismatch) that outlasted every retry
#
# What every transfer guarantees, so a lane gets either the complete verified
# bytes or a loud failure:
#   put   Up to S3_MAX_PUT_BYTES (5 GiB, S3's single-PUT limit) one PUT; above
#         it a multipart upload. Either way the object appears whole or not at
#         all, every request carries Content-MD5 (the store rejects bytes that
#         changed on the way, 400 BadDigest), and the whole file's MD5 travels
#         as x-amz-meta-s3sh-md5. A single PUT's ETag and a HEAD afterwards
#         (size, ETag, that MD5) must match the file. A multipart upload checks
#         each part's ETag, hashes the bytes it actually sent against the MD5
#         it declared (a file that changed mid-upload is re-sent), and checks
#         the completed object's ETag (MD5 of the part MD5s, "-<parts>") and a
#         HEAD. A failed multipart upload is aborted.
#   get   Written to a temp file beside FILE, then renamed over it, so FILE is
#         never partial and an old FILE survives a failed download. Before the
#         rename the byte count must equal Content-Length, and the MD5 must
#         equal the object's x-amz-meta-s3sh-md5, or else its ETag when that is
#         a plain MD5 of the bytes. Otherwise (a multipart upload by another
#         client, or SSE-KMS/SSE-C, whose ETag is not an MD5) only the size is
#         checked, and the log says so. A large object comes down as fixed-size
#         byte ranges, several at once, each pinned to the ETag seen first
#         (If-Match), so ranges of two versions can never be stitched
#         together: an overwrite mid-download is a 412 and the download is
#         retried.
#   cat   Streams: nothing but S3_PARALLEL ranges of S3_PART_BYTES is ever on
#         local disk. Each range is checked (206, its exact length, If-Match
#         on the ETag) BEFORE a byte of it is written, and retried on its own.
#         The whole object's MD5 (as for get) is computed as it streams and the
#         LAST range is held back until it matches, so a corrupt object ends
#         the stream short rather than complete-looking. Any failure exits
#         non-zero once the stream has stopped: the reader then holds a prefix
#         and the CALLER must discard what it made of it (extract into a temp
#         dir and rename only if s3.sh exited 0; POSIX sh has no pipefail, so
#         capture s3.sh's status in a file).
#   copy  x-amz-copy-source, then HEAD on both sides: same size and MD5.
#   Retries: only transient failures (connection refused/reset, DNS, timeouts
#   and stalls, 5xx, 408/429, S3's RequestTimeout/BadDigest/IncompleteBody,
#   integrity mismatches), with exponential backoff. A 403 or a 404 is final on
#   the first answer.
#   Timeouts: connect timeout, plus stall detection (the transfer is aborted
#   when it moves less than S3_LOW_SPEED_LIMIT bytes/s for S3_LOW_SPEED_TIME
#   seconds). A per-attempt ceiling (S3_MAX_TIME) is the last resort only; it
#   is sized so a slow but moving multi-GiB transfer is never cut off.
#   S3_OP_TIMEOUT bounds the whole command, retries and backoff included (for
#   cat, the reader's time too): set it where the caller has a fallback, so a
#   store that is slow but alive cannot hold a lane.
#
# Configuration (the same Woodpecker secrets the lanes had for mc):
#   MINIO_ENDPOINT     http(s)://host[:port]; without a scheme, MINIO_USE_SSL
#                      (true/1/yes/on) picks https, anything else http
#   MINIO_ACCESS_KEY   access key
#   MINIO_SECRET_KEY   secret key; handed to curl on stdin, never in argv, and
#                      never printed (xtrace is switched off below)
#   S3_REGION          SigV4 region (us-east-1; SeaweedFS accepts any), or
#                      auto: the region an AWS endpoint's name carries, else
#                      the bucket's location (GetBucketLocation), as mc and
#                      minio-go resolve it
#   S3_ADDRESSING      path (endpoint/bucket/key, the default), virtual
#                      (bucket.endpoint/key), or auto: virtual for AWS, Google
#                      and Aliyun endpoints (not for a dotted bucket over
#                      https, which no wildcard certificate covers), path
#                      elsewhere -- mc's and minio-go's default
#   S3_TLS_INSECURE    true/1/yes/on: do not verify the endpoint's certificate
#   S3_CA_FILE         a PEM bundle to verify the endpoint's certificate with
#   S3_RETRIES         attempts per request (5)
#   S3_RETRY_DELAY     first backoff in seconds, doubled per retry, capped at
#                      S3_RETRY_MAX_DELAY (2, 30)
#   S3_CONNECT_TIMEOUT seconds (10)
#   S3_LOW_SPEED_LIMIT / S3_LOW_SPEED_TIME   stall detection (32 KiB/s, 60 s)
#   S3_MAX_TIME        per-attempt ceiling in seconds, 0 = none (3600)
#   S3_OP_TIMEOUT      the whole command, in seconds, 0 = none (0)
#   S3_MAX_PUT_BYTES   largest single PUT (5 GiB); larger goes multipart
#   S3_PUT_PART_BYTES  multipart part size (256 MiB, whole MiB, raised to keep
#                      within 10000 parts); one part at a time is on disk
#   S3_LS_PAGE         keys per ListObjectsV2 page (the store's default, 1000)
#   S3_PARALLEL        byte ranges fetched at once by get and cat (4; 1 = one
#                      stream for get); S3_PARALLEL_MIN_BYTES is "large" for
#                      get (32 MiB), and S3_PART_BYTES the size of each range
#                      (32 MiB, rounded up to whole MiB)
#
# There is no alias step: the object argument that used to read
# "myminio/$BUCKET/$KEY" is "$BUCKET/$KEY".

# Never trace this script: the secret is in its variables.
set +x
set -eu

S3_PROG=s3.sh
S3_REGION="${S3_REGION:-us-east-1}"
S3_ADDRESSING="${S3_ADDRESSING:-path}"
S3_TLS_INSECURE="${S3_TLS_INSECURE:-}"
S3_CA_FILE="${S3_CA_FILE:-}"
S3_RETRIES="${S3_RETRIES:-5}"
S3_RETRY_DELAY="${S3_RETRY_DELAY:-2}"
S3_RETRY_MAX_DELAY="${S3_RETRY_MAX_DELAY:-30}"
S3_CONNECT_TIMEOUT="${S3_CONNECT_TIMEOUT:-10}"
S3_LOW_SPEED_LIMIT="${S3_LOW_SPEED_LIMIT:-32768}"
S3_LOW_SPEED_TIME="${S3_LOW_SPEED_TIME:-60}"
S3_MAX_TIME="${S3_MAX_TIME:-3600}"
S3_OP_TIMEOUT="${S3_OP_TIMEOUT:-0}"
S3_MAX_PUT_BYTES="${S3_MAX_PUT_BYTES:-5368709120}"
S3_PUT_PART_BYTES="${S3_PUT_PART_BYTES:-268435456}"
S3_PARALLEL="${S3_PARALLEL:-4}"
S3_PARALLEL_MIN_BYTES="${S3_PARALLEL_MIN_BYTES:-33554432}"
S3_PART_BYTES="${S3_PART_BYTES:-33554432}"
S3_DEADLINE=0

s3_log() { printf '%s: %s\n' "$S3_PROG" "$*" >&2; }
s3_die() { _s3_rc=$1; shift; s3_log "$*"; exit "$_s3_rc"; }
s3_usage() {
  sed -n '/^# Usage/,/^# Exit codes/p' "$0" 2>/dev/null | sed '$d; s/^# \{0,1\}//' >&2 || true
  exit 2
}

for _s3_n in "$S3_RETRIES" "$S3_RETRY_DELAY" "$S3_RETRY_MAX_DELAY" "$S3_CONNECT_TIMEOUT" \
             "$S3_LOW_SPEED_LIMIT" "$S3_LOW_SPEED_TIME" "$S3_MAX_TIME" "$S3_OP_TIMEOUT" \
             "$S3_MAX_PUT_BYTES" "$S3_PUT_PART_BYTES" "${S3_LS_PAGE:-1}" \
             "$S3_PARALLEL" "$S3_PARALLEL_MIN_BYTES" "$S3_PART_BYTES"; do
  case "$_s3_n" in ''|*[!0-9]*) s3_die 2 "S3_* tunables must be non-negative integers (got '$_s3_n')" ;; esac
done
[ "$S3_RETRIES" -ge 1 ] || S3_RETRIES=1
[ "$S3_PARALLEL" -ge 1 ] || S3_PARALLEL=1
[ "$S3_PART_BYTES" -ge 1 ] || S3_PART_BYTES=1
[ "$S3_PUT_PART_BYTES" -ge 1 ] || S3_PUT_PART_BYTES=1
case "$S3_ADDRESSING" in path|virtual|auto) ;; *) s3_die 2 "S3_ADDRESSING must be path, virtual or auto (got '$S3_ADDRESSING')" ;; esac

s3_truthy() { case "$1" in [Tt][Rr][Uu][Ee]|1|[Yy][Ee][Ss]|[Oo][Nn]) return 0 ;; *) return 1 ;; esac; }

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
# Background work (a download's byte ranges, the stream hashers) is stopped on
# a signal, whole process trees (a part is a curl | dd pipeline), before the
# temp files go, so none of it re-creates a file after the cleanup. An
# unfinished multipart upload is aborted.
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
s3_forget_pid() { # $1 = a pid that has been waited for: never signal it again
  _s3_l=; for _s3_p in $S3_PART_PIDS; do [ "$_s3_p" = "$1" ] || _s3_l="$_s3_l $_s3_p"; done
  S3_PART_PIDS=$_s3_l
}
s3_on_signal() { s3_stop_parts; s3_mp_abort; s3_cleanup; exit "$1"; }
trap 's3_cleanup' EXIT
trap 's3_on_signal 130' INT
trap 's3_on_signal 143' TERM
trap 's3_on_signal 129' HUP

# s3_mktemp VAR DIR: create a temp file in DIR, store its path in VAR and
# register it for cleanup. Not `VAR=$(s3_mktemp)`: a command substitution is a
# subshell, and the registration would be lost with it.
s3_mktemp() {
  _s3_t=$(mktemp "$2/.s3tmp.XXXXXXXX") || s3_die 1 "cannot create a temp file in $2"
  s3_register "$_s3_t"
  eval "$1=\$_s3_t"
}

s3_size() { # byte size of a regular file; empty when there is none
  stat -c %s "$1" 2>/dev/null || { wc -c < "$1"; } 2>/dev/null | tr -d ' '
}

s3_md5_file() { md5sum < "$1" | cut -d' ' -f1; }

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

# The text of the first <$2> element in XML file $1, entity-decoded (the tag
# may carry attributes: AWS writes <LocationConstraint xmlns="...">).
s3_xml_field() {
  tr -d '\r\n' < "$1" | awk -v tag="$2" "$S3_AWK_UNESC"'
    BEGIN { RS = "<"; FS = ">" }
    { split($1, t, " ") }
    t[1] == tag { print unesc($2); exit }'
}

# ------------------------------------------------------------ configuration

# curl signs every header it sends only from 7.88.1 on (see the header): an
# older one fails on the first request with a misleading 403, so refuse it
# here, with exit 2 (configuration), before any request.
s3_check_curl() {
  command -v curl >/dev/null 2>&1 || s3_die 2 "curl is not installed"
  _s3_cv=$(curl --version 2>/dev/null | sed -n '1s/^curl \([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p')
  [ -n "$_s3_cv" ] || s3_die 2 "cannot read curl's version"
  _s3_ma=${_s3_cv%%.*}; _s3_mi=${_s3_cv#*.}; _s3_pa=${_s3_mi#*.}; _s3_mi=${_s3_mi%%.*}
  if [ "$_s3_ma" -lt 7 ] || { [ "$_s3_ma" -eq 7 ] && { [ "$_s3_mi" -lt 88 ] ||
       { [ "$_s3_mi" -eq 88 ] && [ "$_s3_pa" -lt 1 ]; }; }; }; then
    s3_die 2 "curl $_s3_cv is too old: s3.sh needs 7.88.1 or newer (older curls leave the x-amz-*, Content-MD5 and If-Match headers out of the SigV4 signature)"
  fi
}

s3_config() {
  _s3_ep="${MINIO_ENDPOINT:-}"
  [ -n "$_s3_ep" ] || s3_die 2 "MINIO_ENDPOINT is not set"
  [ -n "${MINIO_ACCESS_KEY:-}" ] || s3_die 2 "MINIO_ACCESS_KEY is not set"
  [ -n "${MINIO_SECRET_KEY:-}" ] || s3_die 2 "MINIO_SECRET_KEY is not set"
  case "$_s3_ep" in
    http://*|https://*) ;;
    *://*) s3_die 2 "MINIO_ENDPOINT must be http:// or https:// (got '$MINIO_ENDPOINT')" ;;
    *) if s3_truthy "${MINIO_USE_SSL:-false}"; then _s3_ep="https://$_s3_ep"; else _s3_ep="http://$_s3_ep"; fi ;;
  esac
  while :; do case "$_s3_ep" in */) _s3_ep=${_s3_ep%/} ;; *) break ;; esac; done
  S3_SCHEME=${_s3_ep%%://*}
  S3_HOST=${_s3_ep#*://}
  case "$S3_HOST" in
    ''|*/*|*'?'*|*'#'*|*@*|*' '*) s3_die 2 "MINIO_ENDPOINT must be scheme://host[:port] with no path (got '$MINIO_ENDPOINT')" ;;
  esac
  S3_BASE="$S3_SCHEME://$S3_HOST"
  # The Host header as curl and browsers send it: no port when it is the
  # scheme's default. A presigned URL signs this, so it must match exactly.
  S3_HOST_CANON=$S3_HOST
  case "$S3_SCHEME:$S3_HOST" in
    http:*:80) S3_HOST_CANON=${S3_HOST%:80} ;;
    https:*:443) S3_HOST_CANON=${S3_HOST%:443} ;;
  esac
  S3_SIGN_HOST=$S3_HOST_CANON   # s3_split names the bucket's host when virtual
  if [ -n "$S3_CA_FILE" ] && [ ! -r "$S3_CA_FILE" ]; then s3_die 2 "S3_CA_FILE '$S3_CA_FILE' is not readable"; fi
  # curl reads the credentials from a config on stdin: nothing secret in argv.
  # Inside a quoted config value only \ and " need escaping.
  S3_CURL_USER=$(printf '%s:%s' "$MINIO_ACCESS_KEY" "$MINIO_SECRET_KEY" | sed 's/[\\"]/\\&/g')
}

# The region an AWS S3 endpoint's host name carries, or nothing (minio-go's
# GetRegionFromURL: s3.R, s3-R, dualstack, FIPS, China and PrivateLink names).
s3_host_region() { # $1 = host name, no port
  case "$1" in s3-external-1.amazonaws.com|*elb*.amazonaws.com|*elb*.amazonaws.com.cn) return 0 ;; esac
  _s3_hr=$(printf '%s\n' "$1" | sed -n \
    -e '/^s3-fips\.dualstack\.\([a-z0-9-]*\)\.amazonaws\.com$/{s//\1/p;q;}' \
    -e '/^s3-fips\.\([a-z0-9-]*\)\.amazonaws\.com$/{s//\1/p;q;}' \
    -e '/^s3\.dualstack\.\([a-z0-9-]*\)\.amazonaws\.com$/{s//\1/p;q;}' \
    -e '/^s3-\([a-z0-9-]*\)\.amazonaws\.com$/{s//\1/p;q;}' \
    -e '/^s3\.\(cn[a-z0-9-]*\)\.amazonaws\.com\.cn$/{s//\1/p;q;}' \
    -e '/^s3\.dualstack\.\(cn[a-z0-9-]*\)\.amazonaws\.com\.cn$/{s//\1/p;q;}' \
    -e '/^[a-z]*\.vpce-[^.]*\.s3\.\([a-z0-9-]*\)\.vpce\.amazonaws\.com$/{s//\1/p;q;}' \
    -e '/^s3\.\([a-z0-9-]*\)\.amazonaws\.com$/{s//\1/p;q;}')
  case "$_s3_hr" in website-*|xpress-*|control|dualstack) _s3_hr= ;; esac
  printf '%s' "$_s3_hr"
}

s3_hostname() { # S3_HOST_CANON without a port (an [IPv6] literal is kept whole)
  case "$S3_HOST_CANON" in
    \[*) printf '%s' "${S3_HOST_CANON%%]*}]" ;;
    *) printf '%s' "${S3_HOST_CANON%%:*}" ;;
  esac
}

# S3_ADDRESSING=auto: virtual-host style exactly where mc and minio-go use it.
s3_auto_virtual() { # $1 = bucket
  _s3_hn=$(s3_hostname)
  case "$S3_SCHEME:$1" in https:*.*) return 1 ;; esac
  case "$_s3_hn" in
    s3.amazonaws.com|s3-external-1.amazonaws.com|storage.googleapis.com|*aliyuncs.com) return 0 ;;
  esac
  [ -n "$(s3_host_region "$_s3_hn")" ]
}

# S3_REGION=auto, resolved once per command for the first bucket named: the
# region in an AWS endpoint's name, else the bucket's location.
s3_resolve_region() { # $1 = bucket
  [ "$S3_REGION" = auto ] || return 0
  S3_REGION=$(s3_host_region "$(s3_hostname)")
  [ -z "$S3_REGION" ] || return 0
  s3_mktemp S3_LOC_HDR "${TMPDIR:-/tmp}"; s3_mktemp S3_LOC_BODY "${TMPDIR:-/tmp}"
  _s3_lr=0; s3_bucket_location "$1" || _s3_lr=$?
  [ "$_s3_lr" -eq 0 ] || exit "$_s3_lr"
  S3_REGION=$S3_LOCATION
  s3_log "S3_REGION=auto: bucket '$1' is in $S3_REGION"
}

# "bucket/key" -> S3_BUCKET, S3_KEY (key may be empty only if $2 = allow-empty),
# S3_URL (the object), S3_BKT_URL (the bucket), S3_PATH (/bucket/key, what
# x-amz-copy-source names), and the host and path a presigned URL signs.
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
  _s3_enc=$(s3_uriencode "$S3_KEY" /)
  S3_PATH="/$S3_BUCKET/$_s3_enc"
  [ -n "$S3_KEY" ] || S3_PATH="/$S3_BUCKET"
  s3_resolve_region "$S3_BUCKET"
  _s3_style=$S3_ADDRESSING
  if [ "$_s3_style" = auto ]; then
    _s3_style=path; if s3_auto_virtual "$S3_BUCKET"; then _s3_style=virtual; fi
  fi
  if [ "$_s3_style" = virtual ]; then
    S3_BKT_URL="$S3_SCHEME://$S3_BUCKET.$S3_HOST/"
    S3_URL="$S3_SCHEME://$S3_BUCKET.$S3_HOST/$_s3_enc"
    S3_SIGN_HOST="$S3_BUCKET.$S3_HOST_CANON"; S3_SIGN_PATH="/$_s3_enc"
  else
    S3_BKT_URL="$S3_BASE/$S3_BUCKET"
    S3_URL="$S3_BASE$S3_PATH"
    S3_SIGN_HOST=$S3_HOST_CANON; S3_SIGN_PATH=$S3_PATH
  fi
}

# ------------------------------------------------------------------- HTTP

s3_now() { date +%s; }

# s3_curl OUTFILE HDRFILE [curl args...]: one request, body to OUTFILE ("-"
# for stdout), response headers to HDRFILE. Returns curl's exit code; the HTTP
# status is read back from HDRFILE with s3_status. The credentials go to curl
# as a config on stdin, so they never appear in argv. Past the S3_OP_TIMEOUT
# deadline no request is made (curl's timeout code, 28, is returned), and
# before it --max-time is cut to what is left.
s3_curl() {
  _s3_out=$1; _s3_hdr=$2; shift 2
  : > "$_s3_hdr"
  _s3_mt=$S3_MAX_TIME
  if [ "$S3_DEADLINE" -gt 0 ]; then
    _s3_left=$(( S3_DEADLINE - $(s3_now) ))
    [ "$_s3_left" -gt 0 ] || return 28
    if [ "$_s3_mt" -eq 0 ] || [ "$_s3_left" -lt "$_s3_mt" ]; then _s3_mt=$_s3_left; fi
  fi
  set -- --config - --silent --show-error --globoff \
    --aws-sigv4 "aws:amz:$S3_REGION:s3" \
    --connect-timeout "$S3_CONNECT_TIMEOUT" \
    --speed-limit "$S3_LOW_SPEED_LIMIT" --speed-time "$S3_LOW_SPEED_TIME" \
    --output "$_s3_out" --dump-header "$_s3_hdr" "$@"
  if [ "$_s3_mt" -gt 0 ]; then set -- --max-time "$_s3_mt" "$@"; fi
  if s3_truthy "$S3_TLS_INSECURE"; then set -- --insecure "$@"; fi
  if [ -n "$S3_CA_FILE" ]; then set -- --cacert "$S3_CA_FILE" "$@"; fi
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

# After attempt $2 of "$1" failed with a retryable S3_CLASS: 0 = waited, try
# again; 1 = stop (out of attempts, or the S3_OP_TIMEOUT deadline would pass
# first). Logs either way.
s3_retry_wait() {
  if [ "$2" -ge "$S3_RETRIES" ]; then
    s3_log "$1: failed after $2 attempt(s): $S3_WHY"
    return 1
  fi
  _s3_wait=$(s3_backoff "$2")
  if [ "$S3_DEADLINE" -gt 0 ] && [ $(( $(s3_now) + _s3_wait )) -ge "$S3_DEADLINE" ]; then
    s3_log "$1: gave up after $2 attempt(s), S3_OP_TIMEOUT=${S3_OP_TIMEOUT}s reached: $S3_WHY"
    return 1
  fi
  s3_log "$1: attempt $2/$S3_RETRIES failed ($S3_WHY); retrying in ${_s3_wait}s"
  sleep "$_s3_wait"
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
        s3_retry_wait "$_s3_desc" "$_s3_att" || return "$(s3_class_rc)"
        _s3_att=$(( _s3_att + 1 )) ;;
      notfound) return 3 ;;
      *) s3_log "$_s3_desc: $S3_WHY"; return "$(s3_class_rc)" ;;
    esac
  done
}

s3_is_md5_etag() { case "$1" in *[!0-9a-f]*) return 1 ;; *) [ "${#1}" -eq 32 ] ;; esac; }

# What a response's headers say about verifying the bytes. $1 = header dump,
# $2 = the ETag (unquoted). Sets:
#   S3_ETAG_MD5_OK  1 when the ETag is a plain MD5 of the bytes: it looks like
#                   one and the object is not SSE-KMS/SSE-C encrypted (their
#                   ETags are not MD5s, whatever they look like)
#   S3_SSE_OPAQUE   1 when SSE-KMS/SSE-C makes every ETag opaque
#   S3_META_MD5     the object's x-amz-meta-s3sh-md5 (every s3.sh put sets it)
#   S3_WANT_MD5     the MD5 the bytes must have (metadata first, then ETag),
#                   and S3_WANT_FROM which of the two it came from; empty when
#                   neither is usable, and only the size can be checked
s3_want_md5() {
  S3_SSE_OPAQUE=0; S3_ETAG_MD5_OK=0
  case "$(s3_header "$1" x-amz-server-side-encryption)" in aws:kms*) S3_SSE_OPAQUE=1 ;; esac
  [ -z "$(s3_header "$1" x-amz-server-side-encryption-customer-algorithm)" ] || S3_SSE_OPAQUE=1
  if [ "$S3_SSE_OPAQUE" = 0 ] && s3_is_md5_etag "$2"; then S3_ETAG_MD5_OK=1; fi
  S3_META_MD5=$(s3_header "$1" x-amz-meta-s3sh-md5 | tr 'A-F' 'a-f')
  s3_is_md5_etag "$S3_META_MD5" || S3_META_MD5=
  # The metadata is what the writer declared; when a plain-MD5 ETag agrees,
  # the log just says MD5.
  if [ "$S3_ETAG_MD5_OK" = 1 ] && { [ -z "$S3_META_MD5" ] || [ "$S3_META_MD5" = "$2" ]; }; then
    S3_WANT_MD5=$2; S3_WANT_FROM=ETag
  elif [ -n "$S3_META_MD5" ]; then
    S3_WANT_MD5=$S3_META_MD5; S3_WANT_FROM=x-amz-meta-s3sh-md5
    [ "$S3_ETAG_MD5_OK" = 0 ] || S3_WANT_FROM="x-amz-meta-s3sh-md5; ETag $2 differs"
  else S3_WANT_MD5=; S3_WANT_FROM=
  fi
}

# The log's account of what a finished download was checked against.
s3_verified_msg() { # $1 = MD5 of the bytes, or empty when only the size was checked; $2 = ETag
  if [ -n "$1" ]; then
    S3_VERIFIED="MD5 $1 verified"
    [ "$S3_WANT_FROM" = ETag ] || S3_VERIFIED="$S3_VERIFIED ($S3_WANT_FROM)"
  elif [ "$S3_SSE_OPAQUE" = 1 ]; then
    S3_VERIFIED="size verified (SSE-KMS/SSE-C: ETag '$2' is not an MD5, and no x-amz-meta-s3sh-md5)"
  else
    S3_VERIFIED="size verified (ETag '$2' is not a plain MD5, e.g. a multipart upload by another client)"
  fi
}

# ------------------------------------------------------------------- verbs

# HEAD one object. Sets S3_HEAD_SIZE / S3_HEAD_ETAG (without quotes), and from
# s3_want_md5: S3_HEAD_MD5 (what the bytes must hash to, or empty),
# S3_HEAD_MD5_FROM, S3_HEAD_META_MD5, S3_HEAD_SSE_OPAQUE.
s3_head_once() {
  S3_HEAD_SIZE=; S3_HEAD_ETAG=; S3_HEAD_MD5=; S3_HEAD_MD5_FROM=; S3_HEAD_META_MD5=
  S3_HEAD_SSE_OPAQUE=0
  _s3_rc=0
  s3_curl /dev/null "$S3_HDR" --head "$S3_URL" || _s3_rc=$?
  _s3_st=$(s3_status "$S3_HDR")
  s3_classify "$_s3_rc" "$_s3_st" /dev/null
  if [ "$S3_CLASS" = ok ]; then
    S3_HEAD_SIZE=$(s3_header "$S3_HDR" content-length)
    S3_HEAD_ETAG=$(s3_header "$S3_HDR" etag | tr -d '"')
    s3_want_md5 "$S3_HDR" "$S3_HEAD_ETAG"
    S3_HEAD_MD5=$S3_WANT_MD5; S3_HEAD_MD5_FROM=$S3_WANT_FROM; S3_HEAD_META_MD5=$S3_META_MD5
    S3_HEAD_SSE_OPAQUE=$S3_SSE_OPAQUE
  fi
}

# After a 404 on an object, tell "no such key" (exit 3) from "no such bucket"
# (a configuration error, exit 1): HEAD carries no error body to read it from.
# Prints the exit code the command should end with. $2 = quiet: say nothing
# about a missing object (stat is the probe the lanes run to ask "is it
# there?"; get and copy need the object, so a miss is worth a line in the log).
s3_notfound_rc() { # $1 = description, $2 = quiet (optional)
  _s3_rc=0
  s3_curl /dev/null "$S3_HDR" --head "$S3_BKT_URL" || _s3_rc=$?
  _s3_st=$(s3_status "$S3_HDR")
  if [ "$_s3_rc" -eq 0 ] && [ "$_s3_st" = 404 ]; then
    s3_log "$1: bucket '$S3_BUCKET' does not exist"
    echo 1
  else
    [ -n "${2:-}" ] || s3_log "$1: no such object"
    echo 3
  fi
}

cmd_stat() {
  [ $# -eq 1 ] || s3_usage
  s3_split "$1"
  s3_mktemp S3_HDR "${TMPDIR:-/tmp}"
  _s3_r=0; s3_run "stat $1" s3_head_once || _s3_r=$?
  if [ "$_s3_r" -eq 3 ]; then return "$(s3_notfound_rc "stat $1" quiet)"; fi
  [ "$_s3_r" -eq 0 ] || return "$_s3_r"
  printf '%s %s\n' "$S3_HEAD_SIZE" "$S3_HEAD_ETAG"
}

# The HEAD after an upload: the object a later get will see must be the one
# sent. $1 = the MD5 of the whole file, $2 = the ETag the store must report
# unless SSE makes it opaque (a single PUT: the MD5; multipart: see there).
s3_check_readback() {
  if [ "$S3_HEAD_SIZE" != "$S3_SIZE" ]; then
    S3_CLASS=integrity; S3_WHY="read-back is $S3_HEAD_SIZE bytes, ETag $S3_HEAD_ETAG; sent $S3_SIZE bytes, MD5 $1"; return 0
  fi
  if [ -n "$S3_HEAD_META_MD5" ] && [ "$S3_HEAD_META_MD5" != "$1" ]; then
    S3_CLASS=integrity; S3_WHY="read-back x-amz-meta-s3sh-md5 is $S3_HEAD_META_MD5; sent MD5 $1"; return 0
  fi
  if [ "$S3_HEAD_SSE_OPAQUE" = 0 ] && [ "$S3_HEAD_ETAG" != "$2" ]; then
    S3_CLASS=integrity; S3_WHY="read-back ETag is $S3_HEAD_ETAG; want $2 for what was sent"; return 0
  fi
}

s3_put_once() {
  # Sized and hashed on every attempt, not once: if the file changed under an
  # attempt, the store's BadDigest is retried against what the file holds now.
  S3_SIZE=$(s3_size "$S3_SRC")
  if [ "$S3_SIZE" -gt "$S3_MAX_PUT_BYTES" ]; then
    S3_CLASS=fatal; S3_WHY="$S3_SRC grew to $S3_SIZE bytes, over the $S3_MAX_PUT_BYTES-byte single-PUT limit, while it was being sent"; return 0
  fi
  S3_MD5_HEX=$(s3_md5_file "$S3_SRC")
  if ! s3_is_md5_etag "$S3_MD5_HEX"; then S3_CLASS=fatal; S3_WHY="could not hash $S3_SRC"; return 0; fi
  S3_MD5_B64=$(printf '%s' "$S3_MD5_HEX" | s3_hex2bin | base64)
  _s3_rc=0
  s3_curl "$S3_BODY" "$S3_HDR" --upload-file "$S3_SRC" \
    --header "Content-MD5: $S3_MD5_B64" \
    --header 'Content-Type: application/octet-stream' \
    --header "x-amz-meta-s3sh-md5: $S3_MD5_HEX" \
    --header 'x-amz-content-sha256: UNSIGNED-PAYLOAD' \
    "$S3_URL" || _s3_rc=$?
  _s3_st=$(s3_status "$S3_HDR")
  s3_classify "$_s3_rc" "$_s3_st" "$S3_BODY"
  [ "$S3_CLASS" = ok ] || return 0
  _s3_etag=$(s3_header "$S3_HDR" etag | tr -d '"')
  s3_want_md5 "$S3_HDR" "$_s3_etag"
  if [ -n "$_s3_etag" ] && [ "$S3_SSE_OPAQUE" = 0 ] && [ "$_s3_etag" != "$S3_MD5_HEX" ]; then
    S3_CLASS=integrity; S3_WHY="store answered ETag $_s3_etag for MD5 $S3_MD5_HEX"; return 0
  fi
  # Read it back: what a later get will see must be what was sent.
  s3_head_once
  case "$S3_CLASS" in
    ok) ;;
    notfound) S3_CLASS=integrity; S3_WHY="object missing right after a successful PUT"; return 0 ;;
    *) return 0 ;;
  esac
  s3_check_readback "$S3_MD5_HEX" "$S3_MD5_HEX"
}

# ---------------------------------------------------------- multipart put
# For a file over S3_MAX_PUT_BYTES. The upload id lives in S3_MP_ID until the
# object is complete, so a failure or a signal aborts it.
# (The S3_MP_* file variables are set by s3_mktemp, through eval.)
S3_MP_ID=
# shellcheck disable=SC2153
s3_mp_abort() {
  [ -n "$S3_MP_ID" ] || return 0
  _s3m_aid=$(s3_uriencode "$S3_MP_ID"); S3_MP_ID=
  _s3m_dl=$S3_DEADLINE; S3_DEADLINE=0; _s3m_mt=$S3_MAX_TIME; S3_MAX_TIME=30
  s3_curl /dev/null "$S3_MP_HDR" --request DELETE "$S3_URL?uploadId=$_s3m_aid" >/dev/null 2>&1 || true
  S3_DEADLINE=$_s3m_dl; S3_MAX_TIME=$_s3m_mt
}

s3_mp_init_once() {
  _s3_rc=0
  s3_curl "$S3_BODY" "$S3_HDR" --request POST \
    --header 'Content-Type: application/octet-stream' \
    --header "x-amz-meta-s3sh-md5: $S3_MD5_HEX" \
    --header 'x-amz-content-sha256: UNSIGNED-PAYLOAD' \
    "$S3_URL?uploads=" || _s3_rc=$?
  _s3_st=$(s3_status "$S3_HDR")
  s3_classify "$_s3_rc" "$_s3_st" "$S3_BODY"
  [ "$S3_CLASS" = ok ] || return 0
  S3_MP_ID=$(s3_xml_field "$S3_BODY" UploadId)
  [ -n "$S3_MP_ID" ] || { S3_CLASS=fatal; S3_WHY="the store started a multipart upload without an UploadId"; }
}

s3_mp_part_once() {
  _s3_rc=0
  s3_curl "$S3_BODY" "$S3_HDR" --upload-file "$S3_MP_PART" \
    --header "Content-MD5: $S3_MP_PB64" \
    --header 'x-amz-content-sha256: UNSIGNED-PAYLOAD' \
    "$S3_URL?partNumber=$S3_MP_K&uploadId=$S3_MP_EID" || _s3_rc=$?
  _s3_st=$(s3_status "$S3_HDR")
  s3_classify "$_s3_rc" "$_s3_st" "$S3_BODY"
  # 404 NoSuchUpload: the store lost the upload. Retrying the part cannot
  # help; starting the whole upload over can.
  if [ "$S3_CLASS" = notfound ]; then S3_CLASS=fatal; S3_WHY="the store lost the upload ($S3_WHY)"; S3_MP_RESTART=1; fi
  [ "$S3_CLASS" = ok ] || return 0
  S3_MP_PETAG=$(s3_header "$S3_HDR" etag)
  _s3_etag=$(printf '%s' "$S3_MP_PETAG" | tr -d '"')
  s3_want_md5 "$S3_HDR" "$_s3_etag"
  if [ -z "$_s3_etag" ]; then S3_CLASS=fatal; S3_WHY="no ETag for part $S3_MP_K"; return 0; fi
  if [ "$S3_SSE_OPAQUE" = 0 ] && [ "$_s3_etag" != "$S3_MP_PMD5" ]; then
    S3_CLASS=integrity; S3_WHY="store answered ETag $_s3_etag for part $S3_MP_K, MD5 $S3_MP_PMD5"
  fi
}

s3_mp_complete_once() {
  _s3_rc=0
  s3_curl "$S3_BODY" "$S3_HDR" --request POST --data-binary "@$S3_MP_XML" \
    --header 'Content-Type: application/xml' \
    --header 'x-amz-content-sha256: UNSIGNED-PAYLOAD' \
    "$S3_URL?uploadId=$S3_MP_EID" || _s3_rc=$?
  _s3_st=$(s3_status "$S3_HDR")
  s3_classify "$_s3_rc" "$_s3_st" "$S3_BODY"
  [ "$S3_CLASS" = ok ] || return 0
  # S3 may answer 200 and put the error in the body.
  if grep -q '<Error>' "$S3_BODY" 2>/dev/null; then
    s3_classify 0 500 "$S3_BODY"; S3_WHY="complete answered 200 with an error body: $S3_WHY"; return 0
  fi
  S3_MP_DONE_ETAG=$(s3_xml_field "$S3_BODY" ETag | tr -d '"')
}

# One whole multipart upload. Returns 0 or an exit code; S3_MP_RESTART=1 when
# starting over can help (the file changed while it was sent, the store lost
# the upload, or the completed object is not the one sent). A request that
# failed for good after its own retries is final.
# shellcheck disable=SC2153
s3_mp_once() {
  _s3m_desc=$1
  S3_MP_RESTART=
  S3_SIZE=$(s3_size "$S3_SRC")
  _s3m_psz=$(( (S3_PUT_PART_BYTES + 1048575) / 1048576 * 1048576 ))
  _s3m_min=$(( (S3_SIZE + 9999) / 10000 ))
  _s3m_min=$(( (_s3m_min + 1048575) / 1048576 * 1048576 ))
  [ "$_s3m_psz" -ge "$_s3m_min" ] || _s3m_psz=$_s3m_min
  S3_MP_N=$(( (S3_SIZE + _s3m_psz - 1) / _s3m_psz ))
  S3_MD5_HEX=$(s3_md5_file "$S3_SRC")
  s3_is_md5_etag "$S3_MD5_HEX" || { s3_log "$_s3m_desc: could not hash $S3_SRC"; return 1; }
  _s3m_r=0; s3_run "$_s3m_desc: start multipart upload" s3_mp_init_once || _s3m_r=$?
  if [ "$_s3m_r" -eq 3 ]; then
    [ "$(s3_notfound_rc "$_s3m_desc")" = 1 ] || s3_log "$_s3m_desc: store answered 404"
    return 1
  fi
  [ "$_s3m_r" -eq 0 ] || return "$_s3m_r"
  S3_MP_EID=$(s3_uriencode "$S3_MP_ID")
  # What is actually sent is hashed as it goes, so a file that changes between
  # the MD5 declared above and the last part is caught, not stored.
  rm -f "$S3_MP_FIFO"
  mkfifo "$S3_MP_FIFO" || { s3_mp_abort; s3_log "$_s3m_desc: mkfifo failed"; return 1; }
  md5sum < "$S3_MP_FIFO" > "$S3_MP_SUMF" &
  _s3m_hpid=$!
  S3_PART_PIDS="$S3_PART_PIDS $_s3m_hpid"
  exec 8> "$S3_MP_FIFO"
  : > "$S3_MP_MD5S"
  printf '<CompleteMultipartUpload>' > "$S3_MP_XML"
  S3_MP_K=1; _s3m_rc=0
  while [ "$S3_MP_K" -le "$S3_MP_N" ]; do
    _s3m_len=$_s3m_psz
    [ "$S3_MP_K" -lt "$S3_MP_N" ] || _s3m_len=$(( S3_SIZE - (S3_MP_N - 1) * _s3m_psz ))
    if ! dd if="$S3_SRC" of="$S3_MP_PART" bs=1048576 skip=$(( (S3_MP_K - 1) * _s3m_psz / 1048576 )) \
           count=$(( _s3m_psz / 1048576 )) 2>/dev/null; then
      s3_log "$_s3m_desc: reading part $S3_MP_K of $S3_SRC failed"; _s3m_rc=1; break
    fi
    if [ "$(s3_size "$S3_MP_PART")" != "$_s3m_len" ]; then
      S3_WHY="$S3_SRC changed size while it was being uploaded"; S3_MP_RESTART=1; _s3m_rc=6; break
    fi
    S3_MP_PMD5=$(s3_md5_file "$S3_MP_PART")
    S3_MP_PB64=$(printf '%s' "$S3_MP_PMD5" | s3_hex2bin | base64)
    _s3m_r=0; s3_run "$_s3m_desc: part $S3_MP_K/$S3_MP_N" s3_mp_part_once || _s3m_r=$?
    if [ "$_s3m_r" -ne 0 ]; then _s3m_rc=$_s3m_r; [ -z "$S3_MP_RESTART" ] || _s3m_rc=6; break; fi
    cat "$S3_MP_PART" >&8 || { s3_log "$_s3m_desc: hashing part $S3_MP_K failed"; _s3m_rc=1; break; }
    printf '%s' "$S3_MP_PMD5" >> "$S3_MP_MD5S"
    printf '<Part><PartNumber>%s</PartNumber><ETag>%s</ETag></Part>' "$S3_MP_K" "$S3_MP_PETAG" >> "$S3_MP_XML"
    S3_MP_K=$(( S3_MP_K + 1 ))
  done
  rm -f "$S3_MP_PART"
  exec 8>&-
  wait "$_s3m_hpid" 2>/dev/null || true
  s3_forget_pid "$_s3m_hpid"
  if [ "$_s3m_rc" -eq 0 ] && [ "$(cut -d' ' -f1 < "$S3_MP_SUMF")" != "$S3_MD5_HEX" ]; then
    S3_WHY="$S3_SRC changed while it was being uploaded (sent MD5 $(cut -d' ' -f1 < "$S3_MP_SUMF"), declared $S3_MD5_HEX)"
    S3_MP_RESTART=1; _s3m_rc=6
  fi
  if [ "$_s3m_rc" -ne 0 ]; then s3_mp_abort; return "$_s3m_rc"; fi
  printf '</CompleteMultipartUpload>' >> "$S3_MP_XML"
  S3_MP_DONE_ETAG=
  _s3m_r=0; s3_run "$_s3m_desc: complete multipart upload" s3_mp_complete_once || _s3m_r=$?
  # 404 after a retry: the first attempt completed it and its answer was
  # lost. The read-back below decides whether the object is the one sent.
  if [ "$_s3m_r" -ne 0 ] && [ "$_s3m_r" -ne 3 ]; then s3_mp_abort; return "$_s3m_r"; fi
  S3_MP_ID=
  # A multipart ETag is the MD5 of the parts' binary MD5s, then "-<parts>".
  _s3m_want="$(s3_hex2bin < "$S3_MP_MD5S" | md5sum | cut -d' ' -f1)-$S3_MP_N"
  if [ -n "$S3_MP_DONE_ETAG" ] && [ "$S3_SSE_OPAQUE" = 0 ] && [ "$S3_MP_DONE_ETAG" != "$_s3m_want" ]; then
    S3_WHY="complete answered ETag $S3_MP_DONE_ETAG; want $_s3m_want"; S3_MP_RESTART=1; return 6
  fi
  _s3m_r=0; s3_run "$_s3m_desc: read back" s3_head_once || _s3m_r=$?
  if [ "$_s3m_r" -eq 3 ]; then
    S3_WHY="object missing right after its multipart upload completed"; S3_MP_RESTART=1; return 6
  fi
  [ "$_s3m_r" -eq 0 ] || return "$_s3m_r"
  S3_CLASS=ok
  s3_check_readback "$S3_MD5_HEX" "$_s3m_want"
  if [ "$S3_CLASS" != ok ]; then S3_MP_RESTART=1; return 6; fi
}

s3_put_multipart() { # $1 = description
  s3_mktemp S3_MP_HDR "${TMPDIR:-/tmp}"; s3_mktemp S3_MP_SUMF "${TMPDIR:-/tmp}"
  s3_mktemp S3_MP_MD5S "${TMPDIR:-/tmp}"; s3_mktemp S3_MP_XML "${TMPDIR:-/tmp}"
  s3_mktemp S3_MP_PART "${TMPDIR:-/tmp}"
  S3_MP_FIFO="$S3_MP_SUMF.fifo"; s3_register "$S3_MP_FIFO"
  _s3m_att=1
  while :; do
    _s3m_r=0; s3_mp_once "$1" || _s3m_r=$?
    { [ "$_s3m_r" -ne 0 ] && [ -n "$S3_MP_RESTART" ]; } || return "$_s3m_r"
    S3_CLASS=integrity
    s3_retry_wait "$1" "$_s3m_att" || return 6
    _s3m_att=$(( _s3m_att + 1 ))
  done
}

cmd_put() {
  [ $# -eq 2 ] || s3_usage
  S3_SRC=$1
  s3_split "$2"
  _s3_dir=${TMPDIR:-/tmp}
  if [ "$S3_SRC" = - ]; then
    # Unknown length: spool, so the upload is still one verified object.
    s3_mktemp S3_SRC "$_s3_dir"
    cat > "$S3_SRC" || s3_die 1 "put $2: reading stdin failed"
  fi
  { [ -f "$S3_SRC" ] && [ -r "$S3_SRC" ]; } || s3_die 1 "put: '$S3_SRC' is not a readable regular file"
  s3_mktemp S3_HDR "$_s3_dir"; s3_mktemp S3_BODY "$_s3_dir"
  _s3_t0=$(s3_now)
  if [ "$(s3_size "$S3_SRC")" -gt "$S3_MAX_PUT_BYTES" ]; then
    _s3_r=0; s3_put_multipart "put $1 -> $2" || _s3_r=$?
    [ "$_s3_r" -eq 0 ] || return "$_s3_r"
    s3_log "put $2: $S3_SIZE bytes in $S3_MP_N parts, MD5 $S3_MD5_HEX verified, $(( $(s3_now) - _s3_t0 ))s"
    return 0
  fi
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
      "$S3_URL" || _s3_prc=$?
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
  _s3_size=$S3_HEAD_SIZE; _s3_etag=$S3_HEAD_ETAG; _s3_want=$S3_HEAD_MD5
  S3_WANT_FROM=$S3_HEAD_MD5_FROM; S3_SSE_OPAQUE=$S3_HEAD_SSE_OPAQUE
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
  _s3_md5=
  if [ -n "$_s3_want" ]; then
    _s3_md5=$(s3_md5_file "$S3_TMP")
    if [ "$_s3_md5" != "$_s3_want" ]; then
      S3_CLASS=integrity; S3_WHY="assembled MD5 $_s3_md5, want $_s3_want ($S3_WANT_FROM)"; return 0
    fi
  fi
  s3_verified_msg "$_s3_md5" "$_s3_etag"
  S3_VERIFIED="$S3_VERIFIED, $_s3_n parts"
  S3_GOT=$_s3_have
}

s3_get_stream() {
  # The body streams through tee into md5sum while it lands in the temp file,
  # so verifying costs no second pass over a multi-GiB object. curl's exit
  # code comes back through a file: a POSIX pipeline only reports its last
  # command's.
  { _s3_rc=0
    s3_curl - "$S3_HDR" "$S3_URL" || _s3_rc=$?
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
  s3_want_md5 "$S3_HDR" "$_s3_etag"
  _s3_md5=
  if [ -n "$S3_WANT_MD5" ]; then
    _s3_md5=$(cut -d' ' -f1 < "$S3_SUMF")
    if [ "$_s3_md5" != "$S3_WANT_MD5" ]; then
      S3_CLASS=integrity; S3_WHY="received MD5 $_s3_md5, want $S3_WANT_MD5 ($S3_WANT_FROM)"; return 0
    fi
  fi
  s3_verified_msg "$_s3_md5" "$_s3_etag"
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

# ------------------------------------------------------------------- cat
# The object goes to stdout as a run of byte ranges (see the header for the
# guarantees). Up to S3_PARALLEL ranges are fetched ahead in the background,
# each into its own temp file; the one at the head of the line is checked,
# retried alone if it went wrong, written out, and deleted. With a known MD5
# every written byte also goes down fd 7 into md5sum, and the last range is
# written only once the MD5 of everything matches.

s3_cat_bounds() { # $1 = range index -> S3_CAT_FIRST, S3_CAT_LAST, S3_CAT_LEN
  S3_CAT_FIRST=$(( $1 * S3_CAT_PSZ )); S3_CAT_LAST=$(( S3_CAT_FIRST + S3_CAT_PSZ - 1 ))
  [ "$S3_CAT_LAST" -lt "$S3_CAT_SIZE" ] || S3_CAT_LAST=$(( S3_CAT_SIZE - 1 ))
  S3_CAT_LEN=$(( S3_CAT_LAST - S3_CAT_FIRST + 1 ))
}

s3_cat_fetch() { # $1 = range index; its curl exit code goes to a file
  s3_cat_bounds "$1"
  _s3f_rc=0
  s3_curl "$S3_CAT_BASE.$1" "$S3_HDR.$1" --range "$S3_CAT_FIRST-$S3_CAT_LAST" \
    --header "If-Match: \"$S3_CAT_ETAG\"" "$S3_URL" || _s3f_rc=$?
  echo "$_s3f_rc" > "$S3_RCF.$1"
}

s3_cat_start() { # $1 = range index, fetched in the background
  s3_register "$S3_CAT_BASE.$1"; s3_register "$S3_HDR.$1"; s3_register "$S3_RCF.$1"
  rm -f "$S3_RCF.$1"
  s3_cat_fetch "$1" > /dev/null 7>&- 8>&- &
  eval "S3_CAT_PID_$1=\$!"
  S3_PART_PIDS="$S3_PART_PIDS $!"
}

s3_cat_wait() { # $1 = range index
  eval "_s3w_pid=\${S3_CAT_PID_$1:-}"
  [ -n "$_s3w_pid" ] || return 0
  wait "$_s3w_pid" 2>/dev/null || true
  s3_forget_pid "$_s3w_pid"
  eval "S3_CAT_PID_$1="
}

# Sets S3_CLASS for range $1: ok, the usual failure classes, or
#   changed  412: the object is no longer the version the stream started on
#   norange  the store answered 200 with the whole object instead of a range
s3_cat_check() {
  s3_cat_bounds "$1"
  _s3k_rc=$(cat "$S3_RCF.$1" 2>/dev/null || echo 1)
  _s3k_st=$(s3_status "$S3_HDR.$1")
  _s3k_body=/dev/null
  case "$_s3k_st" in 2??) ;; *) _s3k_body="$S3_CAT_BASE.$1" ;; esac
  s3_classify "$_s3k_rc" "$_s3k_st" "$_s3k_body"
  S3_WHY="bytes $S3_CAT_FIRST-$S3_CAT_LAST: $S3_WHY"
  if [ "$S3_CLASS" = ok ]; then
    _s3k_cl=$(s3_header "$S3_HDR.$1" content-length)
    _s3k_have=$(s3_size "$S3_CAT_BASE.$1")
    if [ "$_s3k_st" = 200 ] && ! { [ "$S3_CAT_N" -eq 1 ] && [ "$_s3k_cl" = "$S3_CAT_SIZE" ]; }; then
      S3_CLASS=norange; S3_WHY="the store answered a ranged GET with the whole object"
    elif [ "$_s3k_st" != 206 ] && [ "$_s3k_st" != 200 ]; then
      S3_CLASS=fatal; S3_WHY="bytes $S3_CAT_FIRST-$S3_CAT_LAST: unexpected HTTP $_s3k_st"
    elif [ "$_s3k_cl" != "$S3_CAT_LEN" ] || [ "$_s3k_have" != "$S3_CAT_LEN" ]; then
      S3_CLASS=integrity
      S3_WHY="bytes $S3_CAT_FIRST-$S3_CAT_LAST: received $_s3k_have bytes, Content-Length ${_s3k_cl:-absent}, want $S3_CAT_LEN"
    fi
  elif [ "$_s3k_st" = 412 ]; then
    S3_CLASS=changed
  fi
}

s3_cat_stop() { # stop everything in flight: range fetches, then the hasher
  s3_stop_parts
  if [ -n "$S3_CAT_HPID" ]; then
    exec 7>&-
    kill "$S3_CAT_HPID" 2>/dev/null || true
    wait "$S3_CAT_HPID" 2>/dev/null || true
    S3_CAT_HPID=
  fi
}

s3_cat_once() { # one pass over the object HEAD described; sets S3_CLASS
  S3_CAT_SIZE=$S3_HEAD_SIZE; S3_CAT_ETAG=$S3_HEAD_ETAG; S3_CAT_WANT=$S3_HEAD_MD5
  S3_WANT_FROM=$S3_HEAD_MD5_FROM; S3_SSE_OPAQUE=$S3_HEAD_SSE_OPAQUE
  S3_CAT_PSZ=$(( (S3_PART_BYTES + 1048575) / 1048576 * 1048576 ))
  S3_CAT_N=$(( (S3_CAT_SIZE + S3_CAT_PSZ - 1) / S3_CAT_PSZ ))
  S3_CAT_BASE="$S3_RCF.r"; S3_CAT_HPID=; S3_CAT_LOGGED=
  if [ -n "$S3_CAT_WANT" ]; then
    rm -f "$S3_CAT_FIFO"
    if ! mkfifo "$S3_CAT_FIFO"; then S3_CLASS=fatal; S3_WHY="mkfifo failed"; return 0; fi
    md5sum < "$S3_CAT_FIFO" > "$S3_SUMF" &
    S3_CAT_HPID=$!
    exec 7> "$S3_CAT_FIFO"
  fi
  _s3c_next=0; _s3c_i=0
  while [ "$_s3c_i" -lt "$S3_CAT_N" ]; do
    while [ "$_s3c_next" -lt "$S3_CAT_N" ] && [ "$_s3c_next" -lt $(( _s3c_i + S3_PARALLEL )) ]; do
      s3_cat_start "$_s3c_next"
      _s3c_next=$(( _s3c_next + 1 ))
    done
    s3_cat_wait "$_s3c_i"
    s3_cat_check "$_s3c_i"
    _s3c_att=1
    while [ "$S3_CLASS" = transient ] || [ "$S3_CLASS" = integrity ]; do
      s3_retry_wait "cat $S3_BUCKET/$S3_KEY: bytes $S3_CAT_FIRST-$S3_CAT_LAST" "$_s3c_att" || { S3_CAT_LOGGED=1; break; }
      _s3c_att=$(( _s3c_att + 1 ))
      s3_cat_fetch "$_s3c_i" > /dev/null
      s3_cat_check "$_s3c_i"
    done
    case "$S3_CLASS" in
      ok) ;;
      changed)
        if [ "$S3_CAT_OUT" -eq 0 ]; then
          S3_CLASS=restart; S3_WHY="the object changed before the first byte was written (412)"
        else
          S3_CLASS=integrity; S3_WHY="the object changed after $S3_CAT_OUT bytes had been written (412)"
        fi
        s3_cat_stop; return 0 ;;
      norange)
        [ "$_s3c_i" -eq 0 ] || S3_CLASS=fatal
        s3_cat_stop; return 0 ;;
      *) s3_cat_stop; return 0 ;;
    esac
    _s3c_part="$S3_CAT_BASE.$_s3c_i"
    if [ -n "$S3_CAT_WANT" ] && [ "$_s3c_i" -eq $(( S3_CAT_N - 1 )) ]; then
      # The last range waits for the MD5 of everything.
      if ! cat "$_s3c_part" >&7; then S3_CLASS=fatal; S3_WHY="hashing the stream failed"; s3_cat_stop; return 0; fi
      exec 7>&-
      wait "$S3_CAT_HPID" 2>/dev/null || true
      S3_CAT_HPID=
      _s3c_md5=$(cut -d' ' -f1 < "$S3_SUMF")
      if [ "$_s3c_md5" != "$S3_CAT_WANT" ]; then
        S3_CLASS=integrity
        S3_WHY="the object's MD5 is $_s3c_md5, want $S3_CAT_WANT ($S3_WANT_FROM): its last $S3_CAT_LEN bytes were not written"
        s3_cat_stop; return 0
      fi
      if ! cat "$_s3c_part"; then
        S3_CLASS=fatal; S3_WHY="writing to stdout failed after $S3_CAT_OUT bytes (the reader went away?)"; s3_cat_stop; return 0
      fi
    elif [ -n "$S3_CAT_WANT" ]; then
      # One pass: the reader and the hasher take the range side by side, so
      # hashing never adds to the time the reader waits.
      if ! tee "$S3_CAT_FIFO" < "$_s3c_part"; then
        S3_CLASS=fatal; S3_WHY="writing the stream failed after $S3_CAT_OUT bytes (the reader went away?)"; s3_cat_stop; return 0
      fi
    elif ! cat "$_s3c_part"; then
      S3_CLASS=fatal; S3_WHY="writing to stdout failed after $S3_CAT_OUT bytes (the reader went away?)"; s3_cat_stop; return 0
    fi
    S3_CAT_OUT=$(( S3_CAT_OUT + S3_CAT_LEN ))
    rm -f "$_s3c_part"
    _s3c_i=$(( _s3c_i + 1 ))
  done
  _s3c_md5=
  if [ -n "$S3_CAT_HPID" ]; then
    # An empty object: nothing went through the hasher.
    exec 7>&-
    wait "$S3_CAT_HPID" 2>/dev/null || true
    S3_CAT_HPID=
    _s3c_md5=$(cut -d' ' -f1 < "$S3_SUMF")
    if [ "$_s3c_md5" != "$S3_CAT_WANT" ]; then
      S3_CLASS=integrity; S3_WHY="the object's MD5 is $_s3c_md5, want $S3_CAT_WANT ($S3_WANT_FROM)"; return 0
    fi
  elif [ -n "$S3_CAT_WANT" ]; then
    _s3c_md5=$S3_CAT_WANT
  fi
  s3_verified_msg "$_s3c_md5" "$S3_CAT_ETAG"
  S3_VERIFIED="$S3_VERIFIED, $S3_CAT_N ranges"
  S3_CLASS=ok
}

cmd_cat() {
  [ $# -eq 1 ] || s3_usage
  s3_split "$1"
  _s3c_dir=${TMPDIR:-/tmp}
  s3_mktemp S3_HDR "$_s3c_dir"; s3_mktemp S3_RCF "$_s3c_dir"; s3_mktemp S3_SUMF "$_s3c_dir"
  S3_CAT_FIFO="$S3_RCF.fifo"; s3_register "$S3_CAT_FIFO"
  _s3c_t0=$(s3_now)
  S3_CAT_OUT=0
  _s3c_restart=1
  while :; do
    _s3c_r=0; s3_run "cat $1" s3_head_once || _s3c_r=$?
    if [ "$_s3c_r" -eq 3 ]; then return "$(s3_notfound_rc "cat $1")"; fi
    [ "$_s3c_r" -eq 0 ] || return "$_s3c_r"
    case "$S3_HEAD_SIZE" in ''|*[!0-9]*) s3_log "cat $1: the store sent no Content-Length"; return 1 ;; esac
    s3_cat_once
    case "$S3_CLASS" in
      ok) break ;;
      restart)
        S3_CLASS=transient
        s3_retry_wait "cat $1" "$_s3c_restart" || return 5
        _s3c_restart=$(( _s3c_restart + 1 )) ;;
      norange)
        # Nothing written yet: take the whole object through get (verified,
        # into a temp file), then write it. Only a store that ignores Range
        # ever gets here.
        s3_log "cat $1: the store ignores Range; downloading the whole object before writing it"
        _s3c_f=; s3_mktemp _s3c_f "$_s3c_dir"
        S3_PARALLEL=1
        _s3c_r=0; cmd_get "$1" "$_s3c_f" || _s3c_r=$?
        [ "$_s3c_r" -eq 0 ] || return "$_s3c_r"
        cat "$_s3c_f" || { s3_log "cat $1: writing to stdout failed"; return 1; }
        return 0 ;;
      *) [ -n "$S3_CAT_LOGGED" ] || s3_log "cat $1: $S3_WHY"; return "$(s3_class_rc)" ;;
    esac
  done
  s3_log "cat $1: $S3_CAT_SIZE bytes, $S3_VERIFIED, $(( $(s3_now) - _s3c_t0 ))s"
}

s3_copy_once() {
  _s3_rc=0
  s3_curl "$S3_BODY" "$S3_HDR" --request PUT \
    --header "x-amz-copy-source: $S3_COPY_SRC" \
    --header 'x-amz-content-sha256: UNSIGNED-PAYLOAD' \
    "$S3_URL" || _s3_rc=$?
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
  # Each side's MD5 as get would check it (metadata, else a plain-MD5 ETag);
  # a store may give the copy a fresh ETag, so compare only what both have.
  if [ -n "$S3_SRC_MD5" ] && [ -n "$S3_HEAD_MD5" ]; then
    if [ "$S3_HEAD_MD5" != "$S3_SRC_MD5" ]; then
      S3_CLASS=integrity; S3_WHY="copy has MD5 $S3_HEAD_MD5, source $S3_SRC_MD5"; return 0
    fi
    S3_VERIFIED="size and MD5 verified"
  else
    S3_VERIFIED="size verified (ETags '$S3_SRC_ETAG' / '$S3_HEAD_ETAG': no MD5 on both sides)"
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
  S3_SRC_SIZE=$S3_HEAD_SIZE; S3_SRC_ETAG=$S3_HEAD_ETAG; S3_SRC_MD5=$S3_HEAD_MD5
  s3_split "$2"
  _s3_r=0; s3_run "copy $1 -> $2" s3_copy_once || _s3_r=$?
  if [ "$_s3_r" -eq 3 ]; then s3_log "copy $1 -> $2: store answered 404"; return 1; fi
  [ "$_s3_r" -eq 0 ] || return "$_s3_r"
  s3_log "copy $1 -> $2: $S3_SRC_SIZE bytes, $S3_VERIFIED"
}

s3_rm_once() {
  _s3_rc=0
  s3_curl "$S3_BODY" "$S3_HDR" --request DELETE "$S3_URL" || _s3_rc=$?
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

s3_ls_once() {
  _s3_rc=0
  s3_curl "$S3_BODY" "$S3_HDR" "$S3_BKT_URL?$S3_QUERY" || _s3_rc=$?
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
    _s3_token=$(s3_xml_field "$S3_BODY" NextContinuationToken)
    [ -n "$_s3_token" ] || s3_die 1 "ls: truncated listing without a continuation token"
  done
}

# GetBucketLocation, as S3 clients bootstrap it: path-style, signed for
# us-east-1, which every region answers. The answer's LocationConstraint is the
# region ("" is us-east-1, "EU" eu-west-1). A store that refuses the lookup
# itself (AccessDenied, a wrong-region AuthorizationHeaderMalformed or
# InvalidRegion, NotImplemented) is read as minio-go reads it: the <Region> its
# error names, else us-east-1. Sets S3_LOCATION; returns an exit code.
s3_location_once() {
  _s3_rc=0
  s3_curl "$S3_LOC_BODY" "$S3_LOC_HDR" "$S3_BASE/$S3_LOC_BUCKET?location=" || _s3_rc=$?
  _s3_st=$(s3_status "$S3_LOC_HDR")
  s3_classify "$_s3_rc" "$_s3_st" "$S3_LOC_BODY"
  S3_LOC_FROM_ERROR=
  case "$S3_CLASS:$(s3_error_code "$S3_LOC_BODY")" in
    auth:AccessDenied|fatal:AuthorizationHeaderMalformed|fatal:InvalidRegion|fatal:NotImplemented)
      S3_CLASS=ok; S3_LOC_FROM_ERROR=1 ;;
  esac
}

s3_bucket_location() { # $1 = bucket
  S3_LOC_BUCKET=$1
  _s3_lreg=$S3_REGION; S3_REGION=us-east-1
  _s3_lr=0; s3_run "location $1" s3_location_once || _s3_lr=$?
  S3_REGION=$_s3_lreg
  if [ "$_s3_lr" -eq 3 ]; then s3_log "location: bucket '$1' does not exist"; return 1; fi
  [ "$_s3_lr" -eq 0 ] || return "$_s3_lr"
  if [ -n "$S3_LOC_FROM_ERROR" ]; then
    S3_LOCATION=$(s3_xml_field "$S3_LOC_BODY" Region)
  else
    S3_LOCATION=$(s3_xml_field "$S3_LOC_BODY" LocationConstraint)
  fi
  case "$S3_LOCATION" in '') S3_LOCATION=us-east-1 ;; EU) S3_LOCATION=eu-west-1 ;; esac
}

cmd_location() {
  [ $# -eq 1 ] || s3_usage
  case "$1" in ''|*/*|*[!a-z0-9.-]*) s3_die 2 "location takes BUCKET (got '$1')" ;; esac
  s3_mktemp S3_LOC_HDR "${TMPDIR:-/tmp}"; s3_mktemp S3_LOC_BODY "${TMPDIR:-/tmp}"
  _s3_r=0; s3_bucket_location "$1" || _s3_r=$?
  [ "$_s3_r" -eq 0 ] || return "$_s3_r"
  printf '%s\n' "$S3_LOCATION"
}

# SigV4 query-string presigning (the `mc share download` replacement). It
# signs S3_SIGN_HOST: the Host header a client sends for the printed URL.
# S3_PRESIGN_DATE (YYYYMMDDTHHMMSSZ) pins the clock for tests.
s3_presign_url() { # $1 = method, $2 = canonical path (encoded), $3 = expiry seconds
  _s3_amzdate=${S3_PRESIGN_DATE:-$(date -u +%Y%m%dT%H%M%SZ)}
  _s3_day=${_s3_amzdate%%T*}
  _s3_scope="$_s3_day/$S3_REGION/s3/aws4_request"
  _s3_q="X-Amz-Algorithm=AWS4-HMAC-SHA256"
  _s3_q="$_s3_q&X-Amz-Credential=$(s3_uriencode "$MINIO_ACCESS_KEY/$_s3_scope")"
  _s3_q="$_s3_q&X-Amz-Date=$_s3_amzdate&X-Amz-Expires=$3&X-Amz-SignedHeaders=host"
  _s3_creq=$(printf '%s\n%s\n%s\nhost:%s\n\nhost\nUNSIGNED-PAYLOAD' "$1" "$2" "$_s3_q" "$S3_SIGN_HOST")
  _s3_sts=$(printf 'AWS4-HMAC-SHA256\n%s\n%s\n%s' "$_s3_amzdate" "$_s3_scope" \
    "$(printf '%s' "$_s3_creq" | s3_sha256_hex)")
  _s3_key=$(printf 'AWS4%s' "$MINIO_SECRET_KEY" | s3_hexbytes | tr -d '\n')
  _s3_key=$(printf '%s' "$_s3_day" | s3_hmac "$_s3_key")
  _s3_key=$(printf '%s' "$S3_REGION" | s3_hmac "$_s3_key")
  _s3_key=$(printf 's3' | s3_hmac "$_s3_key")
  _s3_key=$(printf 'aws4_request' | s3_hmac "$_s3_key")
  _s3_sig=$(printf '%s' "$_s3_sts" | s3_hmac "$_s3_key")
  printf '%s://%s%s?%s&X-Amz-Signature=%s\n' "$S3_SCHEME" "$S3_SIGN_HOST" "$2" "$_s3_q" "$_s3_sig"
}

cmd_presign() {
  { [ $# -ge 1 ] && [ $# -le 2 ]; } || s3_usage
  _s3_exp=${2:-604800}
  case "$_s3_exp" in ''|*[!0-9]*) s3_die 2 "presign: expiry must be seconds" ;; esac
  { [ "$_s3_exp" -ge 1 ] && [ "$_s3_exp" -le 604800 ]; } || s3_die 2 "presign: expiry must be 1..604800 seconds (SigV4 maximum)"
  s3_split "$1"
  s3_presign_url GET "$S3_SIGN_PATH" "$_s3_exp"
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
  put|get|stat|copy|cat|ls|rm|presign|location) ;;
  -h|--help|help) s3_usage ;;
  *) s3_log "unknown command '$_s3_verb'"; s3_usage ;;
esac
# presign signs locally, unless S3_REGION=auto has to ask the store.
if [ "$_s3_verb" != presign ] || [ "$S3_REGION" = auto ]; then s3_check_curl; fi
s3_config
if [ "$S3_OP_TIMEOUT" -gt 0 ]; then S3_DEADLINE=$(( $(s3_now) + S3_OP_TIMEOUT )); fi
_s3_rc=0
"cmd_$_s3_verb" "$@" || _s3_rc=$?
exit "$_s3_rc"
