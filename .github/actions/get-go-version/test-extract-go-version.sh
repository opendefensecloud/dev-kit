#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
TESTDIR="$(mktemp -d)"
trap 'rm -rf "$TESTDIR"' EXIT

cd "$TESTDIR"

run_test() {
  local name="$1"
  local expected_rc="$2"
  local expected_output="$3"

  echo "=== $name ==="
  local output
  set +e
  output="$("$ROOT/extract-go-version.sh" 2>&1)"
  local rc=$?
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
}

echo "=== Test 1: extract version ==="
echo '  goVersion = "1.22.3";' > flake.nix
GITHUB_OUTPUT="$(mktemp)"
export GITHUB_OUTPUT
"$ROOT/extract-go-version.sh"
version="$(sed 's/^version=//' "$GITHUB_OUTPUT")"
if [ "$version" != "1.22.3" ]; then
  echo "FAIL: expected version 1.22.3, got $version"
  exit 1
fi
echo "PASS"

echo '' > flake.nix
run_test "Test 2: no goVersion (missing)" 1 "Expected exactly one"

printf '  goVersion = "1.22.3";\n  goVersion = "1.23.0";\n' > flake.nix
run_test "Test 3: multiple matches" 1 "Expected exactly one"

echo "✅ All tests passed"
