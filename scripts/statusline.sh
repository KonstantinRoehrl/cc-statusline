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
# Keep the last raw payload for debugging / discovering any per-model limit field.
printf '%s' "$JSON" >"$HOME/.claude/statusline-last-payload.json" 2>/dev/null || true

# --- jq helper -------------------------------------------------------------
j() { printf '%s' "$JSON" | jq -r "$1" 2>/dev/null; }

# --- shared library (colors, gradient engine, meter primitives) ------------
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=scripts/statusline-lib.sh
. "$LIB_DIR/statusline-lib.sh"

# Wall-clock reset formatter: epoch seconds -> local HH:MM (e.g. 10:50).
fmt_clock() { # $1 epoch seconds
     local epoch=${1:-0}
     [ "$epoch" -le 0 ] && { printf '%s' '--:--'; return; }
     date -r "$epoch" '+%H:%M' 2>/dev/null || printf '%s' '--:--'
}

# Weekday + wall-clock reset formatter: epoch seconds -> "Sat 18:00".
fmt_weekday_clock() { # $1 epoch seconds
     local epoch=${1:-0}
     [ "$epoch" -le 0 ] && { printf -- '--- --:--'; return; }
     date -r "$epoch" '+%a %H:%M' 2>/dev/null || printf -- '--- --:--'
}

# Abbreviate large token counts: 84246 -> 84.2k. Values under 1000 print raw (e.g. 439).
fmt_k() { # $1 integer count
     local n=${1:-0}
     if [ "$n" -ge 1000 ]; then
             printf '%d.%dk' "$((n / 1000))" "$(((n % 1000) / 100))"
     else
             printf '%d' "$n"
     fi
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

CTX_PCT="$(j '(.context_window.used_percentage // empty) | select(. != null) | floor')"

CACHE_PCT="$(j '
 (.context_window.current_usage) as $u
 | select($u != null)
 | (($u.cache_read_input_tokens // 0)) as $r
 | (($u.input_tokens // 0) + ($u.cache_creation_input_tokens // 0) + $r) as $den
 | select($den > 0)
 | ($r * 100 / $den) | floor')"

FH_PCT="$(j '(.rate_limits.five_hour.used_percentage // empty) | select(. != null) | floor')"
FH_RESETS_AT="$(j '(.rate_limits.five_hour.resets_at // empty) | select(type == "number") | floor')"

WK_PCT="$(j '(.rate_limits.seven_day.used_percentage // empty) | select(. != null) | floor')"
WK_RESETS_AT="$(j '(.rate_limits.seven_day.resets_at // empty) | select(type == "number") | floor')"

LINES_ADDED="$(j '.cost.total_lines_added // 0')"
LINES_REMOVED="$(j '.cost.total_lines_removed // 0')"
TOTAL_IN="$(j '.context_window.total_input_tokens // empty')"
TOTAL_OUT="$(j '.context_window.total_output_tokens // empty')"

LBLW=8
GUT="   "

# Colored 4-wide right-justified percentage, e.g. " 62%".
pct4() { printf '%s%3d%%%s' "$2" "$1" "$RESET"; }

# Metric cell: "<label:8><10-dot bar> <pct4>" — 23 visible chars.
mseg() { # $1 label  $2 pct  $3 color
     printf '%s%-*s%s%s %s' \
             "$C_LABEL" "$LBLW" "$1" "$RESET" "$(bar "$2" 10 "$3")" "$(pct4 "$2" "$3")"
}
# Missing-metric cell of equal width: label(8) + "n/a" padded across meter(15).
mseg_na() { # $1 label
     printf '%s%-*s%s%s%-15s%s' \
             "$C_LABEL" "$LBLW" "$1" "$RESET" "$C_NA" 'n/a' "$RESET"
}

# Line 1: identity (model | folder · branch); model padded to meter width (15).
MODELSTR="$MODEL"
[ -n "$EFFORT" ] && MODELSTR="$MODEL ($EFFORT)"
[ "${#MODELSTR}" -gt 15 ] && MODELSTR="${MODELSTR:0:15}"
line1="$(printf '%s%-*s%s%s%-15s%s' "$C_LABEL" "$LBLW" 'model' "$RESET" "$C_VAL" "$MODELSTR" "$RESET")"
line1="${line1}${GUT}$(printf '%s%-*s%s%s%s%s' "$C_LABEL" "$LBLW" 'dir' "$RESET" "$C_VAL" "$DIRBRANCH" "$RESET")"

# Left column: ctx (row A) + cache (row B).
if [ -n "$CTX_PCT" ]; then
     left_a="$(mseg 'ctx' "$CTX_PCT" "$(gradient_worse "$CTX_PCT" 40 65)")"
else
     left_a="$(mseg_na 'ctx')"
fi
if [ -n "$CACHE_PCT" ]; then
     left_b="$(mseg 'cache' "$CACHE_PCT" "$(gradient_better "$CACHE_PCT" 70 40)")"
else
     left_b="$(mseg_na 'cache')"
fi

# Right column: rolling 5h (row A) + weekly (row B).
# Rolling shows a wall-clock reset time (e.g. 10:50) behind a "↻" glyph, since a
# session-length countdown is less useful than knowing when the window reopens.
if [ -n "$FH_PCT" ]; then
     fc="$(gradient_worse "$FH_PCT" 60 85)"
     rc="$DIM"; [ "$FH_PCT" -gt 85 ] && rc="$C_RED"
     BURN_WARN="$(burn_rate_warning "$FH_PCT" "$FH_RESETS_AT" 18000 fmt_clock)"
     right_a="$(mseg 'rolling' "$FH_PCT" "$fc") ${rc}↻$(fmt_clock "${FH_RESETS_AT:-0}")${RESET}${BURN_WARN:+ }${BURN_WARN}"
else
     right_a="$(mseg_na 'rolling')"
fi
if [ -n "$WK_PCT" ]; then
     wc="$(gradient_worse "$WK_PCT" 60 85)"
     rc="$DIM"; [ "$WK_PCT" -gt 85 ] && rc="$C_RED"
     WK_BURN="$(burn_rate_warning "$WK_PCT" "$WK_RESETS_AT" 604800 fmt_weekday_clock)"
     right_b="$(mseg 'week' "$WK_PCT" "$wc") ${rc}$(fmt_weekday_clock "${WK_RESETS_AT:-0}")${RESET}${WK_BURN:+ }${WK_BURN}"
else
     right_b="$(mseg_na 'week')"
fi

line2="${left_a}${GUT}${right_a}"
line3="${left_b}${GUT}${right_b}"

# Line 4: session diff size (+added/-removed) + cumulative tokens (right column).
# Left-column value is padded to 15 visible chars, matching mseg's bar+pct width, so the
# right-column GUT lands in the same place as the dir/rolling/week rows above it.
LINES_PLAIN="+${LINES_ADDED} -${LINES_REMOVED}"
LINES_PAD=$((15 - ${#LINES_PLAIN}))
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
