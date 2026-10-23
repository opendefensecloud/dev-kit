#!/usr/bin/env bash
#
# Lists the commits in a range that will not appear in the generated release
# notes, and fails unless FORCE is true. Prints nothing and exits 0 when the
# range is fully representable.
#
#   check-release-notes.sh v0.3.0..HEAD
#
# Expects the git-cliff context in $CLIFF_CONTEXT (default: ctx.json), produced
# by:
#
#   git cliff --config <cliff.toml> --use-branch-tags --unreleased --bump --context
#
# A commit reaches the notes only if both of these hold:
#
#   1. it is a merge commit, because cliff.toml filters on merge_commit
#   2. its subject parses as a conventional commit, which is what picks a group
#
# The context check keeps a custom cliff config that groups extra types from
# stopping the release: if git-cliff renders the merge, the notes contain it.
#
# Squash and rebase merges fail the first. GitHub's default
# "Merge pull request #1 from ..." subject and the Revert button's default
# title fail the second.

set -euo pipefail

RANGE="${1:?usage: $0 <git range>, e.g. v0.3.0..HEAD}"
CLIFF_CONTEXT="${CLIFF_CONTEXT:-ctx.json}"
FORCE="${FORCE:-false}"

# The types cliff.toml assigns a group to. Anything else has no section to go
# into and is dropped.
CONVENTIONAL_TYPES='feat|fix|perf|refactor|revert|docs|ci|chore|test|style|build'

# git-cliff strips these before parsing, so they have to go here too, otherwise
# a subject like "✨ feat: thing" looks unparseable when git-cliff handles it
# fine. Keep in sync with commit_preprocessors in cliff.toml.
EMOJI_RANGES='\x{1F000}-\x{1FAFF}\x{2600}-\x{27BF}\x{2B00}-\x{2BFF}\x{FE0E}\x{FE0F}\x{200D}'

normalise_subjects() {
  perl -CSD -pe "s/[${EMOJI_RANGES}]//g; s/[ \\t]{2,}/ /g"
}

# Commits git-cliff will render. The notes template keeps merge commits only,
# so a non-merge that protect_breaking_commits puts in the context is not
# rendered and must still be reported.
rendered_ids=$(jq -r '.[0].commits[] | select(.merge_commit == true) | .id' "$CLIFF_CONTEXT")

missing=$(
  git log --first-parent "$RANGE" --format='%H%x09%h%x09%P%x09%s' |
    while IFS=$'\t' read -r sha short parents subject; do
      # Already represented in the notes.
      if grep -qxF "$sha" <<< "$rendered_ids"; then
        continue
      fi

      # A merge whose type the notes deliberately skip is not a missing
      # commit. Non-merges never reach the notes, so they are reported
      # whatever their type.
      if [[ "$parents" == *" "* ]]; then
        normalised=$(printf '%s' "$subject" | normalise_subjects)
        if [[ "$normalised" =~ ^(${CONVENTIONAL_TYPES})(\(.+\))?!?: ]]; then
          continue
        fi
      fi

      printf '%s %s\n' "$short" "$subject"
    done
)

if [ -z "$missing" ]; then
  exit 0
fi

printf '%s\n' "$missing"

if [ "$FORCE" != "true" ]; then
  echo "::error::These commits would be missing from the release notes. Fix the history, or re-run with force to release without them." >&2
  exit 1
fi

echo "::warning::Releasing without the commits above in the notes, because force is set." >&2
