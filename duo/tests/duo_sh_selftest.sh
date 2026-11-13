#!/bin/bash
# Dry run of duo/duo.sh on ONE Mac with stand-ins: no model, no second Mac, no real ssh.
#
# It builds a scratch folder with
#   - a stand-in `ssh` (first on PATH for this test only) that runs the "remote" command on this Mac under zsh, with
#     another HOME: the "other Mac". It ignores -L, so the test's settings give the tunnel's two ends the same port.
#   - a stand-in engine named strata_ds4 (a shell script: prints the lines duo.sh waits for, then sleeps)
#   - a stand-in Strata control folder whose serve.server starts the stand-in engine from serve.json and answers
#     /v1/models and /v1/chat/completions with the API key
#   - real certificates (duo/gen_certs.sh) and tiny fake packs, in folders whose names hold spaces and an apostrophe
# and then runs the REAL duo.sh and the REAL gate through: doctor, start, a request, status, up (already loaded),
# restart, down + a request (the gate loads again), bench, stop, ensure, launchagent, and the same start / request /
# stop with LOCAL_ROLE=suffix.
#
# What it proves: the script's own logic (settings, quoting, the lock, the key's way to the other host, the prepared
# start scripts, the stop patterns, the gate's calls). What it cannot prove: anything about real ssh sessions, macOS's
# local-network rules, the tunnel, or the engines. About 2 minutes.
#
#   duo_sh_selftest.sh
# environment: DUO_SELFTEST_DIR (the scratch folder; default: a new temporary folder, removed at the end),
#   DUO_SELFTEST_PORTS="GATE BACKEND LINK" (default "8092 8093 50176"; BACKEND+1 is used too: the stand-in ssh port)
set -u   # (no pipefail: the checks below read `... | grep -q`, which may close the pipe on a writer)
. "$(dirname "$0")/env.sh"
S=${DUO_SELFTEST_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/duo-sh-selftest.XXXXXX")}
# shellcheck disable=SC2086
set -- ${DUO_SELFTEST_PORTS:-8092 8093 50176}
GP=$1; BP=$2; LP=$3; SSHP=$((BP + 1))
[ -x "$OPENSSL" ] || { echo "no OpenSSL 3 at $OPENSSL (run duo/build.sh, or set DUO_TEST_OPENSSL)" >&2; exit 1; }
mkdir -p "$S" && S=$(cd "$S" && pwd)
DUO="$ROOT/duo/duo.sh"
L="$S/this mac/it's here"                # LOCAL_DIR
PH="$S/peer home"                        # the other Mac's HOME
PD="$PH/peer dir/o'brien"                # PEER_DIR (written ~/peer dir/o'brien in the settings)
CTL="$PH/control dir"
fails=0
ok() { printf 'PASS  %s\n' "$1"; }
bad() { fails=$((fails + 1)); printf 'FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/      /' | tail -15; }
expect() { if eval "$2"; then ok "$1"; else bad "$1" "${3:-}"; fi; }

# ---- the stand-ins
mkdir -p "$S/bin" "$L/build-duo" "$L/duo/certs" "$PD/build-duo" "$PD/duo/certs" "$CTL/serve" "$S/models"
cat > "$S/bin/ssh" <<EOF
#!/bin/bash
# stand-in ssh: options are skipped, the command runs here under zsh with the "other Mac's" HOME
host=""; cmd=""; g=0
while [ \$# -gt 0 ]; do
  case "\$1" in
    -o|-L|-i|-p) shift ;;
    -G) g=1 ;;
    -*) ;;
    *) if [ -z "\$host" ]; then host=\$1; else cmd="\$cmd\${cmd:+ }\$1"; fi ;;
  esac
  shift
