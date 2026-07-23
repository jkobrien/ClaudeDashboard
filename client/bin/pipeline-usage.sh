#!/usr/bin/env bash
# pipeline-usage.sh — per-stage real token capture for the portable pipeline.
#
# Portable copy of the pdp helper (source-of-truth: pdp scripts/dashboard/).
# macOS + Linux compatible: file sizes via a `stat` shim instead of GNU `stat -c`.
#
# Reads Anthropic SDK usage records directly from the local Claude Code
# transcripts in ~/.claude/projects/<project-slug>/*.jsonl. These contain the
# *real* per-message token counts (input_tokens, cache_creation_input_tokens,
# cache_read_input_tokens, output_tokens, model) returned by the API.
#
# Set CLAUDE_PROJECT_SLUG to the current repo's transcript slug, e.g.
#   -Users-jkobrien-code-AonSceal
#
# Modes:
#   snapshot <stage-id>   Record current byte length of every active jsonl file.
#   collect  <stage-id>   Diff against the snapshot, parse only new bytes, emit
#                         JSON { total, by_model, cost_usd } to stdout, then
#                         delete the snapshot.
#
# Pricing per million tokens (matches SKILL.md STEP 10):
#   opus    input  5    output 25   cache_read 0.50  cache_creation 6.25
#   sonnet  input  3    output 15   cache_read 0.30  cache_creation 3.75
#   haiku   input  1    output  5   cache_read 0.10  cache_creation 1.25
#
# Exit codes: 0 success, 2 bad usage, 3 no snapshot found for collect.

set -euo pipefail

PROJECT_SLUG="${CLAUDE_PROJECT_SLUG:--Users-jkobrien-code-AonSceal}"
PROJECT_DIR="${HOME}/.claude/projects/${PROJECT_SLUG}"
SNAP_DIR="${HOME}/.claude-dashboard/data/.snapshots"

mkdir -p "$SNAP_DIR"

# Portable file size in bytes. GNU: stat -c %s ; BSD/macOS: stat -f %z.
filesize() {
  stat -f '%z' "$1" 2>/dev/null || stat -c '%s' "$1" 2>/dev/null || echo 0
}

mode="${1:-}"
stage_id="${2:-}"

if [[ -z "$mode" || -z "$stage_id" ]]; then
  echo "usage: pipeline-usage.sh {snapshot|collect} <stage-id>" >&2
  exit 2
fi

# Sanitise stage_id to a safe filename
safe_id=$(printf '%s' "$stage_id" | tr -c 'A-Za-z0-9._-' '_')
snap_file="${SNAP_DIR}/${safe_id}.snap"

case "$mode" in
  snapshot)
    : > "$snap_file"
    if [[ -d "$PROJECT_DIR" ]]; then
      find "$PROJECT_DIR" -maxdepth 1 -name '*.jsonl' -mmin -60 -print0 2>/dev/null |
        while IFS= read -r -d '' f; do
          printf '%s\t%s\n' "$f" "$(filesize "$f")" >> "$snap_file"
        done
    fi
    ;;

  collect)
    if [[ ! -f "$snap_file" ]]; then
      echo "no snapshot for stage_id=$stage_id" >&2
      exit 3
    fi

    declare -A pre_size
    while IFS=$'\t' read -r f sz; do
      [[ -n "$f" ]] && pre_size["$f"]="$sz"
    done < "$snap_file"

    new_files=$(find "$PROJECT_DIR" -maxdepth 1 -name '*.jsonl' -mmin -60 -print0 2>/dev/null | tr '\0' '\n')

    {
      while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        start="${pre_size[$f]:-0}"
        cur="$(filesize "$f")"
        if (( cur > start )); then
          tail -c +$((start + 1)) "$f"
        fi
      done <<< "$new_files"
    } | jq -cs '
      def add_usage(a; b):
        {
          input:          ((a.input          // 0) + (b.input          // 0)),
          output:         ((a.output         // 0) + (b.output         // 0)),
          cache_read:     ((a.cache_read     // 0) + (b.cache_read     // 0)),
          cache_creation: ((a.cache_creation // 0) + (b.cache_creation // 0))
        };

      def price_for(model):
        if   (model | tostring | startswith("claude-opus"))   then { in: 5, out: 25, cr: 0.50, cc: 6.25 }
        elif (model | tostring | startswith("claude-sonnet")) then { in: 3, out: 15, cr: 0.30, cc: 3.75 }
        elif (model | tostring | startswith("claude-haiku"))  then { in: 1, out:  5, cr: 0.10, cc: 1.25 }
        else { in: 0, out: 0, cr: 0, cc: 0 } end;

      map(select(.type? == "assistant" and .message?.usage? != null and .message?.model? != null))
      | reduce .[] as $m (
          { total: { input:0, output:0, cache_read:0, cache_creation:0 },
            by_model: {},
            cost_usd: 0 };
          .total = add_usage(.total; {
            input:          ($m.message.usage.input_tokens          // 0),
            output:         ($m.message.usage.output_tokens         // 0),
            cache_read:     ($m.message.usage.cache_read_input_tokens     // 0),
            cache_creation: ($m.message.usage.cache_creation_input_tokens // 0)
          })
          | .by_model[$m.message.model] = add_usage(
              (.by_model[$m.message.model] // {}); {
                input:          ($m.message.usage.input_tokens          // 0),
                output:         ($m.message.usage.output_tokens         // 0),
                cache_read:     ($m.message.usage.cache_read_input_tokens     // 0),
                cache_creation: ($m.message.usage.cache_creation_input_tokens // 0)
              })
          | (price_for($m.message.model)) as $p
          | .cost_usd = (.cost_usd
              + ($m.message.usage.input_tokens          // 0) * $p.in  / 1000000
              + ($m.message.usage.output_tokens         // 0) * $p.out / 1000000
              + ($m.message.usage.cache_read_input_tokens     // 0) * $p.cr  / 1000000
              + ($m.message.usage.cache_creation_input_tokens // 0) * $p.cc  / 1000000)
        )
    '

    rm -f "$snap_file"
    ;;

  *)
    echo "unknown mode: $mode (expected snapshot|collect)" >&2
    exit 2
    ;;
esac
