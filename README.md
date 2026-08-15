# cc-statusline

A 4-line ANSI dashboard statusline for [Claude Code](https://claude.com/claude-code):

```
model   Sonnet 5 (high)   dir     Programming
ctx     ●●●●●●●●●● 47%   rolling ●●●●●●●●●● 62% ↻11:25
cache   ●●●●●●●●●● 85%   week    ●●●●●●●●●● 30% Sat 18:00
lines   +214 -58
```

| Row | Left column | Right column |
|---|---|---|
| 1 | model + effort level | folder · git branch |
| 2 | context-window meter | rolling 5h rate-limit meter + reset clock |
| 3 | prompt-cache hit-rate meter | weekly rate-limit meter + weekday-clock reset (⚡ early-exhaustion warning when projected to hit 100% before reset) |
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
    "command": "~/.claude/plugins/marketplaces/cc-statusline/scripts/statusline.sh",
    "padding": 0,
    "refreshInterval": 30
  }
}
```

Point at the **marketplace clone** path, not the versioned plugin cache path
(`~/.claude/plugins/cache/cc-statusline/cc-statusline/<version>/...`) and not
`${CLAUDE_PLUGIN_ROOT}` — that variable is only substituted inside a plugin's
own manifest-defined commands (hooks, MCP servers), not in your personal
`statusLine.command`, and even there it re-resolves to a version-pinned
directory that changes (and gets garbage-collected ~14 days later) on every
update. The marketplace clone path stays fixed forever; `claude plugin
marketplace update` (which `autoUpdate: true` on the marketplace entry
triggers automatically) `git pull`s new commits into that same directory in
place, so the statusline picks up changes without you touching
`settings.json` again. Start a new session (or run `/statusline`) to pick up
the initial change.

## Subagent status line

`scripts/subagent-statusline.sh` renders a compact row for each active subagent: the model it
resolved to (with its effort level when set — a subagent's effort can differ from the
orchestrator's) and its context-window usage lead the row as separate segments, followed by its
task description (Claude Code doesn't send override scripts a subagent role/type name, e.g.
"general-purpose" or "Explore" — only a generic constant — so description is the closest
stand-in), with raw token consumption trailing at the end. Per-subagent cache-hit rate isn't
offered: Claude Code only tracks a single rolling token count per subagent internally, with no
cache-read/cache-creation/input breakdown to compute a hit rate from.

```
Sonnet-5 · ctx 15% · Review fix-5-2 F2 test · 40.8k tok
Opus-4.8 (high) · ctx 42% · Trivial subagent for statusline test · 1.2k tok
```

It is wired via Claude Code's separate **`subagentStatusLine`** setting, which — like `statusLine` —
is a user-level preference a plugin cannot set for you. It requires **Claude Code v2.1.205+** (the
release that added the subagent `model` field). Merge this into `~/.claude/settings.json`:

```json
{
  "subagentStatusLine": {
    "type": "command",
    "command": "~/.claude/plugins/marketplaces/cc-statusline/scripts/subagent-statusline.sh"
  }
}
```

The same marketplace-clone path rules as the main statusline apply (see Install above): point at the
clone, not the versioned cache or `${CLAUDE_PLUGIN_ROOT}`. The last raw subagent payload is cached
at `~/.claude/subagent-statusline-last-payload.json` for debugging.

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
bash -n scripts/statusline.sh scripts/subagent-statusline.sh scripts/statusline-lib.sh
shellcheck -S warning scripts/statusline.sh scripts/subagent-statusline.sh scripts/statusline-lib.sh
echo '{"model":{"display_name":"Claude"}}' | scripts/statusline.sh          # main smoke test
echo '{"tasks":[{"id":"t1","description":"agent","model":"claude-sonnet-5"}]}' | scripts/subagent-statusline.sh  # subagent smoke test
```

## Releases

Every push to `main` is tagged `cc-statusline--v<semver>` with an
auto-generated GitHub Release and `CHANGELOG.md` entry — see
`.github/workflows/bump-version.yml`. This release trail is for
changelog/version visibility only; it is not what keeps your installed
statusline script current. That happens independently, via the
marketplace-clone auto-pull described under Install above (`autoUpdate:
true` + `claude plugin marketplace update`), regardless of the `version`
field.

## License

MIT — see [LICENSE](LICENSE).
