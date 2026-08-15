#!/usr/bin/env bash
# Claude Code subagent status line — one row per active subagent.
# Wired via the user-level `subagentStatusLine` setting (Claude Code v2.1.205+).
# Reads the subagent JSON payload on stdin (a `tasks` array + a `columns` width) and writes one
# JSON line per row to override: {"id":"<task id>","content":"<row body>"}. Rows are associated to
# subagents by `id`. Each row is: <Model> (<effort>) · ctx NN% · <description> · <tokens> — the
# model it resolved to (subtly colored, matching the main statusline's model color), with its
# effort level when set (a subagent's effort can differ from the orchestrator's), and its
# context-window usage lead the row as separate dot-joined segments, ctx% colored via the same
# gradient as the main statusline's ctx meter. Per-subagent cache-hit rate isn't offered: Claude
# Code only tracks a single rolling token count per subagent internally, with no cache-read/
# cache-creation/input breakdown to compute a hit rate from — unlike the main session's usage
# object the main statusline's cache meter reads. The task's description (Claude Code never sends
# override scripts a subagent role/type name, e.g. "general-purpose" or "Explore" — only `type`,
# always the constant "local_agent" — so description is the closest stand-in for one) sits in the
# middle; raw token consumption trails at the end. Fields omitted until resolved degrade gracefully.

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

# Join non-empty args with " · "; skips empty args instead of leaving a stray separator.
join_dot() {
     local out="" a
     for a in "$@"; do
             [ -z "$a" ] && continue
             if [ -n "$out" ]; then out="${out} · ${a}"; else out="$a"; fi
     done
     printf '%s' "$out"
}

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

# One JSON line per task, associated by id. Tasks without an id are skipped. `effort` may arrive as
# either {level:"high"} (mirroring the main payload's `.effort.level`) or a bare string, depending
# on the task's source — normalized to a plain string here either way.
# Fields are \x1f (Unit Separator)-joined rather than @tsv/tab: tab is POSIX "IFS whitespace", so
# `IFS=$'\t' read` silently collapses runs of empty/adjacent tab fields (e.g. a task with no
# `description` yet) and shifts every field after it. \x1f isn't blank-classified, so empty fields
# round-trip correctly.
printf '%s' "$JSON" | jq -r '
     .tasks[]?
     | select(.id != null)
     | [ .id, (.description // ""),
         (.model // ""),
         (if (.effort | type) == "object" then (.effort.level // "") else (.effort // "") end),
         (.tokenCount // ""), (.contextWindowSize // "") ]
     | join("")' | while IFS=$'\x1f' read -r id desc model effort tok ctxsize; do
     disp="$(fmt_model_name "$model")"
     model_str="$disp"
     [ -n "$effort" ] && model_str="${disp} (${effort})"
     model_content="$(printf '%s%s%s' "$C_CYAN" "$model_str" "$RESET")"

     ctx_plain=""
     ctx_content=""
     if is_num "$tok" && is_num "$ctxsize" && [ "$ctxsize" -gt 0 ]; then
             pct=$((tok * 100 / ctxsize))
             [ "$pct" -lt 0 ] && pct=0
             [ "$pct" -gt 100 ] && pct=100
             cc="$(gradient_worse "$pct" 40 65)"
             ctx_plain="ctx ${pct}%"
             ctx_content="$(printf '%sctx %d%%%s' "$cc" "$pct" "$RESET")"
     fi
     # Model(+effort) and ctx% are separate dot-joined segments, the row's leading part.
     lead_plain="$(join_dot "$model_str" "$ctx_plain")"
     lead_content="$(join_dot "$model_content" "$ctx_content")"

     tok_plain=""
     tok_content=""
     if is_num "$tok"; then
             tok_plain="$(fmt_k "$tok") tok"
             tok_content="$(printf '%s%s%s' "$C_VAL" "$tok_plain" "$RESET")"
     fi

     plain="$(join_dot "$lead_plain" "$desc" "$tok_plain")"
     content="$(join_dot "$lead_content" "$desc" "$tok_content")"

     # Truncate to the payload width. The leading model+ctx and trailing token count are the point
     # of this override, so when it's too tight to fit everything, shrink the description in the
     # middle first (with an ellipsis) rather than right-truncating and silently dropping either end.
     if [ "$COLUMNS_W" -gt 0 ] && [ "${#plain}" -gt "$COLUMNS_W" ]; then
             if [ -n "$desc" ]; then
                     # Reserve room for lead/tok plus a " · " separator (3 chars) per boundary
                     # that will actually be present around the (possibly truncated) description.
                     seps=1
                     [ -n "$tok_plain" ] && seps=2
                     avail=$((COLUMNS_W - ${#lead_plain} - ${#tok_plain} - seps * 3))
                     if [ "$avail" -gt 1 ]; then
                             desc_trunc="${desc:0:avail-1}…"
                             plain="$(join_dot "$lead_plain" "$desc_trunc" "$tok_plain")"
                             content="$(join_dot "$lead_content" "$desc_trunc" "$tok_content")"
                     else
                             content="${plain:0:COLUMNS_W}"
                     fi
             else
                     content="${plain:0:COLUMNS_W}"
             fi
     fi

     jq -nc --arg id "$id" --arg content "$content" '{id:$id,content:$content}'
done
