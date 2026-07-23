#!/usr/bin/env bash
#
# export-usage.sh — summarise this machine's Claude Code usage for the hub.
#
#   export-usage.sh [output-file]
#
# Runs ccusage against the LOCAL transcripts and writes a compact, machine-tagged
# summary. Default output: ~/.claude-dashboard/data/usage-<machine>.json
#
# Why a summary rather than the raw data: the transcripts in ~/.claude/projects
# run to hundreds of megabytes per machine (762 MB on the reference Mac) and are
# full conversation history, not just numbers. The computed summary is ~30 KB.
# Only the summary leaves the machine.
#
# ── Slug normalisation ────────────────────────────────────────────────────────
# ccusage reports `sessionId` as the project slug, which encodes the ABSOLUTE
# path: the same repo is `-Users-jkobrien-code-PDP` on macOS and
# `-home-jkobrien-code-PDP` on Linux. Merging without normalising would show one
# repo as two. We resolve each slug to a repo name so per-repo cost aggregates
# correctly across the fleet.
#
set -uo pipefail

MACHINE="$(hostname -s 2>/dev/null || hostname)"
DATA_DIR="${CLAUDE_DASHBOARD_DATA:-$HOME/.claude-dashboard/data}"
OUT="${1:-$DATA_DIR/usage-$(echo "$MACHINE" | tr '[:upper:]' '[:lower:]').json}"

# ccusage: prefer the dashboard's own copy, else anything on PATH.
CCUSAGE=""
for c in "$HOME/code/ClaudeDashboard/node_modules/.bin/ccusage" \
         "$HOME/code/claude-dashboard/node_modules/.bin/ccusage" \
         "$(command -v ccusage 2>/dev/null || true)"; do
  [ -n "$c" ] && [ -x "$c" ] && { CCUSAGE="$c"; break; }
done
[ -n "$CCUSAGE" ] || { echo "export-usage: ccusage not found (npm install in the dashboard repo)" >&2; exit 1; }

mkdir -p "$(dirname "$OUT")"

# CODE_ROOT lets us resolve a slug back to a real repo directory.
[ -f "$HOME/.claude-env" ] && . "$HOME/.claude-env"
: "${CODE_ROOT:=$HOME/code}"

# Write ccusage output to temp files and pass the paths. Piping two JSON blobs
# into one stdin needs a separator, and any byte you pick can appear in the data
# or upset the reader — files avoid the question entirely.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

"$CCUSAGE" session --json >"$TMP/sessions.json" 2>/dev/null || true
"$CCUSAGE" daily   --json >"$TMP/daily.json"    2>/dev/null || true

[ -s "$TMP/sessions.json" ] || { echo "export-usage: ccusage returned nothing" >&2; exit 1; }

python3 - "$OUT" "$MACHINE" "$CODE_ROOT" "$TMP/sessions.json" "$TMP/daily.json" <<'PY'
import json, os, sys, datetime

out_path, machine, code_root, sessions_file, daily_file = sys.argv[1:6]

def load(path, key):
    try:
        with open(path) as f:
            return json.load(f).get(key) or []
    except Exception:
        return []

sessions = load(sessions_file, 'sessions')
daily    = load(daily_file, 'daily')

# Known repo names on this machine — used to resolve a slug to a real repo
# rather than string-splitting, which produces junk like "354" or "subagents".
known = set()
if os.path.isdir(code_root):
    for e in os.scandir(code_root):
        if e.is_dir() and os.path.isdir(os.path.join(e.path, '.git')):
            known.add(e.name)

def slug_to_repo(slug, project_path=""):
    """Resolve a ccusage slug/path to a repo name, or None if it isn't a repo."""
    for cand in (project_path or "", slug or ""):
        if not cand:
            continue
        parts = [p for p in cand.replace('\\', '/').replace('-', '/').split('/') if p]
        # longest match wins: prefer an exact known repo name
        for p in reversed(parts):
            if p in known:
                return p
    return None

by_repo, unattributed = {}, {"cost": 0.0, "tokens": 0, "slugs": []}
for s in sessions:
    repo = slug_to_repo(s.get('sessionId', ''), s.get('projectPath', ''))
    cost = float(s.get('totalCost') or 0)
    toks = int(s.get('totalTokens') or 0)
    if repo is None:
        unattributed["cost"] += cost
        unattributed["tokens"] += toks
        if s.get('sessionId'): unattributed["slugs"].append(s['sessionId'])
        continue
    r = by_repo.setdefault(repo, {"cost": 0.0, "tokens": 0, "models": set(), "sessions": 0})
    r["cost"] += cost; r["tokens"] += toks; r["sessions"] += 1
    for m in (s.get('modelsUsed') or []): r["models"].add(m)

for r in by_repo.values():
    r["models"] = sorted(r["models"])
    r["cost"] = round(r["cost"], 4)
unattributed["cost"] = round(unattributed["cost"], 4)
unattributed["slugs"] = sorted(set(unattributed["slugs"]))

doc = {
    "machine": machine,
    "generated_at": datetime.datetime.now(datetime.timezone.utc)
                        .isoformat(timespec="seconds").replace("+00:00", "Z"),
    "code_root": code_root,
    "totals": {
        "cost": round(sum(r["cost"] for r in by_repo.values()) + unattributed["cost"], 4),
        "tokens": sum(r["tokens"] for r in by_repo.values()) + unattributed["tokens"],
    },
    "by_repo": by_repo,
    "unattributed": unattributed,
    "daily": daily,
}
with open(out_path, 'w') as f:
    json.dump(doc, f, indent=2)
    f.write('\n')

print(f"  machine     : {machine}")
print(f"  repos       : {len(by_repo)}")
print(f"  total cost  : ${doc['totals']['cost']:.2f}")
if unattributed["cost"] > 0:
    print(f"  unattributed: ${unattributed['cost']:.2f} ({len(unattributed['slugs'])} slug(s))")
print(f"  written     : {out_path} ({os.path.getsize(out_path)} bytes)")
PY
