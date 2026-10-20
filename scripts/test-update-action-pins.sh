#!/usr/bin/env bash
set -euo pipefail

# Runs the checks from update-action-pins.yml itself (extracted with yq), so
# the test cannot drift from what CI runs.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Keep the developer's git config (commit signing, hooks) out of the test repos.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

# step <name>: prints the run script of the check-pins step with that name.
step() {
  local run
  run="$(yq ".jobs.check-pins.steps[] | select(.name == \"$1\") | .run" \
    "$ROOT/.github/workflows/update-action-pins.yml")"
  [[ -n "$run" ]] || {
    echo "FAIL: step '$1' not found" >&2
    exit 1
  }
  printf '%s\n' "$run"
}

CHECK="$(step "Verify all actions are pinned to a SHA")"
MOVE_CHECK="$(step "Verify no pin moved to a new commit under the same version")"

SHA=0123456789abcdef0123456789abcdef01234567
fail=0

# report <want> <got> <description>
report() {
  if [[ "$2" == "$1" ]]; then
    echo "ok   $3"
  else
    echo "FAIL $3: expected $1, got $2"
    fail=1
  fi
}

# Steps run as `bash -eo pipefail`, which `shell: bash` gives in CI.
report bash "$(yq '.defaults.run.shell' "$ROOT/.github/workflows/update-action-pins.yml")" \
  "steps run with pipefail"

# expect <pass|fail> <description> <file under .github/> <content>
expect() {
  local want=$1 desc=$2 file=$3 content=$4 dir got
  dir="$(mktemp -d)"
  mkdir -p "$dir/.github/$(dirname "$file")"
  printf '%s\n' "$content" > "$dir/.github/$file"
  if (cd "$dir" && bash -eo pipefail -c "$CHECK") > /dev/null 2>&1; then got=pass; else got=fail; fi
  rm -rf "$dir"
  report "$want" "$got" "$desc"
}

expect pass "pinned action" workflows/a.yml "      - uses: actions/checkout@$SHA # v7"
expect pass "pinned reusable workflow" workflows/a.yml "    uses: org/repo/.github/workflows/x.yml@$SHA # v1"
expect pass "local action" workflows/a.yml "      - uses: ./.github/actions/foo"
expect pass "quoted local action" workflows/a.yml "      - uses: './.github/actions/foo'"
expect pass "double-quoted pinned action" workflows/a.yml "      - uses: \"actions/checkout@$SHA\" # v7"
expect fail "tag ref" workflows/a.yml "      - uses: actions/checkout@v7"
expect fail "double-quoted tag ref" workflows/a.yml "      - uses: \"actions/checkout@v7\""
expect fail "single-quoted tag ref" workflows/a.yml "      - uses: 'actions/checkout@v7'"
expect fail "extra sequence spacing" workflows/a.yml "      -   uses: actions/checkout@v7"
expect fail "unpinned reusable workflow" workflows/a.yml "    uses: org/repo/.github/workflows/x.yml@main"
expect fail "unpinned composite action" actions/foo/action.yml "    - uses: actions/checkout@v7"
expect fail "SHA only in the comment" workflows/a.yml "      - uses: actions/checkout@main # @$SHA"
expect fail "short SHA" workflows/a.yml "      - uses: actions/checkout@${SHA:0:7}"

OTHER=fedcba9876543210fedcba9876543210fedcba98

# expect_move <pass|fail> <description> <base content> <head content>: commits
# both versions of .github/workflows/a.yml and runs the moved-tag check on them.
expect_move() {
  local want=$1 desc=$2 base=$3 head=$4 dir got
  dir="$(mktemp -d)"
  mkdir -p "$dir/.github/workflows"
  (
    cd "$dir"
    git init -q
    printf '%s\n' "$base" > .github/workflows/a.yml
    git add -A && git -c user.name=t -c user.email=t@t commit -qm base
    printf '%s\n' "$head" > .github/workflows/a.yml
    git add -A && git -c user.name=t -c user.email=t@t commit -q --allow-empty -m head
  )
  if (cd "$dir" && bash -eo pipefail -c "$MOVE_CHECK") > /dev/null 2>&1; then got=pass; else got=fail; fi
  rm -rf "$dir"
  report "$want" "$got" "$desc"
}

expect_move pass "unchanged pin" \
  "      - uses: actions/checkout@$SHA # v7.0.1" \
  "      - uses: actions/checkout@$SHA # v7.0.1"
expect_move pass "new SHA with a new version" \
  "      - uses: actions/checkout@$SHA # v7.0.1" \
  "      - uses: actions/checkout@$OTHER # v7.0.2"
expect_move pass "same version of another action" \
  "      - uses: foo/bar@$SHA # v1.0.0" \
  "$(printf '      - uses: foo/bar@%s # v1.0.0\n      - uses: foo/baz@%s # v1.0.0' "$SHA" "$OTHER")"
expect_move fail "new SHA under the same version" \
  "      - uses: actions/checkout@$SHA # v7.0.1" \
  "      - uses: actions/checkout@$OTHER # v7.0.1"
expect_move fail "quoted pin with a new SHA" \
  "      - uses: \"actions/checkout@$SHA\" # v7.0.1" \
  "      - uses: 'actions/checkout@$OTHER' # v7.0.1"
expect_move fail "new SHA under another case of the action name" \
  "      - uses: actions/checkout@$SHA # v7.0.1" \
  "      - uses: Actions/Checkout@$OTHER # v7.0.1"
expect_move fail "reusable workflow with a new SHA" \
  "    uses: org/repo/.github/workflows/x.yml@$SHA # v1.2.3" \
  "    uses: org/repo/.github/workflows/x.yml@$OTHER # v1.2.3"
expect_move fail "second use of the same version with a new SHA" \
  "      - uses: actions/checkout@$SHA # v7.0.1" \
  "$(printf '      - uses: actions/checkout@%s # v7.0.1\n      - uses: actions/checkout@%s # v7.0.1' "$SHA" "$OTHER")"
expect_move pass "version already on two SHAs in the base, untouched" \
  "$(printf '      - uses: actions/checkout@%s # v7.0.1\n      - uses: actions/checkout@%s # v7.0.1' "$SHA" "$OTHER")" \
  "$(printf '      - uses: actions/checkout@%s # v7.0.1\n      - uses: actions/checkout@%s # v7.0.1' "$SHA" "$OTHER")"
expect_move pass "version already on two SHAs in the base, collapsed to one" \
  "$(printf '      - uses: actions/checkout@%s # v7.0.1\n      - uses: actions/checkout@%s # v7.0.1' "$SHA" "$OTHER")" \
  "      - uses: actions/checkout@$SHA # v7.0.1"
expect_move pass "first pin, none in the base" \
  "on: push" \
  "      - uses: actions/checkout@$SHA # v7.0.1"

# Without a base commit the check can't compare, so it must fail rather than
# treat every pin as new.
dir="$(mktemp -d)"
mkdir -p "$dir/.github/workflows"
(
  cd "$dir"
  git init -q
  printf '%s\n' "      - uses: actions/checkout@$OTHER # v7.0.1" > .github/workflows/a.yml
  git add -A && git -c user.name=t -c user.email=t@t commit -qm head
)
if (cd "$dir" && bash -eo pipefail -c "$MOVE_CHECK") > /dev/null 2>&1; then got=pass; else got=fail; fi
rm -rf "$dir"
report fail "$got" "no base commit"

exit "$fail"