done
if [ "\$g" = 1 ]; then printf 'hostname 127.0.0.1\nport $SSHP\n'; exit 0; fi
[ "\$host" = "unreachable" ] && { echo "ssh: connect to host unreachable: Operation timed out" >&2; exit 255; }
export HOME=$(printf '%q' "$PH")
[ -n "\$cmd" ] || exit 0
/bin/zsh -c "\$cmd" <&0 &
child=\$!
trap 'kill \$child 2>/dev/null' TERM HUP INT
wait \$child
EOF
chmod +x "$S/bin/ssh"
cat > "$L/build-duo/strata_ds4" <<'EOF'
#!/bin/bash
# stand-in engine: no model. Prints the lines duo.sh waits for, then sleeps until it is stopped.
case " $* " in *" --version "*) echo "strata-dsv41 0.0.0-selftest build standin"; exit 0 ;; esac
pack=""; listen=""; connect=""; certs=""
while [ $# -gt 0 ]; do
  case "$1" in --pack) pack=$2; shift ;; --duo-listen) listen=$2; shift ;; --duo-connect) connect=$2; shift ;; --duo-certs) certs=$2; shift ;; esac
  shift
done
[ -f "$certs/ca.crt" ] || { echo "maya-ds4: duo: --duo-certs: $certs/ca.crt: No such file or directory" >&2; exit 2; }
echo "ds4 duo: link mode TLS 1.3, mutual authentication (stand-in engine)" >&2
[ -n "$pack" ] || { echo "maya-ds4 --pack <model> (stand-in usage)" >&2; exit 2; }
[ -f "$pack/ds4.txt" ] || { echo "maya-ds4: $pack/ds4.txt: not found" >&2; exit 1; }
if [ -n "$listen" ]; then echo "ds4 duo: prefix host, layers [0, 20); waiting on $listen for the suffix host" >&2
else echo "ds4 duo: link up, TLSv1.3 (stand-in)" >&2; echo "ds4 duo: suffix host, layers [20, 40) + head; prefix host $connect holds [0, 20)" >&2; fi
sleep 3600 &
trap 'kill $! 2>/dev/null; exit 0' TERM HUP INT
wait
EOF
chmod +x "$L/build-duo/strata_ds4"; cp "$L/build-duo/strata_ds4" "$PD/build-duo/strata_ds4"
: > "$CTL/serve/__init__.py"
cat > "$CTL/serve/server.py" <<'EOF'
"""Stand-in for Strata's serve.server: starts the engine named in --config and answers two paths with the API key."""
import argparse, json, os, signal, subprocess, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ap = argparse.ArgumentParser()
ap.add_argument("--engine"); ap.add_argument("--config"); ap.add_argument("--host"); ap.add_argument("--port", type=int)
a = ap.parse_args()
cfg = json.load(open(a.config))
log = open(cfg["log"], "a")
child = subprocess.Popen([cfg["exe"]] + cfg["args"], stdout=log, stderr=log, stdin=subprocess.DEVNULL)
KEY = os.environ.get("STRATA_API_KEY", "")


def stop(*_):
    child.terminate()
    os._exit(0)


signal.signal(signal.SIGTERM, stop)
signal.signal(signal.SIGHUP, stop)


class H(BaseHTTPRequestHandler):
    def log_message(self, *x):
        pass

    def out(self, code, obj):
        b = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def do_any(self):
        n = int(self.headers.get("Content-Length") or 0)
        body = json.loads(self.rfile.read(n)) if n else {}
        if not KEY or self.headers.get("Authorization") != "Bearer " + KEY:
            return self.out(401, {"error": "wrong key"})
        if self.path == "/v1/models":
            if self.headers.get("X-Selftest-Slow"):
                import time
                time.sleep(3)
            return self.out(200, {"object": "list", "data": [{"id": cfg["model_name"], "object": "model", "owned_by": "standin"}]})
        if self.path == "/v1/chat/completions":
            return self.out(200, {"choices": [{"message": {"role": "assistant", "content": "stand-in answer; slots in " + os.environ.get("STRATA_DS4_SLOT_DIR", "?")}}],
                                  "usage": {"prompt_tokens": 5, "completion_tokens": int(body.get("max_tokens", 7))}})
        self.out(404, {"error": "no such path"})

    do_GET = do_POST = do_any


