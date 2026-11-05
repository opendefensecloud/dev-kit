#!/usr/bin/env bash
set -euo pipefail

# Runs steps from release.yml itself (extracted with yq), so the test cannot
# drift from what CI runs, against a stub gh whose releases live in files.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORKFLOW="$ROOT/.github/workflows/release.yml"
TESTDIR="$(mktemp -d)"
trap 'rm -rf "$TESTDIR"' EXIT

# Keep the developer's git config (commit signing, hooks) out of the test repo.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

OLD=1111111111111111111111111111111111111111
NEW=2222222222222222222222222222222222222222

# step <job> <name>: prints the run script of that step.
step() {
  local run
  run="$(yq ".jobs.$1.steps[] | select(.name == \"$2\") | .run" "$WORKFLOW")"
  [[ -n "$run" && "$run" != null ]] || {
    echo "FAIL: step '$2' not found in job $1" >&2
    exit 1
  }
  printf '%s\n' "$run"
}

# Releases: $STATE/releases/<tag>/{draft,target,assets}. The stub answers the
# exact queries release.yml makes, with their --jq already applied.
mkdir -p "$TESTDIR/bin"
cat > "$TESTDIR/bin/gh" << 'GH'
#!/usr/bin/env bash
set -euo pipefail
echo "gh $*" >> "$STATE/calls"
rel="$STATE/releases/${3:-}"
case "$1 $2" in
  "release list")
    for d in "$STATE"/releases/*/; do
      [ -d "$d" ] || continue
      [ "$(cat "$d/draft")" = true ] && basename "$d"
    done
    ;;
  "release view")
    [ -d "$rel" ] || exit 1
    case "$*" in
      *"--json isDraft "*) [ "$(cat "$rel/draft")" = true ] && echo draft || echo published ;;
      *"--json targetCommitish "*) cat "$rel/target" ;;
      *"--json assets "*) cat "$rel/assets" 2>/dev/null || true ;;
      *) echo "unexpected view: $*" >&2; exit 2 ;;
    esac
    ;;
  "release delete-asset"|"release edit"|"release create") ;;
  *) echo "unexpected gh call: $*" >&2; exit 2 ;;
esac
GH
chmod +x "$TESTDIR/bin/gh"

# A repository whose only local tag is v1.0.0.
REPO="$TESTDIR/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q -b main
git -C "$REPO" -c user.email=t@example.com -c user.name=T commit -q --allow-empty -m "chore: init"
git -C "$REPO" tag v1.0.0

fail=0
report() { # report <want> <got> <description>
  if [[ "$2" == "$1" ]]; then echo "ok   $3"; else
    echo "FAIL $3: expected '$1', got '$2'"
    fail=1
  fi
}

# fresh: new stub state and step output file.
fresh() {
  export STATE="$TESTDIR/state-$RANDOM$RANDOM"
  mkdir -p "$STATE/releases"
  : > "$STATE/calls"
  export GITHUB_OUTPUT="$STATE/output"
  : > "$GITHUB_OUTPUT"
}

release() { # release <tag> <draft> <target> [asset...]
  local d="$STATE/releases/$1"
  mkdir -p "$d"
  echo "$2" > "$d/draft"
  echo "$3" > "$d/target"
  shift 3
  : > "$d/assets"
  for a in "$@"; do echo "$a" >> "$d/assets"; done
}

# exec_step <script> [VAR=value...]: runs the script as CI does (bash -e,
# pipefail via set in the script) in the test repo; prints pass|fail.
exec_step() {
  local script=$1
  shift
  if (cd "$REPO" && env PATH="$TESTDIR/bin:$PATH" GITHUB_REPOSITORY=org/repo "$@" \
    bash -e -c "$script" > "$STATE/log" 2>&1); then
    echo pass
  else
    echo fail
  fi
}

calls() { grep -c "$1" "$STATE/calls" || true; }

# --- Frozen tagged draft -----------------------------------------------------

PENDING="$(step prepare "Guard - no tagged draft release already pending")"

fresh
release v1.0.0 true "$OLD"
report pass "$(exec_step "$PENDING" EVENT_NAME=push)" "push with a tagged draft pending succeeds"
report "frozen=true" "$(cat "$GITHUB_OUTPUT")" "push with a tagged draft pending marks the run frozen"

fresh
release v1.0.0 true "$OLD"
report fail "$(exec_step "$PENDING" EVENT_NAME=workflow_dispatch)" "manual run with a tagged draft pending fails"

fresh
release v1.1.0 true "$OLD"
report pass "$(exec_step "$PENDING" EVENT_NAME=push)" "an untagged draft does not block"
report "" "$(cat "$GITHUB_OUTPUT")" "an untagged draft does not freeze the run"

# Every step after the guard must skip when frozen; only the dry-run notice
# may run, and it changes nothing.
# yq expressions, not shell.
# shellcheck disable=SC2016
unguarded=$(yq '.jobs.prepare.steps as $s
  | ($s | to_entries | map(select(.value.id == "pending")) | .[0].key) as $i
  | $s[($i + 1):][]
  | select(.name != "Dry run notice")
  | select((.if // "") | test("steps.pending.outputs.frozen != .true.") | not)
  | .name' "$WORKFLOW")
report "" "$unguarded" "every step after the guard skips a frozen run"

# --- Releasable commits ------------------------------------------------------

RELEASABLE="$(step prepare "Guard - something releasable landed")"

releasable() { # releasable <event> <raw message...>: prints pass|fail and the output
  local event=$1
  shift
  printf '%s\n' "$@" | jq -R '{raw_message: ., breaking: false}' | jq -s '[{commits: .}]' > "$REPO/ctx.json"
  : > "$GITHUB_OUTPUT"
  printf '%s %s\n' "$(exec_step "$RELEASABLE" EVENT_NAME="$event" REF_TYPE=branch PREVIOUS_TAG=v1.0.0)" \
    "$(cat "$GITHUB_OUTPUT")"
}

fresh
report "pass releasable=true" "$(releasable push "fix: thing (#1)")" "a fix commit is releasable"
report "pass releasable=false" "$(releasable push "chore: tidy (#1)" "docs: typo (#2)")" "chore and docs alone leave the draft untouched on push"
report "fail " "$(releasable workflow_dispatch "chore: tidy (#1)")" "chore alone fails a manual run"
rm -f "$REPO/ctx.json"

# --- Stale assets when the draft moves --------------------------------------

UPDATE="$(step prepare "Create or update draft release")"
touch "$REPO/notes.md"

fresh
release v1.1.0 true "$OLD" app-linux app-linux.sigstore.json
report pass "$(exec_step "$UPDATE" ASSETS=false VERSION=v1.1.0 SHA="$NEW")" "draft moves to a new commit"
report 2 "$(calls "release delete-asset v1.1.0")" "a moved draft drops the assets built for the old commit"
report 1 "$(calls "release edit v1.1.0 .*--target $NEW")" "a moved draft is retargeted"
report pass "$(grep -n 'delete-asset' "$STATE/calls" | tail -1 | cut -d: -f1 | {
  read -r last_delete
  edit=$(grep -n 'release edit' "$STATE/calls" | cut -d: -f1)
  [ "$last_delete" -lt "$edit" ] && echo pass || echo fail
})" "assets are deleted before the draft is retargeted"
report 1 "$(calls "release edit v1.1.0 .*--title v1.1.0 ")" "a caller without assets gets the plain title"

fresh
release v1.1.0 true "$OLD"
report pass "$(exec_step "$UPDATE" ASSETS=true VERSION=v1.1.0 SHA="$NEW")" "update for a caller with assets"
report 1 "$(calls "release edit v1.1.0 .*--title v1.1.0 (assets pending) ")" "a caller with assets marks the draft pending"

fresh
report pass "$(exec_step "$UPDATE" ASSETS=true VERSION=v1.1.0 SHA="$NEW")" "new draft for a caller with assets"
report 1 "$(calls "release create v1.1.0 .*--title v1.1.0 (assets pending) ")" "a new draft is created pending"

fresh
release v1.1.0 true "$NEW" app-linux
report pass "$(exec_step "$UPDATE" ASSETS=false VERSION=v1.1.0 SHA="$NEW")" "re-run at the same commit"
report 0 "$(calls "delete-asset")" "a re-run at the same commit keeps its assets"

fresh
release v1.1.0 true "$NEW" solar-v1.1.0.intoto.jsonl
report pass "$(exec_step "$UPDATE" ASSETS=false VERSION=v1.2.0 SHA="$NEW")" "draft renamed to a new version"
report 1 "$(calls "release delete-asset v1.1.0 solar-v1.1.0.intoto.jsonl")" "a renamed draft drops assets named for the old version"

fresh
release v1.1.0 true "$OLD"
report pass "$(exec_step "$UPDATE" ASSETS=false VERSION=v1.1.0 SHA="$NEW")" "a moved draft without assets updates"
report 0 "$(calls "delete-asset")" "nothing to delete on a draft without assets"

fresh
release v1.1.0 false "$OLD" app-linux
report fail "$(exec_step "$UPDATE" ASSETS=false VERSION=v1.1.0 SHA="$NEW")" "a published release is never updated"
report 0 "$(calls "delete-asset")" "a published release keeps its assets"
rm -f "$REPO/notes.md"

# --- Asset retry resolves the draft's commit --------------------------------

RETRY="$(step validate-retry "Check the draft release exists")"

fresh
release v1.1.0 true "$NEW"
report pass "$(exec_step "$RETRY" VERSION=v1.1.0)" "retry of a draft that targets a commit"
report "sha=$NEW" "$(cat "$GITHUB_OUTPUT")" "retry outputs the draft's commit"

fresh
release v1.1.0 true main
report fail "$(exec_step "$RETRY" VERSION=v1.1.0)" "retry of a draft that targets a branch fails"

fresh
release v1.1.0 false "$NEW"
report fail "$(exec_step "$RETRY" VERSION=v1.1.0)" "retry of a published release fails"

exit "$fail"
