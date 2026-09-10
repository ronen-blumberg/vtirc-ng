#!/usr/bin/env bash
# tests/run_net.sh -- run the network integration tests against tests/fakeircd.py
#   tests/run_net.sh [base_port]
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
PORT=${1:-16667}
WORK=${TMPDIR:-/tmp}/vtirc_ng_fakeircd
FBC=${FBC:-/usr/local/bin/fbc}
mkdir -p "$ROOT/build/out/linux64"
(cd "$ROOT" && "$FBC" tests/test_net.bas -w all -gen gcc -g -exx -x build/out/linux64/test_net)
python3 "$ROOT/tests/fakeircd.py" "$PORT" "$WORK" > "$WORK.log" 2>&1 &
SRV=$!
trap 'kill $SRV 2>/dev/null || true' EXIT
for _ in $(seq 1 50); do
    grep -q "ready" "$WORK.log" 2>/dev/null && break
    sleep 0.1
done
"$ROOT/build/out/linux64/test_net" "$PORT"
