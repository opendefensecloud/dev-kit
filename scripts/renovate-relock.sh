#!/usr/bin/env bash
# Relock flake.lock on a Renovate branch whose flake.nix change Renovate cannot
# lock itself. Run from the consumer's checkout by renovate-dev-kit-lock.
#
#   renovate-relock.sh <head-ref> [<go-branch>]
#
# Every branch: `nix flake lock`, which relocks only inputs whose reference
# changed, e.g. a bumped dev-kit tag.
#
# <go-branch> (default renovate/go-version): goVersion changed, but no input
# reference did, and go-overlay follows its branch, so the locked one predates
# the new Go release. Refresh it, then require the dev shell to evaluate:
# go-overlay adds a release up to a day after it ships, and a lock that still
# lacks the version is not worth committing.
#
# Prints `what=<input>` and `changed=true|false` on stdout for $GITHUB_OUTPUT;
# everything else goes to stderr.
set -euo pipefail

head_ref=${1:?usage: $0 <head-ref> [<go-branch>]}
go_branch=${2:-renovate/go-version}

nix flake lock >&2

what=dev-kit
if [ "$head_ref" = "$go_branch" ] &&
  jq -e '.nodes.root.inputs["go-overlay"]' flake.lock > /dev/null; then
  what=go-overlay
  nix flake update go-overlay >&2
  system=$(nix eval --impure --raw --expr builtins.currentSystem)
  if ! nix eval --raw ".#devShells.$system.default.drvPath" > /dev/null; then
    echo "::error::The dev shell does not evaluate with the newest go-overlay; if it lacks the Go version yet, re-run this job later." >&2
    exit 1
  fi
fi
echo "what=$what"

if git diff --quiet -- flake.lock; then
  echo "flake.lock already matches flake.nix" >&2
  echo "changed=false"
else
  echo "changed=true"
fi
