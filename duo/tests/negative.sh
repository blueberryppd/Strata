#!/bin/bash
# Negative tests of the TLS link on loopback: every peer below must be refused.  One TLS worker (the test certificates)
# stays up for the openssl clients - a refused peer leaves it waiting - then engine-against-engine pairs.
#   negative.sh [PORT]     (needs make_test_certs.sh first; C7 needs a plain build: duo/build.sh --plain)
# Loads the model about a dozen times, one or two at a time: the longest of the tests.
set -uo pipefail
. "$(dirname "$0")/env.sh"
need_engine_env
C=$CERTS; O=$OPENSSL; PORT=${1:-50125}
[ -f "$C/ca.crt" ] && [ -d "$OUT/ca2" ] || { echo "run make_test_certs.sh first" >&2; exit 1; }
COMMON="--max-context 8192 --ssd-cache 0 --profile-readonly --prefill-chunk 0 --vram-experts 0.0 --duo-cut 20"
D=$(dirname "$EXE")
mkdir -p "$OUT/logs"; WL="$OUT/logs/neg.worker.log"
echo "##### A. Duo started with neither --duo-certs nor --duo-insecure (worker, then coordinator)"
# shellcheck disable=SC2086
(cd "$D" && "$EXE" --pack "$PK" $COMMON --dspark none --vision off --duo-listen "127.0.0.1:$PORT" --duo-allow 127.0.0.1; echo "   exit $?") 2>&1 | sed 's/^/   /'
# shellcheck disable=SC2086
(cd "$D" && "$EXE" --pack "$PK" $COMMON --dspark none --vision off --ids 1,2,3 --n 1 --duo-connect "127.0.0.1:$PORT"; echo "   exit $?") 2>&1 | sed 's/^/   /'

echo "##### B. openssl s_client against a live TLS worker"
# shellcheck disable=SC2086
(cd "$D" && DS4_NO_CHUNKS=1 exec "$EXE" --pack "$PK" $COMMON --dspark none --vision off --duo-listen "127.0.0.1:$PORT" --duo-allow 127.0.0.1 --duo-certs "$C") > "$WL" 2>&1 &
W=$!
for i in $(seq 1 600); do grep -q "waiting on" "$WL" 2>/dev/null && break; sleep 0.2; done
BASE=(-connect "127.0.0.1:$PORT" -CAfile "$C/ca.crt" -servername strata-stage-worker -verify_hostname strata-stage-worker -alpn strata-duo-1)
client() {   # NAME, then s_client's arguments: the client's own lines, then what the worker said of it
  local name=$1; shift; local before; before=$(wc -l < "$WL")
  echo "--- $name"
  (sleep 1.5) | "$O" s_client "$@" 2>&1 | grep -aE "alert|error|^New, |Verify return|Verification|ALPN protocol|DUOTLS" | head -6 | sed 's/^/   client: /'
  sleep 0.3; tail -n +$((before + 1)) "$WL" | sed 's/^/   worker: /'
  kill -0 $W 2>/dev/null && echo "   (worker still waiting)" || echo "   (WORKER GONE)"
}
client "B1 no client certificate" "${BASE[@]}"
client "B2 TLS 1.2-only client (coordinator certificate)" "${BASE[@]}" -cert "$C/strata-stage-coordinator.crt" -key "$C/strata-stage-coordinator.key" -tls1_2
client "B3 wrong role: the WORKER's certificate presented by a client" "${BASE[@]}" -cert "$C/strata-stage-worker.crt" -key "$C/strata-stage-worker.key"
client "B4 a coordinator certificate of a different CA" "${BASE[@]}" -cert "$OUT/ca2/strata-stage-coordinator.crt" -key "$OUT/ca2/strata-stage-coordinator.key"
client "B5 the right certificate, no ALPN strata-duo-1" -connect "127.0.0.1:$PORT" -CAfile "$C/ca.crt" -servername strata-stage-worker -cert "$C/strata-stage-coordinator.crt" -key "$C/strata-stage-coordinator.key"
echo "--- B6 a peer that connects and says nothing (dropped after the handshake's 10 s)"
before=$(wc -l < "$WL"); (sleep 12) | nc 127.0.0.1 "$PORT" > /dev/null 2>&1; tail -n +$((before + 1)) "$WL" | sed 's/^/   worker: /'
echo "--- B7 (control, must PASS the TLS checks: the right certificate; the worker then ends on the client's non-Duo bytes)"
before=$(wc -l < "$WL")
(sleep 1.5) | "$O" s_client "${BASE[@]}" -cert "$C/strata-stage-coordinator.crt" -key "$C/strata-stage-coordinator.key" 2>&1 | grep -aE "^New, |Verification|ALPN protocol|DUOTLS|Peer signature type|Negotiated TLS1.3 group" | sed 's/^/   client: /'
for i in $(seq 1 25); do kill -0 $W 2>/dev/null || break; sleep 0.2; done
kill -0 $W 2>/dev/null && { kill $W; echo "   (worker killed)"; }; wait $W 2>/dev/null
tail -n +$((before + 1)) "$WL" | grep -E "ds4 duo|maya-ds4" | sed 's/^/   worker: /'

