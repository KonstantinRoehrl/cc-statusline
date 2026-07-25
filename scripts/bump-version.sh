#!/usr/bin/env bash
# Bumps plugin.json version from Conventional Commit subjects since the last
# cc-statusline--v* tag. Prepends a CHANGELOG section, writes
# .release-notes.md, and prints the new version to stdout.
# --dry-run: print "<level> <new_version>" and change nothing.
set -euo pipefail

dry=false
if [ "${1:-}" = "--dry-run" ]; then
  dry=true
fi

last_tag="$(git describe --tags --abbrev=0 --match 'cc-statusline--v*' 2>/dev/null || true)"
range="HEAD"
[ -n "$last_tag" ] && range="$last_tag..HEAD"

subjects="$(git log --format=%s "$range")"
bodies="$(git log --format=%b "$range")"

cc_regex='^(feat|fix|perf|docs|chore|ci|refactor|style|test|build)(\([a-z0-9-]+\))?(!)?: '

releasing=()
have_major=false
have_feat=false
while IFS= read -r subject; do
  [ -z "$subject" ] && continue
  if [[ "$subject" =~ $cc_regex ]]; then
    releasing+=("$subject")
    [ "${BASH_REMATCH[3]}" = "!" ] && have_major=true
    [[ "$subject" == feat* ]] && have_feat=true
  fi
done <<< "$subjects"

level="patch"
if [ "$have_major" = true ] || printf '%s' "$bodies" | grep -q 'BREAKING CHANGE:'; then
  level="major"
elif [ "$have_feat" = true ]; then
  level="minor"
fi

current_version="$(jq -r .version .claude-plugin/plugin.json)"
IFS='.' read -r major minor patch <<< "$current_version"

case "$level" in
  major) new_version="$((major + 1)).0.0" ;;
  minor) new_version="${major}.$((minor + 1)).0" ;;
  *)     new_version="${major}.${minor}.$((patch + 1))" ;;
esac

if [ "$dry" = true ]; then
  echo "$level $new_version"
  exit 0
fi

jq --arg v "$new_version" '.version = $v' .claude-plugin/plugin.json > .claude-plugin/plugin.json.tmp
mv .claude-plugin/plugin.json.tmp .claude-plugin/plugin.json

if [ "${#releasing[@]}" -eq 0 ]; then
  notes="- maintenance release"
else
  notes="$(printf -- '- %s\n' "${releasing[@]}")"
fi

printf '## %s\n\n%s\n' "$new_version" "$notes" > .release-notes.md

changelog_tmp="$(mktemp)"
{
  head -n 1 CHANGELOG.md
  printf '\n## %s\n\n%s\n' "$new_version" "$notes"
  tail -n +2 CHANGELOG.md
} > "$changelog_tmp"
mv "$changelog_tmp" CHANGELOG.md

echo "$new_version"
