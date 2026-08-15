#!/usr/bin/env bash
# Claude Code subagent status line — one row per active subagent.
# Wired via the user-level `subagentStatusLine` setting (Claude Code v2.1.205+).
# Reads the subagent JSON payload on stdin (a `tasks` array + a `columns` width) and writes one
# JSON line per row to override: {"id":"<task id>","content":"<row body>"}. Rows are associated to
# subagents by `id`. Each row shows: <name> · <Model> ctx NN% — ctx% colored with the same gradient
# as the main statusline's ctx meter. Fields omitted until resolved degrade gracefully.

JSON="$(cat)"
# Keep the last raw payload for debugging (best-effort).
printf '%s' "$JSON" >"$HOME/.claude/subagent-statusline-last-payload.json" 2>/dev/null || true

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=scripts/statusline-lib.sh
. "$LIB_DIR/statusline-lib.sh"

# Terminal width for truncation (payload-provided; 0 = no limit).
COLUMNS_W="$(printf '%s' "$JSON" | jq -r '(.columns // 0) | floor' 2>/dev/null)"
case $COLUMNS_W in ''|*[!0-9]*) COLUMNS_W=0 ;; esac

is_num() { case $1 in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

# Model id -> display name: claude-sonnet-5 -> Sonnet-5, claude-opus-4-8 -> Opus-4.8,
# claude-haiku-4-5-20251001 -> Haiku-4.5. Unrecognized -> raw id; empty -> "—".
fmt_model_name() { # $1 model id
     local id=$1 rest family ver
     [ -z "$id" ] && { printf '—'; return; }
     case $id in
             claude-*) rest=${id#claude-} ;;
             *) printf '%s' "$id"; return ;;
     esac
     rest=$(printf '%s' "$rest" | sed -E 's/-[0-9]{8}$//')  # drop a trailing 8-digit date token
     family=${rest%%-*}
     ver=${rest#*-}
     [ "$ver" = "$rest" ] && ver=""                          # no version tokens
     family="$(printf '%s' "${family:0:1}" | tr '[:lower:]' '[:upper:]')${family:1}"
     if [ -n "$ver" ]; then printf '%s-%s' "$family" "${ver//-/.}"; else printf '%s' "$family"; fi
}

# One JSON line per task, associated by id. Tasks without an id are skipped.
printf '%s' "$JSON" | jq -r '
     .tasks[]?
     | select(.id != null)
     | [ .id, (.name // ""), (.model // ""), (.tokenCount // ""), (.contextWindowSize // "") ]
     | @tsv' | while IFS=$'\t' read -r id name model tok ctxsize; do
     disp="$(fmt_model_name "$model")"
     plain="${name} · ${disp}"
     content="${name} · ${disp}"
     if is_num "$tok" && is_num "$ctxsize" && [ "$ctxsize" -gt 0 ]; then
             pct=$((tok * 100 / ctxsize))
             [ "$pct" -lt 0 ] && pct=0
             [ "$pct" -gt 100 ] && pct=100
             cc="$(gradient_worse "$pct" 40 65)"
             plain="${plain} ctx ${pct}%"
             content="${content} $(printf '%sctx %d%%%s' "$cc" "$pct" "$RESET")"
     fi
     # Truncate to the payload width: if the plain (visible) text overflows, emit the plain text
     # truncated — never a partial ANSI escape. Fits -> keep the colored content.
     if [ "$COLUMNS_W" -gt 0 ] && [ "${#plain}" -gt "$COLUMNS_W" ]; then
             content="${plain:0:COLUMNS_W}"
     fi
     jq -nc --arg id "$id" --arg content "$content" '{id:$id,content:$content}'
done
