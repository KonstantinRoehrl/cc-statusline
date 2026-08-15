#!/usr/bin/env bash
# cc-statusline shared library — color constants, gradient engine, meter primitives.
# Sourced by statusline.sh and subagent-statusline.sh; not executed directly.

# Color constants below are consumed by the sourcing scripts, not this file, so
# their use is invisible here — SC2034 is expected and suppressed file-wide.
# shellcheck disable=SC2034

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
C_CYAN="${ESC}[38;5;73m"   # subtle cyan accent: model name, rolling/weekly reset clocks

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

# Abbreviate large token counts: 84246 -> 84.2k. Values under 1000 print raw (e.g. 439).
fmt_k() { # $1 integer count
     local n=${1:-0}
     if [ "$n" -ge 1000 ]; then
             printf '%d.%dk' "$((n / 1000))" "$(((n % 1000) / 100))"
     else
             printf '%d' "$n"
     fi
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
