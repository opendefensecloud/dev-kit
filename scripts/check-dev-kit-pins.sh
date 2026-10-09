#!/usr/bin/env bash
# Assert that every dev-kit reference in a consuming repository resolves to the
# same release.
#
# A consumer pins dev-kit in up to four places, and only one of them is both
# immutable and reviewed:
#
#   .github/workflows/*   @<sha> # <tag>   the commit, with the tag as a comment
#   Makefile              <tag>            DEV_KIT_VERSION, fetches common.mk
#   flake.nix             <tag>            the flake input
#   flake.lock            <sha>            what that tag resolved to when locked
#
# GitHub tags are mutable. flake.lock turns the tag into a commit, but that
# conversion happens whenever the lock is refreshed — including by
# renovate-dev-kit-lock, which runs unattended. A tag moved between a release
# and a relock would be adopted silently, and dev-kit's flake is the shell CI
# runs in, so the consequence is code execution in every job.
#
# The workflow pins are the defence: Renovate writes the commit it resolved, and
# a commit cannot move. Comparing the lock against them turns a moved tag into a
# failed check instead of a lockfile diff nobody reads. Drift between the three
# tags is caught as a side effect.
#
# This detects, it does not prevent. The prevention is immutable release tags on
# dev-kit, which would make the tag itself trustworthy.
#
# Sources are skipped when absent — a consumer without a flake is not checked
# for one. A source that exists but cannot be parsed is an error, never a skip:
# ignoring it is the same silent drift this script exists to catch.
#
# Needs jq, which the dev shell provides.

set -euo pipefail

WORKFLOWS="${WORKFLOWS:-.github/workflows}"
DEV_KIT_MAKEFILE="${DEV_KIT_MAKEFILE:-Makefile}"
FLAKE_NIX="${FLAKE_NIX:-flake.nix}"
FLAKE_LOCK="${FLAKE_LOCK:-flake.lock}"

# The accepted form of the reference GitHub actually resolves — the token after
# `uses:`, with no comment in it. The tag comment is validated separately,
# because a pin pattern sitting in a trailing comment says nothing about what
# runs: `uses: …@main # …@<sha> # v3.0.0` would otherwise read as pinned.
strict_ref="^opendefensecloud/dev-kit/[^@[:space:]]+@[0-9a-f]{40}$"
strict_tag="^v[0-9]+\.[0-9]+\.[0-9]+$"

fail() {
  echo "error: $*" >&2
  exit 1
}

# dev-kit itself, or a consumer that committed a pinned copy of common.mk — the
# same discriminator common.mk's own self-update uses. Such a repository has no
# dev-kit pins to reconcile, so finding none is the expected answer there rather
# than a misconfiguration.
is_dev_kit=false
if git ls-files --error-unmatch "$(dirname "$DEV_KIT_MAKEFILE")/common.mk" > /dev/null 2>&1; then
  is_dev_kit=true
fi

sha=""
tag=""
checked=()

if [ -d "$WORKFLOWS" ]; then
  # Only `uses:` lines, and only where no `#` precedes `uses:` — a commented-out
  # reference is documentation, which is how the README stubs are written.
  mapfile -t lines < <(
    grep -rnE "^[^#]*uses:[[:space:]]*opendefensecloud/dev-kit/" "$WORKFLOWS" || true
  )

  loose=()
  pins=()
  for line in "${lines[@]+"${lines[@]}"}"; do
    where="${line%%:*}:$(cut -d: -f2 <<< "$line")"
    content="${line#*:*:}"

    # The reference GitHub resolves, and the comment that is meant to name its
    # tag — read as separate tokens, never as a pattern somewhere in the line.
    ref="$(sed -E 's/.*uses:[[:space:]]*([^[:space:]]+).*/\1/' <<< "$content")"
    tag_comment="$(sed -E 's/[^#]*//; s/^#[[:space:]]*//; s/[[:space:]]*$//' <<< "$content")"

    if [[ ! $ref =~ $strict_ref ]] || [[ ! $tag_comment =~ $strict_tag ]]; then
      loose+=("$where: $ref${tag_comment:+ # $tag_comment}")
      continue
    fi
    pins+=("${ref##*@} $tag_comment")
  done

  # A reference the comparison cannot read is how drift gets in unseen, and a
  # tag-pinned one is mutable besides, so it fails rather than being skipped.
  if [ "${#loose[@]}" -gt 0 ]; then
    printf 'error: these dev-kit references are not pinned as @<sha> # vX.Y.Z:\n' >&2
    printf '  %s\n' "${loose[@]}" >&2
    exit 1
  fi

  mapfile -t pins < <(printf '%s\n' "${pins[@]+"${pins[@]}"}" | grep . | sort -u || true)
  if [ "${#pins[@]}" -gt 1 ]; then
    printf 'error: workflows disagree on which dev-kit commit to use:\n' >&2
    printf '  %s\n' "${pins[@]}" >&2
    exit 1
  fi
  if [ "${#pins[@]}" -eq 1 ]; then
    sha="${pins[0]%% *}"
    tag="${pins[0]##* }"
    checked+=("workflows=$tag")
  fi
