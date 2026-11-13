#!/bin/bash
# Strata Duo: one DeepSeek V4.1 Flash model split by layers over two Apple Silicon Macs, served as an
# OpenAI-compatible API on this Mac's 127.0.0.1:APIPORT.  See docs/DUO.md.
#
#   prefix host: layers 0-19 and the Engram rows                       (strata_ds4 --duo-listen)
#   suffix host: layers 20-39, the head, sampling, Strata's API server (serve.server + strata_ds4 --duo-connect)
#
# This script runs on ONE of the two Macs ("this Mac"); the other is PEER, reached over ssh. Which role this Mac has
# is LOCAL_ROLE in duo.conf. Clients talk to the gate (duo_gate.py) on 127.0.0.1:APIPORT of this Mac. The gate loads
# the pair when a request comes and unloads it after IDLE_MIN idle minutes.
#
# usage: duo.sh start | stop | restart | status | bench | ensure | up | down | doctor | launchagent
#   start        the service on: the gate, and the pair loaded now        (also sets run/.duo_wanted)
#   stop         the service off: gate and pair, nothing loads by itself  (also clears run/.duo_wanted)
#   restart      the pair unloaded and loaded again (new settings; IDLE_MIN and BUSY_PATTERNS need stop + start)
#   up / down    load / unload the pair only (what the gate calls)
#   ensure       what the LaunchAgent runs at login and every two minutes: the gate back up when wanted
#   status       the gate, the engines and the memory of both Macs
#   bench        ROUNDS (5) requests of 400 tokens through the gate; one JSON line each in run/bench.jsonl
#   doctor       read-only checks of both Macs with PASS / FAIL lines and a fix for each failure
#   launchagent  print a LaunchAgent plist for `ensure` (install: see docs/DUO.md)
# settings: duo.conf beside this script (or DUO_CONF=/path/to/conf); see duo.conf.example
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
SELF="$HERE/$(basename "$0")"
CONF=${DUO_CONF:-"$HERE/duo.conf"}
VERB=${1:-status}

# ---------------------------------------------------------------------------------------------- settings
PEER=""; LOCAL_ROLE=""; LOCAL_DIR=""; PEER_DIR=""; BUILD=""; LOCAL_BUILD=""; PEER_BUILD=""
LOCAL_CERTS=""; PEER_CERTS=""; LOCAL_PACK=""; PEER_PACK=""; LOCAL_RUN=""; PEER_RUN=""
SUFFIX_CONTROL_DIR=""; SUFFIX_PYTHON=""; SLOT_DIR=""; MODEL_ID=""; LINK_PREFIX=""; LINK_LOCAL_IP=""; LINK_PEER_IP=""
GATE_PYTHON=""; BUSY_MAX_S=""; MIN_FREE_GB=""; SERVER_PORT=""; LAUNCHD_LABEL=""
BUSY_PATTERNS=(); SSH_OPTS=()
CONF_FOUND=0
if [ -f "$CONF" ]; then
  CONF_FOUND=1
  # shellcheck disable=SC1090
  . "$CONF"
fi
MODEL=${MODEL:-default}
VX1=${VX1:-0.85}; VX2=${VX2:-0.90}; IDLE_MIN=${IDLE_MIN:-30}; CTX=${CTX:-65536}
PORT=${PORT:-50090}; APIPORT=${APIPORT:-8080}; BACKPORT=${BACKPORT:-8081}; CUT=${CUT:-20}
SERVER_PORT=${SERVER_PORT:-$APIPORT}
LOCAL_ROLE=${LOCAL_ROLE:-prefix}
LOCAL_DIR=${LOCAL_DIR:-$(dirname "$HERE")}
BUILD=${BUILD:-build-duo}
MODEL_ID=${MODEL_ID:-deepseek-v4.1-flash}
LINK_PREFIX=${LINK_PREFIX:-169.254.}
GATE_PYTHON=${GATE_PYTHON:-/usr/bin/python3}
BUSY_MAX_S=${BUSY_MAX_S:-2400}
MIN_FREE_GB=${MIN_FREE_GB:-20}
LAUNCHD_LABEL=${LAUNCHD_LABEL:-local.strata-duo.ensure}

