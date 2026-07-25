# Release automation design

Date: 2026-07-25
Status: approved

## Problem

cc-statusline has no release automation: no git tags, no GitHub Releases, no
release workflow. `.claude-plugin/plugin.json`'s `version` field is bumped by
hand, as documented (until this change) in this repo's `CLAUDE.md`. The user
wants version bumps, tags, and GitHub Releases to happen automatically on
every push/merge to `main`, mirroring the pattern already running in
production on the user's `devcycle` plugin repo
(`.github/workflows/bump-version.yml` + `scripts/bump-version.mjs`).

## Non-goal / pre-existing fact

The stated end goal — "whenever I open Claude Code, the plugin is
auto-updated" — is **already satisfied today**, independent of this design:

- `~/.claude/plugins/known_marketplaces.json` already has `"autoUpdate": true`
  for the `cc-statusline` marketplace entry. Per Claude Code's own docs, this
  causes the marketplace git clone at
  `~/.claude/plugins/marketplaces/cc-statusline/` to auto-refresh
  (`git pull`) in the background after startup (~10 minute random delay).
- This repo's `CLAUDE.md` already documents that the README points users at
  that exact marketplace-clone path
  (`~/.claude/plugins/marketplaces/cc-statusline/scripts/statusline.sh`) for
  their `statusLine.command`, specifically *because* `autoUpdate: true` keeps
  it current via `git pull` at a stable absolute path — independent of the
  `version` field in `plugin.json`.
