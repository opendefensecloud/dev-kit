#!/usr/bin/env bash
set -euo pipefail

# Runs repo-settings.sh against a stub gh that records every call and keeps the
# ruleset it is sent, so the tests check what would reach the API without
# talking to GitHub.

ROOT="$(cd "$(dirname "$0")" && pwd)"
TESTDIR="$(mktemp -d)"
trap 'rm -rf "$TESTDIR"' EXIT

# The stub answers the reads repo-settings.sh makes and logs everything else.
# EXISTING_RULESET set: the protect-main ruleset exists with that ID.
cat > "$TESTDIR/gh" << 'EOF'
#!/usr/bin/env bash
echo "$*" >> "$STUB_LOG"
case "$1 $2" in
  "auth status") exit 0 ;;
  "repo view") echo "org/repo"; exit 0 ;;
esac
if [ "$1" = api ] && [[ "$2" == */rulesets* ]]; then
  input=""
  prev=""
  for arg in "$@"; do
    [ "$prev" = --input ] && input="$arg"
    prev="$arg"
  done
  if [ -n "$input" ]; then
    cat "$input" > "$STUB_RULESET"
  elif [ -n "${EXISTING_RULESET:-}" ]; then
    echo "$EXISTING_RULESET"
  fi
fi
exit 0
EOF
chmod +x "$TESTDIR/gh"

export GH="$TESTDIR/gh" JQ=jq
export STUB_LOG="$TESTDIR/calls" STUB_RULESET="$TESTDIR/ruleset.json"

# run <REPO_STATUS_CHECKS> [VAR=value...]: runs repo-settings.sh with the
# defaults from common.mk; later arguments override them. Sets $rc and $output.
run() {
  rm -f "$STUB_LOG" "$STUB_RULESET"
  touch "$STUB_LOG"
  set +e
  output="$(env \
    REPO_ADMIN_BYPASS=true \
    REPO_REQUIRED_APPROVING_REVIEW_COUNT=1 \
    REPO_REQUIRE_CODE_OWNER_REVIEW=false \
    REPO_REQUIRE_BRANCH_UP_TO_DATE=false \
    REPO_RULESET_BRANCHES='[]' \
    REPO_ALLOW_MERGE_COMMIT=true \
    REPO_ALLOW_SQUASH_MERGE=false \
    REPO_ALLOW_REBASE_MERGE=false \
    REPO_REQUIRE_LAST_PUSH_APPROVAL=false \
    REPO_STATUS_CHECKS="$1" \
    "${@:2}" \
    bash "$ROOT/repo-settings.sh" 2>&1)"
  rc=$?
  set -e
}

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

# checks: prints the required status checks of the ruleset that was sent.
checks() {
  jq -c '[.rules[] | select(.type == "required_status_checks")
    | .parameters.required_status_checks[]]' "$STUB_RULESET"
}

# expect_checks <REPO_STATUS_CHECKS> <want> <description>
expect_checks() {
  run "$1"
  report 0 "$rc" "$3: exit code"
  if [[ -f "$STUB_RULESET" ]]; then
    report "$2" "$(checks)" "$3"
  else
    report "$2" "no ruleset sent" "$3"
  fi
}

# expect_invalid <REPO_STATUS_CHECKS> <description>: the run fails before
# changing anything.
expect_invalid() {
  run "$1"
  report 1 "$rc" "$2: exit code"
  report "" "$(grep -vE '^(auth status|repo view)' "$STUB_LOG" || true)" "$2: nothing changed"
  if ! grep -q 'REPO_STATUS_CHECKS must be' <<< "$output"; then
    echo "FAIL $2: no error naming REPO_STATUS_CHECKS"
    fail=1
  fi
}

expect_checks '["lint", "action-pins / Check action pins"]' \
  '[{"context":"lint"},{"context":"action-pins / Check action pins"}]' \
  "contexts become context objects"
expect_checks '[{"context": "action-pins / Check action pins", "integration_id": 15368}]' \
  '[{"context":"action-pins / Check action pins","integration_id":15368}]' \
  "an integration_id is kept"
expect_checks '["lint", {"context": "Audit action pins", "integration_id": 15368}]' \
  '[{"context":"lint"},{"context":"Audit action pins","integration_id":15368}]' \
  "contexts and objects mix"
expect_checks '[{"context": "lint"}]' '[{"context":"lint"}]' \
  "an object without integration_id accepts any source"
expect_checks '["", "lint"]' '[{"context":"lint"}]' "empty strings are skipped"
expect_checks '[]' '[]' "no checks: no required_status_checks rule"

expect_invalid '[42]' "a number"
expect_invalid '[{"integration_id": 15368}]' "an object without context"
expect_invalid '[{"context": ""}]' "an object with an empty context"
expect_invalid '[{"context": "lint", "app": "github-actions"}]' "an unknown key"
expect_invalid '[{"context": "lint", "integration_id": "15368"}]' "integration_id as a string"
expect_invalid '"lint"' "not an array"

run '[""]' REPO_REQUIRE_BRANCH_UP_TO_DATE=true
report 1 "$rc" "up to date without a check still fails"

run '["lint"]' EXISTING_RULESET=42
report 0 "$rc" "existing ruleset: exit code"
report 1 "$(grep -cE '^api repos/org/repo/rulesets/42 -X PUT' "$STUB_LOG")" \
  "existing ruleset is updated in place"

exit "$fail"
