# Mutants of start-docker: each must fail start-docker-test.sh. Run from the repo root.
import subprocess, sys, tempfile, shutil, os, concurrent.futures as cf
src = open('keploy-ci/start-docker').read()
IMAGE = sys.argv[1] if len(sys.argv) > 1 else 'ghcr.io/keploy/keploy-ci:1.2.40'
M = {
 'the probe in await bounded': [('      "$@" >/dev/null 2>&1 9>&- &\n      pp=$!', '      timeout "$PROBE_SECONDS" "$@" >/dev/null 2>&1 9>&- &\n      pp=$!')],
 'progress ignored': [('    if [ "$size" != "$last" ]; then\n      last=$size quiet=0\n    else\n      quiet=$((quiet + 1))\n    fi', '    quiet=$((quiet + 1))')],
 'dockerd waited on containerd\'s pid': [('if ! await dockerd "$dockerd_pid"', 'if ! await dockerd "${containerd_pid:-$dockerd_pid}"')],
 'DOCKERD_FLAGS dropped': [('dockerd --containerd="$CONTAINERD_SOCK" ${FLAGS}', 'dockerd --containerd="$CONTAINERD_SOCK"')],
 'containerd not restarted': [('      while alive "$pid"; do sleep 1; done\n      echo "start-docker: containerd', '      while :; do sleep 1; done\n      echo "start-docker: containerd')],
 'containerd in the caller\'s session': [('  setsid containerd --config', '  containerd --config')],
 'no lock': [('exec 9>"$LOCK"\nif ! flock -n 9; then', 'exec 9>"$LOCK"\nif false; then')],
 'dockerd holds the lock': [('${FLAGS} >>"$DOCKERD_LOG" 2>&1 9>&- &', '${FLAGS} >>"$DOCKERD_LOG" 2>&1 &')],
 'a failed start keeps what it started': [('      kill -9 "$p" 2>/dev/null || true\n', '      :\n')],
 'logs truncated': [('>>"$CONTAINERD_LOG" 2>&1 9>&- &\n  containerd_pid=$!', '>"$CONTAINERD_LOG" 2>&1 9>&- &\n  containerd_pid=$!'), ('${FLAGS} >>"$DOCKERD_LOG" 2>&1 9>&- &', '${FLAGS} >"$DOCKERD_LOG" 2>&1 9>&- &')],
 'the watcher in the caller\'s session': [("  setsid sh -c '\n    pid=$1", "  sh -c '\n    pid=$1")],
 'no debug level': [('level=$(log_level)', 'level=info')],
 'dockerd\'s --log-level ignored': [('      --log-level=* | -l=*) _level=${1#*=} ;;\n', '')],
 'containerd always at debug': [('level=$(log_level)', 'level=debug')],
 'no stall notice': [('    if [ "$quiet" -gt 0 ] && [ $((quiet % NOTICE)) = 0 ]; then', '    if false; then')],
 'a failed start does not reap': [('    wait "$p" 2>/dev/null || true\n  done\n  exit 1', '  done\n  exit 1')],
 'the watcher killed, not stopped': [('      kill -TERM "$p" 2>/dev/null || true', '      kill -9 "$p" 2>/dev/null || true')],
 'the watcher leaves its containerd': [('    trap "kill -9 \\$! 2>/dev/null; wait; exit 0" TERM\n', '')],
 'Go bool spellings of --debug ignored': [('          1 | t | T | true | TRUE | True) _debug=1 ;;', '          true) _debug=1 ;;')],
 'the settings not checked': [("    '' | *[!0-9]* | 0*) echo", "    '') echo")],
 '-l VALUE ignored': [('      --log-level | -l) [ "$#" -lt 2 ] || { _level=$2; shift; } ;;\n', '')],
 'a dockerd left by an earlier start not waited for': [('if [ -n "$old" ]; then\n  echo "dockerd ($old) is already running', 'if false; then\n  echo "dockerd ($old) is already running')],
 'a containerd left by an earlier start not reused': [('if containerd_pid=$(pidfile_names "$CONTAINERD_PIDFILE" containerd); then', 'if false; then')],
 'a second watcher': [('if [ -n "$containerd_pid" ] && ! { [ -s "$WATCHER_PIDFILE" ] && is_watcher "$(cat "$WATCHER_PIDFILE")"; }; then', 'if [ -n "$containerd_pid" ]; then')],
 'no dockerd pid recorded': [('echo "$dockerd_pid" >"$DOCKERD_STARTED"\n', '')],
 'the watcher known by comm sh': [('  alive "$1" && grep -qxz start-docker-containerd-watcher "/proc/$1/cmdline" 2>/dev/null', '  named "$1" sh')],
 'a restarting containerd not waited for': [('if [ -n "$w" ] && is_watcher "$w" && ! containerd_named; then', 'if false; then')],
 'daemon.json not checked': [('if [ -f /etc/docker/daemon.json ] && grep', 'if false && grep')],
 'fixed flags not refused': [('      fixed DOCKERD_FLAGS "${f%%=*}"\n', '      :\n')],
 'run-together short flags not read': [('          H | p | g) fixed DOCKERD_FLAGS "-$c" ;;', '          :) ;;')],
 "dockerd's one look unbounded": [('--unix-socket "$2" --max-time "$PROBE_SECONDS" http://docker/_ping', '--unix-socket "$2" http://docker/_ping')],
 "containerd's one look unbounded": [('--unix-socket "$2" --max-time "$PROBE_SECONDS" \\\n', '--unix-socket "$2" \\\n')],
 "dockerd's one look by docker info": [('''    _code=$(curl -q -sf -o /dev/null -w '%{http_code}' --unix-socket "$2" --max-time "$PROBE_SECONDS" http://docker/_ping 9>&-) || _rc=$?''', '    timeout "$PROBE_SECONDS" docker -H "unix://$2" info >/dev/null 2>&1 9>&- || _rc=$?; [ "$_rc" != 124 ] || _rc=28; [ "$_rc" = 0 ] || [ "$_rc" = 28 ] || _rc=7')],
 "containerd's one look by ctr": [('    _hdr=$(printf', '    timeout "$PROBE_SECONDS" ctr --address "$2" version >/dev/null 2>&1 9>&- || _rc=$?; [ "$_rc" != 124 ] || _rc=28; [ "$_rc" = 0 ] || [ "$_rc" = 28 ] || _rc=7\n    _hdr=$(true || printf'), ('    if [ "$_rc" = 0 ]; then\n      printf', '    if false; then\n      printf')],
 'a refusing socket not taken over': [('    7) return 1 ;;', '    7) ;;')],
 'a mute unknown socket taken over': [('    28) echo "start-docker: something no pidfile names listens on', '    28) return 1; echo "start-docker: something no pidfile names listens on')],
 'a foreign socket taken over': [('    *) echo "start-docker: something no pidfile names answers on', '    *) return 1; echo "start-docker: something no pidfile names answers on')],
 'any gRPC answer taken for containerd': [("      printf '%s\\n' \"$_hdr\" | grep -q '^grpc-status: 0[[:space:]]*$' && return 0", '      return 0')],
 "the waits cut at curl's --max-time": [('if ! await dockerd "$dockerd_pid" "$DOCKERD_LOG" curl -q -sf -o /dev/null --unix-socket', 'if ! await dockerd "$dockerd_pid" "$DOCKERD_LOG" curl -q -sf -o /dev/null --max-time "$PROBE_SECONDS" --unix-socket')],
 '-s VALUE read as flags': [('          l | G | b | e | s) break ;;', '          l | G | b | e) break ;;')],
 "dockerd's one look at the wrong path": [('--max-time "$PROBE_SECONDS" http://docker/_ping 9>&-)', '--max-time "$PROBE_SECONDS" http://docker/_pingX 9>&-)')],
 "a ~/.curlrc read by the waits": [('  if ! await dockerd "$old" "$DOCKERD_LOG" curl -q -sf', '  if ! await dockerd "$old" "$DOCKERD_LOG" curl -sf'), ('if ! await dockerd "$dockerd_pid" "$DOCKERD_LOG" curl -q -sf', 'if ! await dockerd "$dockerd_pid" "$DOCKERD_LOG" curl -sf')],
 "a ~/.curlrc read by dockerd's one look": [("_code=$(curl -q -sf -o /dev/null -w", "_code=$(curl -sf -o /dev/null -w")],
}
only = sys.argv[2:]
def run(name):
    w = src
    for a, b in M[name]:
        if w.count(a) != 1:
            return 'NOAPPLY %s: %r x%d' % (name, a[:60], w.count(a))
        w = w.replace(a, b)
    d = tempfile.mkdtemp(dir='/var/tmp', prefix='sdmut-')
    shutil.copytree('keploy-ci', os.path.join(d, 'keploy-ci'))
    open(os.path.join(d, 'keploy-ci/start-docker'), 'w').write(w)
    r = subprocess.run(['bash', os.path.join(d, 'keploy-ci/start-docker-test.sh'), IMAGE], capture_output=True, text=True, env=dict(os.environ, CASE_GUARD='300'))
    fails = [l[7:90] for l in r.stdout.splitlines() if l.startswith('FAIL - ')]
    shutil.rmtree(d)
    return ('killed  ' if r.returncode else 'ALIVE   ') + name + (': ' + ' | '.join(fails[:2]) if fails else '')
names = [n for n in M if not only or n in only]
with cf.ThreadPoolExecutor(int(os.environ.get('J', '3'))) as ex:
    for res in ex.map(run, names):
        print(res, flush=True)
