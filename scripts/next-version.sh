#!/bin/bash
# Decides the next version from the conventional-commit messages since the last release tag.
#
# Prints KEY=VALUE lines, so the release workflow can append the output straight to $GITHUB_OUTPUT:
#   release=true|false   whether there is anything worth releasing
#   version=X.Y.Z        only when release=true
#   range=<git range>    the commits the changelog should cover
#
# `--self-check` runs the whole thing against throwaway repos and asserts the bumps. Run it after
# touching any of the patterns below — they are the sort of regex that looks right and isn't.
set -uo pipefail

# `feat!:` / `fix(x)!:` / a `BREAKING CHANGE:` trailer -> major. `feat:` -> minor. `fix|perf` -> patch.
BREAKING='^[a-z]+(\([^)]*\))?!:|^BREAKING CHANGE'
FEATURE='^feat(\([^)]*\))?:'
PATCHY='^(fix|perf)(\([^)]*\))?:'

next_version() {
  local last range major minor patch log bump

  # Highest exact vX.Y.Z tag. `git describe --match` is a *glob*, so it happily matches
  # `v1.2.3-beta` and feeds "3-beta" into the arithmetic below; this is an anchored regex instead.
  # `sort -V` so v1.10.0 outranks v1.9.0, which a lexical sort gets backwards.
  last=$(git tag --list 'v*' | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1)
  if [ -n "$last" ]; then
    range="$last..HEAD"
    IFS=. read -r major minor patch <<< "${last#v}"
  else
    # No tags yet: whatever is on the branch right now becomes 0.1.0.
    range="HEAD"
    major=0; minor=1; patch=0
  fi

  log=$(git log --no-merges --pretty=format:'%s%n%b' "$range")

  if [ -z "$last" ]; then
    bump=initial
  elif printf '%s' "$log" | grep -qE "$BREAKING"; then
    bump=major
  elif printf '%s' "$log" | grep -qE "$FEATURE"; then
    bump=minor
  elif printf '%s' "$log" | grep -qE "$PATCHY"; then
    bump=patch
  elif [ "${EVENT:-}" = "workflow_dispatch" ]; then
    bump=patch   # a manual run always ships something
  else
    bump=none
  fi

  case "$bump" in
    major)   major=$((major + 1)); minor=0; patch=0 ;;
    minor)   minor=$((minor + 1)); patch=0 ;;
    patch)   patch=$((patch + 1)) ;;
    initial) ;;
    none)
      echo "release=false"
      echo "nothing releasable since ${last:-the beginning}" >&2
      return 0
      ;;
  esac

  echo "release=true"
  echo "version=$major.$minor.$patch"
  echo "range=$range"
  echo "releasing $major.$minor.$patch ($bump) from $range" >&2
}

# --- self-check -------------------------------------------------------------

self_check() {
  local failures=0

  # $1 = description, $2 = expected `version=` (or "none"), $3 = starting tags, space separated
  # (or ""), $4… = commit subjects to lay down after the tags.
  case_() {
    local want_desc="$1" want="$2" tags="$3"; shift 3
    local dir out got
    dir=$(mktemp -d)
    (
      cd "$dir" || exit 1
      git init -q .
      git config user.email t@t; git config user.name t
      git commit -q --allow-empty -m "chore: base"
      for t in $tags; do git tag "$t"; done
      for msg in "$@"; do git commit -q --allow-empty -m "$msg"; done
    )
    out=$(cd "$dir" && next_version 2>/dev/null)
    rm -rf "$dir"

    if [ "$want" = "none" ]; then
      got=$(printf '%s' "$out" | grep -c '^release=false')
      [ "$got" = "1" ] && got=none || got="$out"
    else
      got=$(printf '%s' "$out" | sed -n 's/^version=//p')
    fi

    if [ "$got" = "$want" ]; then
      echo "  ok   $want_desc -> $got"
    else
      echo "  FAIL $want_desc -> got '$got', want '$want'" >&2
      failures=$((failures + 1))
    fi
  }

  echo "next-version self-check"
  case_ "no tags at all"          "0.1.0" ""       "feat: anything"
  case_ "feature"                 "1.3.0" "v1.2.3" "feat: add a thing"
  case_ "scoped feature"          "1.3.0" "v1.2.3" "feat(notch): add a thing"
  case_ "fix only"                "1.2.4" "v1.2.3" "fix: repair a thing"
  case_ "perf counts as a fix"    "1.2.4" "v1.2.3" "perf: speed a thing up"
  case_ "bang is breaking"        "2.0.0" "v1.2.3" "feat!: replace a thing"
  case_ "scoped bang is breaking" "2.0.0" "v1.2.3" "fix(core)!: replace a thing"
  case_ "trailer is breaking"     "2.0.0" "v1.2.3" "feat: x

BREAKING CHANGE: the thing moved"
  case_ "feature outranks fix"    "1.3.0" "v1.2.3" "fix: a" "feat: b"
  case_ "breaking outranks all"   "2.0.0" "v1.2.3" "fix: a" "feat: b" "refactor!: c"
  case_ "docs alone release nothing" "none" "v1.2.3" "docs: tweak the readme"
  case_ "chore alone releases nothing" "none" "v1.2.3" "chore: bump a dep"
  case_ "prerelease tag is not a release" "0.1.0" "v1.2.3-beta" "feat: add a thing"
  case_ "picks the newest tag, not the longest" "1.11.0" "v1.9.0 v1.10.0" "feat: add a thing"
  case_ "ignores junk tags alongside real ones" "1.2.4" "nightly v1.2.3" "fix: repair a thing"

  EVENT=workflow_dispatch case_ "manual run always ships" "1.2.4" "v1.2.3" "docs: tweak"

  if [ "$failures" -gt 0 ]; then
    echo "$failures case(s) failed" >&2
    return 1
  fi
  echo "all cases passed"
}

if [ "${1:-}" = "--self-check" ]; then
  self_check
else
  next_version
fi