ThreadingHTTPServer((a.host, a.port), H).serve_forever()
EOF
# certificates (real ones) and packs (fake: the files a pack names, a few bytes each)
OPENSSL="$OPENSSL" DAYS=7 bash "$ROOT/duo/gen_certs.sh" "$S/gen" > /dev/null || { echo "gen_certs.sh failed" >&2; exit 1; }
cp -p "$S/gen/prefix/"* "$L/duo/certs/"; cp -p "$S/gen/suffix/"* "$PD/duo/certs/"
mkpack() {   # PACK_DIR MODEL_DIR
  mkdir -p "$1/tokenizer" "$2"
  printf 'vocab_size 10\nformat gguf\nmodel_dir %s\n' "$2" > "$1/ds4.txt"
  printf 'file 0 shard-00001-of-00002.gguf\nfile 1 shard-00002-of-00002.gguf\nfile 2 engram.gguf\nt x BF16 0 0 4 2\n' > "$1/tensors.txt"
  echo '{}' > "$1/tokenizer/vocab.json"; echo engram > "$1/engram.bin"
  for f in shard-00001-of-00002.gguf shard-00002-of-00002.gguf engram.gguf; do printf 'fake %s\n' "$f" > "$2/$f"; done
}
mkpack "$L/packs/model x" "$S/models/this mac"
mkpack "$PD/packs/model x" "$PH/models"
conf() {   # ROLE: the settings file for this Mac in that role
  {
    printf 'PEER=%q\nLOCAL_ROLE=%q\n' "peer" "$1"
    # (paths of the other Mac in double quotes, as duo.conf.example has them: the ~ must reach the other Mac unexpanded)
    printf 'LOCAL_DIR=%q\nPEER_DIR="%s"\n' "$L" "~/peer dir/o'brien"
    printf 'MODEL=x\nLOCAL_PACK=%q\nPEER_PACK="%s"\n' "$L/packs/model x" "~/peer dir/o'brien/packs/model x"
    if [ "$1" = prefix ]; then printf 'SUFFIX_CONTROL_DIR="%s"\n' "~/control dir"; else printf 'SUFFIX_CONTROL_DIR=%q\n' "$CTL"; fi
    printf 'SUFFIX_PYTHON=/usr/bin/python3\nIDLE_MIN=0\nAPIPORT=%s\nBACKPORT=%s\nSERVER_PORT=%s\nPORT=%s\n' "$GP" "$BP" "$BP" "$LP"
    printf 'LINK_LOCAL_IP=127.0.0.1\nLINK_PEER_IP=127.0.0.1\nMIN_FREE_GB=1\nBUSY_PATTERNS=("no_such_job_%s")\n' "$$"
  } > "$S/duo.conf"
}
export PATH="$S/bin:$PATH" DUO_CONF="$S/duo.conf"
RUN="$L/duo/run"
/usr/bin/python3 -c "import socket,time; s=socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(('127.0.0.1', $SSHP)); s.listen(5); time.sleep(600)" &
LISTENER=$!
cleanup() {
  bash "$DUO" stop > /dev/null 2>&1
  kill $LISTENER 2>/dev/null; wait $LISTENER 2>/dev/null
  pkill -f "$S" 2>/dev/null
  return 0
}
key_hidden() {   # the key is in no process's arguments (the snapshot is compared inside the shell: no grep process holds it)
  local snap; snap=$(ps -ww -axo command=)
  [ -n "$KEYV" ] || return 1
  case "$snap" in *"$KEYV"*) return 1 ;; esac
  return 0
}
trap cleanup EXIT
ask() {   # a chat request through the gate; the key comes from a 600 header file, as in duo.sh
  curl -s -m 120 -H "@$RUN/api_auth.hdr" -H 'Content-Type: application/json' \
    -d '{"model":"deepseek-v4.1-flash","max_tokens":9,"messages":[{"role":"user","content":"hi"}]}' "http://127.0.0.1:$GP/v1/chat/completions"
}
running() { pgrep -f "$S" | while read -r p; do ps -ww -o command= -p "$p"; done; }

