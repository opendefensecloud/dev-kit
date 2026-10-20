#!/usr/bin/env bash
set -euo pipefail

# Runs the steps from audit-action-pins.yml itself (extracted with yq), so the
# test cannot drift from what CI runs; the filter runs on findings shaped like
# zizmor's json-v1 output.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Keep the developer's git config (commit signing, hooks) out of the test repos.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

# step <name>: prints the run script of the audit-pins step with that name.
step() {
  local run
  run="$(yq ".jobs.audit-pins.steps[] | select(.name == \"$1\") | .run" \
    "$ROOT/.github/workflows/audit-action-pins.yml")"
  [[ -n "$run" ]] || {
    echo "FAIL: step '$1' not found" >&2
    exit 1
  }
  printf '%s\n' "$run"
}

FILTER="$(step "Fail on untrusted pins")"
LIST="$(step "List the lines the PR changes")"

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

# The steps below run as `bash -eo pipefail`, which `shell: bash` gives in CI.
report bash "$(yq '.defaults.run.shell' "$ROOT/.github/workflows/audit-action-pins.yml")" \
  "steps run with pipefail"

# finding <ident>: prints one finding on .github/workflows/a.yml line 7 as
# zizmor reports it.
finding() {
  jq -n --arg ident "$1" '{
    ident: $ident,
    desc: "description",
    locations: [{
      symbolic: {key: {Local: {verbatim_path: "./.github/workflows/a.yml"}}, kind: "Primary", annotation: null},
      concrete: {location: {start_point: {row: 6, column: 8}}}
    }]
  }'
}

# check <pass|fail> <description> <report>: runs the filter on <report> as
# zizmor.json, scoped to the lines in $SCOPE (one <path>:<line> each) when set.
check() {
  local want=$1 desc=$2 dir got
  dir="$(mktemp -d)"
  printf '%s' "$3" > "$dir/zizmor.json"
  if [[ -n "${SCOPE+x}" ]]; then printf '%s' "$SCOPE" > "$dir/changed-lines"; fi
  if RUNNER_TEMP=$dir bash -eo pipefail -c "$FILTER" > /dev/null 2>&1; then got=pass; else got=fail; fi
  rm -rf "$dir"
  report "$want" "$got" "$desc"
}

# expect <pass|fail> <description> <finding>...: runs the filter on a report
# holding the given findings.
expect() {
  local want=$1 desc=$2
  shift 2
  if (($#)); then
    check "$want" "$desc" "$(printf '%s\n' "$@" | jq -s .)"
  else
    check "$want" "$desc" '[]'
  fi
}

expect pass "no findings"
expect pass "other audits only" "$(finding artipacked)" "$(finding known-vulnerable-actions)"
expect fail "impostor-commit" "$(finding impostor-commit)"
expect fail "ref-version-mismatch" "$(finding ref-version-mismatch)"
expect fail "relevant finding among others" "$(finding artipacked)" "$(finding impostor-commit)"
check fail "empty report" ''
check fail "truncated report" '[{"ident": "impostor-commit"'
check fail "report that isn't an array" '{"error": "rate limited"}'
check fail "finding in an unexpected shape" '[{"ident": "impostor-commit", "desc": "description"}]'

SCOPE=".github/workflows/a.yml:7"
expect fail "finding on a changed line" "$(finding impostor-commit)"
SCOPE=".github/workflows/a.yml:8"
expect pass "finding on an unchanged line" "$(finding ref-version-mismatch)"
SCOPE=".github/workflows/b.yml:7"
expect pass "finding on the same line of another file" "$(finding impostor-commit)"
unset SCOPE

# expect_lines <description> <file> <base> <head> <expected lines> <expected
# audit>: commits both versions of <file> (none when empty) and runs the list
# step on them. Expected lines are <path>:<line>, space-separated; expected
# audit is the step's `audit` output.
expect_lines() {
  local desc=$1 file=$2 base=$3 head=$4 want="$5 audit=$6" dir got
  dir="$(mktemp -d)"
  mkdir -p "$dir/repo/$(dirname "$file")"
  (
    cd "$dir/repo"
    git init -q
    if [[ -n "$base" ]]; then printf '%s\n' "$base" > "$file"; fi
    git add -A && git -c user.name=t -c user.email=t@t commit -q --allow-empty -m base
    if [[ -n "$head" ]]; then printf '%s\n' "$head" > "$file"; else rm -f "$file"; fi
    git add -A && git -c user.name=t -c user.email=t@t commit -q --allow-empty -m head
  )
  if (cd "$dir/repo" && RUNNER_TEMP=$dir GITHUB_OUTPUT=$dir/output bash -eo pipefail -c "$LIST") > /dev/null 2>&1; then
    got="$(tr '\n' ' ' < "$dir/changed-lines" | sed 's/ $//') $(cat "$dir/output")"
  else
    got="(step failed)"
  fi
  rm -rf "$dir"
  report "$want" "$got" "$desc"
}

A=".github/workflows/a.yml"
expect_lines "changed line" "$A" "$(printf 'a\nb\nc')" "$(printf 'a\nB\nc')" "$A:2" true
expect_lines "added lines" "$A" "$(printf 'a\nc')" "$(printf 'a\nb1\nb2\nc')" "$A:2 $A:3" true
expect_lines "removed line only" "$A" "$(printf 'a\nb\nc')" "$(printf 'a\nc')" "" false
expect_lines "new file" "$A" "" "$(printf 'a\nb')" "$A:1 $A:2" true
expect_lines "deleted file" "$A" "$(printf 'a\nb')" "" "" false
expect_lines "added line that looks like a header" "$A" "a" "$(printf 'a\n++ b')" "$A:2" true

for f in .github/workflows/a.yaml .github/actions/foo/action.yml action.yaml \
  ".github/actions/my action/action.yml" .github/actions/größe/action.yml; do
  expect_lines "change to $f" "$f" "" "a" "$f:1" true
done
for f in main.go .github/dependabot.yml .github/workflows/sub/a.yml myaction.yml; do
  expect_lines "change to $f" "$f" "" "a" "$f:1" false
done

# Without the base commit, the list step must fail rather than find no changes.
dir="$(mktemp -d)"
mkdir -p "$dir/repo/.github/workflows"
(
  cd "$dir/repo"
  git init -q
  printf 'a\n' > .github/workflows/a.yml
  git add -A && git -c user.name=t -c user.email=t@t commit -q -m head
)
if (cd "$dir/repo" && RUNNER_TEMP=$dir GITHUB_OUTPUT=$dir/output bash -eo pipefail -c "$LIST") > /dev/null 2>&1; then
  got=pass
else
  got=fail
fi
rm -rf "$dir"
report fail "$got" "missing base commit"

exit "$fail"
