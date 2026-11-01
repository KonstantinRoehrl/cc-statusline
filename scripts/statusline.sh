#!/usr/bin/env bash
# Claude Code statusline — 4-line dashboard, strict two-column grid.
# Reads the statusline JSON payload on stdin and prints four ANSI-colored lines:
#   left column        right column
#   1) model + effort  | folder · git branch
#   2) ctx meter        | rolling (5h) meter + reset clock
#   3) cache meter       | weekly meter + reset
#   4) lines +/- (session)
#
# ASCII/Unicode-block visualizers, no emojis. Color = health (green good, orange
# watch, red bad); for cache-hit the scale inverts since higher is better.
# All date/percentage math is done via jq/bash arithmetic.

JSON="$(cat)"
NOW="$(date +%s)"
# Keep the last raw payload for debugging / discovering new fields. Nothing reads it back; the
# group (not a bare `2>/dev/null` on the command) silences the shell's own "No such file" error.
{ printf '%s' "$JSON" >"$HOME/.claude/statusline-last-payload.json"; } 2>/dev/null || true
# Per-session rate-limit snapshots shared between concurrently running sessions (see limits_merge).
CACHE_DIR="${CC_STATUSLINE_CACHE_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/statusline-cache}"

# --- jq helper -------------------------------------------------------------
j() { printf '%s' "$JSON" | jq -r "$1" 2>/dev/null; }

# --- shared library (colors, gradient engine, meter primitives) ------------
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=scripts/statusline-lib.sh
. "$LIB_DIR/statusline-lib.sh"

