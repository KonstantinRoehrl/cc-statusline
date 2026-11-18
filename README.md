# cc-statusline

A 4-line ANSI dashboard statusline for [Claude Code](https://claude.com/claude-code):

```
model   Sonnet 5 (high)        dir     Programming #42 ✓
ctx     ●●●●●●●●●●  47%        rolling ●●●●●●●●●●  62% ↻10:37
cache   ●●●●●●●●●●  85% ◷50m   week    ●●●●●●●●●●  30% Mon 09:37
lines   +214 -58               tokens  84.2k in · 12.1k out
```

| Row | Left column | Right column |
|---|---|---|
| 1 | model + effort level | folder · git branch, then the open PR: `#42 ✓` approved, `✗` changes requested, `…` pending, `◌` draft (`!7` for a GitLab merge request); nothing when there is no open PR |
| 2 | context-window meter | rolling 5h rate-limit meter + reset clock |
| 3 | prompt-cache hit-rate meter + `◷50m` time until the cache goes cold (red in its last 20% of the TTL; whole hours, e.g. `◷20h`, past 99 minutes) | weekly rate-limit meter + weekday-clock reset (⚡ early-exhaustion warning when projected to hit 100% before reset) |
| 4 | session line diff (+added/-removed) | cumulative input/output tokens |

Meters are dotted bars, gradient-colored by health (green → amber → red as
usage climbs; the cache-hit meter inverts the scale since higher is better).
No emojis, no external services — everything is derived from the JSON
payload Claude Code already feeds the statusline command on stdin.

## Requirements

- `jq` 1.7+ on `PATH` (`brew install jq` on macOS, `apt install jq` on Linux).
- A 24-bit true-color terminal (iTerm2, Kitty, Alacritty, VS Code's integrated
  terminal, and most modern terminals all qualify) — the gradients use
  `\033[38;2;R;G;Bm` escapes, not the 256-color palette.
- The reset clocks work on macOS and Linux with no setup: they try GNU `date -d @<epoch>` first and fall
  back to BSD `date -r <epoch>`.

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

## Agent panel rows

The plugin ships a small Claude Code mod that restyles the rows of Claude Code's built-in agent panel,
for subagents and teammates, in the format the original subagent status line used: the model the agent
runs on (with its effort level when known), its context-window usage, its task description, and its
token count. Each agent appears once, in the panel.

```
Opus-4.8 (high) · ctx 42% · Trivial subagent for statusline test · 420.0k tok
— · researcher · 0 tok
```

Installing the plugin is the whole setup: there is nothing to add to `settings.json`. The mod is early
access in Claude Code and was written against **Claude Code v2.1.327**. Details:

- `tok` is the agent's token count as Claude Code reports it: its latest request's input plus all its
  output. `ctx NN%` is that over the agent's context window, and appears whenever the window is known.
- The effort shown is the level set for the agent, else the one its last request carried; with neither,
  the row has no parentheses.
- A teammate running in a terminal pane of its own has no model Claude Code can report, so its row shows
  `—` in place of the model.
- Per-subagent cache-hit rate is not shown, as before.

If `subagentStatusLine` is set in `~/.claude/settings.json`, a command that prints a row takes precedence
over the mod's row. If it still points at the `scripts/subagent-statusline.sh` that v1.0.0 removed,
delete that key: the mod draws the row either way, but Claude Code keeps running the missing command.

## How it works

Claude Code invokes the configured `statusLine` command on an interval,
piping a JSON payload (model, effort, workspace, context-window usage,
rate-limit usage, session cost) to stdin. `scripts/statusline.sh` reads that
payload with `jq`, computes percentages and reset times, and prints four
ANSI-colored lines. The last raw payload is cached at
`~/.claude/statusline-last-payload.json` for debugging or discovering new
fields Claude Code starts sending.

Claude Code builds the rate-limit numbers from each session's own last API response, so a session
that is idle would show frozen usage while other sessions keep spending. To keep the rolling and weekly
meters current, every run also saves its limits to
`${CLAUDE_CONFIG_DIR:-~/.claude}/statusline-cache/<session-id>.limits.json` (override the directory
with `CC_STATUSLINE_CACHE_DIR`) and shows the freshest across all sessions: the newest window, and
within it the highest usage. Once a window has reset and no session has used the new one yet, the meter
shows 0% with `--:--` (`--- --:--` for the weekly meter) as reset time until fresh data arrives. Snapshots older than 8 days are deleted;
if the directory is unusable the statusline silently falls back to its own session's numbers.
`~/.claude/statusline-last-payload.json` is a debugging aid only: nothing reads it back.

## Development

```bash
for f in scripts/statusline.sh scripts/statusline-lib.sh tests/smoke.sh; do bash -n "$f"; done  # bash -n only parses its first file argument
shellcheck -S warning scripts/statusline.sh scripts/statusline-lib.sh tests/smoke.sh
bash tests/smoke.sh   # end-to-end cases for statusline.sh, each in a throwaway HOME and cache directory
HOME="$(mktemp -d)" claude plugin validate .   # manifest and agent row mod checks
HOME="$(mktemp -d)" claude plugin test .       # hooks/*.test.ts(x); needs Claude Code on PATH
```

Type-checking the mod with tsc needs the type definitions Claude Code writes to .claude-plugin/types/ when a session loads the mod from a folder (claude --plugin-dir .); that folder is gitignored and CI does not run tsc.

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
