#!/bin/bash
# Loopback tests of the chunked prompt path (this Mac only): a long prompt, then GEN tokens; prints the output's hash.
#   run.sh single LABEL CHUNK [N_TOKENS] [GEN]          one process, --prefill-chunk CHUNK (0: windows of 16; default: no flag)
#   run.sh duo    LABEL CHUNK [N_TOKENS] [GEN] [PORT]   worker + coordinator over 127.0.0.1:PORT
# Extra environment for the engines: DUO_ENV="K=V K2=V2"; for the worker only: WORKER_ENV="K=V"; COORD_ENV for the
# coordinator / single. LINK: the link's flags (default: --duo-certs <test certificates>). VRAM: --vram-experts (0.0).
# The exact comparison:  DUO_ENV="DS4_SUM_BY_EXPERT=1 DS4_SPEC_WASTE=1e9" run.sh single a 1024 ; ... run.sh duo b 1024
# Results: <out>/results.jsonl, logs: <out>/logs/. Needs DUO_TEST_TEXT. One model load (single) or two (duo) a run.
set -o pipefail
. "$(dirname "$0")/env.sh"
need_engine_env
[ -n "$TEXT" ] && [ -f "$TEXT" ] || { echo "set DUO_TEST_TEXT to a UTF-8 text file (60,000 characters or more)" >&2; exit 1; }
mode=$1; label=$2; chunk=$3; ntok=${4:-3200}; gen=${5:-48}; port=${6:-50100}
mkdir -p "$OUT/logs"
wait_for_memory
COMMON="--max-context 8192 --ssd-cache 0 --profile-readonly --prefill-chunk $chunk --vram-experts ${VRAM:-0.0}"
[ "$chunk" = default ] && COMMON="--max-context 8192 --ssd-cache 0 --profile-readonly --vram-experts ${VRAM:-0.0}"   # (no --prefill-chunk: the engine's default)
LINKF=${LINK:---duo-certs $CERTS}
envs=(); envflags=()
for kv in ${DUO_ENV:-}; do envs+=("$kv"); envflags+=(--env "$kv"); done
for kv in ${COORD_ENV:-}; do envflags+=(--env "$kv"); done
[ "$chunk" = 0 ] && { envs+=("DS4_NO_CHUNKS=1"); envflags+=(--env DS4_NO_CHUNKS=1); }
wpid=""
if [ "$mode" = duo ]; then
  # shellcheck disable=SC2086
  (cd "$(dirname "$EXE")" && exec env ${envs[@]+"${envs[@]}"} ${WORKER_ENV:-} "$EXE" --pack "$PK" $COMMON --duo-cut 20 --dspark none --vision off \
      --duo-listen "127.0.0.1:$port" --duo-allow 127.0.0.1 $LINKF > "$OUT/logs/$label.worker.log" 2>&1) &
  wpid=$!
  for i in $(seq 1 600); do grep -q "waiting on" "$OUT/logs/$label.worker.log" 2>/dev/null && break; kill -0 $wpid 2>/dev/null || break; sleep 1; done
  grep -q "waiting on" "$OUT/logs/$label.worker.log" || { echo "worker did not come up"; tail -5 "$OUT/logs/$label.worker.log"; exit 1; }
  COMMON="$COMMON --duo-cut 20 --duo-connect 127.0.0.1:$port $LINKF"
fi
# shellcheck disable=SC2086
"$PY" "$T/ds4_run.py" --exe "$EXE" --pack "$PK" --n "$gen" --label "$label" --long-file "$TEXT" --long-tokens "$ntok" --out "$OUT/results.jsonl" \
    --ids-out "$OUT/logs/$label.ids.txt" ${envflags[@]+"${envflags[@]}"} -- $COMMON 2> "$OUT/logs/$label.runner.err" | tee "$OUT/logs/$label.out.json"
if [ -n "$wpid" ]; then
  for i in $(seq 1 60); do kill -0 $wpid 2>/dev/null || break; sleep 1; done
  kill $wpid 2>/dev/null && echo "worker killed"
  wait $wpid 2>/dev/null
  echo "--- worker tail"; grep -E "^duo |ds4 duo|maya-ds4|forward_chunks|ds4 prompt stream" "$OUT/logs/$label.worker.log" | cut -c1-400 | tail -8
fi
