# On-device results: token consumption metrics

## Task 1 — session token totals
- Tokens cell alignment: FAILED, then fixed and re-confirmed — the `tokens` cell's right
  column started to the left of where `dir`/`rolling`/`week` start on the lines above it.
  Root cause: `LINES_VAL` (line 4's left-column value) was printed unpadded, while every
  other left-column value is padded to 15 chars via `mseg`/`mseg_na`. Fixed by padding
  `LINES_VAL` to 15 visible chars (`scripts/statusline.sh`, `LINES_PLAIN`/`LINES_PAD`).
  Re-verified on-device: tokens now starts at the same column as dir/rolling/week.
- Missing-tokens n/a case: passed — shows dim `n/a`, same style as other n/a cells.

## Task 2 — 5h rolling-window burn-rate warning
- Off-pace warning: passed — red `⚡HH:MM` shown next to `↻`, projected time earlier than
  actual reset, plausible.
- On-pace, no warning: passed — rolling row unchanged, no `⚡` glyph.
- Missing `resets_at` fallback: FAILED, then fixed and re-confirmed — `fmt_clock()`'s
  fallback `printf '--:--'` errored (`printf: --: invalid option`) because bash's `printf`
  builtin treats a leading `--` as an option marker. Pre-existing (introduced in commit
  `b5e3cf0`, 2026-07-25, before this cycle) but directly exercised by this cycle's own
  checklist item, so fixed on this branch too: changed to `printf '%s' '--:--'`
  (`scripts/statusline.sh:102-103`). Re-verified on-device: `↻--:--` renders cleanly, no
  stderr error.

All 5 checklist items pass as of the fixes above.