fi

# expect_tag <source> <tag> — every tag found must agree. The first one seen
# becomes the reference, so a repository with no workflow pins still has its
# Makefile and flake cross-checked against each other.
expect_tag() {
  local source="$1" found="$2"
  if [ -z "$tag" ]; then
    tag="$found"
  elif [ "$found" != "$tag" ]; then
    fail "$source pins dev-kit $found but ${checked[0]%%=*} pins $tag"
  fi
  checked+=("$source=$found")
}

# DEV_KIT_VERSION := vX.Y.Z
#
# Skipped when common.mk is tracked by git — the same discriminator common.mk's
# own self-update uses. That means dev-kit itself, where DEV_KIT_VERSION is
# `main` by design, or a consumer that deliberately committed a pinned copy.
if [ -f "$DEV_KIT_MAKEFILE" ] && [ "$is_dev_kit" = false ]; then
  mk_tag="$(sed -nE 's/^[[:space:]]*DEV_KIT_VERSION[[:space:]]*:=[[:space:]]*(v[0-9]+\.[0-9]+\.[0-9]+)[[:space:]]*$/\1/p' "$DEV_KIT_MAKEFILE")"
  if grep -qE '^[[:space:]]*DEV_KIT_VERSION[[:space:]]*[:?+]?=' "$DEV_KIT_MAKEFILE"; then
    [ -n "$mk_tag" ] ||
      fail "$DEV_KIT_MAKEFILE has a DEV_KIT_VERSION that is not 'DEV_KIT_VERSION := vX.Y.Z'"
    expect_tag "$DEV_KIT_MAKEFILE" "$mk_tag"
  fi
fi

# url = "github:opendefensecloud/dev-kit/vX.Y.Z";
#
# Nix comments are stripped first, so a commented-out url cannot stand in for
# the active one — and the ref is read from inside the quotes rather than
# matched anywhere in the line.
flake_has_dev_kit=false
if [ -f "$FLAKE_NIX" ]; then
  flake_body="$(sed 's/#.*//' "$FLAKE_NIX")"
  if grep -q "github:opendefensecloud/dev-kit/" <<< "$flake_body"; then
    flake_has_dev_kit=true
    flake_ref="$(sed -nE 's#.*"github:opendefensecloud/dev-kit/([^"]*)".*#\1#p' <<< "$flake_body" | head -1)"
    [[ $flake_ref =~ $strict_tag ]] ||
      fail "$FLAKE_NIX pins the dev-kit input at '${flake_ref:-?}', not a release tag (vX.Y.Z)"
    expect_tag "$FLAKE_NIX" "$flake_ref"
  fi
fi

if [ "${#checked[@]}" -eq 0 ]; then
  if [ "$is_dev_kit" = true ]; then
    echo "no dev-kit pins to check: common.mk is tracked here"
    exit 0
  fi
  fail "no dev-kit reference found — checked $WORKFLOWS/, $DEV_KIT_MAKEFILE and $FLAKE_NIX"
fi

# The resolved commit in the lock, which is the value an unattended relock
# writes. Only comparable when a workflow pin gave us an immutable commit.
if [ -f "$FLAKE_LOCK" ]; then
  lock_sha="$(jq -r '.nodes["dev-kit"].locked.rev // empty' "$FLAKE_LOCK")"

  # A lock with no dev-kit rev, next to a flake that declares the input, is a
  # stale or hand-edited lock. Skipping the comparison there would report
  # agreement on the strength of the two mutable tags alone.
  if [ -z "$lock_sha" ] && [ "$flake_has_dev_kit" = true ]; then
    fail "$FLAKE_NIX declares the dev-kit input but $FLAKE_LOCK has no rev for it — run \`nix flake lock\`"
  fi
fi

if [ -f "$FLAKE_LOCK" ] && [ -n "$sha" ]; then
  if [ -n "$lock_sha" ] && [ "$lock_sha" != "$sha" ]; then
    cat >&2 <<- EOF
			error: $FLAKE_LOCK resolved dev-kit $tag to a different commit than the workflows pin.
			  $FLAKE_LOCK: $lock_sha
			  workflows:   $sha
			Either the lock is stale — run \`nix flake update dev-kit\` — or the $tag tag
			moved after the workflow pins were written, which needs investigating before
			this is merged: the flake input is the shell CI runs in.
		EOF
    exit 1
  fi
  [ -z "$lock_sha" ] || checked+=("$FLAKE_LOCK=$sha")
fi

echo "dev-kit pins agree: ${checked[*]}"