untilde() {   # a leading ~/ of a path of THIS Mac
  case "$1" in "~") printf '%s' "$HOME" ;; "~/"*) printf '%s/%s' "$HOME" "${1#\~/}" ;; *) printf '%s' "$1" ;; esac
}
under() {   # DIR SUB: SUB when it is absolute (or starts with ~), else DIR/SUB
  case "$2" in /*|"~"*) printf '%s' "$2" ;; *) printf '%s/%s' "$1" "$2" ;; esac
}
LOCAL_DIR=$(untilde "$LOCAL_DIR")
LOCAL_BUILD=$(untilde "${LOCAL_BUILD:-$(under "$LOCAL_DIR" "$BUILD")}")
LOCAL_CERTS=$(untilde "${LOCAL_CERTS:-$LOCAL_DIR/duo/certs}")
LOCAL_RUN=$(untilde "${LOCAL_RUN:-$LOCAL_DIR/duo/run}")
LOCAL_PACK=$(untilde "$LOCAL_PACK")
# (paths of the peer keep a leading ~/: it is expanded there)
[ -n "$PEER_DIR" ] && PEER_BUILD=${PEER_BUILD:-$(under "$PEER_DIR" "$BUILD")}
[ -n "$PEER_DIR" ] && PEER_CERTS=${PEER_CERTS:-$PEER_DIR/duo/certs}
[ -n "$PEER_DIR" ] && PEER_RUN=${PEER_RUN:-$PEER_DIR/duo/run}
if [ "$LOCAL_ROLE" = suffix ]; then SUFFIX_RUN=$LOCAL_RUN; else SUFFIX_RUN=$PEER_RUN; fi
[ -n "$SUFFIX_CONTROL_DIR" ] && SUFFIX_PYTHON=${SUFFIX_PYTHON:-$SUFFIX_CONTROL_DIR/python/bin/python3.12}
# conversations kept on the suffix host, a folder a model (a server removes the slots of another model's from its folder)
SLOT_DIR=${SLOT_DIR:-$SUFFIX_RUN/slots-$MODEL}

RUN=$LOCAL_RUN
KEY="$RUN/api_key"            # the API key (600): made at the first start, checked by the gate and the server
AUTH="$RUN/api_auth.hdr"      # the same as one HTTP header line (600), for `curl -H @file`: the key is never an argument
WANTED="$RUN/.duo_wanted"; LOCK="$RUN/.duo_starting"
SSH=(ssh -o ConnectTimeout=8 -o ServerAliveInterval=10 -o ServerAliveCountMax=3 -o BatchMode=yes ${SSH_OPTS[@]+"${SSH_OPTS[@]}"})

die() { printf 'duo.sh: %s\n' "$*" >&2; exit 1; }
is_num() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }
is_ip() { printf '%s' "$1" | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}$'; }

conf_problems() {   # one line a problem; nothing when the settings can run a pair
  [ "$CONF_FOUND" = 1 ] || { echo "no settings file: $CONF (copy duo.conf.example to duo.conf and edit it)"; return; }
  [ -n "$PEER" ] || echo "PEER is not set (the ssh destination of the other Mac)"
  case "$LOCAL_ROLE" in prefix|suffix) ;; *) echo "LOCAL_ROLE must be prefix or suffix (is: $LOCAL_ROLE)" ;; esac
  [ -n "$PEER_DIR" ] || echo "PEER_DIR is not set (the install directory on the other Mac)"
  [ -n "$LOCAL_PACK" ] || echo "LOCAL_PACK is not set (the model pack on this Mac)"
  [ -n "$PEER_PACK" ] || echo "PEER_PACK is not set (the model pack on the other Mac)"
  [ -n "$SUFFIX_CONTROL_DIR" ] || echo "SUFFIX_CONTROL_DIR is not set (the Strata control directory on the suffix host)"
  local v
  for v in PORT APIPORT BACKPORT SERVER_PORT CTX CUT BUSY_MAX_S MIN_FREE_GB; do
    is_num "${!v}" || echo "$v must be a number (is: ${!v})"
  done
  case "$MODEL" in *[!A-Za-z0-9._-]*) echo "MODEL may hold letters, digits, dot, dash and underscore only (is: $MODEL)" ;; esac
  [ "$APIPORT" != "$BACKPORT" ] || echo "APIPORT and BACKPORT must differ"
  if [ -n "$LINK_LOCAL_IP$LINK_PEER_IP" ]; then
    is_ip "$LINK_LOCAL_IP" && is_ip "$LINK_PEER_IP" || echo "LINK_LOCAL_IP and LINK_PEER_IP must both be IPv4 addresses (or both empty)"
  fi
}
need_conf() {
  local p; p=$(conf_problems)
  [ -z "$p" ] || { printf 'duo.sh: the settings are not complete:\n%s\n' "$p" >&2; echo "run: $SELF doctor" >&2; exit 1; }
  mkdir -p "$RUN" && chmod 700 "$RUN" || die "cannot create $RUN"
}

# ---------------------------------------------------------------------------------------------- the two hosts
# A piece of bash runs on a host with that host's settings as H_* variables: on this Mac through `bash -s`, on the
# peer through `ssh PEER bash -s`. Everything travels on stdin, quoted by printf %q: no path, however odd, and no
# secret is ever part of an ssh command line.
host_vars() {   # local|peer [NAME=VALUE ...]
  local side=$1 role dir build certs pack run pair
  shift
  if [ "$side" = local ]; then
    role=$LOCAL_ROLE; dir=$LOCAL_DIR; build=$LOCAL_BUILD; certs=$LOCAL_CERTS; pack=$LOCAL_PACK; run=$LOCAL_RUN
  else
    if [ "$LOCAL_ROLE" = prefix ]; then role=suffix; else role=prefix; fi
    dir=$PEER_DIR; build=$PEER_BUILD; certs=$PEER_CERTS; pack=$PEER_PACK; run=$PEER_RUN
  fi
  printf '%s=%q\n' H_SIDE "$side" H_ROLE "$role" H_DIR "$dir" H_BUILD "$build" H_CERTS "$certs" H_PACK "$pack" H_RUN "$run" \
    H_CONTROL "$SUFFIX_CONTROL_DIR" H_PYTHON "$SUFFIX_PYTHON" H_SLOTS "$SLOT_DIR" H_MODEL_ID "$MODEL_ID" \
    H_PORT "$PORT" H_APIPORT "$APIPORT" H_BACKPORT "$BACKPORT" H_SERVER_PORT "$SERVER_PORT" H_CTX "$CTX" H_CUT "$CUT" \
    H_VX1 "$VX1" H_VX2 "$VX2" H_MIN_FREE_GB "$MIN_FREE_GB" H_LINK_PREFIX "$LINK_PREFIX"
  for pair in "$@"; do printf '%s=%q\n' "${pair%%=*}" "${pair#*=}"; done
}

read -r -d '' HOSTLIB <<'HOSTLIB_EOF' || true
h_untilde() { case "$1" in "~") printf '%s' "$HOME" ;; "~/"*) printf '%s/%s' "$HOME" "${1#\~/}" ;; *) printf '%s' "$1" ;; esac; }
H_DIR=$(h_untilde "$H_DIR"); H_BUILD=$(h_untilde "$H_BUILD"); H_CERTS=$(h_untilde "$H_CERTS"); H_PACK=$(h_untilde "$H_PACK")
H_RUN=$(h_untilde "$H_RUN"); H_CONTROL=$(h_untilde "$H_CONTROL"); H_PYTHON=$(h_untilde "$H_PYTHON"); H_SLOTS=$(h_untilde "$H_SLOTS")
H_EXE="$H_BUILD/strata_ds4"
# TERM every process of this user whose command line matches the regular expression $1 AND contains the text $2
kill_matching() {
  local pid cmd
  for pid in $(pgrep -U "$(id -u)" -f "$1" 2>/dev/null); do
    [ "$pid" = "$$" ] && continue
    cmd=$(ps -ww -o command= -p "$pid" 2>/dev/null) || continue
    case "$cmd" in *"$2"*) kill "$pid" 2>/dev/null ;; esac
  done
  return 0
}
# this pair's engine on this host, by its link port (other engines on this Mac are not ours to stop)
engine_regex() {
  if [ "$H_ROLE" = prefix ]; then printf 'strata_ds4 .*--duo-listen [0-9.]*:%s( |$)' "$H_PORT"
  else printf 'strata_ds4 .*--duo-connect [0-9.]*:%s( |$)' "$H_PORT"; fi
}
host_down() {
  if [ "$H_ROLE" = suffix ]; then
    # Require the exact config argument, not a substring of another pair's filename.
    local pid cmd
    for pid in $(pgrep -U "$(id -u)" -f 'serve\.server --engine strata --config' 2>/dev/null); do
      cmd=$(ps -ww -o command= -p "$pid" 2>/dev/null) || continue
      case "$cmd" in *"--config $H_RUN/serve.json --host "*) kill "$pid" 2>/dev/null ;; esac
    done
    sleep 1
  fi
  kill_matching "$(engine_regex)" "strata_ds4"
}
host_status() {
  pgrep -U "$(id -u)" -fl 'strata_ds4|serve\.server' 2>/dev/null | cut -c1-110
  memory_pressure 2>/dev/null | tail -1
  sysctl -n vm.swapusage 2>/dev/null
}
HOSTLIB_EOF

run_on() {   # local|peer SCRIPT [NAME=VALUE ...]: SCRIPT (bash) on that host, its stdin empty
  local side=$1 script=$2
  shift 2
  if [ "$side" = local ]; then
    { host_vars local "$@"; printf '__duo_main() {\n%s\n%s\n}\n__duo_main < /dev/null\n' "$HOSTLIB" "$script"; } | bash -s
  else
    { host_vars peer "$@"; printf '__duo_main() {\n%s\n%s\n}\n__duo_main < /dev/null\n' "$HOSTLIB" "$script"; } | "${SSH[@]}" "$PEER" 'bash -s'
  fi
}
rq() {   # one word for the peer's login shell, whatever characters it holds
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}
kill_local() {   # REGEX TEXT: as kill_matching, on this Mac
  local pid cmd
  for pid in $(pgrep -U "$(id -u)" -f "$1" 2>/dev/null); do
    [ "$pid" = "$$" ] && continue
    cmd=$(ps -ww -o command= -p "$pid" 2>/dev/null) || continue
    case "$cmd" in *"$2"*) kill "$pid" 2>/dev/null ;; esac
  done
  return 0
}
local_engine_regex() {
  if [ "$LOCAL_ROLE" = prefix ]; then printf 'strata_ds4 .*--duo-listen [0-9.]*:%s( |$)' "$PORT"
  else printf 'strata_ds4 .*--duo-connect [0-9.]*:%s( |$)' "$PORT"; fi
}
curl_auth() {   # curl with the API key, read from a 600 file (never on a command line)
  if [ ! -s "$AUTH" ] || [ "$KEY" -nt "$AUTH" ]; then
    ( umask 077; printf 'Authorization: Bearer %s\n' "$(cat "$KEY")" > "$AUTH" ) 2>/dev/null || return 1
  fi
  curl -s -H "@$AUTH" "$@"
}
backend_ok() {   # the pair is loaded and answers
  pgrep -U "$(id -u)" -f "$(local_engine_regex)" >/dev/null && [ -s "$KEY" ] &&
    curl_auth -m5 "http://127.0.0.1:$BACKPORT/v1/models" 2>/dev/null | grep -q '"id"'
}
gate_ok() { curl -s -m3 "http://127.0.0.1:$APIPORT/duo/status" 2>/dev/null | grep -q '"idle_min"'; }
gate_start() {
  gate_ok && return 0
  # A slow gate is not a dead gate. In particular ensure must never kill one on a failed 3 s probe.
  if pgrep -U "$(id -u)" -f "duo_gate\.py --listen $APIPORT( |\$)" >/dev/null; then
    echo "the gate process is running but slow to answer; leaving it alone"
    return 0
  fi
  # the gate reads the busy patterns from a file: a pattern on its own command line would match the gate itself
  ( umask 077; : > "$RUN/busy_patterns"
    for p in ${BUSY_PATTERNS[@]+"${BUSY_PATTERNS[@]}"}; do [ -n "$p" ] && printf '%s\n' "$p" >> "$RUN/busy_patterns"; done )
  nohup "$GATE_PYTHON" "$HERE/duo_gate.py" --listen "$APIPORT" --backend "$BACKPORT" --idle-min "$IDLE_MIN" \
    --run-dir "$RUN" --duo-sh "$SELF" --model-id "$MODEL_ID" --engine-role "$LOCAL_ROLE" --link-port "$PORT" \
    --busy-max-s "$BUSY_MAX_S" >> "$RUN/gate.log" 2>&1 < /dev/null &
  local i
  for i in 1 2 3 4 5 6; do sleep 1; gate_ok && return 0; done
  echo "the gate did not start (is something else on port $APIPORT?)"; tail -3 "$RUN/gate.log"; return 1
}

LIP=""; PIP=""; IFACE=""
link_ips() {   # the link's two addresses, found fresh each time (self-assigned addresses change after a reboot)
  if [ -n "$LINK_LOCAL_IP" ] && [ -n "$LINK_PEER_IP" ]; then LIP=$LINK_LOCAL_IP; PIP=$LINK_PEER_IP; IFACE="(set in duo.conf)"; return 0; fi
  local ip cands
  # shellcheck disable=SC2016
  cands=$(run_on peer 'for i in $(ifconfig -l); do ifconfig "$i" 2>/dev/null | awk -v p="$H_LINK_PREFIX" '\''$1 == "inet" && index($2, p) == 1 {print $2}'\''; done' 2>/dev/null)
  PIP=""
  for ip in $cands; do
    is_ip "$ip" || continue
    ping -c1 -t1 "$ip" >/dev/null 2>&1 && { PIP=$ip; break; }
  done
  [ -n "$PIP" ] || { echo "cannot find the other Mac on the link (no $LINK_PREFIX* address of $PEER answers a ping; is the cable in?)"; return 1; }
  IFACE=$(route -n get "$PIP" 2>/dev/null | awk '/interface:/{print $2}')
  [ -n "$IFACE" ] || { echo "no route to $PIP"; return 1; }
  LIP=$(ifconfig "$IFACE" | awk -v p="$LINK_PREFIX" '$1 == "inet" && index($2, p) == 1 {print $2; exit}')
  [ -n "$LIP" ] || LIP=$(ifconfig "$IFACE" | awk '$1 == "inet" {print $2; exit}')
  is_ip "$LIP" || { echo "no IPv4 address on $IFACE"; return 1; }
}
host_key_alias() {   # the name ssh knows the peer's host key by: kept when the session goes to the link address
  "${SSH[@]}" -G "$PEER" 2>/dev/null | awk '$1 == "hostkeyalias" {a = $2} $1 == "hostname" {h = $2} END {print (a != "" ? a : h)}'
}

remember_session() {   # NAME PID: only sessions we launched, with their exact command for PID-reuse protection
  ( umask 077; printf '%s\n' "$2" > "$RUN/$1.pid"; ps -ww -o command= -p "$2" > "$RUN/$1.command" )
}
stop_session() {
  local pid was now
  pid=$(cat "$RUN/$1.pid" 2>/dev/null) || return 0
  was=$(cat "$RUN/$1.command" 2>/dev/null) || return 0
  now=$(ps -ww -o command= -p "$pid" 2>/dev/null) || return 0
  [ -n "$was" ] && [ "$was" = "$now" ] && kill "$pid" 2>/dev/null
  rm -f "$RUN/$1.pid" "$RUN/$1.command"
  return 0
}
down() {
  # No broad ssh match: another pair may use a script with the same name.
  stop_session server_ssh
  stop_session prefix_ssh
  if [ "$LOCAL_ROLE" = suffix ]; then run_on local 'host_down'; run_on peer 'host_down' 2>/dev/null
  else run_on peer 'host_down' 2>/dev/null; run_on local 'host_down'; fi
  echo unloaded
}

# what the suffix host needs before its server starts: the key, the server's settings and a start script (all in its run folder)
read -r -d '' SUFFIX_PREP <<'PREP_EOF' || true
umask 077
mkdir -p "$H_RUN" "$H_SLOTS" && chmod 700 "$H_RUN" || { echo "cannot create $H_RUN"; return 1; }
[ -n "${API_KEY:-}" ] && printf '%s\n' "$API_KEY" > "$H_RUN/api_key"
[ -s "$H_RUN/api_key" ] || { echo "no API key in $H_RUN"; return 1; }
"$H_PYTHON" - "$H_EXE" "$H_PACK" "$H_CTX" "$H_VX2" "$LINK_PREFIX_ADDR" "$SERVE_PORT" "$H_CUT" "$H_CERTS" "$H_CONTROL" "$H_RUN" "$H_MODEL_ID" <<'PYEOF' || { echo "could not write $H_RUN/serve.json"; return 1; }
import json, os, sys
exe, pack, ctx, vx, peer, port, cut, certs, control, run, model_id = sys.argv[1:]
args = ['--pack', pack, '--max-context', ctx, '--eos', '1', '--vision', 'off', '--dspark', 'none', '--ssd-cache', '0', '--profile-readonly',
        '--vram-experts', vx, '--duo-cut', cut, '--duo-connect', peer, '--duo-certs', certs]
cfg = {'exe': exe, 'args': args, 'args_written': args, 'cwd': control, 'tokenizer': pack + '/tokenizer',
       'model_name': model_id, 'arch': 'deepseek41', 'log': run + '/engine.log', 'lib_dirs': [os.path.dirname(exe)],
       'port': int(port), 'engine_ready_s': 3600, 'backend': 'metal', 'host': '127.0.0.1', 'open_browser': False}
with open(run + '/serve.json', 'w') as f:
    json.dump(cfg, f, indent=1)
PYEOF
{
  printf '#!/bin/bash\n# written by duo.sh at each start\n'
  printf 'cd %q || exit 1\n' "$H_CONTROL"
  printf 'export STRATA_DS4_SLOT_DIR=%q\n' "$H_SLOTS"
  printf 'STRATA_API_KEY=$(cat %q) || exit 1\nexport STRATA_API_KEY\n' "$H_RUN/api_key"
  printf 'exec %q -m serve.server --engine strata --config %q --host 127.0.0.1 --port %q\n' "$H_PYTHON" "$H_RUN/serve.json" "$SERVE_PORT"
} > "$H_RUN/start_server.sh"
chmod 700 "$H_RUN/start_server.sh"
: > "$H_RUN/engine.log"
printf 'START %s\n' "$H_RUN/start_server.sh"
PREP_EOF

# the prefix host when it is the peer: a start script in its run folder (the engine then stays a child of an ssh session)
read -r -d '' PREFIX_PREP <<'PREP_EOF' || true
umask 077
mkdir -p "$H_RUN" && chmod 700 "$H_RUN" || { echo "cannot create $H_RUN"; return 1; }
{
  printf '#!/bin/bash\n# written by duo.sh at each start\n'
  printf 'cd %q || exit 1\n' "$H_BUILD"
  printf 'exec ./strata_ds4 --pack %q --max-context %q --ssd-cache 0 --profile-readonly --duo-cut %q --dspark none --vision off --vram-experts %q --duo-listen %q --duo-allow %q --duo-certs %q\n' \
    "$H_PACK" "$H_CTX" "$H_CUT" "$H_VX1" "$LISTEN_ADDR" "$ALLOW_IP" "$H_CERTS"
} > "$H_RUN/start_prefix.sh"
chmod 700 "$H_RUN/start_prefix.sh"
printf 'START %s\n' "$H_RUN/start_prefix.sh"
PREP_EOF

make_key() {
  [ -s "$KEY" ] || ( umask 077; openssl rand -hex 24 > "$KEY" )
  [ -s "$KEY" ] || die "could not create the API key $KEY"
  chmod 600 "$KEY"
}

up_local_prefix() {   # this Mac: prefix engine. The peer: suffix engine under Strata's API server, held by one ssh session
  local i out start hka job
  local COMMON=(--max-context "$CTX" --ssd-cache 0 --profile-readonly --duo-cut "$CUT" --dspark none --vision off)
  # (no subshell around it: one would stay as the engine's parent and keep this script's stdout open)
  cd "$LOCAL_BUILD" || { echo "no build directory $LOCAL_BUILD (run duo/build.sh)"; return 1; }
  nohup ./strata_ds4 --pack "$LOCAL_PACK" "${COMMON[@]}" --vram-experts "$VX1" --duo-listen "$LIP:$PORT" --duo-allow "$PIP" \
    --duo-certs "$LOCAL_CERTS" > "$RUN/prefix.log" 2>&1 < /dev/null &
  job=$!
  cd "$HERE" || return 1
  for i in $(seq 1 300); do grep -q "waiting on\|maya-ds4:" "$RUN/prefix.log" 2>/dev/null && break; kill -0 "$job" 2>/dev/null || break; sleep 2; done
  grep -E "layers \[|maya-ds4:" "$RUN/prefix.log" | cut -c1-170
  grep -q "waiting on" "$RUN/prefix.log" || { echo "the prefix host did not start (see $RUN/prefix.log)"; return 1; }
  make_key
  out=$(run_on peer "$SUFFIX_PREP" "API_KEY=$(cat "$KEY")" "LINK_PREFIX_ADDR=$LIP:$PORT" "SERVE_PORT=$SERVER_PORT") || { echo "$out"; echo "could not prepare the suffix host"; return 1; }
  start=$(printf '%s\n' "$out" | sed -n 's/^START //p' | tail -1)
  [ -n "$start" ] || { echo "$out"; echo "could not prepare the suffix host"; return 1; }
  hka=$(host_key_alias)
  # (the server stays a child of this ssh session: a process detached on the other Mac is refused the local network
  #  by macOS - "No route to host" - and the same ssh carries the API's tunnel)
  nohup ssh -o BatchMode=yes -o HostName="$PIP" ${hka:+-o HostKeyAlias="$hka"} -o ServerAliveInterval=30 -o ExitOnForwardFailure=yes \
    ${SSH_OPTS[@]+"${SSH_OPTS[@]}"} -L "$BACKPORT:127.0.0.1:$SERVER_PORT" "$PEER" "exec bash $(rq "$start")" > "$RUN/server.log" 2>&1 < /dev/null &
  job=$!
  remember_session server_ssh "$job"
  for i in $(seq 1 100); do
    kill -0 "$job" 2>/dev/null || { echo "the ssh session that holds the server ended:"; tail -3 "$RUN/server.log"; break; }
    curl_auth -m2 "http://127.0.0.1:$BACKPORT/v1/models" 2>/dev/null | grep -q '"id"' &&
      run_on peer 'grep -q "suffix host" "$H_RUN/engine.log"' 2>/dev/null && break
    run_on peer 'grep -q "maya-ds4:" "$H_RUN/engine.log"' 2>/dev/null && { echo "the suffix host failed:"; break; }
    sleep 3
  done
  run_on peer 'grep -E "link up|layers \[|maya-ds4" "$H_RUN/engine.log" | cut -c1-170; memory_pressure | tail -1' 2>/dev/null
}

up_local_suffix() {   # the peer: prefix engine, held by one ssh session. This Mac: suffix engine under Strata's API server
  local i out start hka job control python
  out=$(run_on peer "$PREFIX_PREP" "LISTEN_ADDR=$PIP:$PORT" "ALLOW_IP=$LIP") || { echo "$out"; echo "could not prepare the prefix host"; return 1; }
  start=$(printf '%s\n' "$out" | sed -n 's/^START //p' | tail -1)
  [ -n "$start" ] || { echo "$out"; echo "could not prepare the prefix host"; return 1; }
  hka=$(host_key_alias)
  nohup ssh -o BatchMode=yes -o HostName="$PIP" ${hka:+-o HostKeyAlias="$hka"} -o ServerAliveInterval=30 \
    ${SSH_OPTS[@]+"${SSH_OPTS[@]}"} "$PEER" "exec bash $(rq "$start")" > "$RUN/prefix.log" 2>&1 < /dev/null &
  job=$!
  remember_session prefix_ssh "$job"
  for i in $(seq 1 300); do grep -q "waiting on\|maya-ds4:" "$RUN/prefix.log" 2>/dev/null && break; kill -0 "$job" 2>/dev/null || break; sleep 2; done
  grep -E "layers \[|maya-ds4:" "$RUN/prefix.log" | cut -c1-170
  grep -q "waiting on" "$RUN/prefix.log" || { echo "the prefix host did not start (see $RUN/prefix.log)"; return 1; }
  make_key
  out=$(run_on local "$SUFFIX_PREP" "LINK_PREFIX_ADDR=$PIP:$PORT" "SERVE_PORT=$BACKPORT") || { echo "$out"; echo "could not prepare the suffix host"; return 1; }
  control=$(untilde "$SUFFIX_CONTROL_DIR"); python=$(untilde "$SUFFIX_PYTHON")
  cd "$control" || { echo "no control directory $control"; return 1; }
  STRATA_DS4_SLOT_DIR=$(untilde "$SLOT_DIR") STRATA_API_KEY=$(cat "$KEY") nohup "$python" -m serve.server --engine strata \
    --config "$RUN/serve.json" --host 127.0.0.1 --port "$BACKPORT" > "$RUN/server.log" 2>&1 < /dev/null &
  job=$!
  cd "$HERE" || return 1
  for i in $(seq 1 100); do
    kill -0 "$job" 2>/dev/null || { echo "the server ended:"; tail -3 "$RUN/server.log"; break; }
    curl_auth -m2 "http://127.0.0.1:$BACKPORT/v1/models" 2>/dev/null | grep -q '"id"' && grep -q "suffix host" "$RUN/engine.log" 2>/dev/null && break
    grep -q "maya-ds4:" "$RUN/engine.log" 2>/dev/null && { echo "the suffix host failed:"; break; }
    sleep 3
  done
  grep -E "link up|layers \[|maya-ds4" "$RUN/engine.log" 2>/dev/null | cut -c1-170; memory_pressure | tail -1
}

# ---------------------------------------------------------------------------------------------- doctor
# Each host reports lines "P|check|detail", "F|check|detail|fix", "W|check|detail|advice", "I|check|detail" and
# "D|name|value" (values this Mac compares between the two hosts).
read -r -d '' HOST_DOCTOR <<'DOCTOR_EOF' || true
# (a "|" inside a text would shift the fields: it is written as "/")
p() { printf 'P|%s|%s\n' "$1" "${2//|//}"; }
f() { printf 'F|%s|%s|%s\n' "$1" "${2//|//}" "${3//|//}"; }
w() { printf 'W|%s|%s|%s\n' "$1" "${2//|//}" "${3//|//}"; }
i() { printf 'I|%s|%s\n' "$1" "${2//|//}"; }
i "system" "macOS $(sw_vers -productVersion 2>/dev/null), $(uname -m), $(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1073741824 )) GB memory, role: $H_ROLE host"
[ "$(uname -s)" = Darwin ] && [ "$(uname -m)" = arm64 ] || f "platform" "$(uname -s) $(uname -m)" "Strata Duo runs on Apple Silicon Macs only"

# -- the engine
if [ -x "$H_EXE" ]; then
  ver=$("$H_EXE" --version 2>/dev/null | head -1)
  p "engine" "$H_EXE: ${ver:-no --version answer}"
  printf 'D|version|%s\n' "$ver"
  printf 'D|engine_sha|%s\n' "$(shasum -a 256 "$H_EXE" 2>/dev/null | cut -c1-16)"
else
  f "engine" "$H_EXE not found" "on this host run: $H_DIR/duo/build.sh   (or set BUILD / LOCAL_BUILD / PEER_BUILD in duo.conf)"
fi

# -- the certificates of this host's role
if [ "$H_ROLE" = prefix ]; then role=strata-stage-worker; other=strata-stage-coordinator; else role=strata-stage-coordinator; other=strata-stage-worker; fi
certs_ok=1
for x in ca.crt "$role.crt" "$role.key"; do
  [ -r "$H_CERTS/$x" ] || { certs_ok=0; f "certificates" "$H_CERTS/$x is missing" "copy the $H_ROLE folder made by duo/gen_certs.sh into $H_CERTS on this host"; }
done
if [ "$certs_ok" = 1 ]; then
  mode=$(stat -f %Lp "$H_CERTS/$role.key" 2>/dev/null)
  if [ "$mode" = 600 ] || [ "$mode" = 400 ]; then p "key permissions" "$role.key is mode $mode"
  else f "key permissions" "$H_CERTS/$role.key is mode $mode" "chmod 600 '$H_CERTS/$role.key'"; fi
  text=$(openssl x509 -in "$H_CERTS/$role.crt" -noout -text 2>/dev/null)
  if printf '%s' "$text" | grep -q "DNS:$role"; then p "certificate role" "$role.crt names the role $role (subjectAltName)"
  else f "certificate role" "$H_CERTS/$role.crt has no subjectAltName DNS:$role" "make a new set with duo/gen_certs.sh and copy the $H_ROLE folder here"; fi
  if openssl verify -CAfile "$H_CERTS/ca.crt" "$H_CERTS/$role.crt" >/dev/null 2>&1; then p "certificate chain" "$role.crt is signed by ca.crt"
  else f "certificate chain" "$role.crt is not signed by $H_CERTS/ca.crt (or has expired)" "both hosts need files of the same gen_certs.sh run"; fi
  end=$(openssl x509 -in "$H_CERTS/$role.crt" -noout -enddate 2>/dev/null | cut -d= -f2)
  if ! openssl x509 -in "$H_CERTS/$role.crt" -noout -checkend 0 >/dev/null 2>&1; then f "certificate validity" "expired ($end)" "make a new set with duo/gen_certs.sh"
  elif ! openssl x509 -in "$H_CERTS/$role.crt" -noout -checkend 2592000 >/dev/null 2>&1; then w "certificate validity" "expires within 30 days ($end)" "make a new set with duo/gen_certs.sh"
  else p "certificate validity" "until $end"; fi
  printf 'D|ca|%s\n' "$(openssl x509 -in "$H_CERTS/ca.crt" -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2)"
  # the engine's own verdict on this directory in this role: its checks before any model load (no --pack is given,
  # so it stops at its usage text right after them)
  if [ -x "$H_EXE" ]; then
    if [ "$H_ROLE" = prefix ]; then pre=$("$H_EXE" --duo-listen 127.0.0.1:9 --duo-allow 127.0.0.1 --duo-certs "$H_CERTS" 2>&1 | grep -E "ds4 duo:|maya-ds4: duo:" | head -1)
    else pre=$("$H_EXE" --duo-connect 127.0.0.1:9 --duo-certs "$H_CERTS" 2>&1 | grep -E "ds4 duo:|maya-ds4: duo:" | head -1); fi
    case "$pre" in
      *"link mode TLS 1.3"*) p "engine accepts the certificates" "TLS 1.3, mutual authentication, this host is $role" ;;
      *"needs an engine built with TLS"*) f "engine accepts the certificates" "this strata_ds4 was built without the TLS link" "build it with duo/build.sh (not a plain cmake build)" ;;
      *) f "engine accepts the certificates" "${pre:-no answer from the engine}" "see the message; make a new set with duo/gen_certs.sh if the files are wrong" ;;
    esac
  fi
fi
[ -e "$H_CERTS/$other.key" ] && w "foreign key" "$H_CERTS/$other.key is on the $H_ROLE host" "delete it here: the $other key belongs on the other host only"
for x in "$H_CERTS/ca.key" "$H_CERTS/ca/ca.key"; do
  [ -e "$x" ] && w "CA key" "$x is on this host" "move it to offline storage or delete it: neither host needs it to run"
done

# -- the model pack and the model files it names
if [ -f "$H_PACK/ds4.txt" ] && [ -f "$H_PACK/tensors.txt" ]; then
  md=$(sed -n 's/^model_dir //p' "$H_PACK/ds4.txt" | head -1)
  if [ -z "$md" ] || [ ! -d "$md" ]; then
    f "model files" "ds4.txt says model_dir ${md:-(nothing)}, which is not a folder on this host" "python3 $H_DIR/duo/pack_relocate.py '$H_PACK' --model-dir /where/the/GGUF/files/are   (duo/make_pack.md)"
  else
    miss=0; list=""
    while read -r _ idx name; do
      [ -n "$name" ] || continue
      if [ -f "$md/$name" ]; then list="$list $(basename "$name"):$(stat -f %z "$md/$name")"
      else miss=$((miss + 1)); f "model files" "file $idx: $md/$name is missing" "copy it to this host, or point the pack at it: duo/pack_relocate.py (duo/make_pack.md)"; fi
      case "$name" in /*|../*|*/../*) w "model files" "file $idx is outside the model folder: $name" "it must exist at that path on this host too (duo/pack_relocate.py --check shows what the pack opens)" ;; esac
    done <<FILES
$(grep '^file ' "$H_PACK/tensors.txt")
FILES
    [ "$miss" = 0 ] && p "model files" "$(printf '%s' "$list" | wc -w | tr -d ' ') files in $md"
    printf 'D|models|%s\n' "$list"
  fi
  printf 'D|ds4|%s\n' "$(grep -v '^model_dir ' "$H_PACK/ds4.txt" | shasum -a 256 | cut -c1-16)"
  printf 'D|packfiles|%s\n' "$(cd "$H_PACK" && for x in *; do [ -f "$x" ] && [ "$x" != ds4.txt ] && [ "$x" != tensors.txt ] && [ "$x" != expert-profile.bin ] && printf '%s:%s ' "$x" "$(stat -f %z "$x")"; done)"
  [ "$H_ROLE" = suffix ] && { [ -f "$H_PACK/tokenizer/vocab.json" ] && p "tokenizer" "$H_PACK/tokenizer" || f "tokenizer" "$H_PACK/tokenizer/vocab.json is missing" "the pack is incomplete: build it again (duo/make_pack.md)"; }
  p "model pack" "$H_PACK"
else
  f "model pack" "$H_PACK has no ds4.txt and tensors.txt" "build or copy the pack (duo/make_pack.md) and set LOCAL_PACK / PEER_PACK in duo.conf"
fi

# -- free disk where the run folder (logs, kept conversations) lives
d="$H_RUN"; while [ ! -d "$d" ] && [ "$d" != / ]; do d=$(dirname "$d"); done
free=$(( $(df -k "$d" 2>/dev/null | awk 'NR == 2 {print $4}') / 1048576 ))
if [ "$free" -ge "$H_MIN_FREE_GB" ]; then p "free disk" "$free GB free at $d"
else f "free disk" "$free GB free at $d (wanted: $H_MIN_FREE_GB GB)" "free some space, or lower MIN_FREE_GB in duo.conf"; fi

# -- the ports this host listens on
port_check() {   # PORT WHAT
  local pids cmd
  pids=$(lsof -nP -iTCP:"$1" -sTCP:LISTEN -t 2>/dev/null | tr '\n' ' ')
  if [ -z "$pids" ]; then p "port $1" "free ($2)"; return; fi
  cmd=$(ps -ww -o command= -p "${pids%% *}" 2>/dev/null | cut -c1-90)
  case "$cmd" in
    *duo_gate.py*|*strata_ds4*|*serve.server*|*start_server.sh*) p "port $1" "held by this pair, which is running ($2)" ;;
    *) f "port $1" "in use by: ${cmd:-pid $pids} ($2)" "stop that program, or choose another port in duo.conf" ;;
  esac
}
[ "$H_ROLE" = prefix ] && port_check "$H_PORT" "the link: the prefix engine listens here"
if [ "$H_SIDE" = local ]; then port_check "$H_APIPORT" "the gate: what clients connect to"; port_check "$H_BACKPORT" "the server behind the gate"; fi
[ "$H_SIDE" = peer ] && [ "$H_ROLE" = suffix ] && port_check "$H_SERVER_PORT" "Strata's API server"

# -- Strata's API server (the suffix host)
if [ "$H_ROLE" = suffix ]; then
  if [ -f "$H_CONTROL/serve/server.py" ]; then p "control directory" "$H_CONTROL (serve/server.py)"
  else f "control directory" "$H_CONTROL/serve/server.py not found" "set SUFFIX_CONTROL_DIR to the folder that holds serve/ (in the Strata app: Strata.app/Contents/Resources/control)"; fi
  if [ -x "$H_PYTHON" ] && pv=$("$H_PYTHON" -c 'import sys; print("%d.%d.%d" % sys.version_info[:3])' 2>/dev/null); then p "server python" "$H_PYTHON ($pv)"
  else f "server python" "$H_PYTHON does not run" "set SUFFIX_PYTHON to the Python that Strata's control directory uses"; fi
fi
[ "$H_SIDE" = local ] && printf 'D|link_addrs|%s\n' "$(for n in $(ifconfig -l); do ifconfig "$n" 2>/dev/null | awk -v p="$H_LINK_PREFIX" -v n="$n" '$1 == "inet" && index($2, p) == 1 {printf "%s(%s) ", $2, n}'; done)"
true
DOCTOR_EOF

doctor() {
  local fails=0 warns=0 problems l kind a b c peer_ok=0 lout pout host port
  line() {   # KIND CHECK DETAIL [FIX]
    case "$1" in
      P) printf 'PASS  %s: %s\n' "$2" "$3" ;;
      F) fails=$((fails + 1)); printf 'FAIL  %s: %s\n' "$2" "$3"; [ -n "${4:-}" ] && printf '      fix: %s\n' "$4" ;;
      W) warns=$((warns + 1)); printf 'WARN  %s: %s\n' "$2" "$3"; [ -n "${4:-}" ] && printf '      advice: %s\n' "$4" ;;
      I) printf 'INFO  %s: %s\n' "$2" "$3" ;;
      S) printf 'SKIP  %s: %s\n' "$2" "$3" ;;
    esac
    return 0
  }
  report() {   # LABEL OUTPUT: a host's lines
    while IFS='|' read -r kind a b c; do
      case "$kind" in P|F|W|I) line "$kind" "$1: $a" "$b" "$c" ;; esac
    done <<REPORT
$2
REPORT
  }
  dval() { printf '%s\n' "$1" | sed -n "s/^D|$2|//p" | head -1; }

  echo "Strata Duo doctor (read-only): $(date '+%F %T')"
  echo "-- settings"
  if [ "$CONF_FOUND" = 1 ]; then line P "settings file" "$CONF"; else line F "settings file" "$CONF not found" "cp '$HERE/duo.conf.example' '$HERE/duo.conf' and edit it"; fi
  problems=$(conf_problems)
  if [ "$CONF_FOUND" = 1 ] && [ -n "$problems" ]; then
    while read -r l; do line F "settings" "$l" "edit $CONF"; done <<PROBLEMS
$problems
PROBLEMS
  fi
  if [ "$CONF_FOUND" = 1 ] && [ -z "$problems" ]; then
    line P "settings" "this Mac is the $LOCAL_ROLE host, PEER=$PEER, MODEL=$MODEL, ports: gate $APIPORT, backend $BACKPORT, link $PORT"
    case "$(stat -f %Lp "$CONF" 2>/dev/null)" in *[2367][0-7]|*[2367]) line W "settings file" "$CONF is writable by others (it is run as a script)" "chmod 600 '$CONF'" ;; esac
  fi
  if [ -x "$GATE_PYTHON" ] && "$GATE_PYTHON" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)' 2>/dev/null; then line P "gate python" "$GATE_PYTHON ($("$GATE_PYTHON" -c 'import sys; print("%d.%d.%d" % sys.version_info[:3])'))"
  else line F "gate python" "$GATE_PYTHON is not Python 3.9 or newer" "install the Xcode Command Line Tools (xcode-select --install) or set GATE_PYTHON"; fi
  if [ -e "$KEY" ]; then
    case "$(stat -f %Lp "$KEY")" in 600|400) line P "API key file" "$KEY (mode $(stat -f %Lp "$KEY"))" ;; *) line F "API key file" "$KEY is mode $(stat -f %Lp "$KEY")" "chmod 600 '$KEY'" ;; esac
  else line I "API key file" "not made yet (the first start makes $KEY)"; fi
  if [ -n "$problems" ] || [ "$CONF_FOUND" != 1 ]; then
    echo "-- the remaining checks need complete settings"
    echo "RESULT: $fails failed"
    return 1
  fi

  echo "-- the other Mac ($PEER)"
  host=$("${SSH[@]}" -G "$PEER" 2>/dev/null | awk '$1 == "hostname" {print $2; exit}'); port=$("${SSH[@]}" -G "$PEER" 2>/dev/null | awk '$1 == "port" {print $2; exit}')
  if [ -n "$host" ] && nc -z -G 5 "$host" "${port:-22}" >/dev/null 2>&1; then line P "Remote Login" "$host port ${port:-22} answers"
  else line F "Remote Login" "${host:-$PEER} port ${port:-22} does not answer" "on the other Mac: System Settings > General > Sharing > Remote Login on; check the name or address in PEER (or ~/.ssh/config)"; fi
  if "${SSH[@]}" "$PEER" true >/dev/null 2>&1; then peer_ok=1; line P "ssh without a password" "$PEER"
  else line F "ssh without a password" "ssh -o BatchMode=yes $PEER fails" "ssh-keygen -t ed25519 (if you have no key), then ssh-copy-id $PEER, then try: ssh -o BatchMode=yes $PEER true"; fi

  echo "-- this Mac"
  lout=$(run_on local "$HOST_DOCTOR" 2>&1)
  report "this Mac" "$lout"
  if [ "$peer_ok" = 1 ]; then
    echo "-- the other Mac"
    pout=$(run_on peer "$HOST_DOCTOR" 2>&1)
    report "other Mac" "$pout"
    echo "-- the pair"
    a=$(dval "$lout" version); b=$(dval "$pout" version)
    if [ -n "$a" ] && [ "$a" = "$b" ]; then line P "same engine build" "both: $a (compared: strata_ds4 --version, i.e. engine version and source commit)"
    elif [ -n "$a" ] && [ -n "$b" ]; then line F "same engine build" "this Mac: $a / other Mac: $b (compared: strata_ds4 --version)" "check out the same commit on both Macs and run duo/build.sh on both"
    else line S "same engine build" "an engine is missing (see above)"; fi
    line I "engine file hash" "this Mac $(dval "$lout" engine_sha), other Mac $(dval "$pout" engine_sha) (sha256, first 16; they differ when each Mac built its own: the build holds its checkout's path)"
    a=$(dval "$lout" ca); b=$(dval "$pout" ca)
    if [ -n "$a" ] && [ "$a" = "$b" ]; then line P "same CA" "both hosts trust the same ca.crt"
    elif [ -n "$a" ] && [ -n "$b" ]; then line F "same CA" "the two hosts have different ca.crt files" "copy the prefix and suffix folders of ONE gen_certs.sh run to the two hosts"
    else line S "same CA" "certificates are missing (see above)"; fi
    a=$(dval "$lout" models); b=$(dval "$pout" models)
    if [ -n "$a" ] && [ "$a" = "$b" ]; then line P "same model files" "names and sizes agree ($(printf '%s' "$a" | wc -w | tr -d ' ') files)"
    elif [ -n "$a" ] && [ -n "$b" ]; then line F "same model files" "this Mac:$a / other Mac:$b" "both Macs need the complete, identical model files (the engines compare names and sizes when they connect)"
    else line S "same model files" "a pack or its files are missing (see above)"; fi
    a=$(dval "$lout" ds4); b=$(dval "$pout" ds4)
    if [ -n "$a" ] && [ "$a" = "$b" ] && [ "$(dval "$lout" packfiles)" = "$(dval "$pout" packfiles)" ]; then line P "same pack" "ds4.txt (apart from model_dir) and the pack's files agree (names and sizes)"
    elif [ -n "$a" ] && [ -n "$b" ]; then line F "same pack" "the packs differ (this Mac: $(dval "$lout" packfiles)/ other Mac: $(dval "$pout" packfiles))" "copy the pack folder from one Mac to the other, then duo/pack_relocate.py (duo/make_pack.md)"
    else line S "same pack" "a pack is missing (see above)"; fi
    if a=$(link_ips 2>&1); then line P "link addresses" "this Mac $LIP <-> other Mac $PIP on $IFACE"
    else line F "link addresses" "$a" "connect the Thunderbolt cable; both Macs should show a self-assigned $LINK_PREFIX* address on the Thunderbolt Bridge (System Settings > Network), or set LINK_LOCAL_IP and LINK_PEER_IP"; fi
  else
    echo "-- the other Mac"
    for c in "engine" "certificates" "model pack and files" "free disk" "ports" "same engine build" "same CA" "same model files" "link addresses"; do
      line S "other Mac: $c" "not checked: $PEER is not reachable over ssh"
    done
    a=$(dval "$lout" link_addrs)
    if [ -n "$a" ]; then line I "link addresses" "this Mac has $a(the other end was not checked)"; else line W "link addresses" "this Mac has no $LINK_PREFIX* address" "connect the Thunderbolt cable"; fi
  fi
  echo "-- other"
  if [ ${#BUSY_PATTERNS[@]} -gt 0 ]; then
    for c in "${BUSY_PATTERNS[@]}"; do
      if pgrep -f "$c" >/dev/null 2>&1; then line I "busy pattern" "'$c' matches a running process now: the gate would wait"; else line I "busy pattern" "'$c' matches nothing now"; fi
    done
  else line I "busy patterns" "none set"; fi
  line I "gate" "$(curl -s -m3 "http://127.0.0.1:$APIPORT/duo/status" 2>/dev/null || echo 'not running')   wanted: $([ -f "$WANTED" ] && echo yes || echo no)"
  if [ "$fails" = 0 ]; then echo "RESULT: all checks passed ($warns warnings)"; return 0; fi
  echo "RESULT: $fails failed, $warns warnings"
  return 1
}

launchagent() {
  local tpl esc
  tpl=$(cat "$HERE/launchd/strata-duo.plist.template") || die "no template in $HERE/launchd"
  xml() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }
  esc=$(xml "$LAUNCHD_LABEL"); tpl=${tpl//@LABEL@/$esc}
  esc=$(xml "$SELF"); tpl=${tpl//@DUO_SH@/$esc}
  esc=$(xml "$RUN/agent.log"); tpl=${tpl//@LOG@/$esc}
  esc=$(xml "$CONF"); tpl=${tpl//@DUO_CONF@/$esc}
  printf '%s\n' "$tpl"
}

# ---------------------------------------------------------------------------------------------- verbs
case "$VERB" in
doctor) doctor; exit $? ;;
launchagent) launchagent; exit 0 ;;
-h|--help|help) sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
start|stop|restart|status|bench|ensure|up|down) ;;
*) echo "usage: duo.sh start | stop | restart | status | bench | ensure | up | down | doctor | launchagent" >&2; exit 2 ;;
esac
need_conf

case "$VERB" in
stop) rm -f "$WANTED"; kill_local "duo_gate\.py --listen $APIPORT( |\$)" "$HERE/duo_gate.py"; down >/dev/null; echo stopped ;;
down) down ;;
restart) down >/dev/null; exec "$SELF" up ;;
ensure)
  [ -f "$WANTED" ] || exit 0
  gate_ok && exit 0
  echo "$(date '+%F %T') wanted, the gate is not up: starting it"
  gate_start ;;
start)
  touch "$WANTED"
  gate_start || exit 1
  exec "$SELF" up ;;
status)
  echo "gate: $(curl -s -m3 "http://127.0.0.1:$APIPORT/duo/status" 2>/dev/null || echo 'not running')   wanted: $([ -f "$WANTED" ] && echo yes || echo no)"
  echo "this Mac ($LOCAL_ROLE host):"; run_on local 'host_status'
  echo "other Mac ($PEER):"; run_on peer 'host_status' 2>/dev/null || echo "  (not reachable over ssh)"
  [ -s "$KEY" ] && curl_auth -m3 "http://127.0.0.1:$APIPORT/v1/models" | head -c 160; echo ;;
bench)
  [ -s "$KEY" ] || die "no API key yet ($KEY): start the service first"
  exec "$GATE_PYTHON" "$HERE/bench.py" --url "http://127.0.0.1:$APIPORT" --key-file "$KEY" --model "$MODEL_ID" --n 400 \
    --rounds "${ROUNDS:-5}" --label "${LABEL:-duo}" --out "$RUN/bench.jsonl" ;;
up)
  # flock is provided by Python's standard library on macOS. Hold it in a supervisor while the real up runs;
  # neither engines nor ssh inherit it. There is no age-based stealing, stale directory removal or PID reuse race.
  if [ "${DUO_UP_LOCKED:-}" != "$RUN" ]; then
    exec "$GATE_PYTHON" - "$SELF" "$RUN" <<'LOCKPY'
import fcntl, os, signal, subprocess, sys, time
script, run = sys.argv[1:]
with open(os.path.join(run, '.duo_starting.lock'), 'a') as lockfile:
    until = time.monotonic() + 1200
    while True:
        try:
            fcntl.flock(lockfile, fcntl.LOCK_EX | fcntl.LOCK_NB)
            break
        except BlockingIOError:
            if time.monotonic() >= until:
                sys.exit('a load is still under way after 1200 s; its lock was not stolen')
            time.sleep(0.25)
    env = dict(os.environ, DUO_UP_LOCKED=run)
    child = subprocess.Popen(['/bin/bash', script, 'up'], env=env)
    def interrupted(signum, frame):
        child.send_signal(signum)
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    signal.signal(signal.SIGHUP, interrupted)
    try:
        sys.exit(child.wait())
    finally:
        # If this supervisor is interrupted, do not leave a loading script without its lock.
        if child.poll() is None:
            child.terminate()
            child.wait()
LOCKPY
  fi
  backend_ok && { echo "already loaded"; exit 0; }
  # A failed probe while a request is being generated is not permission to tear down a working pair. The gate
  # counts all requests; direct up is conservative too: an alive local engine requires an explicit restart.
  if pgrep -U "$(id -u)" -f "$(local_engine_regex)" >/dev/null; then
    echo "the engine is running but its API probe failed; leaving the pair alone (use restart explicitly)"
    exit 1
  fi
  down >/dev/null
  link_ips || exit 1
  if [ "$LOCAL_ROLE" = prefix ]; then
    echo "link: this Mac (prefix) $LIP <-> other Mac (suffix) $PIP   model $MODEL (VX1 $VX1, VX2 $VX2)"
    up_local_prefix || { down > /dev/null; exit 1; }
  else
    echo "link: this Mac (suffix) $LIP <-> other Mac (prefix) $PIP   model $MODEL (VX1 $VX1, VX2 $VX2)"
    up_local_suffix || { down > /dev/null; exit 1; }
  fi
  # (a failed load is unloaded again: half a pair would only hold memory. The logs stay.)
  backend_ok || { echo "the pair did not come up (logs: $RUN/prefix.log, $RUN/server.log, and engine.log in the suffix host's run folder)"; down > /dev/null; exit 1; } ;;
esac