# ---- LOCAL_ROLE=prefix (the measured layout)
conf prefix
echo "== doctor (stand-in engine, real certificates)"
out=$(bash "$DUO" doctor 2>&1); rc=$?
printf '%s\n' "$out" | grep -E "^(FAIL|WARN)|RESULT" | cut -c1-200
expect "doctor: every check passes on the stand-in pair" '[ "$rc" = 0 ] && ! printf "%s\n" "$out" | grep -q "^FAIL"' "$out"
expect "doctor: certificate roles, chain and key permissions checked on both hosts" '[ "$(printf "%s\n" "$out" | grep -cE "^PASS  (this|other) Mac: (certificate role|certificate chain|key permissions)")" = 6 ]' "$out"
expect "doctor: the pair's comparisons ran" '[ "$(printf "%s\n" "$out" | grep -cE "^PASS  (same engine build|same CA|same model files|same pack|link addresses)")" = 5 ]' "$out"
expect "doctor: the link line names both addresses and the interface" 'printf "%s\n" "$out" | grep -qE "^PASS  link addresses: this Mac [0-9.]+ <-> other Mac [0-9.]+ on [^ ]+"' "$out"
expect "doctor: wrote nothing" '[ ! -e "$RUN" ]'
chmod 644 "$L/duo/certs/strata-stage-worker.key"; cp "$PD/duo/certs/strata-stage-coordinator.key" "$L/duo/certs/"
echo "x" >> "$PH/models/engram.gguf"
out=$(bash "$DUO" doctor 2>&1); rc=$?
expect "doctor: a 644 key, a foreign key and a model file of another size are reported" '[ "$rc" = 1 ] && printf "%s\n" "$out" | grep -q "^FAIL  this Mac: key permissions" && printf "%s\n" "$out" | grep -q "^WARN  this Mac: foreign key" && printf "%s\n" "$out" | grep -q "^FAIL  same model files"' "$out"
chmod 600 "$L/duo/certs/strata-stage-worker.key"; rm "$L/duo/certs/strata-stage-coordinator.key"; printf 'fake engram.gguf\n' > "$PH/models/engram.gguf"