echo "##### C. engine against engine (pair.sh)"
echo "--- C1 the coordinator holds the worker's certificate under its own file names (wrong role, caught on the coordinator before the wire)"
"$T/pair.sh" neg-swap "$EXE" "$EXE" "$PORT" "--duo-certs $C" "--duo-certs $OUT/swap"
echo "--- C2 the coordinator's directory is a different CA's (it refuses the worker; the worker sees its alert)"
"$T/pair.sh" neg-ca2 "$EXE" "$EXE" "$PORT" "--duo-certs $C" "--duo-certs $OUT/ca2"
echo "--- C3 the coordinator trusts the real CA but presents a different CA's coordinator certificate (the worker refuses it)"
"$T/pair.sh" neg-ca2mix "$EXE" "$EXE" "$PORT" "--duo-certs $C" "--duo-certs $OUT/ca2mix"
echo "--- C4 the coordinator's address is outside --duo-allow (the worker admits 127.0.0.2, the coordinator comes from 127.0.0.1)"
"$T/pair.sh" neg-allow "$EXE" "$EXE" "$PORT" "--duo-certs $C" "--duo-certs $C" 127.0.0.2
echo "--- C5 a plain (--duo-insecure) coordinator against a TLS worker"
"$T/pair.sh" neg-plain-to-tls "$EXE" "$EXE" "$PORT" "--duo-certs $C" "--duo-insecure"
echo "--- C6 a TLS coordinator against a plain (--duo-insecure) worker"
"$T/pair.sh" neg-tls-to-plain "$EXE" "$EXE" "$PORT" "--duo-insecure" "--duo-certs $C"
echo "--- C7 the default build (TLS off) given --duo-certs"
if [ -x "$PLAIN_EXE" ]; then
  # shellcheck disable=SC2086
  (cd "$(dirname "$PLAIN_EXE")" && "$PLAIN_EXE" --pack "$PK" $COMMON --dspark none --vision off --duo-listen "127.0.0.1:$PORT" --duo-allow 127.0.0.1 --duo-certs "$C"; echo "   exit $?") 2>&1 | sed 's/^/   /'
else echo "   skipped: no plain build at $PLAIN_EXE (duo/build.sh --plain)"; fi
echo "--- C8 the coordinator against a server that holds a COORDINATOR certificate of the real CA (wrong role on the worker's side)"
(sleep 40 | "$O" s_server -accept "127.0.0.1:$PORT" -cert "$C/strata-stage-coordinator.crt" -key "$C/strata-stage-coordinator.key" -CAfile "$C/ca.crt" -Verify 1 -alpn strata-duo-1 -tls1_3 -naccept 1 > "$OUT/logs/neg.s_server.log" 2>&1) &
S=$!; sleep 1
# shellcheck disable=SC2086
(cd "$D" && "$EXE" --pack "$PK" $COMMON --dspark none --vision off --ids 1,2,3 --n 1 --duo-connect "127.0.0.1:$PORT" --duo-certs "$C" 2>&1 | grep -E "ds4 duo:|maya-ds4:" | sed 's/^/   coord:  /')
pkill -P $S 2>/dev/null; wait $S 2>/dev/null
grep -aE "alert|error" "$OUT/logs/neg.s_server.log" | head -2 | sed 's/^/   server: /'
