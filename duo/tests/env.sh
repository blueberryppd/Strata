# Sourced by the loopback tests: where things are. Every value can be set in the environment.
#   DUO_TEST_EXE      the engine under test            (default: <checkout>/build-duo/strata_ds4)
#   DUO_TEST_PLAIN    a plain build (duo/build.sh --plain), for negative.sh's C7  (default: <checkout>/build-duo-plain/strata_ds4)
#   DUO_TEST_PACK     a DeepSeek V4.1 pack folder      (required by the engine tests; see README.md for the size to pick)
#   DUO_TEST_PYTHON   a Python with the `regex` package (required by the engine tests; Strata's own Python has it)
#   DUO_TEST_TEXT     a UTF-8 text file, 135,000 characters or more: the long prompts are cut from it
#   DUO_TEST_CERTS    a folder with ca.crt and BOTH role certificates and keys (default: <out>/certs, made by make_test_certs.sh)
#   DUO_TEST_OPENSSL  an OpenSSL 3 program             (default: <checkout>/.duo-deps/openssl/bin/openssl, built by duo/build.sh)
#   DUO_TEST_OUT      logs, results, test certificates (default: duo/tests/out; not tracked by git)
# The test scripts split their flag strings on spaces: use paths without spaces for these.
T=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$T/../.." && pwd)
EXE=${DUO_TEST_EXE:-$ROOT/build-duo/strata_ds4}
PLAIN_EXE=${DUO_TEST_PLAIN:-$ROOT/build-duo-plain/strata_ds4}
OUT=${DUO_TEST_OUT:-$T/out}
CERTS=${DUO_TEST_CERTS:-$OUT/certs}
OPENSSL=${DUO_TEST_OPENSSL:-$ROOT/.duo-deps/openssl/bin/openssl}
PK=${DUO_TEST_PACK:-}
PY=${DUO_TEST_PYTHON:-}
TEXT=${DUO_TEST_TEXT:-}
need_engine_env() {
  [ -x "$EXE" ] || { echo "no engine at $EXE (run duo/build.sh, or set DUO_TEST_EXE)" >&2; exit 1; }
  [ -n "$PK" ] && [ -f "$PK/ds4.txt" ] || { echo "set DUO_TEST_PACK to a DeepSeek V4.1 pack folder" >&2; exit 1; }
  [ -n "$PY" ] && [ -x "$PY" ] || { echo "set DUO_TEST_PYTHON to a Python with the regex package" >&2; exit 1; }
}
wait_for_memory() {   # two engines on one Mac: wait until a quarter of the memory is free
  local free
  while :; do
    free=$(memory_pressure | tail -1 | grep -oE '[0-9]+' | tail -1)
    [ "${free:-0}" -ge 25 ] && break
    echo "free memory ${free}%: waiting"; sleep 20
  done
}