# Claude Code builds `rate_limits` from this session's own last API response, so an idle session
# shows frozen numbers while other sessions keep spending. Each run therefore saves its snapshot to
# the cache dir and merges everyone's: the newest window wins and, within it, the highest usage
# (usage only grows inside a window). Best-effort throughout: any failure degrades to the payload.
limits_save() {
     local sid tmp
     sid="$(j '.session_id // empty')"
     sid="${sid//[^A-Za-z0-9_-]/_}"
     [ -n "$sid" ] || return 0
     {
          mkdir -p "$CACHE_DIR" || return 0
          tmp="$(mktemp "$CACHE_DIR/.limits.XXXXXX")" || return 0
          printf '%s' "$JSON" | jq -c '
               (.rate_limits // {}) | {five_hour, seven_day}
               | with_entries(select(.value | type == "object"))
               | map_values({used_percentage, resets_at})
               | select(length > 0)' >"$tmp"
          if [ -s "$tmp" ]; then mv -f "$tmp" "$CACHE_DIR/$sid.limits.json"; else rm -f "$tmp"; fi
     } 2>/dev/null
     return 0
}

# Snapshots older than the 7-day window can no longer matter.
limits_prune() {
     find "$CACHE_DIR" -maxdepth 1 -type f \( -name '*.limits.json' -o -name '.limits.*' \) -mtime +8 -delete 2>/dev/null
     return 0
}

# Merge all snapshots plus this payload; prints "<state> <pct> <resets_at>" for five_hour, then for
# seven_day. State is `ok`; `lapsed` (snapshots exist but every window has reset: 0 %, reset time
# unknown); or `absent` (no data anywhere). `awk 1` terminates every file with a newline so a
# truncated file cannot swallow its neighbour's line; unparsable lines are skipped.
limits_merge() {
     awk 1 "$CACHE_DIR"/*.limits.json 2>/dev/null |
          jq -nRr --argjson now "$NOW" --arg cur "$JSON" '
               def entries($k): [ .[] | .[$k]? | select(type == "object")
                    | select((.used_percentage | type) == "number" and (.resets_at | type) == "number")
                    | {p: (.used_percentage | floor), r: (.resets_at | floor)} ];
               def merged($k):
                    entries($k) as $all
                    | if ($all | length) == 0 then "absent 0 0"
                      else ($all | map(select(.r > $now))) as $live
                           | if ($live | length) == 0 then "lapsed 0 0"
                             else ($live | max_by(.r) | .r) as $r
                                  | "ok \($live | map(select(.r == $r) | .p) | max) \($r)"
                             end
                      end;
               [ inputs | fromjson? | select(type == "object") ]
                    + [ ($cur | fromjson? | .rate_limits? | select(type == "object")) ]
               | "\(merged("five_hour")) \(merged("seven_day"))"' 2>/dev/null
}

# Wall-clock reset formatter: epoch seconds -> local HH:MM (e.g. 10:50).
fmt_clock() { # $1 epoch seconds
     local epoch=${1:-0}
     [ "$epoch" -le 0 ] && { printf '%s' '--:--'; return; }
     # GNU date (Linux) takes `-d @epoch`; BSD/macOS date takes `-r epoch`.
     date -d "@$epoch" '+%H:%M' 2>/dev/null || date -r "$epoch" '+%H:%M' 2>/dev/null || printf '%s' '--:--'
}

# Weekday + wall-clock reset formatter: epoch seconds -> "Sat 18:00".
fmt_weekday_clock() { # $1 epoch seconds
     local epoch=${1:-0}
     [ "$epoch" -le 0 ] && { printf -- '--- --:--'; return; }
     # GNU date (Linux) takes `-d @epoch`; BSD/macOS date takes `-r epoch`.
     date -d "@$epoch" '+%a %H:%M' 2>/dev/null || date -r "$epoch" '+%a %H:%M' 2>/dev/null || printf -- '--- --:--'
}

# Rolling-window burn-rate warning: projects the wall-clock time the window's usage would hit 100%
# at the current pace, and prints a warning glyph only when that projection is earlier than the
# window's actual scheduled reset. Silent otherwise (missing data, a window too fresh to
# extrapolate from, on-pace, or already at/past 100%). Serves both the 5h and 7-day windows via the
# window length ($3) and reset formatter ($4).
burn_rate_warning() { # $1 pct(0-100)  $2 resets_at(epoch)  $3 window_len(sec)  $4 formatter-fn
     local pct=$1 resets_at=$2 window_len=$3 fmt=$4 now window_start elapsed remaining time_to_cap projected
     [ -z "$pct" ] && return
     [ -z "$resets_at" ] && return
     now=$(date +%s)
     window_start=$((resets_at - window_len))
     elapsed=$((now - window_start))
     [ "$elapsed" -lt 300 ] && return          # window too fresh to extrapolate
     [ "$pct" -lt 1 ] && return
     remaining=$((100 - pct))
     [ "$remaining" -le 0 ] && return           # already at/over cap
     time_to_cap=$((remaining * elapsed / pct))
     projected=$((now + time_to_cap))
     [ "$projected" -ge "$resets_at" ] && return  # on pace: silent
     printf '%s⚡%s%s' "$C_RED" "$("$fmt" "$projected")" "$RESET"
}

# --- gather fields ---------------------------------------------------------
MODEL="$(j '.model.display_name // "Claude"')"
EFFORT="$(j '.effort.level // empty')"

CWD="$(j '.workspace.current_dir // .cwd // empty')"
BRANCH=""
if [ -n "$CWD" ]; then
     BRANCH="$(git -C "$CWD" branch --show-current 2>/dev/null)"
fi
FOLDER="${CWD##*/}"
if [ -n "$BRANCH" ]; then
     DIRBRANCH="${FOLDER} · ${BRANCH}"
else
     DIRBRANCH="${FOLDER}"
fi
if [ "${#DIRBRANCH}" -gt 40 ]; then DIRBRANCH="${DIRBRANCH:0:39}…"; fi

# PR segment ("#42 ✓"), appended after the truncated folder · branch so it is never cut off.
# Claude Code sends `pr` only while an open PR exists; `kind: "mr"` marks a GitLab merge request.
PR_SEG=""
read -r PR_REF PR_STATE <<<"$(j '.pr | select(type == "object" and (.number | type) == "number")
     | "\(if .kind == "mr" then "!" else "#" end)\(.number | floor) \(.review_state // "-")"')"
if [ -n "$PR_REF" ]; then
     case "$PR_STATE" in
             approved) PR_MARK="${C_GREEN}✓" ;;
             changes_requested) PR_MARK="${C_RED}✗" ;;
             pending) PR_MARK="${C_LABEL}…" ;;
             draft) PR_MARK="${C_LABEL}◌" ;;
             *) PR_MARK="" ;;
     esac
     PR_SEG=" ${C_VAL}${PR_REF}${PR_MARK:+ }${PR_MARK}${RESET}"
