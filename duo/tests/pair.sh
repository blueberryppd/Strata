#!/bin/bash
# One loopback Duo run on this Mac: a worker and a coordinator of the given engines, on 127.0.0.1:PORT (windowed path).
#   pair.sh LABEL WORKER_EXE COORD_EXE PORT "WORKER LINK FLAGS" "COORDINATOR LINK FLAGS" [ALLOW]
# e.g. pair.sh tls "$EXE" "$EXE" 50121 "--duo-certs $CERTS" "--duo-certs $CERTS"
#      pair.sh plain "$EXE" "$EXE" 50121 --duo-insecure --duo-insecure
# Logs: <out>/logs/LABEL.worker.log, LABEL.coord.log; the coordinator's record goes to <out>/results.jsonl.
# Loads the model twice on one Mac (a worker and a coordinator): use a pack that fits (README.md).
set -uo pipefail
. "$(dirname "$0")/env.sh"
need_engine_env
LABEL=$1; WEXE=$2; CEXE=$3; PORT=$4; WX=$5; CX=$6; ALLOW=${7:-127.0.0.1}
COMMON="--max-context 8192 --ssd-cache 0 --profile-readonly --prefill-chunk 0 --vram-experts 0.0 --duo-cut 20"
mkdir -p "$OUT/logs"; WL="$OUT/logs/$LABEL.worker.log"; CL="$OUT/logs/$LABEL.coord.log"
wait_for_memory
# shellcheck disable=SC2086
(cd "$(dirname "$WEXE")" && DS4_NO_CHUNKS=1 exec "$WEXE" --pack "$PK" $COMMON --dspark none --vision off --duo-listen "127.0.0.1:$PORT" --duo-allow "$ALLOW" $WX) > "$WL" 2>&1 &
W=$!
for i in $(seq 1 600); do grep -q "waiting on" "$WL" 2>/dev/null && break; kill -0 $W 2>/dev/null || break; sleep 0.2; done
# (ds4_run.py keeps the last lines of stderr only: the coordinator runs through a wrapper that keeps all of it)
CE="$OUT/logs/$LABEL.coord.stderr"; CW="$OUT/logs/$LABEL.coord.sh"; : > "$CE"
printf '#!/bin/bash\ncd %q && DS4_NO_CHUNKS=1 %q "$@" 2> %q; rc=$?; cat %q >&2; exit $rc\n' "$(dirname "$CEXE")" "$CEXE" "$CE" "$CE" > "$CW"; chmod +x "$CW"
if kill -0 $W 2>/dev/null; then
  # shellcheck disable=SC2086
  "$PY" "$T/ds4_run.py" --exe "$CW" --pack "$PK" --n "${N:-32}" --label "$LABEL" --out "$OUT/results.jsonl" -- $COMMON --duo-connect "127.0.0.1:$PORT" $CX > "$CL" 2>&1
  for i in $(seq 1 25); do kill -0 $W 2>/dev/null || break; sleep 0.2; done   # (a refused coordinator leaves the worker waiting)
fi
if kill -0 $W 2>/dev/null; then kill $W; WSTATE="still waiting, killed"; wait $W 2>/dev/null; else wait $W; WSTATE="exit $?"; fi
echo "== $LABEL: worker $WSTATE"
grep -E "ds4 duo:|maya-ds4:|duo prefix: [0-9]+ windows" "$WL" | sed 's/^/   worker: /'
grep -E "ds4 duo:|maya-ds4:|^decode:|^duo suffix" "$CE" | sed 's/^/   coord:  /'
grep -E '"rc"|"ids_sha"' "$CL" | tr -d '\n' | sed 's/^ */   coord:  /'; echo
