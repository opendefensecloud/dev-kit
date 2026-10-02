#!/usr/bin/env bash
set -euo pipefail

# Runs the pin check from update-action-pins.yml itself (extracted with yq), so
# the test cannot drift from what CI runs.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK="$(yq '.jobs.check-pins.steps[] | select(.name == "Verify all actions are pinned to a SHA") | .run' \
  "$ROOT/.github/workflows/update-action-pins.yml")"
[[ -n "$CHECK" ]] || { echo "FAIL: pin check step not found"; exit 1; }

SHA=0123456789abcdef0123456789abcdef01234567
fail=0

# expect <pass|fail> <description> <file under .github/> <content>
expect() {
  local want=$1 desc=$2 file=$3 content=$4 dir got
  dir="$(mktemp -d)"
  mkdir -p "$dir/.github/$(dirname "$file")"
  printf '%s\n' "$content" > "$dir/.github/$file"
  if (cd "$dir" && bash -c "$CHECK") >/dev/null 2>&1; then got=pass; else got=fail; fi
  rm -rf "$dir"
  if [[ "$got" == "$want" ]]; then
    echo "ok   $desc"
  else
    echo "FAIL $desc: expected $want, got $got"
    fail=1
  fi
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

exit "$fail"
