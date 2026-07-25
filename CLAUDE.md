# cc-statusline

A Claude Code plugin distributing one file: `scripts/statusline.sh`. Global
conventions (Conventional Commits, branch discipline, CI hardening, etc.)
apply as-is — see the global CLAUDE.md. This file covers only what's
specific to this repo.

## What this repo is

Not an application — a plugin manifest (`.claude-plugin/plugin.json` +
`marketplace.json`) wrapping a single bash script. There is no build step
and no package manager.

## Testing

No test framework — verification is:

```
bash -n scripts/statusline.sh
shellcheck -S warning scripts/statusline.sh
echo '<sample JSON payload>' | scripts/statusline.sh
```

Info-level `SC2016` hits on the `j()` helper's single-quoted jq filters are
intentional (the filters must not undergo bash expansion) — don't "fix"
them by switching to double quotes. Lint at `-S warning` or higher, not the
default severity.

## Constraints to respect

- `statusLine` is a **user-level** Claude Code setting; a plugin manifest
  cannot set it. Don't add a `settings.json`-in-plugin key expecting it to
  auto-configure the user's statusline — document the manual snippet in
  README.md instead (it already is).
- Reference the script's own directory via `${CLAUDE_PLUGIN_ROOT}` in any
  install instructions, never a hardcoded path — that's what keeps
  `autoUpdate` installs working after every update.
- `fmt_clock()` uses BSD `date -r <epoch>` (macOS). Any Linux compatibility
  fix belongs behind a `date -r ... || date -d @...` fallback in the
  script itself, not just a README note, if/when that's prioritized.

## Release process

Bump `version` in `.claude-plugin/plugin.json` (semver) as part of the PR
that ships the change; `autoUpdate: true` on installs means marketplace
users pick up `dev`→`main` merges without a manual step on their end.
