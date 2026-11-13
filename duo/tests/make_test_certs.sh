#!/bin/bash
# Throwaway certificates for the loopback tests (never use them for a real pair; they live in the tests' out folder).
#   make_test_certs.sh          writes into $DUO_TEST_OUT (default duo/tests/out):
#     certs/    one CA, both role certificates and keys in ONE folder (on loopback both engines read the same folder)
#     ca2/      a SECOND CA with the same two role names (a certificate of a different CA)
#     ca2mix/   trusts the first CA but presents the second CA's coordinator certificate
#     swap/     the first CA, with the WORKER's certificate and key under the coordinator's file names (the wrong role)
#     short/    the first set under the short names the link also reads (worker.crt/.key, coordinator.crt/.key)
# Takes a few seconds. Needs OpenSSL 3 (duo/build.sh builds one).
set -euo pipefail
. "$(dirname "$0")/env.sh"
[ -x "$OPENSSL" ] || { echo "no OpenSSL 3 at $OPENSSL (run duo/build.sh, or set DUO_TEST_OPENSSL)" >&2; exit 1; }
mkdir -p "$OUT"
rm -rf "$OUT/gen" "$OUT/gen2" "$OUT/certs" "$OUT/ca2" "$OUT/ca2mix" "$OUT/swap" "$OUT/short"
OPENSSL="$OPENSSL" DAYS=7 bash "$ROOT/duo/gen_certs.sh" "$OUT/gen" > /dev/null
OPENSSL="$OPENSSL" DAYS=7 bash "$ROOT/duo/gen_certs.sh" "$OUT/gen2" > /dev/null
umask 077
mkdir -p "$OUT/certs" "$OUT/ca2" "$OUT/ca2mix" "$OUT/swap" "$OUT/short"
cp -p "$OUT/gen/prefix/"* "$OUT/gen/suffix/"* "$OUT/certs/"
cp -p "$OUT/gen2/prefix/"* "$OUT/gen2/suffix/"* "$OUT/ca2/"
rm -rf "$OUT/gen" "$OUT/gen2"   # (with them the two CA keys: nothing more is issued)
ln -s "$OUT/certs/ca.crt" "$OUT/ca2mix/ca.crt"
ln -s "$OUT/ca2/strata-stage-coordinator.crt" "$OUT/ca2mix/"; ln -s "$OUT/ca2/strata-stage-coordinator.key" "$OUT/ca2mix/"
ln -s "$OUT/certs/ca.crt" "$OUT/swap/ca.crt"
ln -s "$OUT/certs/strata-stage-worker.crt" "$OUT/swap/strata-stage-coordinator.crt"
ln -s "$OUT/certs/strata-stage-worker.key" "$OUT/swap/strata-stage-coordinator.key"
ln -s "$OUT/certs/ca.crt" "$OUT/short/ca.crt"
for r in worker coordinator; do for e in crt key; do ln -s "$OUT/certs/strata-stage-$r.$e" "$OUT/short/$r.$e"; done; done
for d in certs ca2; do
  for r in strata-stage-worker strata-stage-coordinator; do
    printf '%s/%s.crt: ' "$d" "$r"; "$OPENSSL" x509 -in "$OUT/$d/$r.crt" -noout -ext subjectAltName | tail -1 | tr -d ' '
  done
done
echo "test certificates in $OUT"
