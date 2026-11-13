#!/bin/bash
# Create the private CA and the two role certificates of a Strata Duo pair.
#
#   duo/gen_certs.sh [OUT_DIR]        (default: duo/certs-new; refuses to write into a directory that has certificates)
#
# The engine's link is TLS 1.3 with mutual authentication (src/dsv41/ds4_duo.hpp). Each host has a directory
# (--duo-certs DIR) with ca.crt and its own role certificate and key. The role is the certificate's DNS subjectAltName:
#
#   prefix host (layers 0-19, listens):   strata-stage-worker.crt       strata-stage-worker.key
#   suffix host (layers 20-39, connects): strata-stage-coordinator.crt  strata-stage-coordinator.key
#
# This script writes three folders, so that each host's files can be copied as one folder and nothing else:
#
#   OUT_DIR/prefix/   ca.crt + the worker certificate and key        -> the prefix host's certificate directory
#   OUT_DIR/suffix/   ca.crt + the coordinator certificate and key   -> the suffix host's certificate directory
#   OUT_DIR/ca/       ca.crt + ca.key (the key that can issue new certificates: keep it offline or delete it)
#
# Needs OpenSSL 3 (macOS's own `openssl` is LibreSSL and cannot copy the extensions). duo/build.sh builds one; it is
# found in .duo-deps/openssl. Another one: OPENSSL=/path/to/openssl.
# Environment: DAYS (validity, default 365), DELETE_CA_KEY=1 (delete ca.key at the end: no certificate can be added
# later, a new set has to be made instead - which takes a minute).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")
OUT=${1:-"$HERE/certs-new"}
DAYS=${DAYS:-365}

OPENSSL=${OPENSSL:-}
if [ -z "$OPENSSL" ]; then
  for c in "${STRATA_DUO_OPENSSL_ROOT:-}/bin/openssl" "${STRATA_DUO_DEPS:-$ROOT/.duo-deps}/openssl/bin/openssl" "$(command -v openssl || true)"; do
    if [ -x "$c" ] && "$c" version 2>/dev/null | grep -q '^OpenSSL 3'; then OPENSSL=$c; break; fi
  done
fi
if [ -z "$OPENSSL" ] || ! "$OPENSSL" version 2>/dev/null | grep -q '^OpenSSL 3'; then
  echo "gen_certs.sh: OpenSSL 3 not found. Run duo/build.sh first (it builds one), or set OPENSSL=/path/to/openssl" >&2
  exit 1
fi
case "$DAYS" in ''|*[!0-9]*) echo "gen_certs.sh: DAYS must be a number" >&2; exit 2 ;; esac
if [ -e "$OUT/ca" ] || [ -e "$OUT/prefix" ] || [ -e "$OUT/suffix" ] || [ -e "$OUT/ca.crt" ]; then
  echo "gen_certs.sh: $OUT already holds certificates; choose another directory or remove it first" >&2
  exit 1
fi

umask 077
mkdir -p "$OUT/ca" "$OUT/prefix" "$OUT/suffix"
OUT=$(cd "$OUT" && pwd)
# (OpenSSL's "make install_sw" installs no openssl.cnf: req gets a minimal one)
CNF=$(mktemp "$OUT/req.XXXXXX"); trap 'rm -f "$CNF" "$OUT"/*.csr "$OUT/ca/ca.srl"' EXIT
printf '[req]\ndistinguished_name=dn\nprompt=no\n[dn]\n' > "$CNF"
export OPENSSL_CONF="$CNF"

"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days "$DAYS" -keyout "$OUT/ca/ca.key" -out "$OUT/ca/ca.crt" \
  -subj "/CN=strata-duo-private-ca" -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" 2>/dev/null
issue() {   # ROLE FOLDER
  "$OPENSSL" req -new -newkey rsa:2048 -nodes -keyout "$OUT/$2/$1.key" -out "$OUT/$1.csr" -subj "/CN=$1" \
    -addext "subjectAltName=DNS:$1" 2>/dev/null
  "$OPENSSL" x509 -req -in "$OUT/$1.csr" -CA "$OUT/ca/ca.crt" -CAkey "$OUT/ca/ca.key" -CAcreateserial -days "$DAYS" \
    -copy_extensions copy -out "$OUT/$2/$1.crt" 2>/dev/null
  rm -f "$OUT/$1.csr"
  cp "$OUT/ca/ca.crt" "$OUT/$2/ca.crt"
  "$OPENSSL" verify -CAfile "$OUT/$2/ca.crt" "$OUT/$2/$1.crt" >/dev/null
}
issue strata-stage-worker prefix
issue strata-stage-coordinator suffix
rm -f "$OUT/ca/ca.srl"
chmod 700 "$OUT" "$OUT/ca" "$OUT/prefix" "$OUT/suffix"
chmod 600 "$OUT"/ca/ca.key "$OUT"/prefix/*.key "$OUT"/suffix/*.key
chmod 644 "$OUT"/ca/ca.crt "$OUT"/prefix/*.crt "$OUT"/suffix/*.crt
if [ "${DELETE_CA_KEY:-0}" = 1 ]; then rm -P "$OUT/ca/ca.key" 2>/dev/null || rm -f "$OUT/ca/ca.key"; fi

echo "Certificates written (valid $DAYS days, until $("$OPENSSL" x509 -in "$OUT/prefix/strata-stage-worker.crt" -noout -enddate | cut -d= -f2)):"
( cd "$OUT" && ls -l ca prefix suffix | sed 's/^/  /' )
cat <<EOF

Where each folder goes (CERTS = the certificate directory of duo.conf: LOCAL_CERTS on this host, PEER_CERTS on the
other; by default <install directory>/duo/certs):

  1. The PREFIX host (layers 0-19) gets the three files of
       $OUT/prefix/
     ca.crt, strata-stage-worker.crt, strata-stage-worker.key.
     The worker key must never leave the prefix host.

  2. The SUFFIX host (layers 20-39, API server) gets the three files of
       $OUT/suffix/
     ca.crt, strata-stage-coordinator.crt, strata-stage-coordinator.key.
     The coordinator key must never leave the suffix host.

  For the host you are on:        mkdir -p CERTS && chmod 700 CERTS && cp -p "$OUT/<role>/"* CERTS/
  For the other host (over ssh):  ssh PEER 'mkdir -p CERTS && chmod 700 CERTS' && scp -p "$OUT/<role>/"* PEER:CERTS/
  Then remove the copied folders here:  rm -rf "$OUT/prefix" "$OUT/suffix"
  (a host should hold its own key only; duo.sh doctor reports a key that is on the wrong host)

  3. $OUT/ca/ca.key can sign new certificates for this pair. Neither host needs it to run.
     Move it to offline storage, or delete it (a new set is made in a minute):  rm -P "$OUT/ca/ca.key"
EOF
[ "${DELETE_CA_KEY:-0}" = 1 ] && echo "     (DELETE_CA_KEY=1: ca.key was deleted.)"
exit 0
