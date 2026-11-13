#!/bin/bash
# The Duo link's refusals and failure handling, no model: builds link_security.cpp against src/dsv41/ds4_duo.hpp and
# runs it over loopback (see the table in README.md for what it checks). About a minute: one check waits out the TLS
# handshake's 10 s deadline and one watches a stopped peer for 32 s.
#   link_security.sh [PORT]      (default 50180; it uses a few ports from there)
set -euo pipefail
. "$(dirname "$0")/env.sh"
PORT=${1:-50180}
SSL=$(cd "$(dirname "$OPENSSL")/.." && pwd)
[ -f "$SSL/lib/libssl.a" ] || { echo "no static OpenSSL at $SSL (run duo/build.sh, or set DUO_TEST_OPENSSL)" >&2; exit 1; }
[ -f "$CERTS/ca.crt" ] || bash "$T/make_test_certs.sh" > /dev/null
mkdir -p "$OUT"
clang++ -std=c++20 -O2 -DSTRATA_DUO_TLS=1 -I "$ROOT/src/dsv41" -isystem "$SSL/include" "$T/link_security.cpp" \
  "$SSL/lib/libssl.a" "$SSL/lib/libcrypto.a" -o "$OUT/link_security"
"$OUT/link_security" "$PORT" "$CERTS" "$OUT/link_security.sparse"
