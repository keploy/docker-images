#!/usr/bin/env bash
# shellcheck disable=SC2016 # each case is a script for the container's bash, quoted whole
# Tests for start-docker, each case in a fresh privileged container of IMAGE
# with this checkout's start-docker. CI builds the keploy-ci image of the
# commit and runs them on it (docker-build.yml); by default, the published
# base:
#
#   bash keploy-ci/start-docker-test.sh [IMAGE]
#
# Stand-ins (shims first on PATH) make containerd slow, dead or silent, and
# dockerd slow or wedged in its init, as a starved host does.
set -u
IMAGE="${1:-ghcr.io/keploy/keploy-ci:1.2.40}"
HERE="$(cd "$(dirname "$0")" && pwd)"
failures=0

# run CASE SCRIPT: runs SCRIPT (bash) in a fresh container; its output is in
# $out and its status in $rc.
# A case that hangs is ended after CASE_GUARD seconds (900 by default; a hang
# guard, so that a start that blocks fails its case instead of the job): rc
# is then 124, and its container is removed. The container runs detached and
# is waited for (docker wait), the wait under the guard. A guard around
# `docker run` would signal only the client, which hands the signal on to the
# container's PID 1, a bash that does not die of it, and waits on.
# A container is known by the id docker run gave it, never by its name, and
# is removed with its volume (the image's /var/lib/docker); the one running is
# removed too when the run ends otherwise (EXIT, INT, TERM). The wait runs in
# the background and is waited for with the wait builtin, which a trapped
# signal interrupts at once (a command substitution would hold it until the
# case ended).
cid=""
WAITED=$(mktemp)
drop() {
  [ -z "$cid" ] || docker rm -f -v "$cid" >/dev/null 2>&1 || true
  cid=""
}
trap 'drop; rm -f "$WAITED"' EXIT
trap 'drop; trap - INT; kill -INT $$' INT
trap 'drop; exit 143' TERM
run() {
  name="start-docker-test-$1-$$"
  if ! cid=$(docker run -d --privileged --name "$name" \
    -v "$HERE/start-docker:/usr/local/bin/start-docker:ro" \
    "$IMAGE" bash -c "$2"); then
    out="the case's container did not start: $cid" rc=125 cid=""
    return
  fi
  timeout -k 10 "${CASE_GUARD:-900}" docker wait "$cid" >"$WAITED" 2>&1 &
  wait $!
  w=$?
  rc=$(cat "$WAITED")
  out=$(docker logs "$cid" 2>&1)
  case $w in
    0) ;;
    124 | 137) out="$out
the case guard (${CASE_GUARD:-900} s) ended it" rc=124 ;;
    *) out="$out
docker wait failed ($w): $rc" rc=125 ;;
  esac
  drop
}
pass() { echo "ok   - $1"; }
# fail prints the case's last 40 lines that are not a daemon's own (level=)
# lines, which would bury what start-docker said.
fail() { echo "FAIL - $1"; echo "$out" | grep -v 'level=' | tail -n 40 | sed 's/^/    /'; failures=$((failures + 1)); }

# A containerd that loads for N seconds, a line a second, as a starved one
# loads its plugins, before it is the real one.
slow_shim='mkdir -p /opt/shim && cat >/opt/shim/containerd <<"EOF"
#!/bin/sh
for i in $(seq 1 "${SLOW:-20}"); do echo "loading plugin $i (slow host)"; sleep 1; done
exec /usr/bin/containerd "$@"
EOF
chmod +x /opt/shim/containerd'

# The guard itself: a case that hangs is ended, and its container removed.
CASE_GUARD=5 run "guard" 'sleep 600'
if [ "$rc" = 124 ] && ! docker container inspect "start-docker-test-guard-$$" >/dev/null 2>&1; then
  pass "the case guard ends a case that hangs, and removes its container"
else fail "the case guard ends a case that hangs, and removes its container (rc=$rc)"; fi

# Settings that are not whole numbers, 1 or more, and DOCKERD_FLAGS that move
# what start-docker fixes (its root, socket and pidfile), are refused (2),
# before anything is started.
run "settings" 'for s in START_DOCKER_SILENCE_CHECKS=0 START_DOCKER_PROBE_SECONDS=x START_DOCKER_NOTICE_LOOKS=-1 DOCKERD_FLAGS=--data-root=/x "DOCKERD_FLAGS=--debug -H tcp://0.0.0.0:2375" DOCKERD_FLAGS=-Htcp://0.0.0.0:2375 "DOCKERD_FLAGS=-DH tcp://0.0.0.0:2375" DOCKERD_FLAGS=-p/x.pid DOCKERD_FLAGS=--config-file=/x.json; do
  env "$s" start-docker; echo "$s: rc=$?"
