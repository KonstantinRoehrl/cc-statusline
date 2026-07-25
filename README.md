# cc-statusline

A 4-line ANSI dashboard statusline for [Claude Code](https://claude.com/claude-code):

```
model   Sonnet 5 (high)   dir     Programming
ctx     ●●●●●●●●●● 47%   rolling ●●●●●●●●●● 62% ↻11:25
cache   ●●●●●●●●●● 85%   week    ●●●●●●●●●● 30% 2d
lines   +214 -58
```

| Row | Left column | Right column |
|---|---|---|
| 1 | model + effort level | folder · git branch |
| 2 | context-window meter | rolling 5h rate-limit meter + reset clock |
| 3 | prompt-cache hit-rate meter | weekly rate-limit meter + reset |
| 4 | session line diff (+added/-removed) | |

Meters are dotted bars, gradient-colored by health (green → amber → red as
usage climbs; the cache-hit meter inverts the scale since higher is better).
No emojis, no external services — everything is derived from the JSON
payload Claude Code already feeds the statusline command on stdin.

## Requirements

- `jq` 1.7+ on `PATH` (`brew install jq` on macOS, `apt install jq` on Linux).
- A 24-bit true-color terminal (iTerm2, Kitty, Alacritty, VS Code's integrated
  terminal, and most modern terminals all qualify) — the gradients use
  `\033[38;2;R;G;Bm` escapes, not the 256-color palette.
- The 5h reset clock uses BSD `date -r <epoch>` (macOS-native). On Linux,
  edit `fmt_clock()` in `scripts/statusline.sh` to use `date -d @<epoch>
  '+%H:%M'` (GNU date) instead.

## Install

```
claude plugin marketplace add KonstantinRoehrl/cc-statusline
claude plugin install cc-statusline@cc-statusline
```

Claude Code plugins cannot set the `statusLine` key in your personal
`settings.json` automatically — it's a user-level preference, not something a
plugin can inject. After installing, add this to `~/.claude/settings.json`
yourself (merge it in, don't overwrite the rest of the file):

```json
{
  "statusLine": {
    "type": "command",
    "command": "${CLAUDE_PLUGIN_ROOT}/scripts/statusline.sh",
    "padding": 0,
    "refreshInterval": 30
  }
}
```

`${CLAUDE_PLUGIN_ROOT}` is substituted by Claude Code at runtime to the
plugin's installed directory, so the path keeps working across
`autoUpdate`-driven updates. Start a new session (or run `/statusline`) to
pick up the change.

## How it works

Claude Code invokes the configured `statusLine` command on an interval,
piping a JSON payload (model, effort, workspace, context-window usage,
rate-limit usage, session cost) to stdin. `scripts/statusline.sh` reads that
payload with `jq`, computes percentages and reset times, and prints four
ANSI-colored lines. The last raw payload is cached at
`~/.claude/statusline-last-payload.json` for debugging or discovering new
fields Claude Code starts sending.

## Development

```
bash -n scripts/statusline.sh          # syntax check
shellcheck -S warning scripts/statusline.sh   # lint (info-level SC2016 hits on
                                               # single-quoted jq filters are intentional)
echo '{"model":{"display_name":"Claude"}}' | scripts/statusline.sh   # smoke test
```

## License

MIT — see [LICENSE](LICENSE).
