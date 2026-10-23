#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
TESTDIR="$(mktemp -d)"
trap 'rm -rf "$TESTDIR"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

new_repo() {
  local dir="$1"
  mkdir -p "$dir"
  cd "$dir"
  git init -q -b main
  git config user.email test@example.com
  git config user.name Test
  git config commit.gpgsign false
  git config tag.gpgsign false
  git commit -q --allow-empty -m "chore: init"
  git tag v0.1.0
}

merge_commit() {
  local branch="$1"
  local subject="$2"
  local title="$3"
  git checkout -q -b "$branch" main
  git commit -q --allow-empty -m "$subject"
  git checkout -q main
  git merge -q --no-ff "$branch" -m "$title"
  git rev-parse HEAD
}

# Mixed history: rendered and unrendered merges, a deliberately skipped type,
# and direct commits on main.
new_repo "$TESTDIR/mixed"

feat_merge=$(merge_commit feat "feat: real feature" "feat: real feature (#1)")
merge_commit test "test: thing" "test: skipped merge (#2)" > /dev/null
weird_merge=$(merge_commit weird "whatever" "Weird title (#3)")
deps_merge=$(merge_commit deps "deps: bump" "deps: bump (#4)")
breaking_merge=$(merge_commit breaking "feat!: breaking" "feat!: breaking merge (#5)")

# Conventional subject with emoji and extra whitespace, absent from the
# context: normalization must trim it so the type filter still skips it.
merge_commit spaced "feat: spaced" "  ✨  feat:   spaced   feature  " > /dev/null

git commit -q --allow-empty -m "fix: direct commit"
fix_direct=$(git rev-parse HEAD)
git commit -q --allow-empty -m "feat!: direct breaking commit"
breaking_direct=$(git rev-parse HEAD)

# The context also carries protected breaking non-merges. The notes template
# renders merges only, so those must still be reported.
jq -n \
  --arg feat "$feat_merge" \
  --arg deps "$deps_merge" \
  --arg breaking "$breaking_merge" \
  --arg direct_breaking "$breaking_direct" \
  '[{commits: [
    {id: $feat, merge_commit: true},
    {id: $deps, merge_commit: true},
    {id: $breaking, merge_commit: true},
    {id: $direct_breaking, merge_commit: false}
  ]}]' > ctx.json

expected=$(
  printf '%s %s\n' "$(git rev-parse --short "$breaking_direct")" "feat!: direct breaking commit"
  printf '%s %s\n' "$(git rev-parse --short "$fix_direct")" "fix: direct commit"
  printf '%s %s\n' "$(git rev-parse --short "$weird_merge")" "Weird title (#3)"
)

echo "=== Test 1: mixed history ==="
set +e
actual=$(CLIFF_CONTEXT=ctx.json bash "$ROOT/check-release-notes.sh" v0.1.0..HEAD 2> /dev/null)
rc=$?
set -e
[ "$rc" -eq 1 ] || fail "expected exit 1, got $rc"
[ "$actual" = "$expected" ] || fail "unexpected output:
$actual"
echo "PASS"

echo "=== Test 2: force ==="
set +e
actual=$(FORCE=true CLIFF_CONTEXT=ctx.json bash "$ROOT/check-release-notes.sh" v0.1.0..HEAD 2> /dev/null)
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "expected exit 0, got $rc"
[ "$actual" = "$expected" ] || fail "unexpected output:
$actual"
echo "PASS"

# Clean history: the only commit since the tag is rendered.
new_repo "$TESTDIR/clean"
clean_merge=$(merge_commit feat "feat: only feature" "feat: only feature (#1)")
jq -n --arg id "$clean_merge" '[{commits: [{id: $id, merge_commit: true}]}]' > ctx.json

echo "=== Test 3: nothing missing ==="
set +e
actual=$(CLIFF_CONTEXT=ctx.json bash "$ROOT/check-release-notes.sh" v0.1.0..HEAD 2> /dev/null)
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "expected exit 0, got $rc"
[ -z "$actual" ] || fail "expected no output, got:
$actual"
echo "PASS"

# Root commit: an empty %P field must not shift the subject into parents.
new_repo "$TESTDIR/root"
jq -n '[{commits: []}]' > ctx.json

echo "=== Test 4: root commit keeps its subject ==="
set +e
actual=$(CLIFF_CONTEXT=ctx.json bash "$ROOT/check-release-notes.sh" HEAD 2> /dev/null)
rc=$?
set -e
[ "$rc" -eq 1 ] || fail "expected exit 1, got $rc"
expected="$(git rev-parse --short HEAD) chore: init"
[ "$actual" = "$expected" ] || fail "unexpected output:
$actual"
echo "PASS"

# The shared config is the contract for the guard's subject normalisation and
# type list. Assert that the two have not drifted apart.
echo "=== Test 5: guard constants match the shared cliff.toml ==="
config="$ROOT/../../../cliff.toml"
[ -f "$config" ] || fail "shared cliff.toml not found at $config"

guard_emoji=$(awk -F"'" '/^EMOJI_RANGES=/{print $2}' "$ROOT/check-release-notes.sh")
guard_types=$(awk -F"'" '/^CONVENTIONAL_TYPES=/{print $2}' "$ROOT/check-release-notes.sh")
[ -n "$guard_emoji" ] || fail "could not read EMOJI_RANGES from check-release-notes.sh"
[ -n "$guard_types" ] || fail "could not read CONVENTIONAL_TYPES from check-release-notes.sh"

config_emoji=$(awk -F'[][]' '/1F000/{print $2}' "$config")
[ "$config_emoji" = "$guard_emoji" ] || fail "EMOJI_RANGES drifted from the shared cliff.toml"

config_types=$(grep -oE "message = '\^[a-z]+" "$config" | sed "s/message = '\^//" | sort -u | paste -sd'|')
expected_types=$(printf '%s' "$guard_types" | tr '|' '\n' | sort -u | paste -sd'|')
[ "$config_types" = "$expected_types" ] || fail "CONVENTIONAL_TYPES drifted from the shared cliff.toml (config: ${config_types})"
echo "PASS"

echo "✅ All tests passed"
