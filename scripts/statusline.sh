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

# --- colors ----------------------------------------------------------------
ESC=$'\033'
RESET="${ESC}[0m"
DIM="${ESC}[2m"
C_GREEN="${ESC}[38;5;40m"
C_RED="${ESC}[38;5;196m"
C_LABEL="${ESC}[38;5;245m" # muted label
C_VAL="${ESC}[38;5;252m"   # bright value
C_NA="${ESC}[38;5;240m"    # dim "n/a"
C_TRACK="${ESC}[38;5;238m" # unfilled meter dots

# --- gradient coloring (true-color, smooth green -> amber -> red) ----------
# Replaces hard 3-bucket thresholds with a continuous ramp, while keeping each
# metric's own "safe" (g) and "danger" (o) percentages as the ramp's endpoints:
# flat green at/before g, flat red at/after o, smoothly interpolated between.
lerp() { printf '%d' "$(($1 + (($2 - $1) * $3) / 100))"; } # $1 a $2 b $3 t(0-100)

# $1 t(0-100 within the green->amber->red transition) -> "R G B"
grad_rgb() {
     local t=$1 tt R G B
     if [ "$t" -le 50 ]; then
             tt=$((t * 2))
             R=$(lerp 0 255 "$tt"); G=$(lerp 215 135 "$tt"); B=0
     else
             tt=$(((t - 50) * 2))
             R=255; G=$(lerp 135 0 "$tt"); B=0
     fi
     printf '%d %d %d' "$R" "$G" "$B"
}

# color for "higher is worse" (context / limits): green<=g ... red>=o, gradient between.
gradient_worse() { # $1 p  $2 g  $3 o
     local p=$1 g=$2 o=$3 t rgb
     if [ "$o" -eq "$g" ]; then t=100; else t=$(((p - g) * 100 / (o - g))); fi
     [ "$t" -lt 0 ] && t=0
     [ "$t" -gt 100 ] && t=100
     rgb="$(grad_rgb "$t")"
     printf '%s[38;2;%sm' "$ESC" "${rgb// /;}"
}

# color for "higher is better" (cache hit rate): green>=g ... red<=o, gradient between.
gradient_better() { # $1 p  $2 g  $3 o
     local p=$1 g=$2 o=$3 t rgb
     if [ "$g" -eq "$o" ]; then t=0; else t=$(((g - p) * 100 / (g - o))); fi
     [ "$t" -lt 0 ] && t=0
     [ "$t" -gt 100 ] && t=100
     rgb="$(grad_rgb "$t")"
     printf '%s[38;2;%sm' "$ESC" "${rgb// /;}"
}

repeat() { # $1 char  $2 count
     local i out=""
     for ((i = 0; i < $2; i++)); do out+="$1"; done
     printf '%s' "$out"
}

# Dotted meter: filled dots in $3 (metric color), remaining dots in the dim track.
# Dots carry presence without stacking into a solid vertical blob.
bar() { # $1 pct(int 0-100)  $2 width  $3 fill-color
     local p=$1 w=$2 color=$3 filled empty
     [ "$p" -lt 0 ] && p=0
     [ "$p" -gt 100 ] && p=100
     filled=$((p * w / 100))
     empty=$((w - filled))
     printf '%s%s%s%s%s' \
             "$color" "$(repeat '●' "$filled")" \
             "$C_TRACK" "$(repeat '●' "$empty")" "$RESET"
}

# Short day/hour reset formatter: seconds -> ~2d / ~5h.
fmt_days_short() { # $1 seconds
     local s=${1:-0} d h
     [ "$s" -lt 0 ] && s=0
     d=$((s / 86400))
     h=$((s / 3600))
     if [ "$d" -ge 1 ]; then printf '%dd' "$d"; else printf '%dh' "$h"; fi
}

# Wall-clock reset formatter: epoch seconds -> local HH:MM (e.g. 10:50).
fmt_clock() { # $1 epoch seconds
     local epoch=${1:-0}
     [ "$epoch" -le 0 ] && { printf '%s' '--:--'; return; }
     # GNU date (Linux) takes `-d @epoch`; BSD/macOS date takes `-r epoch`.
     date -d "@$epoch" '+%H:%M' 2>/dev/null || date -r "$epoch" '+%H:%M' 2>/dev/null || printf '%s' '--:--'
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

# 5h rolling-window burn-rate warning: projects the wall-clock time the window's usage
# would hit 100% at the current pace, and prints a warning glyph only when that projection
# is earlier than the window's actual scheduled reset. Silent otherwise (missing data, a
# window too fresh to extrapolate from, on-pace, or already at/past 100%).
burn_rate_warning() { # $1 pct(0-100)  $2 resets_at(epoch seconds)
     local pct=$1 resets_at=$2 now window_start elapsed remaining time_to_cap projected
     [ -z "$pct" ] && return
     [ -z "$resets_at" ] && return
     now=$(date +%s)
     window_start=$((resets_at - 18000))
     elapsed=$((now - window_start))
     [ "$elapsed" -lt 300 ] && return
     [ "$pct" -lt 1 ] && return
     remaining=$((100 - pct))
     [ "$remaining" -le 0 ] && return
     time_to_cap=$((remaining * elapsed / pct))
     projected=$((now + time_to_cap))
     [ "$projected" -ge "$resets_at" ] && return
     printf '%s⚡%s%s' "$C_RED" "$(fmt_clock "$projected")" "$RESET"
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
WK_LEFT="$(j '(.rate_limits.seven_day.resets_at // empty) | select(type == "number") | (. - now) | floor')"

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
     BURN_WARN="$(burn_rate_warning "$FH_PCT" "$FH_RESETS_AT")"
     right_a="$(mseg 'rolling' "$FH_PCT" "$fc") ${rc}↻$(fmt_clock "${FH_RESETS_AT:-0}")${RESET}${BURN_WARN:+ }${BURN_WARN}"
else
     right_a="$(mseg_na 'rolling')"
fi
if [ -n "$WK_PCT" ]; then
     wc="$(gradient_worse "$WK_PCT" 60 85)"
     rc="$DIM"; [ "$WK_PCT" -gt 85 ] && rc="$C_RED"
     right_b="$(mseg 'week' "$WK_PCT" "$wc") ${rc}$(fmt_days_short "${WK_LEFT:-0}")${RESET}"
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
