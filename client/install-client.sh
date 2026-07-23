#!/usr/bin/env bash
#
# install-client.sh — install the metrics client onto this machine.
#
#   ./client/install-client.sh
#
# Copies client/bin/*.sh to ~/.claude-dashboard/bin and ensures the data
# directory exists. Idempotent.
#
# This repo is the SINGLE SOURCE OF TRUTH for the client scripts. ClaudeSetup
# clones this repo during install and calls this script, so machines never carry
# their own copies — which is how the previous three-copy divergence happened.
#
# The dashboard SERVER (server.js) is separate: install it only on the hub, with
# `npm install && node server.js`.
#
set -uo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/bin"
DEST="${CLAUDE_DASHBOARD_HOME:-$HOME/.claude-dashboard}"

ok()   { printf '\033[32m✓\033[0m %s\n' "$*"; }
info() { printf '\033[36m→\033[0m %s\n' "$*"; }
warn() { printf '\033[33m!\033[0m %s\n' "$*"; }

info "installing metrics client → $DEST"

mkdir -p "$DEST/bin" "$DEST/data"

installed=0
for s in "$SRC"/*.sh; do
  [ -f "$s" ] || continue
  b="$(basename "$s")"
  if [ -f "$DEST/bin/$b" ] && cmp -s "$s" "$DEST/bin/$b"; then
    ok "$b already current"
  else
    cp "$s" "$DEST/bin/$b"
    chmod +x "$DEST/bin/$b"
    ok "installed $b"
    installed=$((installed+1))
  fi
done

# The metrics store is per-machine and accumulates; never clobber an existing one.
STORE="$DEST/data/pipeline-executions.json"
if [ ! -f "$STORE" ]; then
  printf '%s\n' '{"executions":[]}' > "$STORE"
  ok "initialised empty metrics store"
else
  n=$(python3 -c "
import json
try: print(len(json.load(open('$STORE')).get('executions',[])))
except Exception: print('?')" 2>/dev/null)
  ok "metrics store exists ($n executions) — left alone"
fi

echo
info "client installed. To collect and push:"
echo "    $DEST/bin/export-usage.sh          # summarise this machine's usage"
echo "    $DEST/bin/sync-metrics.sh [hub]    # push to the hub (default: mordor)"
echo
if command -v ccusage >/dev/null 2>&1 || [ -x "$(dirname "$SRC")/../node_modules/.bin/ccusage" ]; then
  ok "ccusage available"
else
  warn "ccusage not found — run 'npm install' in this repo for usage export"
fi
