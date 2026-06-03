#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
TESTDIR="$(mktemp -d)"
trap 'rm -rf "$TESTDIR"' EXIT

cd "$TESTDIR" || exit
git init
git config user.email "test@test"
git config user.name "Test"
git commit --no-gpg-sign --allow-empty -m "init"

run_test() {
  local name="$1"
  local expected_rc="$2"
  local expected_output="$3"

  echo "=== $name ==="
  local output
  set +e
  output="$("$ROOT/verify-clean.sh" 2>&1)"
  local rc=$?
  set -e
  echo "$output"
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
}

run_test "Test 1: clean tree" 0 "clean"

touch new.txt
run_test "Test 2: untracked file" 1 "dirty"

echo "data" > tracked.txt && git add tracked.txt && git commit --no-gpg-sign -m "add"
echo "modified" > tracked.txt
run_test "Test 3: modified tracked file" 1 "dirty"

rm new.txt && git add tracked.txt && git commit --no-gpg-sign -m "fix"
run_test "Test 4: committed file (should be clean)" 0 "clean"

echo "✅ All tests passed"