fi

CTX_PCT="$(j '(.context_window.used_percentage // empty) | select(. != null) | floor')"

CACHE_PCT="$(j '
 (.context_window.current_usage) as $u
 | select($u != null)
 | (($u.cache_read_input_tokens // 0)) as $r
 | (($u.input_tokens // 0) + ($u.cache_creation_input_tokens // 0) + $r) as $den
 | select($den > 0)
 | ($r * 100 / $den) | floor')"

limits_save
limits_prune
read -r FH_STATE FH_PCT FH_RESETS_AT WK_STATE WK_PCT WK_RESETS_AT <<<"$(limits_merge)"
[ "${FH_STATE:-absent}" = absent ] && FH_PCT=""
[ "${WK_STATE:-absent}" = absent ] && WK_PCT=""

LINES_ADDED="$(j '.cost.total_lines_added // 0')"
LINES_REMOVED="$(j '.cost.total_lines_removed // 0')"
TOTAL_IN="$(j '.context_window.total_input_tokens // empty')"
TOTAL_OUT="$(j '.context_window.total_output_tokens // empty')"

LBLW=8
GUT="   "
METER_W=15 # mseg: 10-dot bar + space + 4-wide percentage
COL_W=20   # visible width of every left-column value: a meter plus room for " ◷NNm"

# Spaces completing a left-column value that already shows $1 visible characters.
col_pad() { printf '%*s' "$((COL_W > $1 ? COL_W - $1 : 0))" ''; }

# Prompt-cache countdown cell " ◷NNm" (exactly COL_W - METER_W visible chars) while the cache is
# warm; nothing otherwise. Red once 20% of the TTL is left (60 s when the TTL is not 5m/1h).
cache_countdown() {
     local expires ttl ttl_s left txt color
     expires="$(j '(.prompt_cache // empty) | select(type == "object" and .warm == true and .caching_observed != false)
             | (.expires_at // empty) | select(type == "number") | floor')"
     [ -n "$expires" ] || return 0
     left=$((expires - NOW))
     [ "$left" -gt 0 ] || return 0
     ttl="$(j '.prompt_cache.ttl // empty')"
     case "$ttl" in 5m) ttl_s=300 ;; 1h) ttl_s=3600 ;; *) ttl_s=0 ;; esac
     if [ "$left" -lt 60 ]; then txt='<1m'; else txt="$(((left + 59) / 60))m"; fi
     color="$C_LABEL"
     if [ "$ttl_s" -gt 0 ]; then
             [ $((left * 5)) -le "$ttl_s" ] && color="$C_RED"
     else
             [ "$left" -le 60 ] && color="$C_RED"
     fi
     printf ' %s◷%s%s%*s' "$color" "$txt" "$RESET" "$((COL_W - METER_W - 2 - ${#txt}))" ''
}

# Colored 4-wide right-justified percentage, e.g. " 62%".
pct4() { printf '%s%3d%%%s' "$2" "$1" "$RESET"; }

# Metric cell: "<label:8><10-dot bar> <pct4>" — 23 visible chars.
mseg() { # $1 label  $2 pct  $3 color
     printf '%s%-*s%s%s %s' \
             "$C_LABEL" "$LBLW" "$1" "$RESET" "$(bar "$2" 10 "$3")" "$(pct4 "$2" "$3")"
}
# Missing-metric cell of equal width: label(8) + "n/a" padded across the left-column value width.
mseg_na() { # $1 label
     printf '%s%-*s%s%s%-*s%s' \
             "$C_LABEL" "$LBLW" "$1" "$RESET" "$C_NA" "$COL_W" 'n/a' "$RESET"
}

# Line 1: identity (model | folder · branch); model padded to the left-column value width.
MODELSTR="$MODEL"
[ -n "$EFFORT" ] && MODELSTR="$MODEL ($EFFORT)"
[ "${#MODELSTR}" -gt "$COL_W" ] && MODELSTR="${MODELSTR:0:COL_W}"
line1="$(printf '%s%-*s%s%s%-*s%s' "$C_LABEL" "$LBLW" 'model' "$RESET" "$C_CYAN" "$COL_W" "$MODELSTR" "$RESET")"
line1="${line1}${GUT}$(printf '%s%-*s%s%s%s%s' "$C_LABEL" "$LBLW" 'dir' "$RESET" "$C_VAL" "$DIRBRANCH" "$RESET")${PR_SEG}"

# Left column: ctx (row A) + cache (row B).
if [ -n "$CTX_PCT" ]; then
     left_a="$(mseg 'ctx' "$CTX_PCT" "$(gradient_worse "$CTX_PCT" 40 65)")$(col_pad "$METER_W")"
else
     left_a="$(mseg_na 'ctx')"
fi
if [ -n "$CACHE_PCT" ]; then
     COUNTDOWN="$(cache_countdown)"
     left_b="$(mseg 'cache' "$CACHE_PCT" "$(gradient_better "$CACHE_PCT" 70 40)")${COUNTDOWN:-$(col_pad "$METER_W")}"
else
     left_b="$(mseg_na 'cache')"
fi

# Right column: rolling 5h (row A) + weekly (row B).
# Rolling shows a wall-clock reset time (e.g. 10:50) behind a "↻" glyph, since a
# session-length countdown is less useful than knowing when the window reopens.
if [ -n "$FH_PCT" ]; then
     fc="$(gradient_worse "$FH_PCT" 60 85)"
     rc="$C_CYAN"; [ "$FH_PCT" -gt 85 ] && rc="$C_RED"
     BURN_WARN="$(burn_rate_warning "$FH_PCT" "$FH_RESETS_AT" 18000 fmt_clock)"
     right_a="$(mseg 'rolling' "$FH_PCT" "$fc") ${rc}↻$(fmt_clock "${FH_RESETS_AT:-0}")${RESET}${BURN_WARN:+ }${BURN_WARN}"
else
     right_a="$(mseg_na 'rolling')"
fi
if [ -n "$WK_PCT" ]; then
     wc="$(gradient_worse "$WK_PCT" 60 85)"
     rc="$C_CYAN"; [ "$WK_PCT" -gt 85 ] && rc="$C_RED"
     WK_BURN="$(burn_rate_warning "$WK_PCT" "$WK_RESETS_AT" 604800 fmt_weekday_clock)"
     right_b="$(mseg 'week' "$WK_PCT" "$wc") ${rc}$(fmt_weekday_clock "${WK_RESETS_AT:-0}")${RESET}${WK_BURN:+ }${WK_BURN}"
else
     right_b="$(mseg_na 'week')"
fi

line2="${left_a}${GUT}${right_a}"
line3="${left_b}${GUT}${right_b}"

# Line 4: session diff size (+added/-removed) + cumulative tokens (right column).
# Left-column value is padded to COL_W visible chars, matching the meter rows, so the
# right-column GUT lands in the same place as the dir/rolling/week rows above it.
LINES_PLAIN="+${LINES_ADDED} -${LINES_REMOVED}"
LINES_PAD=$((COL_W - ${#LINES_PLAIN}))
[ "$LINES_PAD" -lt 0 ] && LINES_PAD=0
LINES_VAL="$(printf '%s+%s%s %s-%s%s%*s' "$C_GREEN" "$LINES_ADDED" "$RESET" "$C_RED" "$LINES_REMOVED" "$RESET" "$LINES_PAD" '')"
line4="$(printf '%s%-*s%s%s' "$C_LABEL" "$LBLW" 'lines' "$RESET" "$LINES_VAL")"
if [ -n "$TOTAL_IN" ] && [ -n "$TOTAL_OUT" ]; then
	TOKENS_VAL="$(printf '%s%s in · %s out%s' "$C_VAL" "$(fmt_k "$TOTAL_IN")" "$(fmt_k "$TOTAL_OUT")" "$RESET")"
	line4="${line4}${GUT}$(printf '%s%-*s%s%s' "$C_LABEL" "$LBLW" 'tokens' "$RESET" "$TOKENS_VAL")"
else
	line4="${line4}${GUT}$(printf '%s%-*s%s%s%s' "$C_LABEL" "$LBLW" 'tokens' "$RESET" "$C_NA" 'n/a')${RESET}"
fi

printf '%s\n%s\n%s\n%s\n' "$line1" "$line2" "$line3" "$line4"
