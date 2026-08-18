#!/bin/bash
# Pushes main, waits for the Release workflow, then installs the DMG it published.
#
# The release job is the only thing that builds a versioned artefact, so this waits on the run
# rather than building locally — what lands in /Applications is exactly what users download.
# Falls back to the ZIP because package.sh skips the DMG when hdiutil misbehaves.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP=Tyland

command -v gh >/dev/null || { echo "gh CLI required: brew install gh" >&2; exit 1; }

branch=$(git rev-parse --abbrev-ref HEAD)
[ "$branch" = "main" ] || { echo "on '$branch', not main — switch or merge first" >&2; exit 1; }

if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "uncommitted changes — commit them first (conventional commit, it picks the version bump)" >&2
  exit 1
fi

sha=$(git rev-parse HEAD)
git push origin main

# Releases no longer fire on push — a README typo used to ship a build to every customer, and each
# one reset their permissions. Ask for the run explicitly.
gh workflow run release.yml --ref main

# The run does not exist the instant the dispatch returns, so wait for the one built from this commit.
echo "waiting for the release run…"
id=""
for _ in $(seq 1 60); do
  id=$(gh run list --workflow=release.yml --limit 20 \
       --json databaseId,headSha -q "map(select(.headSha==\"$sha\"))[0].databaseId" 2>/dev/null || true)
  [ -n "$id" ] && [ "$id" != "null" ] && break
  sleep 5
done
[ -n "$id" ] && [ "$id" != "null" ] || { echo "no release run for $sha — check: gh run list" >&2; exit 1; }

gh run watch "$id" --exit-status

# The job commits the changelog and version stamp back to main; stay in step with it.
git pull --rebase --autostash

tag=$(gh release view --json tagName -q .tagName)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

if gh release download "$tag" --pattern "$APP.dmg" --dir "$tmp" 2>/dev/null; then
  # The volume name has a space in it ("Tyland 0.4.2"), so take everything from /Volumes to EOL
  # rather than a column — hdiutil's column count varies with the image format.
  mount=$(hdiutil attach "$tmp/$APP.dmg" -nobrowse -readonly | sed -n 's#.*\(/Volumes/.*\)#\1#p' | tail -1)
  [ -d "$mount/$APP.app" ] || { hdiutil detach "$mount" -quiet || true; echo "no $APP.app in the DMG" >&2; exit 1; }
  src="$mount/$APP.app"
else
  echo "no DMG in $tag — installing the ZIP instead"
  gh release download "$tag" --pattern "$APP.zip" --dir "$tmp"
  ditto -x -k "$tmp/$APP.zip" "$tmp/unpacked"
  src="$tmp/unpacked/$APP.app"
  mount=""
fi

# Copying over a running app leaves a half-replaced bundle, so stop it first.
pkill -x "$APP" 2>/dev/null || true
rm -rf "/Applications/$APP.app"
ditto "$src" "/Applications/$APP.app"
[ -n "$mount" ] && hdiutil detach "$mount" -quiet
xattr -dr com.apple.quarantine "/Applications/$APP.app" 2>/dev/null || true

open -a "/Applications/$APP.app"
echo "installed $tag and relaunched $APP"
