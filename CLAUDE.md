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
- `${CLAUDE_PLUGIN_ROOT}` does **not** work for this purpose — it's only
  substituted inside a plugin's own manifest-defined commands (hooks, MCP
  servers), not in a user's personal `statusLine.command`, and even there
  it resolves to the version-pinned plugin cache directory
  (`~/.claude/plugins/cache/<marketplace>/<plugin>/<version>/...`), which
  changes on every update and is garbage-collected ~14 days later. The
  README instead points users at the **marketplace clone** path
  (`~/.claude/plugins/marketplaces/cc-statusline/scripts/statusline.sh`),
  which `claude plugin marketplace update` (auto-triggered by
  `autoUpdate: true` on the marketplace entry) refreshes in place via
  `git pull` — same absolute path, forever. Verified empirically
  2026-07-25: bumping `plugin.json` version and running `claude plugin
  marketplace update` left the marketplace path unchanged while the cache
  path gained a brand-new version-numbered sibling directory.
- `fmt_clock()` uses BSD `date -r <epoch>` (macOS). Any Linux compatibility
  fix belongs behind a `date -r ... || date -d @...` fallback in the
  script itself, not just a README note, if/when that's prioritized.

## Release process

`.github/workflows/bump-version.yml` (the `Release` workflow) handles
versioning automatically: every push to `main` (except the release bot's own
`chore(release):` commits) runs `scripts/bump-version.sh`, which bumps
`.claude-plugin/plugin.json`'s `version` field, prepends a section to
`CHANGELOG.md`, commits, tags the result `cc-statusline--v<semver>`, and
publishes a GitHub Release from that tag. Never hand-edit the `version`
field — the workflow owns it, and any manual edit is overwritten by the next
push.

The bump level is derived from Conventional Commit subjects since the last
`cc-statusline--v*` tag: a `!` after type/scope or a `BREAKING CHANGE:` body
trailer bumps major, any `feat:` subject (with no breaking change present)
bumps minor, everything else bumps patch — every push releases at least a
patch, mirroring the identical pattern already running in production on the
user's `devcycle` plugin repo. This makes PR titles load-bearing beyond
`validate.yml`'s existing Conventional Commit check (`pr-title` job): a
malformed title still fails that check, but a correctly-typed title is also
what determines whether the next release is a patch, minor, or major bump.
