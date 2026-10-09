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

# The one accepted form for a reference in a workflow. Used both to reject
# anything else and to read the pins, so the two cannot drift apart.
strict="opendefensecloud/dev-kit/[^@]+@[0-9a-f]{40} # v[0-9]+\.[0-9]+\.[0-9]+"

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
  # Every workflow line mentioning dev-kit, as file:line:content, minus YAML
  # comments: a commented-out reference is documentation — dev-kit's own
  # README stubs are written that way — not a pin.
  mapfile -t refs < <(
    grep -rnE "opendefensecloud/dev-kit/" "$WORKFLOWS" |
      grep -vE "^[^:]*:[0-9]+:[[:space:]]*#" || true
  )

  # Anything referencing dev-kit that is not in the strict form is reported
  # rather than skipped: a reference the comparison cannot read is how drift
  # gets in unseen, and a tag-pinned reference is mutable on top of that.
  mapfile -t loose < <(printf '%s\n' "${refs[@]+"${refs[@]}"}" | grep -vE "$strict" | grep . || true)
  if [ "${#loose[@]}" -gt 0 ]; then
    printf 'error: these dev-kit references are not pinned as @<sha> # vX.Y.Z:\n' >&2
    printf '  %s\n' "${loose[@]}" >&2
    exit 1
  fi

  mapfile -t pins < <(
    printf '%s\n' "${refs[@]+"${refs[@]}"}" |
      grep -oE "[0-9a-f]{40} # v[0-9]+\.[0-9]+\.[0-9]+" | sort -u
  )
  if [ "${#pins[@]}" -gt 1 ]; then
    printf 'error: workflows disagree on which dev-kit commit to use:\n' >&2
    printf '  %s\n' "${pins[@]}" >&2
    exit 1
  fi
  if [ "${#pins[@]}" -eq 1 ]; then
    sha="${pins[0]%% *}"
    tag="${pins[0]##*# }"
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
if [ -f "$FLAKE_NIX" ]; then
  if grep -q "github:opendefensecloud/dev-kit/" "$FLAKE_NIX"; then
    flake_tag="$(sed -nE 's#.*github:opendefensecloud/dev-kit/(v[0-9]+\.[0-9]+\.[0-9]+).*#\1#p' "$FLAKE_NIX")"
    [ -n "$flake_tag" ] ||
      fail "$FLAKE_NIX references dev-kit but not as github:opendefensecloud/dev-kit/vX.Y.Z"
    expect_tag "$FLAKE_NIX" "$flake_tag"
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
if [ -f "$FLAKE_LOCK" ] && [ -n "$sha" ]; then
  lock_sha="$(jq -r '.nodes["dev-kit"].locked.rev // empty' "$FLAKE_LOCK")"
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
