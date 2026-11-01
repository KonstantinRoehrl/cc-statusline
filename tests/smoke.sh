#!/usr/bin/env bash
# End-to-end smoke tests for scripts/statusline.sh.
# Every case pipes a crafted payload into the script inside a throwaway HOME and cache directory
# and asserts on the rendered output. Plain bash 3.2+ and jq; exits non-zero if any assertion fails.

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/statusline.sh"
# shellcheck source=scripts/statusline-lib.sh
. "$REPO_ROOT/scripts/statusline-lib.sh" # color constants, so assertions match the script's escapes

SANDBOX="$(mktemp -d)"
trap 'chmod -R u+rwx "$SANDBOX" 2>/dev/null; rm -rf "$SANDBOX"' EXIT
PASSES=0
FAILURES=0

# --- assertions -------------------------------------------------------------
pass() { PASSES=$((PASSES + 1)); }
fail() { # $1 message
	FAILURES=$((FAILURES + 1))
	printf 'FAIL: %s\n' "$1" >&2
}
assert_eq() { # $1 name  $2 expected  $3 actual
	if [ "$2" = "$3" ]; then pass; else fail "$1: expected [$2], got [$3]"; fi
}
assert_contains() { # $1 name  $2 haystack  $3 needle
	case "$2" in *"$3"*) pass ;; *) fail "$1: [$2] does not contain [$3]" ;; esac
}
assert_not_contains() { # $1 name  $2 haystack  $3 needle
	case "$2" in *"$3"*) fail "$1: [$2] unexpectedly contains [$3]" ;; *) pass ;; esac
}
assert_empty_stderr() { # $1 name
	if [ -z "$ERR" ]; then pass; else fail "$1: stderr was not empty: [$ERR]"; fi
}

# --- fixtures ---------------------------------------------------------------
BASE_PAYLOAD='{"model":{"display_name":"Claude"},"session_id":"sess-base","workspace":{"current_dir":"/nonexistent/proj"},"cost":{"total_lines_added":3,"total_lines_removed":1},"context_window":{"used_percentage":40,"total_input_tokens":1200,"total_output_tokens":300,"current_usage":{"input_tokens":10,"cache_creation_input_tokens":10,"cache_read_input_tokens":80}}}'

now() { date +%s; }

payload() { # $1 optional JSON object deep-merged over BASE_PAYLOAD
	local overlay="${1:-}"
	[ -n "$overlay" ] || overlay='{}'
	jq -cn --argjson base "$BASE_PAYLOAD" --argjson overlay "$overlay" '$base * $overlay'
}

fresh_sandbox() { # per-case HOME and cache directory
	CASE_DIR="$(mktemp -d "$SANDBOX/case.XXXXXX")"
	HOME_DIR="$CASE_DIR/home"
	CACHE="$CASE_DIR/cache"
	mkdir -p "$HOME_DIR/.claude" "$CACHE"
}

windows_json() { # $1 five_hour pct  $2 five_hour resets_at  [$3 seven_day pct  $4 seven_day resets_at] -> rate-limit windows
	jq -cn --argjson fp "$1" --argjson fr "$2" --arg wp "${3:-}" --arg wr "${4:-}" \
		'{five_hour: {used_percentage: $fp, resets_at: $fr}}
		 + (if $wp == "" then {} else {seven_day: {used_percentage: ($wp | tonumber), resets_at: ($wr | tonumber)}} end)'
}

write_snapshot() { # $1 file stem, then the windows_json arguments -> a cache file another session would have written
	local stem="$1"
	shift
	windows_json "$@" >"$CACHE/$stem.limits.json"
}

limits_payload() { # windows_json arguments -> BASE_PAYLOAD with those rate_limits
	local windows
	windows="$(windows_json "$@")"
	payload "$(jq -cn --argjson w "$windows" '{rate_limits: $w}')"
}

run_sl() { # $1 payload -> sets OUT (stdout), ERR (stderr)
	local err_file="$CASE_DIR/stderr"
	OUT="$(printf '%s' "$1" | env -u CLAUDE_CONFIG_DIR HOME="$HOME_DIR" CC_STATUSLINE_CACHE_DIR="$CACHE" "$SCRIPT" 2>"$err_file")"
	ERR="$(cat "$err_file")"
}

strip_ansi() { sed "s/${ESC}\[[0-9;]*m//g"; }
plain_line() { printf '%s\n' "$OUT" | strip_ansi | sed -n "${1}p"; } # $1 line number, ANSI removed
raw_line() { printf '%s\n' "$OUT" | sed -n "${1}p"; }                 # $1 line number, escapes kept

col_of() { # $1 line number  $2 label -> character offset (not bytes) where the label starts
	plain_line "$1" | jq -Rr --arg label "$2" 'split($label) | if length > 1 then .[0] | length else -1 end'
}

assert_four_lines() { # $1 name
	assert_eq "$1: line count" 4 "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')"
}

assert_aligned() { # $1 name -> the right column starts at one offset on all four lines
	local dir rolling week tokens
	dir="$(col_of 1 dir)"; rolling="$(col_of 2 rolling)"; week="$(col_of 3 week)"; tokens="$(col_of 4 tokens)"
	if [ "$dir" -gt 0 ] && [ "$dir" = "$rolling" ] && [ "$rolling" = "$week" ] && [ "$week" = "$tokens" ]; then
		pass
	else
		fail "$1: right column offsets differ (dir=$dir rolling=$rolling week=$week tokens=$tokens)"
	fi
}

# --- cases: baseline --------------------------------------------------------
case_baseline_minimal_payload() {
	run_sl '{"model":{"display_name":"Claude"}}'
	assert_four_lines "minimal payload"
	assert_empty_stderr "minimal payload"
	assert_contains "minimal payload rolling" "$(plain_line 2)" "n/a"
	assert_aligned "minimal payload"
}

case_baseline_full_payload() {
	local reset
	reset=$(($(now) + 3600))
	run_sl "$(limits_payload 30 "$reset" 50 "$((reset + 86400))")"
	assert_four_lines "full payload"
	assert_empty_stderr "full payload"
	assert_contains "full payload rolling" "$(plain_line 2)" " 30%"
	assert_contains "full payload week" "$(plain_line 3)" " 50%"
	assert_aligned "full payload"
}

# --- cases: runner ----------------------------------------------------------
for case_fn in $(compgen -A function | grep '^case_'); do
	fresh_sandbox
	"$case_fn"
done

printf '%d passed, %d failed\n' "$PASSES" "$FAILURES"
[ "$FAILURES" -eq 0 ]
