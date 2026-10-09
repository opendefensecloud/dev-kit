#!/usr/bin/env bash
# Fixtures for check-dev-kit-pins.sh.
#
# dev-kit cannot dogfood this check: it has no dev-kit flake input, and its
# common.mk is the source file rather than a download. So the consuming
# repository's shape is built here instead — four files in a temp directory,
# one case per way they can disagree.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
TESTDIR="$(mktemp -d)"
trap 'rm -rf "$TESTDIR"' EXIT

cd "$TESTDIR"

SHA_A="c9fbc95b84be3c9acdb02656091eca21dfee8501"
SHA_B="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

run_test() {
  local name="$1" expected_rc="$2" expected_output="$3"

  echo "=== $name ==="
  local output rc
  set +e
  output="$(bash "$ROOT/check-dev-kit-pins.sh" 2>&1)"
  rc=$?
  set -e
  if [ -n "$output" ]; then
    echo "$output"
  fi
  if [ "$rc" -ne "$expected_rc" ]; then
    echo "FAIL: expected exit code $expected_rc, got $rc"
    exit 1
  fi
  if echo "$output" | grep -q "$expected_output"; then
    echo "PASS"
  else
    echo "FAIL: expected output to contain '$expected_output'"
    exit 1
  fi
  echo
}

reset() {
  rm -rf .github Makefile flake.nix flake.lock
}

# workflow <tag> [sha] — one stub and one composite-action reference, the shape
# a real consumer has.
workflow() {
  local tag="$1" sha="${2:-$SHA_A}"
  mkdir -p .github/workflows
  cat > .github/workflows/golang.yaml <<- EOF
		jobs:
		  lint:
		    steps:
		      - uses: opendefensecloud/dev-kit/.github/actions/setup-nix@${sha} # ${tag}
	EOF
  cat > .github/workflows/update-action-pins.yml <<- EOF
		jobs:
		  update-action-pins:
		    uses: opendefensecloud/dev-kit/.github/workflows/update-action-pins.yml@${sha} # ${tag}
	EOF
}

makefile() { printf 'DEV_KIT_VERSION := %s\n-include common.mk\n' "$1" > Makefile; }

flake() {
  cat > flake.nix <<- EOF
		{
		  inputs.dev-kit.url = "github:opendefensecloud/dev-kit/$1";
		}
	EOF
}

lock() { jq -n --arg rev "$1" '{nodes: {"dev-kit": {locked: {rev: $rev, type: "github"}}}}' > flake.lock; }

# --- every source present and agreeing ------------------------------------
reset
workflow v3.1.0
makefile v3.1.0
flake v3.1.0
lock "$SHA_A"
run_test "all four sources agree" 0 "dev-kit pins agree"

# --- each tag out of step --------------------------------------------------
reset
workflow v3.1.0
makefile v3.0.0
flake v3.1.0
lock "$SHA_A"
run_test "Makefile left behind" 1 "Makefile pins dev-kit v3.0.0"

reset
workflow v3.1.0
makefile v3.1.0
flake v3.0.0
lock "$SHA_A"
run_test "flake input left behind" 1 "flake.nix pins dev-kit v3.0.0"

# --- the case the check exists for ----------------------------------------
reset
workflow v3.1.0
makefile v3.1.0
flake v3.1.0
lock "$SHA_B"
run_test "lock resolved the tag to another commit" 1 "resolved dev-kit v3.1.0 to a different commit"

# --- references the comparison cannot read --------------------------------
reset
workflow v3.1.0
makefile v3.1.0
flake v3.1.0
lock "$SHA_A"
cat >> .github/workflows/golang.yaml <<- EOF
	      - uses: opendefensecloud/dev-kit/.github/actions/diff-check@v3.1.0
EOF
run_test "a reference pinned by tag, not SHA" 1 "not pinned as @<sha>"

reset
workflow v3.1.0
makefile v3.1.0
flake v3.1.0
lock "$SHA_A"
cat >> .github/workflows/golang.yaml <<- EOF
	      - uses: opendefensecloud/dev-kit/.github/actions/diff-check@${SHA_A}
EOF
run_test "a SHA pin with no tag comment" 1 "not pinned as @<sha>"

# --- a commented-out example is documentation, not a pin ------------------
reset
workflow v3.1.0
makefile v3.1.0
flake v3.1.0
lock "$SHA_A"
cat >> .github/workflows/golang.yaml <<- EOF
	# A consumer stub looks like this:
	#   uses: opendefensecloud/dev-kit/.github/workflows/osv-scanner.yml@<sha-or-tag>
EOF
run_test "a commented-out reference is ignored" 0 "dev-kit pins agree"

# --- workflows disagreeing among themselves -------------------------------
reset
workflow v3.1.0
makefile v3.1.0
flake v3.1.0
lock "$SHA_A"
cat >> .github/workflows/golang.yaml <<- EOF
	      - uses: opendefensecloud/dev-kit/.github/actions/diff-check@${SHA_B} # v3.0.0
EOF
run_test "two workflow pins at different commits" 1 "workflows disagree"

# --- absent sources are skipped, present-but-broken ones are not ----------
reset
makefile v3.1.0
flake v3.1.0
run_test "no workflows and no lock: the two tags still agree" 0 "dev-kit pins agree"

reset
workflow v3.1.0
lock "$SHA_A"
run_test "only workflows and a lock" 0 "dev-kit pins agree"

reset
workflow v3.1.0
makefile v3.1.0
flake v3.1.0
run_test "no lock at all" 0 "dev-kit pins agree"

reset
workflow v3.1.0
makefile v3.1.0
flake v3.1.0
lock "$SHA_A"
printf 'DEV_KIT_VERSION ?= main\n' > Makefile
run_test "a DEV_KIT_VERSION that is not a release tag" 1 "not 'DEV_KIT_VERSION := vX.Y.Z'"

reset
workflow v3.1.0
makefile v3.1.0
lock "$SHA_A"
printf '{\n  inputs.dev-kit.url = "github:opendefensecloud/dev-kit/main";\n}\n' > flake.nix
run_test "a flake input on a branch rather than a tag" 1 "not a release tag"

# --- a comment cannot stand in for the active reference ------------------
reset
makefile v3.1.0
flake v3.1.0
mkdir -p .github/workflows
cat > .github/workflows/x.yml <<- EOF
	jobs:
	  a:
	    steps:
	      - uses: opendefensecloud/dev-kit/.github/actions/setup-nix@main # was opendefensecloud/dev-kit/.github/actions/setup-nix@ # v3.1.0
EOF
run_test "a pin smuggled into a trailing comment" 1 "not pinned as @<sha>"

reset
workflow v3.1.0
makefile v3.1.0
lock "$SHA_A"
cat > flake.nix <<- EOF
	{
	  # url = "github:opendefensecloud/dev-kit/v3.1.0";
	  inputs.dev-kit.url = "github:opendefensecloud/dev-kit/main";
	}
EOF
run_test "a commented-out flake url beside a branch ref" 1 "not a release tag"

# --- a lock that cannot be compared --------------------------------------
reset
workflow v3.1.0
makefile v3.1.0
flake v3.1.0
echo '{"nodes": {"nixpkgs": {"locked": {"rev": "abc"}}}}' > flake.lock
run_test "a lock with no dev-kit rev beside a flake that wants one" 1 "has no rev for it"

# --- nothing to check at all ----------------------------------------------
reset
run_test "a repository with no dev-kit reference" 1 "no dev-kit reference found"

echo "All tests passed"
