#!/usr/bin/env bash
#
# sync-metrics.sh — push this machine's metrics to the dashboard hub.
#
#   sync-metrics.sh [hub]            default hub: mordor
#
# Run on every machine (cron, or manually). Exports a fresh usage summary, then
# copies this machine's files to the hub over the tailnet.
#
# ── Why per-machine files rather than a shared append ─────────────────────────
# Three machines appending to one JSON over a network is a corruption risk — the
# local flock in record-pipeline-execution.sh protects local writers only. So
# each machine owns its own files on the hub:
#
#     <hub>:~/.claude-dashboard/data/usage-<machine>.json
#     <hub>:~/.claude-dashboard/data/pipeline-<machine>.json
#
# server.js merges them at read time. That is idempotent (a re-push overwrites)
# and degrades well: if the hub is offline the machine keeps recording locally
# and the next sync catches up. No queue, no partial writes.
#
# ── Transport ─────────────────────────────────────────────────────────────────
# The hub must be able to RECEIVE, which on a Tailscale fleet means it runs the
# Tailscale SSH server — Linux only. macOS (sandboxed GUI build) and Windows
# cannot, which is precisely why the Linux box is the hub. Every other machine
# only needs to be an SSH *client*, which all of them can be.
#
set -uo pipefail

HUB="${1:-${CLAUDE_METRICS_HUB:-mordor}}"
MACHINE_RAW="$(hostname -s 2>/dev/null || hostname)"
MACHINE="$(echo "$MACHINE_RAW" | tr '[:upper:]' '[:lower:]')"
DATA_DIR="${CLAUDE_DASHBOARD_DATA:-$HOME/.claude-dashboard/data}"
BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REMOTE_DIR=".claude-dashboard/data"

ok()   { printf '\033[32m✓\033[0m %s\n' "$*"; }
info() { printf '\033[36m→\033[0m %s\n' "$*"; }
warn() { printf '\033[33m!\033[0m %s\n' "$*"; }
die()  { printf '\033[31m✗\033[0m %s\n' "$*" >&2; exit 1; }

info "machine: $MACHINE   hub: $HUB"

# --- 1. refresh this machine's usage summary --------------------------------
if [ -x "$BIN_DIR/export-usage.sh" ]; then
  "$BIN_DIR/export-usage.sh" "$DATA_DIR/usage-$MACHINE.json" >/dev/null 2>&1 \
    && ok "exported usage-$MACHINE.json" \
    || warn "usage export failed (ccusage missing?) — syncing whatever exists"
else
  warn "export-usage.sh not found next to this script"
fi

# --- 2. name the pipeline store per machine ---------------------------------
# The local store is machine-agnostic; the hub copy must not be, or three
# machines would overwrite each other.
LOCAL_PIPELINE="$DATA_DIR/pipeline-executions.json"
STAGED_PIPELINE="$DATA_DIR/pipeline-$MACHINE.json"
[ -f "$LOCAL_PIPELINE" ] && cp "$LOCAL_PIPELINE" "$STAGED_PIPELINE"

# --- 3. am I the hub? -------------------------------------------------------
if [ "$MACHINE" = "$(echo "$HUB" | tr '[:upper:]' '[:lower:]')" ]; then
  ok "this machine IS the hub — nothing to send"
  exit 0
fi

# --- 4. push ----------------------------------------------------------------
command -v tailscale >/dev/null 2>&1 || die "tailscale not installed"
tailscale status >/dev/null 2>&1     || die "tailscale is not running"

online=$(tailscale status --json 2>/dev/null | python3 -c "
import json,sys
h=sys.argv[1].lower()
d=json.load(sys.stdin)
for p in (d.get('Peer') or {}).values():
    if (p.get('HostName') or '').lower()==h:
        print('yes' if p.get('Online') else 'no'); break
else: print('missing')
" "$HUB")

case "$online" in
  missing) die "'$HUB' is not on this tailnet" ;;
  no)      warn "'$HUB' is offline — records stay local, next sync will catch up"; exit 0 ;;
esac

# macOS ships openrsync, which has no --mkpath. Create the remote directory over
# ssh first so this works with either openrsync or GNU rsync.
# -n stops ssh consuming this script's stdin.
ssh -n "$HUB" "mkdir -p ~/$REMOTE_DIR" 2>/dev/null \
  || die "cannot reach $HUB over SSH — is Tailscale SSH enabled there?"

sent=0
for f in "$DATA_DIR/usage-$MACHINE.json" "$STAGED_PIPELINE"; do
  [ -f "$f" ] || continue
  if rsync -q "$f" "$HUB:$REMOTE_DIR/$(basename "$f")" 2>/dev/null; then
    ok "sent $(basename "$f") ($(wc -c < "$f" | tr -d ' ') bytes)"
    sent=$((sent+1))
  else
    warn "failed to send $(basename "$f") — is Tailscale SSH enabled on $HUB?"
  fi
done

[ $sent -gt 0 ] && ok "synced $sent file(s) to $HUB" || die "nothing sent"
