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

# --- cases: shared rate-limit snapshots -------------------------------------
case_limits_max_across_sessions() {
	local reset
	reset=$(($(now) + 3600))
	write_snapshot sess-a 7 "$reset"
	write_snapshot sess-b 26 "$reset"
	run_sl "$(limits_payload 7 "$reset")"
	assert_contains "same window: highest percentage wins" "$(plain_line 2)" " 26%"
	assert_empty_stderr "same window"
	assert_aligned "same window"
}

case_limits_writes_session_snapshot() {
	local reset
	reset=$(($(now) + 3600))
	run_sl "$(limits_payload 12 "$reset" 40 "$((reset + 86400))")"
	assert_eq "snapshot five_hour pct" 12 "$(jq -r '.five_hour.used_percentage' "$CACHE/sess-base.limits.json")"
	assert_eq "snapshot seven_day pct" 40 "$(jq -r '.seven_day.used_percentage' "$CACHE/sess-base.limits.json")"
}

case_limits_newer_window_wins() {
	local t
	t=$(now)
	write_snapshot sess-new 5 "$((t + 9000))"
	run_sl "$(limits_payload 80 "$((t + 1000))")"
	assert_contains "newer window beats higher percentage" "$(plain_line 2)" "  5%"
	assert_not_contains "newer window beats higher percentage" "$(plain_line 2)" "80%"
}

case_limits_lapsed_window() {
	local t
	t=$(now)
	write_snapshot sess-old 99 "$((t - 100))" 90 "$((t - 100))"
	run_sl "$(payload)"
	assert_contains "lapsed rolling shows 0%" "$(plain_line 2)" "  0%"
	assert_contains "lapsed rolling reset cell" "$(plain_line 2)" "--:--"
	assert_not_contains "lapsed rolling is not n/a" "$(plain_line 2)" "n/a"
	assert_not_contains "lapsed rolling has no burn warning" "$(plain_line 2)" "⚡"
	assert_contains "lapsed weekly shows 0%" "$(plain_line 3)" "  0%"
	assert_contains "lapsed weekly reset cell" "$(plain_line 3)" "--- --:--"
	assert_not_contains "lapsed weekly has no burn warning" "$(plain_line 3)" "⚡"
	assert_aligned "lapsed"
}

case_limits_absent_window() {
	run_sl "$(payload)"
	assert_contains "absent rolling" "$(plain_line 2)" "n/a"
	assert_contains "absent weekly" "$(plain_line 3)" "n/a"
}

case_limits_payload_beats_lapsed_cache() {
	local t
	t=$(now)
	write_snapshot sess-old 99 "$((t - 100))"
	run_sl "$(limits_payload 33 "$((t + 3600))")"
	assert_contains "live payload window wins over lapsed cache" "$(plain_line 2)" " 33%"
}

case_limits_corrupt_cache_file() {
	local reset clean
	reset=$(($(now) + 3600))
	write_snapshot sess-good 26 "$reset"
	run_sl "$(limits_payload 7 "$reset")"
	clean="$OUT"
	printf '{"five_hour":{"used_perc' >"$CACHE/sess-truncated.limits.json"
	printf '5\n"text"\n[]\n{"five_hour":3}\n' >"$CACHE/sess-wrong-shape.limits.json"
	run_sl "$(limits_payload 7 "$reset")"
	assert_eq "corrupt files leave output unchanged" "$clean" "$OUT"
	assert_empty_stderr "corrupt files"
}

case_limits_unusable_cache_dir() {
	local reset good
	reset=$(($(now) + 3600))
	run_sl "$(limits_payload 7 "$reset")"
	good="$OUT"
	: >"$CASE_DIR/not-a-dir"
	CACHE="$CASE_DIR/not-a-dir/cache"
	run_sl "$(limits_payload 7 "$reset")"
	assert_eq "unwritable cache dir degrades to the payload alone" "$good" "$OUT"
	assert_empty_stderr "unwritable cache dir"
}