- Known platform gap (GitHub issue #61854): `autoUpdate: true` reliably
  refreshes the marketplace catalog, but does not reliably re-run
  `claude plugin update` against the versioned plugin **cache**
  (`~/.claude/plugins/cache/<marketplace>/<plugin>/<version>/`). This gap
  does not affect cc-statusline, because the script is consumed directly from
  the marketplace clone, never from the cache.

So this design is about **release hygiene** — semver, tags, changelog,
GitHub Releases, matching the devcycle pattern — not about making the script
update live. That already works.

## Approach

Hand-rolled bash+jq workflow, structurally mirroring devcycle's
`bump-version.yml`, reimplemented in bash instead of Node to match this
repo's existing all-bash, no-package-manager, no-build-step convention
(`CLAUDE.md`already establishes this constraint; `validate.yml` already uses
`jq`). Rejected alternatives: `release-please` (PR-based release model,
doesn't match "as devcycle does", adds a third-party action to audit) and
`semantic-release` (requires `package.json` + npm install, conflicts with the
repo's explicit no-build-step/no-package-manager constraint).

## Design

### New workflow: `.github/workflows/bump-version.yml`

```yaml
name: Release
on:
  push:
    branches: [main]
permissions:
  contents: read
concurrency:
  group: release-main
  cancel-in-progress: false
jobs:
  bump:
    if: ${{ !contains(github.event.head_commit.message, '[skip ci]') }}
    runs-on: ubuntu-latest
    permissions:
      contents: write
    steps:
      - uses: actions/checkout@<pinned-sha> # vX.Y.Z — same pin as validate.yml
        with:
          fetch-depth: 0
      - name: Bump version and changelog
        id: bump
        run: echo "version=$(scripts/bump-version.sh)" >> "$GITHUB_OUTPUT"
      - name: Commit, tag, release
        env:
          GH_TOKEN: ${{ github.token }}
          V: ${{ steps.bump.outputs.version }}
        run: |
          if git rev-parse -q --verify "refs/tags/cc-statusline--v$V" >/dev/null; then
            echo "tag cc-statusline--v$V already exists — nothing to release"
            exit 0
          fi
          git config user.name "github-actions[bot]"
          git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
          git add .claude-plugin/plugin.json CHANGELOG.md
          git commit -m "chore(release): v$V [skip ci]"
          n=0
          until git push origin main; do
            n=$((n+1))
            if [ "$n" -ge 3 ]; then
              echo "branch push failed after $n rebase retries — manual release repair needed"
              exit 1
            fi
            git pull --rebase origin main
          done
          git tag "cc-statusline--v$V"
          git push origin "cc-statusline--v$V"
          gh release create "cc-statusline--v$V" --title "cc-statusline v$V" --notes-file .release-notes.md
```

Notes:
- `permissions: contents: write` on the job is sufficient even though the
  repo's default workflow permission is `read` (confirmed: devcycle's own
  repo has the identical `default_workflow_permissions: read` and this exact
  pattern works there today).
- The `[skip ci]` guard prevents the bot's own release commit from
  re-triggering this workflow.
- Branch push happens before the tag push: a tag pushed before a failed
  branch push would leave an orphan tag blocking every later release
  (mirrors devcycle's comment/reasoning verbatim).
- This is CI (`github-actions[bot]`, scoped `GITHUB_TOKEN`, explicit job
  permission) pushing directly to `main`, not a human or Claude session — the
  case the user's "never push main directly" rule is not meant to block, and
  which the user's own devcycle repo already does identically.

### New script: `scripts/bump-version.sh`

Bash + jq, no new runtime dependency (jq already used in `validate.yml`).
Supports a `--dry-run` flag (mirrors devcycle's script) that prints the
computed level and version to stdout without writing any files — used for
local/CI testing without mutating repo state. Responsibilities:

1. `git describe --tags --abbrev=0 --match 'cc-statusline--v*'` for the last
   release tag (empty today — no tags exist yet, so the first run ranges
   over full history).
2. `git log --format=%s <range>` (subjects) and `--format=%b <range>`
   (bodies, for `BREAKING CHANGE:` detection).
3. Classify the bump level against the Conventional Commit regex
   `^(feat|fix|perf|docs|chore|ci|refactor|style|test|build)(\([a-z0-9-]+\))?(!)?: `
   (same regex `validate.yml`'s `pr-title` job already enforces):
   - any subject with `!` after type/scope, or `BREAKING CHANGE:` in a body
     → `major`
   - else any `feat:` subject → `minor`
   - else → `patch` (default — every push bumps at least patch; mirrors
     devcycle's behavior exactly, per approved design decision: release scope
     is "every push", not gated to only feat/fix/perf/breaking)
4. Read current version via `jq -r .version .claude-plugin/plugin.json`;
   compute the new semver string with bash arithmetic on the
   `.`-split components.
5. Write the new version back:
   `jq --arg v "$new" '.version = $v' .claude-plugin/plugin.json > tmp && mv tmp .claude-plugin/plugin.json`.
6. Write `.release-notes.md` (git-ignored): a bullet list of the
   Conventional-Commit-formatted subjects in range, or `- maintenance
   release` if none matched.
7. Prepend a `## <version>` section (with the same bullet list) to
   `CHANGELOG.md`, under its `# Changelog` header.
8. Print the new version to stdout (captured by the workflow step as
   `$GITHUB_OUTPUT`).

### Supporting file changes

- **New `CHANGELOG.md`** at repo root, seeded with a `# Changelog` header.
- **`.gitignore`**: add `.release-notes.md`.
- **`.github/workflows/validate.yml`**: unchanged — its existing JSON/smoke
  checks already cover bot-authored commits.
- **`CLAUDE.md`** ("Release process" section): rewritten to describe the
  automated flow — version bumps, tags, and GitHub Releases happen
  automatically on every push to `main`; contributors must never hand-edit
  `.claude-plugin/plugin.json`'s `version` field; PR titles must stay
  Conventional-Commit-formatted (already CI-enforced) since that drives bump
  classification.
- **`README.md`**: note that releases are tagged
  `cc-statusline--v<semver>` with auto-generated GitHub Releases, and
  clarify that the statusline script itself updates independently via the
  marketplace-clone auto-pull (see Non-goal section above) — the release
  trail is for changelog/version visibility, not a precondition for the
  script staying current.

### Tag / release naming

`cc-statusline--v<semver>`, matching devcycle's `<plugin-name>--v<semver>`
convention exactly.

### Release artifact scope

Source-only (GitHub's auto-generated source archive at the tag). No
SHA256SUMS file — matches devcycle's own releases under the same global
CLAUDE.md rule, since neither repo publishes standalone binary/build
artifacts.

## Testing

- `bash -n scripts/bump-version.sh` (syntax).
- `shellcheck -S warning scripts/bump-version.sh`.
- Manual dry run (`--dry-run` flag on the script, printing the computed level
  and version without writing files) against this repo's real, empty tag
  history, to confirm the classification logic runs against the actual
  commit log and produces valid JSON output — the exact resulting version
  depends on this repo's real commit history at implementation time and is
  not asserted here.
- End-to-end verification happens by observing the first real push to `main`
  produce a tag + GitHub Release (or via a manual `workflow_dispatch`-free
  dry run of the script locally, since GitHub Actions has no safe way to
  "trial run" a push-triggered workflow without an actual push).

## Open risk / caveat carried forward

None blocking. The GitHub issue #61854 plugin-cache gap is noted above as
context but is out of scope to fix (it's a Claude Code platform issue, not
something this repo's release workflow can address).
