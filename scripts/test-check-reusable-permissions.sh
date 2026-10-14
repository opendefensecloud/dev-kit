#!/usr/bin/env bash
# Fixtures for check-reusable-permissions.sh.
#
# dev-kit dogfoods this check: CI runs it against this repository own workflows.
# But the interesting cases are the broken ones, which must not be committed.
# So each case builds a miniature repo in a temp directory: one called workflow,
# one caller, and the README stub a consumer would copy.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
TESTDIR="$(mktemp -d)"
trap 'rm -rf "$TESTDIR"' EXIT

cd "$TESTDIR"

run_test() {
  local name="$1" expected_rc="$2" expected_output="$3"

  echo "=== $name ==="
  local output rc
  set +e
  output="$(bash "$ROOT/check-reusable-permissions.sh" "$TESTDIR" 2>&1)"
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
  rm -rf .github README.md
  mkdir -p .github/workflows
}

# emit_perms <indent> <value>
# "-" omits the block. A value with a colon is a mapping written on the
# following lines; one without is a scalar on the same line, which is how
# `permissions: read-all` and `permissions: {}` are spelled.
emit_perms() {
  local ind="$1" val="$2"
  [ "$val" = "-" ] && return 0
  case "$val" in
    *:*)
      printf '%spermissions:\n' "$ind"
      printf '%s\n' "$val" | sed "s/^/${ind}  /"
      ;;
    *) printf '%spermissions: %s\n' "$ind" "$val" ;;
  esac
}

# callee <workflow-permissions> <job-permissions>
callee() {
  {
    echo "name: Callee"
    emit_perms "" "$1"
    echo "on:"
    echo "  workflow_call:"
    echo "jobs:"
    echo "  work:"
    echo "    runs-on: ubuntu-24.04"
    emit_perms "    " "$2"
    echo "    steps:"
    echo "      - run: 'true'"
  } > .github/workflows/callee.yml
}

# local_caller <workflow-permissions> <job-permissions>
local_caller() {
  {
    echo "name: Local caller"
    emit_perms "" "$1"
    echo "on:"
    echo "  pull_request:"
    echo "jobs:"
    echo "  call:"
    emit_perms "    " "$2"
    echo "    uses: ./.github/workflows/callee.yml"
  } > .github/workflows/local-caller.yml
}

# readme_stub <workflow-permissions> <job-permissions>
readme_stub() {
  {
    echo "# Fixture"
    echo
    echo '```yaml'
    echo "name: Consumer"
    emit_perms "" "$1"
    echo "on:"
    echo "  pull_request:"
    echo "jobs:"
    echo "  consume:"
    emit_perms "    " "$2"
    echo "    uses: opendefensecloud/dev-kit/.github/workflows/callee.yml@0000000000000000000000000000000000000000 # v0.0.0"
    echo '```'
  } > README.md
}

# ---------------------------------------------------------------------------
# The two rules
# ---------------------------------------------------------------------------

reset
callee "contents: read" "-"
local_caller "contents: read" "-"
run_test "caller job inherits a workflow-level grant that is enough" 0 "ok    callee.yml"

reset
callee "contents: read" "-"
local_caller "contents: read" "contents: write"
run_test "write satisfies a request for read" 0 "ok    callee.yml"

# The #53 class: the job block replaces the workflow block, so contents is gone.
reset
callee "contents: read" "issues: write"
local_caller "contents: read" "issues: write"
run_test "job-level block replaces rather than merges" 1 "contents: wants read, caller grants none"

reset
callee "contents: read" "-"
local_caller "contents: read" "{}"
run_test "explicit empty grant does not fall back to the workflow level" 1 "contents: wants read, caller grants none"

reset
callee "{}" "issues: write"
local_caller "contents: read" "issues: write"
run_test "callee asking for nothing at the workflow level passes" 0 "ok    callee.yml"

# A called workflow cannot elevate at its job level either.
reset
callee "{}" "pull-requests: write"
local_caller "contents: read" "contents: read"
run_test "callee job-level request is capped by the caller too" 1 "pull-requests: wants write, caller grants none"

reset
callee "actions: read
contents: read" "-"
local_caller "contents: read" "contents: read
security-events: write"
run_test "only the missing key is reported" 1 "actions: wants read, caller grants none"

# ---------------------------------------------------------------------------
# read-all / write-all, which are valid at both levels
# ---------------------------------------------------------------------------

reset
callee "read-all" "-"
local_caller "contents: read" "contents: read"
run_test "a callee wanting read-all is not satisfied by one scope" 1 "all scopes: wants read, caller grants none"

reset
callee "read-all" "-"
local_caller "contents: read" "read-all"
run_test "a callee wanting read-all is satisfied by read-all" 0 "ok    callee.yml"

reset
callee "contents: read" "-"
local_caller "contents: read" "write-all"
run_test "write-all satisfies a request for one scope" 0 "ok    callee.yml"

# ---------------------------------------------------------------------------
# Who counts as a caller
# ---------------------------------------------------------------------------

reset
callee "contents: read" "-"
local_caller "contents: read" "contents: read"
readme_stub "contents: read" "issues: write"
run_test "a broken README stub fails even when the in-repo caller is fine" 1 "README.md (stub) (consume)"

reset
callee "contents: read" "-"
local_caller "contents: read" "contents: read"
readme_stub "contents: read" "contents: read"
run_test "both callers correct" 0 "ok    callee.yml"

reset
callee "contents: read" "-"
local_caller "-" "-"
run_test "caller declaring nothing anywhere warns instead of failing" 0 "WARN  callee.yml"

reset
callee "contents: read" "-"
run_test "a reusable workflow nobody calls warns" 0 "nothing calls it in this repo or the README"

# Another repository's workflow can share a filename with ours; its grant must
# not be compared against our callee.
reset
callee "contents: read" "-"
local_caller "contents: read" "contents: read"
cat >> .github/workflows/local-caller.yml << 'EOF'
  theirs:
    permissions: {}
    uses: someorg/unrelated/.github/workflows/callee.yml@0000000000000000000000000000000000000000
EOF
run_test "a foreign workflow with the same filename is not a caller" 0 "ok    callee.yml"

# ---------------------------------------------------------------------------
# Unparseable input must stop the check, not shrink it
# ---------------------------------------------------------------------------

# The broken file is also the broken caller, so swallowing the parse error
# would turn a FAIL into a pass with the callee reported as uncalled.
reset
callee "contents: read" "-"
local_caller "contents: read" "issues: write"
echo '  oops: [this is: not valid' >> .github/workflows/local-caller.yml
run_test "a workflow that does not parse fails the check" 1 "cannot parse"

reset
callee "contents: read" "-"
local_caller "contents: read" "contents: read"
readme_stub "contents: read" "contents: read"
# Break the stub that calls us.
sed -i 's|^on:$|on: [this is: not valid|' README.md
run_test "a README stub that calls us and does not parse fails the check" 1 "does not parse"

# An illustrative fragment that does not call us may legitimately not stand
# alone, and must not fail the check.
reset
callee "contents: read" "-"
local_caller "contents: read" "contents: read"
{
  echo "# Fixture"
  echo
  echo '```yaml'
  echo "# a fragment, not a whole workflow"
  echo "with: {scan-args: |-"
  echo '```'
} > README.md
run_test "an unparseable fragment that does not call us is ignored" 0 "ok    callee.yml"

echo "All checks passed."
