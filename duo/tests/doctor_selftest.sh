#!/bin/bash
# `duo.sh doctor` against settings whose PEER cannot be reached: it must finish, report the peer as unreachable with a
# fix, check this Mac anyway, mark the other Mac's checks as skipped, change nothing and exit 1.
#   doctor_selftest.sh [SCRATCH_DIR]      (default: a new temporary folder, removed at the end)
# About 20 seconds (two connection timeouts). No model, no second Mac.
set -uo pipefail
T=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$T/../.." && pwd)
S=${1:-$(mktemp -d "${TMPDIR:-/tmp}/duo-doctor-selftest.XXXXXX")}
mkdir -p "$S"
cat > "$S/duo.conf" <<EOF
PEER="nobody@192.0.2.1"            # (192.0.2.0/24 is reserved for documentation: nothing answers there)
LOCAL_ROLE=prefix
PEER_DIR="~/strata-duo"
LOCAL_PACK="$S/no such pack/it's missing"
PEER_PACK="~/packs/x"
LOCAL_RUN="$S/run"
SUFFIX_CONTROL_DIR="/Applications/Strata.app/Contents/Resources/control"
APIPORT=8097; BACKPORT=8098; PORT=50178
EOF
before=$(ls -A "$S" | tr '\n' ' ')
out=$(DUO_CONF="$S/duo.conf" bash "$ROOT/duo/duo.sh" doctor 2>&1); rc=$?
printf '%s\n' "$out"
after=$(ls -A "$S" | tr '\n' ' ')
ok=1
[ "$rc" = 1 ] || { echo "SELFTEST FAIL: exit status $rc, wanted 1"; ok=0; }
printf '%s\n' "$out" | grep -q "^FAIL  ssh without a password" || { echo "SELFTEST FAIL: no FAIL line for ssh"; ok=0; }
printf '%s\n' "$out" | grep -q "^FAIL  Remote Login" || { echo "SELFTEST FAIL: no FAIL line for Remote Login"; ok=0; }
printf '%s\n' "$out" | grep -q "^SKIP  other Mac" || { echo "SELFTEST FAIL: the other Mac's checks are not marked skipped"; ok=0; }
printf '%s\n' "$out" | grep -q "this Mac: model pack" || { echo "SELFTEST FAIL: this Mac was not checked"; ok=0; }
printf '%s\n' "$out" | grep -q "^RESULT: " || { echo "SELFTEST FAIL: no RESULT line"; ok=0; }
printf '%s\n' "$out" | grep -qiE "unbound variable|syntax error|command not found" && { echo "SELFTEST FAIL: a shell error in the output"; ok=0; }
[ "$before" = "$after" ] || { echo "SELFTEST FAIL: doctor created files: $after"; ok=0; }
[ $# -ge 1 ] || rm -rf "$S"
[ "$ok" = 1 ] && echo "SELFTEST PASS: doctor fails cleanly with an unreachable peer (exit 1, nothing written)" || exit 1