echo "== start"
out=$(bash "$DUO" start 2>&1); rc=$?
printf '%s\n' "$out" | cut -c1-160
expect "start: exit 0 and the pair answers" '[ "$rc" = 0 ] && ask | grep -q "stand-in answer"' "$out"
KEYV=$(cat "$RUN/api_key" 2>/dev/null)
expect "the key and its header file are mode 600" '[ "$(stat -f %Lp "$RUN/api_key")" = 600 ] && [ "$(stat -f %Lp "$RUN/api_auth.hdr")" = 600 ] && [ "$(stat -f %Lp "$PD/duo/run/api_key")" = 600 ]'
expect "the key is in no process's arguments" 'key_hidden'
# Observe ps WHILE curl carries the authorization header, not only after it has exited.
curl -s -m 10 -H "@$RUN/api_auth.hdr" -H 'X-Selftest-Slow: 1' "http://127.0.0.1:$BP/v1/models" > "$S/slow_curl.out" &
cpid=$!
sleep .5
expect "curl is running and the API key is absent from every argv" 'kill -0 "$cpid" 2>/dev/null && key_hidden'
wait "$cpid"
expect "prefix engine here, server and suffix engine on the other host, held by one ssh session" 'running | grep -q "strata_ds4 --pack .*this mac.*--duo-listen 127.0.0.1:$LP --duo-allow 127.0.0.1" && running | grep -q "serve.server --engine strata --config .*peer home.*serve.json" && running | grep -q "strata_ds4 --pack .*peer home.*--duo-connect 127.0.0.1:$LP" && running | grep -q "ssh .*-L $BP:127.0.0.1:$BP peer exec bash .*start_server.sh"' "$(running)"
expect "kept conversations: a folder for this model on the suffix host" 'ask | grep -q "peer dir/o.brien/duo/run/slots-x"' "$(ask)"
expect "the gate was given the busy patterns in a file" 'grep -q "no_such_job" "$RUN/busy_patterns" && ! running | grep "duo_gate.py" | grep -q no_such_job'
out=$(bash "$DUO" status 2>&1)
expect "status: gate loaded, both hosts listed" 'printf "%s\n" "$out" | grep -q "\"loaded\": true" && printf "%s\n" "$out" | grep -q "other Mac" && [ "$(printf "%s\n" "$out" | grep -c strata_ds4)" -ge 2 ]' "$out"
out=$(bash "$DUO" up 2>&1)
expect "up while loaded: already loaded" '[ "$out" = "already loaded" ]' "$out"
# A stopped process still has a live PID; a slow HTTP probe is never permission for ensure to kill it.
gatepid=$(pgrep -f "duo_gate.py --listen $GP " | while read -r p; do ps -ww -o command= -p "$p" | grep -F -q -- "$RUN" && echo "$p"; done)
kill -STOP "$gatepid"
out=$(bash "$DUO" ensure 2>&1)
expect "ensure never kills a merely slow gate" 'kill -0 "$gatepid" 2>/dev/null && printf "%s" "$out" | grep -q "leaving it alone"' "$out"
kill -CONT "$gatepid"
# A wrong auth header: the server answers 401, which says nothing against the pair; both engines must survive a direct up.
cp "$RUN/api_auth.hdr" "$S/auth.saved"
printf 'Authorization: Bearer selftest-wrong\n' > "$RUN/api_auth.hdr"
touch -t 203001010000 "$RUN/api_auth.hdr"
out=$(bash "$DUO" up 2>&1); rc=$?
expect "up with a key the server refuses never tears down an alive engine" '[ "$rc" = 1 ] && printf "%s" "$out" | grep -q "the pair is left alone" && running | grep -q "strata_ds4 .*--duo-listen"' "$out"
mv "$S/auth.saved" "$RUN/api_auth.hdr"
out=$(ROUNDS=1 LABEL=selftest bash "$DUO" bench 2>&1)
expect "bench: one round through the gate, one line in run/bench.jsonl" 'printf "%s\n" "$out" | grep -q "overall: " && [ "$(wc -l < "$RUN/bench.jsonl" | tr -d " ")" = 1 ]' "$out"
out=$(bash "$DUO" restart 2>&1); rc=$?
expect "restart: loaded again" '[ "$rc" = 0 ] && ask | grep -q "stand-in answer"' "$out"
out=$(bash "$DUO" down 2>&1)
expect "down: engines, server and session gone, the gate stays" '[ "$out" = unloaded ] && ! running | grep -q -E "strata_ds4|serve.server|start_server" && running | grep -q duo_gate.py' "$(running)"
expect "a request after down: the gate loads the pair again (it calls duo.sh up)" 'ask | grep -q "stand-in answer" && running | grep -q "strata_ds4 .*--duo-listen"' "$(tail -5 "$RUN/gate.log")"
/usr/bin/python3 - "$RUN/.duo_starting.lock" <<'LOCKTEST' &
import fcntl,sys,time
with open(sys.argv[1], 'a') as f:
    fcntl.flock(f, fcntl.LOCK_EX)
    print('lock held', flush=True)
    time.sleep(4)
