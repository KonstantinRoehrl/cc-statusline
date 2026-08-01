# Token consumption metrics for the statusline

Date: 2026-08-01
Status: approved

## Context

`scripts/statusline.sh` renders a 4-line dashboard (model/dir, ctx/rolling,
cache/week, lines +/-) from the JSON payload Claude Code feeds it on stdin.
The user is on a Claude Max plan (rate-limited, not billed per token), so
`cost.total_cost_usd` is not a useful signal for them. What's missing is a
way to see (a) how many tokens a session has actually consumed, and (b)
whether the current pace is going to exhaust the 5-hour rolling rate limit
before it naturally resets.

Alternatives considered and rejected during scoping/brainstorming:

- **`total_cost_usd`** — irrelevant on a Max plan.
- **API-active-ratio** (`total_api_duration_ms / total_duration_ms`) —
  deprioritized as a "nice to have," not core to token consumption.
- **Full input/output/cached 3-way token split** — the payload only exposes
  cache figures for the *last* API call
  (`context_window.current_usage.cache_read_input_tokens` /
  `cache_creation_input_tokens`), not a session cumulative. Getting a true
  cumulative would require summing every turn in the transcript JSONL
  (`transcript_path`), which is a heavier parse than the other fields
  warrant. Dropped in favor of the two fields that are already
  session-cumulative in the payload.

## Design

### 1. Session token totals

`context_window.total_input_tokens` and `context_window.total_output_tokens`
are already cumulative across the session — no derivation needed.

```bash
TOTAL_IN="$(j '.context_window.total_input_tokens // empty')"
TOTAL_OUT="$(j '.context_window.total_output_tokens // empty')"
```

A new `fmt_k()` helper abbreviates large counts (`84246` → `84.2k`; values
under 1000 print raw, e.g. `439`). Rendered in line 4's **right column**
(currently empty), reusing the `GUT` separator already used elsewhere:

```
lines   +214 -58         tokens  84.2k in · 439 out
```

Color: `C_VAL` (plain value color, like the `lines` row) — this is a
magnitude readout, not a health signal, so no gradient. Missing data (either
field absent) renders as `n/a` in the same style as `mseg_na`.

### 2. Burn-rate projection

Goal: warn when the *current pace* of 5h-rolling-window usage will exhaust
the window before its scheduled reset. Uses only fields already fetched
(`FH_PCT` = `rate_limits.five_hour.used_percentage`, `FH_RESETS_AT` =
`rate_limits.five_hour.resets_at`) — no new payload dependencies.

**Why not `cost.total_duration_ms` (session elapsed time)?** `FH_PCT`
reflects usage across the *whole 5-hour window*, which can include work from
before this session started (other sessions, or earlier turns in the same
window if the terminal was reopened). Using session duration as the rate's
denominator would misattribute that prior usage to this session's pace.
Instead, derive elapsed time from the window itself:

```bash
window_start = FH_RESETS_AT - 18000        # 18000s = 5h
elapsed      = now - window_start
remaining    = 100 - FH_PCT
time_to_cap  = remaining * elapsed / FH_PCT   # guard: FH_PCT > 0
projected_at = now + time_to_cap
```

**Minimum-sample threshold** (avoids wild extrapolation early in a fresh
window): only compute/show a projection when `elapsed >= 300` (5 minutes
into the window) **and** `FH_PCT >= 1`. Below that threshold, the rolling
row behaves exactly as it does today (just `↻HH:MM`, no projection).

**Display rule:** only surface the projection when it's actionable — i.e.
when `projected_at < FH_RESETS_AT` (current pace would blow the window
before its natural reset). On-pace sessions see no change. Off-pace sessions
see a warning glyph appended to the existing rolling row:

```
On pace (unchanged):
rolling ●●●●●●●●●● 62% ↻11:25

Burning faster than reset:
rolling ●●●●●●●●●● 88% ↻11:25 ⚡09:40
```

`⚡$(fmt_clock projected_at)` reuses the existing `fmt_clock()` formatter,
colored `C_RED` (by construction this only ever renders in the warning
case).

### Edge cases

- `FH_PCT` or `FH_RESETS_AT` missing → skip the projection silently (same
  path as today's `mseg_na` fallback for the whole rolling row).
- `elapsed` negative (clock skew or a stale/cached payload) → skip.
- `remaining <= 0` (at or over 100% already) → skip; not meaningful to
  project further.

### Testing

No new test infra — consistent with the rest of the repo:
`bash -n scripts/statusline.sh`, `shellcheck -S warning scripts/statusline.sh`,
and hand-crafted JSON payloads piped through the script to exercise:

1. Normal case (both new fields present, on-pace rolling usage).
2. `total_input_tokens` / `total_output_tokens` missing → `n/a`.
3. Fresh window (`elapsed < 300`) → no `⚡`, unchanged rolling row.
4. On-pace (`projected_at > resets_at`) → no `⚡`.
5. Off-pace (`projected_at < resets_at`) → `⚡` renders, red.
6. `FH_PCT` missing entirely → whole rolling row still falls back to `n/a`
   (existing behavior), no crash from the new projection logic.

## Out of scope

- Cached-token breakdown (see rejected alternatives above).
- Cost-based metrics (`total_cost_usd`).
- Weekly-window burn-rate projection — only the 5h rolling window was
  requested; the weekly meter's reset is measured in days, where a
  wall-clock projection is less useful than the existing `2d`-style
  countdown it already shows.
