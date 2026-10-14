#!/bin/bash
# Repro harness for the reconnect loop (uses OPENBULB_TRACE hooks).
#
#   repro-stuck.sh [duration-s] [binary] [mode]
#
# Modes:
#   outage   — sustained lamp outage: config points at a dead routable IP and
#              the sandbox blocks TCP 6668 so rediscovery sweeps find nothing.
#              GREEN expectations: polls coalesced (op.start ≈ duration/5s),
#              at most ~1 sweep per 60s throttle window, state settles in
#              .offline and STAYS (no connecting/offline churn).
#              (Pre-fix RED: 7 sweeps in 100s, endless churn, never settles.)
#   selfheal — dead IP but network open: the first sweep must find the real
#              lamp, fix the config and return to .online (IP-change path).
#
# The sandbox also sidesteps the keychain ACL hang on bare-binary runs, so the
# app's config load can complete in both modes.
set -euo pipefail
cd "$(dirname "$0")/.."

DUR=${1:-100}
BIN=${2:-.build/release/OpenBulb}
MODE=${3:-outage}
LOG=/tmp/openbulb-repro.log
CFG="$HOME/Library/Application Support/OpenBulb/config.json"
PROFILE=$(mktemp /tmp/openbulb-sb.XXXXXX)

if [ "$MODE" = "outage" ]; then
  cat > "$PROFILE" <<'EOF'
(version 1)
(allow default)
(deny network-outbound (remote ip "*:6668"))
EOF
else
  cat > "$PROFILE" <<'EOF'
(version 1)
(allow default)
EOF
fi

osascript -e 'quit app "OpenBulb"' 2>/dev/null || true
sleep 1

cp "$CFG" /tmp/openbulb-config-backup.json
python3 - "$CFG" <<'EOF'
import json, sys
p = sys.argv[1]
cfg = json.load(open(p))
cfg["ip"] = "10.255.255.1"          # dead routable IP: real SYN timeouts
json.dump(cfg, open(p, "w"))
EOF
restore() { cp /tmp/openbulb-config-backup.json "$CFG"; }
trap 'restore; kill $APP 2>/dev/null || true' EXIT

: > "$LOG"
KEY=$(security find-generic-password -s com.lunaperegrina.openbulb -a device-local-key -w 2>/dev/null || true)
OPENBULB_TRACE=1 OPENBULB_TEST_POPOVER=1 OPENBULB_LOCAL_KEY="$KEY" \
  sandbox-exec -f "$PROFILE" "$BIN" >> "$LOG" 2>&1 &
APP=$!
sleep "$DUR"
kill $APP 2>/dev/null || true
sleep 1
restore

OPS=$(grep -c 'op.start' "$LOG" || true)
OK=$(grep -c 'op.ok' "$LOG" || true)
ERR=$(grep -c 'op.err' "$LOG" || true)
SCANS=$(grep -c 'scan.start' "$LOG" || true)
ONLINE=$(grep -c 'state .* -> online' "$LOG" || true)
echo "=== repro summary (${MODE}, ${DUR}s) ==="
echo "ops: $OPS   ok: $OK   failed: $ERR   sweeps: $SCANS   went-online: $ONLINE"
echo "--- state transition histogram ---"
grep 'state ' "$LOG" | sed 's/.*state //' | sort | uniq -c | sort -rn | head -10
echo "--- last 4 events ---"
tail -4 "$LOG"
echo "log: $LOG"