LOCKTEST
locker=$!
sleep 1
before=$(date +%s)
out=$(bash "$DUO" up 2>&1)
wait "$locker"
expect "a live load lock is not stolen: up waits then probes" '[ "$out" = "already loaded" ] && [ $(( $(date +%s) - before )) -ge 2 ]' "$out"
# The lock file can stay forever: an unlocked inode is not a live load.
bash "$DUO" down > /dev/null 2>&1
out=$(bash "$DUO" up 2>&1); rc=$?
expect "an unlocked persistent lock file does not block a load" '[ "$rc" = 0 ] && ask | grep -q "stand-in answer"' "$out"
out=$(bash "$DUO" stop 2>&1)
expect "stop: nothing of the pair is left, not wanted" '[ "$out" = stopped ] && ! running | grep -q -E "strata_ds4|serve.server|duo_gate|start_server" && [ ! -e "$RUN/.duo_wanted" ]' "$(running)"
bash "$DUO" ensure > /dev/null 2>&1
expect "ensure when not wanted: does nothing" '! running | grep -q duo_gate.py'
touch "$RUN/.duo_wanted"; bash "$DUO" ensure > /dev/null 2>&1
expect "ensure when wanted: the gate is back, nothing is loaded" 'running | grep -q duo_gate.py && ! running | grep -q strata_ds4'
bash "$DUO" stop > /dev/null 2>&1
out=$(bash "$DUO" launchagent 2>&1)
expect "launchagent: a valid plist naming this duo.sh and settings file" 'printf "%s\n" "$out" | plutil -lint - > /dev/null && printf "%s\n" "$out" | grep -q "duo.sh</string><string>ensure" && printf "%s\n" "$out" | grep -q "it.s here/duo/run/agent.log"' "$out"

# ---- LOCAL_ROLE=suffix
conf suffix
rm -rf "$L/duo/certs" "$PD/duo/certs"; mkdir -p "$L/duo/certs" "$PD/duo/certs"
cp -p "$S/gen/suffix/"* "$L/duo/certs/"; cp -p "$S/gen/prefix/"* "$PD/duo/certs/"
echo "== LOCAL_ROLE=suffix: doctor, start, stop"
out=$(bash "$DUO" doctor 2>&1); rc=$?
expect "suffix layout: doctor passes" '[ "$rc" = 0 ]' "$out"
out=$(bash "$DUO" start 2>&1); rc=$?
printf '%s\n' "$out" | cut -c1-160
expect "suffix layout: start, and the pair answers" '[ "$rc" = 0 ] && ask | grep -q "stand-in answer"' "$out"
expect "suffix layout: prefix engine on the other host under an ssh session, server and suffix engine here" 'running | grep -q "strata_ds4 --pack .*peer home.*--duo-listen 127.0.0.1:$LP" && running | grep -q "ssh .*peer exec bash .*start_prefix.sh" && running | grep -q "serve.server --engine strata --config .*this mac.*serve.json" && running | grep -q "strata_ds4 --pack .*this mac.*--duo-connect"' "$(running)"
KEYV=$(cat "$RUN/api_key" 2>/dev/null)
expect "suffix layout: the key is in no process's arguments" 'key_hidden'
out=$(bash "$DUO" stop 2>&1)
expect "suffix layout: stop leaves nothing" '! running | grep -q -E "strata_ds4|serve.server|duo_gate|start_prefix"' "$(running)"

# ---- an unreachable peer
sed -i '' 's/^PEER=.*/PEER=unreachable/' "$S/duo.conf"
out=$(bash "$DUO" up 2>&1); rc=$?
expect "up with an unreachable peer: fails with a message, nothing left running" '[ "$rc" = 1 ] && [ -n "$out" ] && ! running | grep -q strata_ds4 && [ ! -d "$RUN/.duo_starting" ]' "$out"

trap - EXIT; cleanup
sleep 1
left=$(pgrep -f "$S" | tr '\n' ' ')
expect "nothing of the test is left running" '[ -z "$left" ]' "$left"
for p in $GP $BP $SSHP; do lsof -nP -iTCP:"$p" -sTCP:LISTEN -t > /dev/null 2>&1 && bad "port $p is still in use"; done
[ -n "${DUO_SELFTEST_DIR:-}" ] || rm -rf "$S"
if [ "$fails" = 0 ]; then echo "RESULT: all checks passed"; else echo "RESULT: $fails failed"; exit 1; fi
