# On-device checklist — token consumption metrics

Walkthrough target: `scripts/statusline.sh`, run against a real Claude Code session
(or piped sample JSON payloads) in an actual terminal, per
`docs/superpowers/specs/2026-08-01-token-metrics-design.md`.

## Task 1 — session token totals

- [ ] The `tokens` cell in line 4's right column renders `<in> in · <out> out` (e.g.
      `84.2k in · 439 out`) with the same label color/width and value color as the
      existing `lines` cell to its left — no misalignment, no column drift.
- [ ] When `total_input_tokens`/`total_output_tokens` are absent from the payload, the
      `tokens` cell shows `n/a` in the same dim/`n/a` style used elsewhere (e.g. the
      `dir` cell), never a bare `null`, blank space, or broken line.

## Task 2 — 5h rolling-window burn-rate warning

- [ ] Off-pace usage in the 5h rolling window shows a `⚡HH:MM` glyph in red next to the
      `rolling` row's `↻` reset clock, and the projected time reads as plausible (earlier
      than the window's actual reset).
- [ ] On-pace usage, a fresh window (<5 min old), or already-past-100% usage shows no `⚡`
      glyph — the rolling row looks exactly as it does today.
- [ ] Missing `resets_at` for the 5h window doesn't crash the statusline and doesn't show
      a stray `⚡` — the rolling row falls back to `↻--:--` as before.