done
mkdir -p /etc/docker && printf "{\"data-root\": \"/x\"}\n" >/etc/docker/daemon.json && start-docker; echo "daemon.json: rc=$?"; rm -f /etc/docker/daemon.json
DOCKERD_FLAGS="-ldebug -spool --dns 1.1.1.1" START_DOCKER_SILENCE_CHECKS=1 start-docker >/tmp/fine.out 2>&1; grep -q "sets" /tmp/fine.out && echo "a fine flag refused"
pgrep -x containerd >/dev/null && echo "a start began" || echo "nothing started"; pkill -9 -x dockerd; pkill -9 -x containerd; true'
if grep -q "START_DOCKER_SILENCE_CHECKS=0: rc=2" <<<"$out" && grep -q "START_DOCKER_PROBE_SECONDS=x: rc=2" <<<"$out" \
  && grep -q "START_DOCKER_NOTICE_LOOKS=-1: rc=2" <<<"$out" && grep -q "whole numbers, 1 or more" <<<"$out" \
  && grep -q "DOCKERD_FLAGS=--data-root=/x: rc=2" <<<"$out" && grep -q "DOCKERD_FLAGS sets --data-root, which start-docker fixes" <<<"$out" \
  && grep -q "DOCKERD_FLAGS=--debug -H tcp://0.0.0.0:2375: rc=2" <<<"$out" && grep -q "DOCKERD_FLAGS=-Htcp://0.0.0.0:2375: rc=2" <<<"$out" \
  && grep -q "DOCKERD_FLAGS=-DH tcp://0.0.0.0:2375: rc=2" <<<"$out" && grep -q "DOCKERD_FLAGS=-p/x.pid: rc=2" <<<"$out" \
  && grep -q "DOCKERD_FLAGS=--config-file=/x.json: rc=2" <<<"$out" && grep -q "daemon.json: rc=2" <<<"$out" \
  && grep -q "/etc/docker/daemon.json sets \"data-root\"" <<<"$out" && ! grep -q "a fine flag refused" <<<"$out"; then
  pass "settings that are not whole numbers, 1 or more, and DOCKERD_FLAGS that move what start-docker fixes, are refused before anything starts"
else fail "settings that are not whole numbers, 1 or more, and DOCKERD_FLAGS that move what start-docker fixes, are refused before anything starts"; fi

# Started, it builds and runs a container: an image of the static tini the
# engine ships (/usr/libexec/docker/docker-init), so nothing is pulled.
# DOCKERD_FLAGS reach dockerd (the lanes' registry mirror), containerd and
# its watcher each lead a session of their own, and containerd logs at
# dockerd's level (--debug).
run "starts" 'set -o pipefail; DOCKERD_FLAGS="--registry-mirror=http://127.0.0.1:5999 --debug" start-docker | tee /tmp/start.out && docker info --format "{{.ServerVersion}}" && pgrep -a dockerd &&
docker info --format "mirrors {{.RegistryConfig.Mirrors}}" &&
c=$(pidof containerd) && [ "$(ps -o sid= -p "$c" | tr -d " ")" = "$c" ] && echo "containerd leads its own session" &&
w=$(sed -n "s/.*its watcher (\([0-9]*\)).*/\1/p" /tmp/start.out) && [ -n "$w" ] && [ "$(ps -o sid= -p "$w" | tr -d " ")" = "$w" ] && echo "the watcher leads its own session" &&
grep -q "level=debug" /var/log/containerd.log && echo "containerd logs at debug" &&
mkdir -p /tmp/img && cp /usr/libexec/docker/docker-init /tmp/img/tini &&
printf "FROM scratch\nCOPY tini /tini\nENTRYPOINT [\"/tini\", \"--version\"]\n" >/tmp/img/Dockerfile &&
docker build -q -t start-docker-test /tmp/img >/dev/null && docker run --rm start-docker-test'
if [ "$rc" = 0 ] && grep -q -- '--containerd=/var/run/docker/containerd/containerd.sock' <<<"$out" && grep -q "tini version" <<<"$out" \
  && grep -q "mirrors.*127.0.0.1:5999" <<<"$out" && grep -q "containerd leads its own session" <<<"$out" \
  && grep -q "the watcher leads its own session" <<<"$out" && grep -q "containerd logs at debug" <<<"$out"; then
  pass "it starts containerd (in its own session, at dockerd's --debug, with a watcher in a session of its own) and then dockerd on it with DOCKERD_FLAGS, returns once docker answers, and builds and runs a container"
else fail "it starts containerd (in its own session, at dockerd's --debug, with a watcher in a session of its own) and then dockerd on it with DOCKERD_FLAGS, returns once docker answers, and builds and runs a container"; fi

run "already" 'DOCKER_HOST=tcp://127.0.0.1:1 DOCKERD_FLAGS=--log-level=debug start-docker >/dev/null && grep -q "level=debug" /var/log/containerd.log && echo "containerd logs at debug" && start-docker'
if [ "$rc" = 0 ] && grep -q "dockerd ([0-9]*) is already running; waiting for it to answer" <<<"$out" && grep -q "Docker daemon is ready" <<<"$out" \
  && grep -q "containerd logs at debug" <<<"$out"; then
  pass "a second start finds the daemon running (and containerd logs at dockerd's --log-level)"
