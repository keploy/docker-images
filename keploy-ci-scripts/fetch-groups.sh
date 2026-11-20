#!/bin/sh
# fetch-groups.sh OUT NAME PKG... [-- NAME PKG...]...
#
# For each group, in order: the .apk files `apk add PKG...` would install or
# upgrade at that point (on top of the image and of the groups before it),
# saved to OUT/NAME/, then installed from those files alone, exactly as a step
# installs them (apk add --no-network --repositories-file /dev/null
# /opt/apk/NAME/*.apk). So the build fails here when a group cannot install
# from its files, or when installing it reads the network, and never in the
# step.
#
# Run in a throwaway build stage: the installs are only there so that each
# group resolves against the ones before it.
set -eu
out=$1
shift
while [ $# -gt 0 ]; do
  name=$1
  shift
  pkgs=
  while [ $# -gt 0 ] && [ "$1" != -- ]; do
    pkgs="$pkgs $1"
    shift
  done
  [ $# -eq 0 ] || shift
  [ -n "$pkgs" ] || { echo "fetch-groups: group $name names no package" >&2; exit 1; }
  # shellcheck disable=SC2086 # one word per package
  sim=$(apk add --simulate --no-cache $pkgs)
  names=$(printf '%s\n' "$sim" | sed -En 's/^\([0-9]+\/[0-9]+\) (Installing|Upgrading) ([^ ]+) \(.*/\2/p')
  [ -n "$names" ] || { printf 'fetch-groups: apk add%s would install nothing:\n%s\n' "$pkgs" "$sim" >&2; exit 1; }
  mkdir -p "$out/$name"
  # shellcheck disable=SC2086
  apk fetch --no-cache -o "$out/$name" $names
  # The step's command. With no repository named, apk resolves the files
  # against the installed packages alone and fetches no index: with only
  # --no-network --no-cache, apk 2.14 still fetched the main and community
  # APKINDEX. A "fetch http" line in its output fails the build.
  log=$(apk add --no-network --repositories-file /dev/null "$out/$name"/*.apk 2>&1) || {
    printf '%s\n' "$log" >&2
    echo "fetch-groups: group $name does not install from its files alone" >&2
    exit 1
  }
  printf '%s\n' "$log"
  if printf '%s\n' "$log" | grep -F 'fetch http' >&2; then
    echo "fetch-groups: installing group $name from its files read the network" >&2
    exit 1
  fi
  for p in $pkgs; do
    apk info -e "$p" >/dev/null || { echo "fetch-groups: $p is not installed after group $name" >&2; exit 1; }
  done
  # shellcheck disable=SC2086 # one word per package
  echo "fetch-groups: $name:$(printf ' %s' $names)"
done
