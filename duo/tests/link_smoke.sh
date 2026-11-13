#!/bin/bash
# The Duo link alone, no model: builds link_bench.cpp against src/dsv41/ds4_duo.hpp and runs it over loopback, plain
# and TLS. A worker thread answers each 36-byte call with a 92 KB hand-off, as a decode step does; the program prints
# the round trip's time. Proves: the TLS link of this source tree builds, the two role certificates are accepted in
# their roles, and what the link costs a token. About 10 seconds (plus a few seconds to compile).
#   link_smoke.sh [PORT] [ROUNDS] [CERTS_DIR]      (default: 50160, 5000, the test certificates of make_test_certs.sh)
# CERTS_DIR must hold ca.crt and BOTH role certificates and keys (both ends run in this one process).
set -euo pipefail
. "$(dirname "$0")/env.sh"
PORT=${1:-50160}; ROUNDS=${2:-5000}; C=${3:-$CERTS}
SSL=$(cd "$(dirname "$OPENSSL")/.." && pwd)
[ -f "$SSL/lib/libssl.a" ] || { echo "no static OpenSSL at $SSL (run duo/build.sh, or set DUO_TEST_OPENSSL)" >&2; exit 1; }
[ -f "$C/ca.crt" ] || bash "$T/make_test_certs.sh" > /dev/null
mkdir -p "$OUT"
clang++ -std=c++20 -O2 -DSTRATA_DUO_TLS=1 -I "$ROOT/src/dsv41" -isystem "$SSL/include" "$T/link_bench.cpp" \
  "$SSL/lib/libssl.a" "$SSL/lib/libcrypto.a" -o "$OUT/link_bench"
"$OUT/link_bench" "$PORT" "$ROUNDS"
"$OUT/link_bench" "$((PORT + 1))" "$ROUNDS" "$C"