else fail "a second start finds the daemon running (and containerd logs at dockerd's --log-level)"; fi

# The failure it fixes: dockerd starting its own containerd gives it 15 s.
run "managed" "$slow_shim"'
PATH=/opt/shim:$PATH dockerd >/var/log/d.log 2>&1 &
d=$!; until grep -q "timeout waiting for containerd" /var/log/d.log || docker info >/dev/null 2>&1 || ! kill -0 "$d" 2>/dev/null; do sleep 1; done
cat /var/log/d.log | grep -E "timeout waiting for containerd|API listen" | head -3'
if grep -q "timeout waiting for containerd to start" <<<"$out"; then
  pass "(the failure fixed) dockerd quits when the containerd it starts takes over 15 s"
else fail "(the failure fixed) dockerd quits when the containerd it starts takes over 15 s"; fi

# Slow and logging: waited for on its progress, with 60 looks of silence
# allowed (more than a real daemon here keeps silent, 15 s on a starved
# runner) and 75 s of loading, so it is the growing log that keeps the wait
# going.
run "slow" "$slow_shim"'
SLOW=75 PATH=/opt/shim:$PATH START_DOCKER_SILENCE_CHECKS=60 start-docker && docker info --format "{{.ServerVersion}}"'
if [ "$rc" = 0 ] && grep -q "Docker daemon is ready" <<<"$out"; then
  pass "a containerd that takes 75 s, logging as it loads, is waited for on its progress past 60 looks"
else fail "a containerd that takes 75 s, logging as it loads, is waited for on its progress past 60 looks"; fi

# Slow and silent, as containerd sat in its bolt store's open (11931):
# waited for while within its silence checks.
run "slow-silent" 'mkdir -p /opt/shim && printf "#!/bin/sh\nsleep 20\nexec /usr/bin/containerd \"\$@\"\n" >/opt/shim/containerd && chmod +x /opt/shim/containerd
PATH=/opt/shim:$PATH START_DOCKER_SILENCE_CHECKS=60 start-docker'
if [ "$rc" = 0 ] && grep -q "Docker daemon is ready" <<<"$out"; then
  pass "a containerd silent for 20 s, then up, is waited for within its silence checks"
else fail "a containerd silent for 20 s, then up, is waited for within its silence checks"; fi

run "dies" 'mkdir -p /opt/shim && printf "#!/bin/sh\necho cannot start; exit 1\n" >/opt/shim/containerd && chmod +x /opt/shim/containerd
PATH=/opt/shim:$PATH START_DOCKER_SILENCE_CHECKS=30 start-docker'
if [ "$rc" = 1 ] && grep -q "containerd exited before it answered" <<<"$out" && grep -q "cannot start" <<<"$out"; then
  pass "a containerd that exits fails the start at once, with its log"
else fail "a containerd that exits fails the start at once, with its log"; fi

run "silent" 'mkdir -p /opt/shim && printf "#!/bin/sh\nexec sleep 1000000\n" >/opt/shim/containerd && chmod +x /opt/shim/containerd
PATH=/opt/shim:$PATH START_DOCKER_SILENCE_CHECKS=3 start-docker'
if [ "$rc" = 1 ] && grep -q "containerd has not answered, and its log has not grown in 3 looks" <<<"$out"; then
  pass "a containerd that neither answers nor logs fails the start after its silence checks"
else fail "a containerd that neither answers nor logs fails the start after its silence checks"; fi

# A start that fails runs under a subreaper that reaps nothing (python3,
# PR_SET_CHILD_SUBREAPER): whatever it leaves, running or a zombie, is then
# the subreaper's child, and is listed.
reaper='mkdir -p /opt && cat >/opt/reaper.py <<"PY"
import ctypes, os, subprocess, sys
if ctypes.CDLL(None, use_errno=True).prctl(36, 1, 0, 0, 0) != 0:
    sys.exit("prctl(PR_SET_CHILD_SUBREAPER): errno %d: nothing left behind could be seen" % ctypes.get_errno())
print("first rc=%d" % subprocess.run(sys.argv[1:]).returncode, flush=True)
left = []
for p in filter(str.isdigit, os.listdir("/proc")):
    try:
        f = dict(l.split(":", 1) for l in open("/proc/%s/status" % p).read().splitlines() if ":" in l)
    except OSError:
        continue
    if f["PPid"].strip() == str(os.getpid()):
        left.append("%s %s (%s)" % (p, f["Name"].strip(), f["State"].strip()))
print("left by the failed start: %s" % (", ".join(left) or "nothing"), flush=True)
PY'

