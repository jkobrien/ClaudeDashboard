#!/usr/bin/env bash
# record-pipeline-execution.sh — file-locked append to pipeline-executions.json.
#
# Portable copy of the pdp helper (source-of-truth: pdp scripts/dashboard/).
# Storage model is identical: a single shared store, one record per task,
# machine-keyed. This copy is macOS + Linux portable (GNU-only `date %N` removed).
#
# Takes a fully-formed execution record on stdin (or --record-file PATH),
# acquires an advisory lock on the metrics file, validates, appends to
# `.executions`, writes back atomically, and emits the new record ID to stdout.
#
# Auto-injects:
#   - machine: short hostname
#   - recorded_at: current ISO8601 UTC time (separate from caller's `timestamp`)
#
# The caller's record passes through verbatim, so extra fields (e.g. `project`)
# are preserved.
#
# Env:
#   PIPELINE_METRICS_FILE   override the store path (default shared store below)
#
# Usage:
#   echo '<json>'                       | record-pipeline-execution.sh
#   record-pipeline-execution.sh --record-file path/to/record.json
#
# Exit codes: 0 success, 2 bad usage, 3 lock timeout, 4 invalid JSON.

set -euo pipefail

DATA_FILE="${PIPELINE_METRICS_FILE:-${HOME}/.claude-dashboard/data/pipeline-executions.json}"
LOCK_FILE="${DATA_FILE}.lock"
LOCK_TIMEOUT=15

record_file=""
if [[ "${1:-}" == "--record-file" ]]; then
  record_file="${2:-}"
  [[ -z "$record_file" ]] && { echo "missing path after --record-file" >&2; exit 2; }
  [[ ! -f "$record_file" ]] && { echo "record file not found: $record_file" >&2; exit 2; }
fi

# Read record
if [[ -n "$record_file" ]]; then
  record_json=$(cat "$record_file")
else
  record_json=$(cat)
fi

# Validate
if ! printf '%s' "$record_json" | jq -e . >/dev/null 2>&1; then
  echo "record is not valid JSON" >&2
  exit 4
fi

# Required fields
for field in id task_number plan status; do
  if ! printf '%s' "$record_json" | jq -e "has(\"$field\")" >/dev/null; then
    echo "record missing required field: $field" >&2
    exit 4
  fi
done

# Enrich. Portable ISO8601 UTC to the second (no GNU %N — macOS date lacks it).
machine=$(hostname -s 2>/dev/null || hostname)
recorded_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
enriched=$(printf '%s' "$record_json" | jq --arg m "$machine" --arg t "$recorded_at" \
  '. + {machine: $m, recorded_at: $t}')

# Acquire lock and append. flock is Linux-native; on macOS install via `brew install flock`.
mkdir -p "$(dirname "$DATA_FILE")"
if command -v flock >/dev/null 2>&1; then
  exec 9>"$LOCK_FILE"
  if ! flock -w "$LOCK_TIMEOUT" 9; then
    echo "could not acquire lock on $LOCK_FILE within ${LOCK_TIMEOUT}s" >&2
    exit 3
  fi
fi

# Initialise if needed
if [[ ! -s "$DATA_FILE" ]]; then
  echo '{"executions":[]}' > "$DATA_FILE"
fi

# Append + atomic rename
tmp=$(mktemp "${DATA_FILE}.XXXXXX")
trap 'rm -f "$tmp"' EXIT
jq --argjson rec "$enriched" '.executions += [$rec]' "$DATA_FILE" > "$tmp"
mv "$tmp" "$DATA_FILE"
trap - EXIT

# Emit ID for caller
printf '%s' "$enriched" | jq -r .id
