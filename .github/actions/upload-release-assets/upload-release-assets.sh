#!/usr/bin/env bash
# Uploads release assets only to a draft that still targets the commit they
# were built from. Publishing makes a release immutable, and a newer run may
# have moved the draft on, so both are checked before and after the upload.
#
# Env: TAG, SHA (full commit), FILES (one path or glob per line),
# GITHUB_REPOSITORY, GH_TOKEN.
set -euo pipefail

: "${TAG:?TAG is required}"
: "${SHA:?SHA is required}"
: "${FILES:?FILES is required}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"

if [[ ! "$SHA" =~ ^[0-9a-f]{40}$ ]]; then
  echo "::error::sha must be a full commit SHA, got '${SHA}'."
  exit 1
fi

files=()
shopt -s nullglob
while IFS= read -r pattern; do
  pattern="${pattern#"${pattern%%[![:space:]]*}"}"
  pattern="${pattern%"${pattern##*[![:space:]]}"}"
  [ -n "$pattern" ] || continue
  # Unquoted on purpose: the pattern is a glob. An empty IFS keeps paths
  # with spaces whole.
  IFS=
  # shellcheck disable=SC2206
  matches=($pattern)
  unset IFS
  if [ ${#matches[@]} -eq 0 ]; then
    echo "::error::No file matches '${pattern}'."
    exit 1
  fi
  files+=("${matches[@]}")
done <<< "$FILES"
shopt -u nullglob

# check <when>: fails unless TAG is a draft targeting SHA.
check() {
  local state is_draft target
  if ! state=$(gh release view "$TAG" --repo "$GITHUB_REPOSITORY" \
    --json isDraft,targetCommitish --jq '"\(.isDraft) \(.targetCommitish)"'); then
    echo "::error::Release ${TAG} not found $1."
    exit 1
  fi
  read -r is_draft target <<< "$state"

  if [ "$is_draft" != "true" ]; then
    echo "::error::Release ${TAG} was published $1. Published releases are immutable, so its assets are missing or were built from another commit. Do not publish while the Release run is building assets; cut the next version."
    exit 1
  fi
  if [ "$target" != "$SHA" ]; then
    echo "::error::Draft ${TAG} now targets ${target}, but these assets were built from ${SHA} (checked $1). A newer run owns the draft; it builds its own assets."
    exit 1
  fi
}

check "before the upload"
echo "Uploading ${#files[@]} assets to draft ${TAG} at ${SHA}."
# --clobber makes a retry idempotent; it can only replace assets on a draft.
gh release upload "$TAG" "${files[@]}" --repo "$GITHUB_REPOSITORY" --clobber
check "during the upload"