# A dockerd that fails: said at once, what the start began is stopped and
# reaped, and the next start begins clean, with one containerd, both logs
# appended to.
run "dockerd-fails" "$reaper"'
DOCKERD_FLAGS="--no-such-flag -l debug" python3 /opt/reaper.py start-docker
grep -q "level=debug" /var/log/containerd.log && echo "containerd logs at debug (-l debug)"
start-docker && echo "containerds: $(pgrep -cx containerd)"
echo "containerd starts in its log: $(grep -c "starting containerd" /var/log/containerd.log)"
grep -q "no-such-flag" /var/log/dockerd.log && echo "the failed dockerd is still in its log"'
if grep -q "first rc=1" <<<"$out" && grep -q "dockerd exited before it answered" <<<"$out" && grep -q "left by the failed start: nothing" <<<"$out" \
  && grep -q "Docker daemon is ready" <<<"$out" && grep -q "containerds: 1" <<<"$out" \
  && grep -q "containerd starts in its log: 2" <<<"$out" && grep -q "the failed dockerd is still in its log" <<<"$out" \
  && grep -q "containerd logs at debug (-l debug)" <<<"$out"; then
  pass "a dockerd that exits fails the start at once, what the start began is stopped and reaped, and the next start begins clean, its logs appended to"
else fail "a dockerd that exits fails the start at once, what the start began is stopped and reaped, and the next start begins clean, its logs appended to"; fi

# A start that fails after its watcher started containerd again leaves
# nothing either: the watcher stops and reaps the containerd it started.
run "fails-after-a-restart" "$reaper"'
mkdir -p /opt/shim && cat >/opt/shim/dockerd <<"EOF"
#!/bin/sh
kill -9 "$(pidof containerd)"
until grep -q "exited; starting it again" /var/log/containerd.log; do sleep 0.1; done
echo "dockerd stand-in: containerd was started again; exiting"
exit 1
EOF
chmod +x /opt/shim/dockerd
DOCKERD_FLAGS="--log-level debug" PATH=/opt/shim:$PATH python3 /opt/reaper.py start-docker
grep -q "level=debug" /var/log/containerd.log && echo "containerd logs at debug (--log-level debug)"'
if grep -q "first rc=1" <<<"$out" && grep -q "containerd was started again; exiting" <<<"$out" && grep -q "left by the failed start: nothing" <<<"$out" \
  && grep -q "containerd logs at debug (--log-level debug)" <<<"$out"; then
  pass "a start that fails after containerd was started again leaves nothing: the watcher stops and reaps the containerd it started"
else fail "a start that fails after containerd was started again leaves nothing: the watcher stops and reaps the containerd it started"; fi

# dockerd listens before its init and answers after: a stand-in stops the
# real one once its socket is there, so its /_ping blocks, as on a slow
# init. Saying what it does (its log grows), it is waited for, a blocked
# probe being no answer that look (and one wedged, saying nothing, fails:
# dockerd-wedged, below, with a stand-in of its own).
dockerd_shim='mkdir -p /opt/shim && cat >/opt/shim/dockerd <<"EOF"
#!/bin/sh
/usr/bin/dockerd "$@" & d=$!
until [ -S /var/run/docker.sock ]; do sleep 0.05; done
kill -STOP $d
if [ -n "${PROGRESS:-}" ]; then
  for i in $(seq 1 "${STEPS:-15}"); do echo "init step $i"; sleep 1; done
  kill -CONT $d
fi
wait $d
EOF
chmod +x /opt/shim/dockerd'
run "dockerd-slow-init" "$dockerd_shim"'
PROGRESS=1 STEPS=75 PATH=/opt/shim:$PATH START_DOCKER_SILENCE_CHECKS=60 start-docker'
if [ "$rc" = 0 ] && grep -q "Docker daemon is ready" <<<"$out"; then
  pass "a dockerd whose init is slow but says what it does is waited for, its blocked probes no answer, not the end"
else fail "a dockerd whose init is slow but says what it does is waited for, its blocked probes no answer, not the end"; fi
# Wedged, it is given 4 looks of silence. containerd answers before the
# start (one no pidfile names: taken after one bounded look, not waited on),
# so the 4 looks are dockerd's alone, none spent on a containerd starting.
# The wedged dockerd is a stand-in that listens on dockerd's socket, as
# dockerd does before its init, and never answers nor logs: the real one,
# stopped once its socket is there, could finish its init first on a
# starved host.
wedged_shim='mkdir -p /opt/shim && cat >/opt/shim/dockerd <<"EOF"
#!/usr/bin/python3
import os, socket, time
s = socket.socket(socket.AF_UNIX)
s.bind("/var/run/docker.sock.tmp")
s.listen()
os.rename("/var/run/docker.sock.tmp", "/var/run/docker.sock")
while True:
    time.sleep(3600)
EOF
chmod +x /opt/shim/dockerd'
run "dockerd-wedged" "$wedged_shim"'
mkdir -p /var/lib/docker/containerd/daemon /var/run/docker/containerd
containerd --root /var/lib/docker/containerd/daemon --state /var/run/docker/containerd/daemon --address /var/run/docker/containerd/containerd.sock >/var/log/own-containerd.log 2>&1 & c=$!
until ctr --address /var/run/docker/containerd/containerd.sock version >/dev/null 2>&1 || ! kill -0 "$c" 2>/dev/null; do sleep 0.1; done
PATH=/opt/shim:$PATH START_DOCKER_SILENCE_CHECKS=4 START_DOCKER_NOTICE_LOOKS=2 START_DOCKER_PROBE_SECONDS=60 start-docker'
if [ "$rc" = 1 ] && grep -q "containerd already answers on /var/run/docker/containerd/containerd.sock (no pidfile names it" <<<"$out" \
  && grep -q "dockerd has not answered, and its log has not grown in 2 looks; still waiting" <<<"$out" \
  && grep -q "dockerd has not answered, and its log has not grown in 4 looks$" <<<"$out"; then
  pass "a dockerd wedged in its init, its probes blocked and its log still, is said to stall as it goes on, and fails the start, said"