case_limits_missing_claude_dir() {
	rmdir "$HOME_DIR/.claude"
	run_sl "$(limits_payload 7 "$(($(now) + 3600))")"
	assert_four_lines "missing ~/.claude"
	assert_empty_stderr "missing ~/.claude (debug payload write)"
}

case_limits_float_percentage_is_floored() {
	local reset
	reset=$(($(now) + 3600))
	write_snapshot sess-a 23 "$reset"
	run_sl "$(limits_payload 23.5 "$reset")"
	assert_contains "float percentage floors to match the cached integer" "$(plain_line 2)" " 23%"
	assert_not_contains "float percentage floors to match the cached integer" "$(plain_line 2)" "24%"
}

case_limits_prunes_old_snapshots() {
	local reset
	reset=$(($(now) + 3600))
	write_snapshot sess-stale 50 "$reset"
	touch -t 202001010000 "$CACHE/sess-stale.limits.json"
	run_sl "$(limits_payload 7 "$reset")"
	[ ! -e "$CACHE/sess-stale.limits.json" ] && pass || fail "snapshot older than 8 days was not pruned"
}

# --- cases: prompt-cache countdown ------------------------------------------
cache_payload() { # $1 seconds until expiry  [$2 ttl, omitted when empty] -> BASE_PAYLOAD with a warm prompt_cache
	payload "$(jq -cn --argjson exp "$(($(now) + $1))" --arg ttl "${2:-}" \
		'{prompt_cache: ({warm: true, caching_observed: true, expires_at: $exp} + (if $ttl == "" then {} else {ttl: $ttl} end))}')"
}

case_countdown_dim_when_plenty_left() {
	run_sl "$(cache_payload 3090 1h)"
	assert_contains "52m left" "$(plain_line 3)" "◷52m"
	assert_contains "52m left is dim" "$(raw_line 3)" "${C_LABEL}◷52m"
	assert_empty_stderr "52m left"
	assert_aligned "52m left"
}

case_countdown_red_when_close_to_eviction() {
	run_sl "$(cache_payload 300 1h)"
	assert_contains "5m left of 1h" "$(raw_line 3)" "${C_RED}◷5m"
	run_sl "$(cache_payload 50 5m)"
	assert_contains "50s left of 5m" "$(raw_line 3)" "${C_RED}◷<1m"
	assert_aligned "50s left"
}

case_countdown_unknown_ttl_turns_red_at_one_minute() {
	run_sl "$(cache_payload 90)"
	assert_contains "90s left, no ttl" "$(raw_line 3)" "${C_LABEL}◷2m"
	run_sl "$(cache_payload 45)"
	assert_contains "45s left, no ttl" "$(raw_line 3)" "${C_RED}◷<1m"
}

case_countdown_hidden_without_a_warm_cache() {
	local t variant
	t=$(now)
	for variant in \
		'{}' \
		'{"prompt_cache":null}' \
		'{"prompt_cache":{"warm":false,"caching_observed":true,"ttl":"1h","expires_at":9999999999}}' \
		'{"prompt_cache":{"warm":true,"caching_observed":true,"ttl":"1h","expires_at":null}}' \
		"$(jq -cn --argjson t "$t" '{prompt_cache: {warm: true, caching_observed: true, ttl: "1h", expires_at: ($t - 5)}}')" \
		"$(jq -cn --argjson t "$t" '{prompt_cache: {warm: true, caching_observed: false, ttl: "1h", expires_at: ($t + 3000)}}')"; do
		run_sl "$(payload "$variant")"
		assert_not_contains "no countdown for $variant" "$(plain_line 3)" "◷"
		assert_empty_stderr "no countdown for $variant"
		assert_aligned "no countdown for $variant"
	done
}

# --- cases: runner ----------------------------------------------------------
for case_fn in $(compgen -A function | grep '^case_'); do
	fresh_sandbox
	"$case_fn"
done

printf '%d passed, %d failed\n' "$PASSES" "$FAILURES"
[ "$FAILURES" -eq 0 ]