else fail "a dockerd wedged in its init, its probes blocked and its log still, is said to stall as it goes on, and fails the start, said"; fi

# A probe that takes long is waited for, not cut: dockerd's socket reached
# through a relay that holds each connection 8 s before it passes it on (as
# a starved host answers late), with 60 looks of silence allowed and the
# bound on one-shot probes at 2 s. The 8 s are the probe's own, within
# curl's transfer: a bound on it (timeout, or curl's --max-time) cuts it.
run "slow-probe" 'mkdir -p /opt/shim && cat >/opt/relay.py <<"PY"
import socket, threading, time
def pump(a, b):
    try:
        while True:
            x = a.recv(65536)
            if not x:
                break
            b.sendall(x)
    except OSError:
        pass
    for s in (a, b):
        try:
            s.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
def relay(c):
    time.sleep(8)
    d = socket.socket(socket.AF_UNIX)
    try:
        d.connect("/var/run/docker.sock")
    except OSError:
        c.close()
        return
    threading.Thread(target=pump, args=(d, c), daemon=True).start()
    pump(c, d)
l = socket.socket(socket.AF_UNIX)
l.bind("/tmp/slow.sock")
l.listen(64)
while True:
    threading.Thread(target=relay, args=(l.accept()[0],), daemon=True).start()
PY
cat >/opt/shim/curl <<"EOF"
#!/bin/sh
for a; do shift; [ "$a" != /var/run/docker.sock ] || a=/tmp/slow.sock; set -- "$@" "$a"; done
exec /usr/bin/curl "$@"
EOF
chmod +x /opt/shim/curl
python3 /opt/relay.py & until [ -S /tmp/slow.sock ]; do sleep 0.05; done
PATH=/opt/shim:$PATH START_DOCKER_SILENCE_CHECKS=60 START_DOCKER_PROBE_SECONDS=2 start-docker'
if [ "$rc" = 0 ] && grep -q "Docker daemon is ready" <<<"$out"; then
  pass "a probe that takes 8 s to answer is waited for, not cut short, and its answer taken"
else fail "a probe that takes 8 s to answer is waited for, not cut short, and its answer taken"; fi

# A socket no pidfile names, dockerd's or containerd's, gets one look,
# bounded (START_DOCKER_PROBE_SECONDS). One that refuses (nothing listens: a
# daemon gone without removing it) is taken over: the start goes on, and its
# own daemon binds the socket. The bound is the dial's: clients that take 3 s
# to start (a starved host's), against a bound of 2, do not make a socket
# that refuses look mute. One that listens and does not answer (a daemon
# start-docker knows nothing of, slow or wedged), or answers as no such
# daemon does, fails the start, said, and nothing is started over it.
# listen.py SOCK dead|mute|http404 binds SOCK and: listens on nothing (dead);
# listens and never accepts (mute); answers every request with a 404
# (http404). A listening socket is bound beside SOCK and renamed onto it once
# it listens: SOCK is never there unlistened, which start-docker would take
# for a dead one and take over.
listener='mkdir -p /opt /var/run/docker/containerd && cat >/opt/listen.py <<"PY"
import socket, sys, time
import os
s = socket.socket(socket.AF_UNIX)
if sys.argv[2] == "dead":
    s.bind(sys.argv[1])
    sys.exit(0)
s.bind(sys.argv[1] + ".tmp")
s.listen()
os.rename(sys.argv[1] + ".tmp", sys.argv[1])
if sys.argv[2] == "mute":
    time.sleep(600)
while True:
    c, _ = s.accept()
    c.recv(65536)
    c.sendall(b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
    c.close()
PY
CSOCK=/var/run/docker/containerd/containerd.sock
listen() { python3 /opt/listen.py "$1" "$2" & until [ -S "$1" ]; do sleep 0.05; done; }'
run "dead-socket" "$listener"'
listen /var/run/docker.sock dead; listen "$CSOCK" dead
mkdir -p /opt/shim && for c in curl docker ctr; do printf "#!/bin/sh\nsleep 3\nexec /usr/bin/$c \"\$@\"\n" >"/opt/shim/$c"; chmod +x "/opt/shim/$c"; done
PATH=/opt/shim:$PATH START_DOCKER_PROBE_SECONDS=2 start-docker'
if [ "$rc" = 0 ] && grep -q "Starting containerd" <<<"$out" && grep -q "Docker daemon is ready" <<<"$out"; then
  pass "sockets no pidfile names that refuse, dockerd's and containerd's, are taken over, clients slow to start notwithstanding, and the start goes on"
else fail "sockets no pidfile names that refuse, dockerd's and containerd's, are taken over, clients slow to start notwithstanding, and the start goes on"; fi
run "mute-socket" "$listener"'
listen /var/run/docker.sock mute; m=$!
START_DOCKER_PROBE_SECONDS=2 start-docker; echo "dockerd: rc=$?"
kill "$m"; wait "$m"; rm -f /var/run/docker.sock
listen "$CSOCK" mute
START_DOCKER_PROBE_SECONDS=2 start-docker; echo "containerd: rc=$?"
pgrep -x containerd >/dev/null || pgrep -x dockerd >/dev/null && echo "a daemon was started" || echo "nothing started"'
if grep -q "dockerd: rc=1" <<<"$out" && grep -q "listens on /var/run/docker.sock and did not answer in 2s: not starting a second dockerd over it" <<<"$out" \
  && grep -q "containerd: rc=1" <<<"$out" && grep -q "listens on /var/run/docker/containerd/containerd.sock and did not answer in 2s: not starting a second containerd over it" <<<"$out" \
  && grep -q "nothing started" <<<"$out"; then
  pass "sockets no pidfile names that listen and do not answer, dockerd's and containerd's, fail the start, said, and nothing is started over them"
else fail "sockets no pidfile names that listen and do not answer, dockerd's and containerd's, fail the start, said, and nothing is started over them"; fi
# Answering as no such daemon does: an HTTP server on either socket, and a
# containerd without its Version service (its gRPC answers, Unimplemented).
run "foreign-socket" "$listener"'
listen /var/run/docker.sock http404; m=$!
START_DOCKER_PROBE_SECONDS=2 start-docker; echo "dockerd: rc=$?"
kill "$m"; wait "$m"; rm -f /var/run/docker.sock
listen "$CSOCK" http404; m=$!
START_DOCKER_PROBE_SECONDS=2 start-docker; echo "containerd, http: rc=$?"
kill "$m"; wait "$m"; rm -f "$CSOCK"
printf "version = 2\ndisabled_plugins = [\"io.containerd.grpc.v1.version\", \"io.containerd.grpc.v1.cri\"]\n" >/tmp/no-version.toml
containerd --config /tmp/no-version.toml --root /tmp/croot --state /tmp/cstate --address "$CSOCK" >/tmp/c.log 2>&1 & c=$!
until curl -s -o /dev/null --http2-prior-knowledge --unix-socket "$CSOCK" http://containerd/ || ! kill -0 "$c" 2>/dev/null; do sleep 0.1; done
START_DOCKER_PROBE_SECONDS=2 start-docker; echo "containerd, no Version: rc=$?"
echo "containerds: $(pgrep -cx containerd)"; pgrep -x dockerd >/dev/null && echo "a dockerd was started" || echo "no dockerd started"'
if grep -q "dockerd: rc=1" <<<"$out" && grep -q "answers on /var/run/docker.sock, but not as dockerd does (curl's exit 22 on its /_ping, HTTP status 404): not starting a second dockerd over it" <<<"$out" \
  && grep -q "containerd, http: rc=1" <<<"$out" && grep -q "answers on /var/run/docker/containerd/containerd.sock, but not as containerd does (curl's exit [0-9]* on its Version call): not starting a second containerd over it" <<<"$out" \
  && grep -q "containerd, no Version: rc=1" <<<"$out" && grep -q "but not as containerd does (its Version call answered grpc-status: 12)" <<<"$out" \
  && grep -q "containerds: 1" <<<"$out" && grep -q "no dockerd started" <<<"$out"; then
  pass "sockets no pidfile names that answer as no such daemon does, dockerd's and containerd's, fail the start, said, and nothing is started over them"
else fail "sockets no pidfile names that answer as no such daemon does, dockerd's and containerd's, fail the start, said, and nothing is started over them"; fi
# A dockerd that answers and that no pidfile names (one a lane started some
# other way, or whose pidfiles are gone) is reused after one look: no second
# dockerd on the same socket. A ~/.curlrc that would change curl's request
# (HTTP/2, which dockerd's socket does not speak) changes neither start's.
run "unnamed-dockerd" 'echo --http2-prior-knowledge >/root/.curlrc &&
START_DOCKER_SILENCE_CHECKS=60 start-docker >/dev/null && rm -f /var/run/docker.pid /var/run/docker/start-docker-dockerd.pid &&
start-docker; echo "second rc=$?"; echo "dockerds: $(pgrep -cx dockerd)"'
if grep -q "Docker daemon already running" <<<"$out" && grep -q "second rc=0" <<<"$out" && grep -q "dockerds: 1" <<<"$out"; then
  pass "a dockerd that answers and that no pidfile names is reused after one look, and no second one is started"
else fail "a dockerd that answers and that no pidfile names is reused after one look, and no second one is started"; fi

# A start killed after it started dockerd, before dockerd wrote its own
# pidfile (dockerd slow to begin, as a starved one is; here held until the
# case lets it go, once the next start has looked): the next start finds it
# by the pid start-docker wrote, and waits for it.
run "killed-before-dockerd-pidfile" 'mkdir -p /opt/shim && printf "#!/bin/sh\nuntil [ -e /tmp/go ]; do sleep 0.05; done\nexec /usr/bin/dockerd \"\$@\"\n" >/opt/shim/dockerd && chmod +x /opt/shim/dockerd
PATH=/opt/shim:$PATH start-docker >/dev/null 2>&1 & first=$!
until [ -s /var/run/docker/start-docker-dockerd.pid ]; do sleep 0.05; done
kill -9 "$first"; wait "$first" 2>/dev/null
PATH=/opt/shim:$PATH start-docker >/tmp/second.out 2>&1 & second=$!
until grep -q "is already running; waiting for it to answer\|Starting dockerd" /tmp/second.out || ! kill -0 "$second" 2>/dev/null; do sleep 0.05; done
[ -s /var/run/docker.pid ] || echo "dockerd has written no pidfile yet"
touch /tmp/go
wait "$second"; echo "second rc=$?"; cat /tmp/second.out'
if grep -q "dockerd has written no pidfile yet" <<<"$out" && grep -q "dockerd ([0-9]*) is already running; waiting for it to answer" <<<"$out" \
  && grep -q "second rc=0" <<<"$out"; then
  pass "a start killed before dockerd wrote its pidfile leaves its pid: the next start waits for that dockerd"
else fail "a start killed before dockerd wrote its pidfile leaves its pid: the next start waits for that dockerd"; fi

# A watcher pidfile that names some other sh (a pid reused) is no watcher:
# the start gives its containerd one of its own.
run "stale-watcher-pidfile" 'mkdir -p /var/run/docker/containerd && { sh -c "sleep 600; :" & echo "$!" >/var/run/docker/containerd/watcher.pid; } && start-docker'
if [ "$rc" = 0 ] && grep -q "its watcher ([0-9]*) starts it again should it exit" <<<"$out"; then
  pass "a watcher pidfile that names another sh is no watcher: the start gives containerd its own"
else fail "a watcher pidfile that names another sh is no watcher: the start gives containerd its own"; fi

# A start while containerd's watcher is starting it again (held, here, by
# SIGSTOP, between containerd's death and its start) waits for the watcher,
# then reuses the containerd it starts: no second containerd on the root.
run "watcher-restarting" 'start-docker >/tmp/first.out && d=$(pidof dockerd) && kill "$d" && while kill -0 "$d" 2>/dev/null; do sleep 0.2; done &&
w=$(cat /var/run/docker/containerd/watcher.pid) && kill -STOP "$w" && kill -9 "$(pidof containerd)" && while pidof containerd >/dev/null; do sleep 0.1; done &&
{ start-docker >/tmp/second.out 2>&1 & s=$!; } &&
until grep -q "watcher ($w) is starting it again; waiting for it" /tmp/second.out; do sleep 0.1; done && kill -CONT "$w" &&
wait "$s"; echo "second rc=$?"; cat /tmp/second.out
echo "containerds: $(pgrep -cx containerd)"'
if grep -q "is starting it again; waiting for it" <<<"$out" && grep -q "second rc=0" <<<"$out" && grep -q "already answers on" <<<"$out" \
  && grep -q "containerds: 1" <<<"$out"; then
  pass "a start while containerd's watcher is starting it again waits for the watcher, and reuses what it starts"
else fail "a start while containerd's watcher is starting it again waits for the watcher, and reuses what it starts"; fi

# A second start while the first's containerd is still starting (a lock):
# it waits for the first, and then finds its dockerd, which it waits on
# until it answers (its pidfile). One containerd, one watcher, both ready.
run "starting-twice" "$slow_shim"'
PATH=/opt/shim:$PATH start-docker >/tmp/first.out 2>&1 & first=$!
until grep -q "loading plugin" /var/log/containerd.log 2>/dev/null; do sleep 0.05; done
PATH=/opt/shim:$PATH start-docker; echo "second rc=$?"
wait "$first"; echo "first rc=$?"; cat /tmp/first.out
echo "containerds: $(pgrep -cx containerd)"
echo "watchers: $(for p in /proc/[0-9]*; do tr "\0" "\n" <"$p/cmdline" 2>/dev/null | grep -qx start-docker-containerd-watcher && echo "$p"; done | wc -l)"'
if grep -q "another start-docker is running; waiting for it" <<<"$out" && grep -q "dockerd ([0-9]*) is already running; waiting for it to answer" <<<"$out" \
  && grep -q "second rc=0" <<<"$out" && grep -q "first rc=0" <<<"$out" && grep -q "containerds: 1" <<<"$out" && grep -q "watchers: 1" <<<"$out"; then
  pass "a start while another is still starting waits for it, then for its dockerd, and starts nothing twice"
else fail "a start while another is still starting waits for it, then for its dockerd, and starts nothing twice"; fi

# A start killed while its containerd or its dockerd is starting leaves them
# running: the next start waits for them (their pidfiles) until they answer,
# and starts no second one on the same root.
run "killed-in-containerd" "$slow_shim"'
PATH=/opt/shim:$PATH start-docker >/dev/null 2>&1 & first=$!
until grep -q "loading plugin" /var/log/containerd.log 2>/dev/null; do sleep 0.05; done
kill -9 "$first"; wait "$first" 2>/dev/null
PATH=/opt/shim:$PATH start-docker; echo "second rc=$?"
echo "containerds: $(pgrep -cx containerd)"'
if grep -q "containerd ([0-9]*) is already running; waiting for it to answer" <<<"$out" && grep -q "second rc=0" <<<"$out" \
  && grep -q "containerds: 1" <<<"$out" && grep -q "its watcher ([0-9]*) starts it again" <<<"$out"; then
  pass "a start after one killed while containerd was starting waits for that containerd, and gives it a watcher"
else fail "a start after one killed while containerd was starting waits for that containerd, and gives it a watcher"; fi
run "killed-in-dockerd" "$dockerd_shim"'
PROGRESS=1 PATH=/opt/shim:$PATH start-docker >/dev/null 2>&1 & first=$!
until [ -S /var/run/docker.sock ]; do sleep 0.05; done
kill -9 "$first"; wait "$first" 2>/dev/null
PATH=/opt/shim:$PATH start-docker; echo "second rc=$?"'
if grep -q "dockerd ([0-9]*) is already running; waiting for it to answer" <<<"$out" && grep -q "second rc=0" <<<"$out" \
  && grep -q "Docker daemon is ready" <<<"$out"; then
  pass "a start after one killed while dockerd was in its init waits for that dockerd until it answers"
else fail "a start after one killed while dockerd was in its init waits for that dockerd until it answers"; fi

# containerd killed under a running dockerd is started again, and said; then
# dockerd says it is back on it (at --debug, its event stream processed
# again: its containerd client is serving), and docker runs a container.
events='grep -c "msg=\"processing event stream\" module=libcontainerd namespace=moby$" /var/log/dockerd.log'
run "containerd-restarted" 'DOCKERD_FLAGS=--debug=1 start-docker >/dev/null && grep -q "level=debug" /var/log/containerd.log && echo "containerd logs at debug (--debug=1)" &&
mkdir -p /tmp/img && cp /usr/libexec/docker/docker-init /tmp/img/tini &&
printf "FROM scratch\nCOPY tini /tini\nENTRYPOINT [\"/tini\", \"--version\"]\n" >/tmp/img/Dockerfile &&
docker build -q -t t2 /tmp/img >/dev/null && n=$('"$events"') &&
kill -9 "$(pidof containerd)" &&
until grep -q "exited; starting it again" /var/log/containerd.log; do sleep 0.2; done && echo "containerd is started again" &&
until [ "$('"$events"')" -gt "$n" ]; do sleep 0.2; done && echo "dockerd is back on containerd" &&
docker run --rm t2'
if [ "$rc" = 0 ] && grep -q "containerd is started again" <<<"$out" && grep -q "dockerd is back on containerd" <<<"$out" && grep -q "tini version" <<<"$out" \
  && grep -q "containerd logs at debug (--debug=1)" <<<"$out"; then
  pass "a containerd that dies under dockerd is started again, said in its log, dockerd goes back on it, and docker runs a container"
else fail "a containerd that dies under dockerd is started again, said in its log, dockerd goes back on it, and docker runs a container"; fi

# A start after dockerd stopped reuses the containerd that answers, and
# appends to dockerd's log. containerd is at info by default.
run "rerun" 'start-docker >/dev/null && head -n 1 /var/log/dockerd.log >/tmp/first-line && d=$(pidof dockerd) && kill "$d" && while kill -0 "$d" 2>/dev/null; do sleep 0.2; done &&
start-docker && echo "containerds: $(pgrep -cx containerd)"
echo "watchers: $(for p in /proc/[0-9]*; do tr "\0" "\n" <"$p/cmdline" 2>/dev/null | grep -qx start-docker-containerd-watcher && echo "$p"; done | wc -l)"
[ "$(head -n 1 /var/log/dockerd.log)" = "$(cat /tmp/first-line)" ] && echo "the first dockerd is still in its log"
grep -q "level=debug" /var/log/containerd.log || echo "containerd logs at info"'
if grep -q "containerd ([0-9]*) already answers on" <<<"$out" && grep -q "containerds: 1" <<<"$out" && grep -q "watchers: 1" <<<"$out" \
  && grep -q "the first dockerd is still in its log" <<<"$out" && grep -q "containerd logs at info" <<<"$out"; then
  pass "a start after dockerd stopped reuses the containerd that answers and its watcher, starts no second of either, and appends to dockerd's log"
else fail "a start after dockerd stopped reuses the containerd that answers and its watcher, starts no second of either, and appends to dockerd's log"; fi

if [ "$failures" -gt 0 ]; then echo "$failures failure(s)"; exit 1; fi
echo "all start-docker cases pass"
