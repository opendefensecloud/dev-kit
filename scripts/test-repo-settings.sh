#!/usr/bin/env bash
set -euo pipefail

# Runs repo-settings.sh against a stub gh and checks the rulesets it sends.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TESTDIR="$(mktemp -d)"
trap 'rm -rf "$TESTDIR"' EXIT

# State: $STATE/existing holds "<id> <name>" per repository ruleset; each
# create or update is saved as $STATE/sent/<METHOD>-<name>.json.
mkdir -p "$TESTDIR/bin"
cat > "$TESTDIR/bin/gh" << 'GH'
#!/usr/bin/env bash
set -euo pipefail
echo "gh $*" >> "$STATE/calls"
case "$1" in
  auth | label) exit 0 ;;
  repo) echo org/repo ;;
  api)
    path=$2
    shift 2
    method=GET input="" query=""
    while [ $# -gt 0 ]; do
      case "$1" in
        -X) method=$2; shift ;;
        --input) input=$2; shift ;;
        -q) query=$2; shift ;;
      esac
      shift
    done
    case "$method $path" in
      "GET repos/org/repo/rulesets?includes_parents=false")
        name=$(sed -E 's/.*name=="([^"]+)".*/\1/' <<< "$query")
        awk -v n="$name" '$2 == n { print $1 }' "$STATE/existing"
        ;;
      "GET "*) echo "unexpected lookup: $path" >&2; exit 2 ;;
      "PUT repos/org/repo/rulesets/"* | "POST repos/org/repo/rulesets")
        json=$(cat "$input")
        jq . <<< "$json" > "$STATE/sent/$method-$(jq -r .name <<< "$json").json"
        ;;
    esac
    ;;
  *) echo "unexpected gh call: $*" >&2; exit 2 ;;
esac
GH
chmod +x "$TESTDIR/bin/gh"

fail=0
# report <want> <got> <description>
report() {
  if [[ "$2" == "$1" ]]; then
    echo "ok   $3"
  else
    echo "FAIL $3: expected '$1', got '$2'"
    fail=1
  fi
}

run() { # run [<id> <name>]...: runs repo-settings.sh with those rulesets present
  export STATE="$TESTDIR/state-$RANDOM$RANDOM"
  mkdir -p "$STATE/sent"
  : > "$STATE/calls"
  : > "$STATE/existing"
  while [ $# -gt 0 ]; do
    echo "$1 $2" >> "$STATE/existing"
    shift 2
  done
  PATH="$TESTDIR/bin:$PATH" GH=gh JQ=jq \
    REPO_ADMIN_BYPASS=true REPO_REQUIRED_APPROVING_REVIEW_COUNT=1 \
    REPO_REQUIRE_CODE_OWNER_REVIEW=false REPO_REQUIRE_BRANCH_UP_TO_DATE=false \
    REPO_STATUS_CHECKS='[]' REPO_RULESET_BRANCHES='[]' \
    REPO_ALLOW_MERGE_COMMIT=true REPO_ALLOW_SQUASH_MERGE=false REPO_ALLOW_REBASE_MERGE=false \
    REPO_REQUIRE_LAST_PUSH_APPROVAL=false \
    bash "$ROOT/scripts/repo-settings.sh" > "$STATE/log" 2>&1
}

sent() { jq -c "$2" "$STATE/sent/$1.json" 2> /dev/null || echo missing; }

run
report '["creation"]' "$(sent POST-restrict-release-tag-creation '[.rules[].type]')" \
  "the creation ruleset only restricts creation"
report '[{"actor_id":15368,"actor_type":"Integration","bypass_mode":"always"}]' \
  "$(sent POST-restrict-release-tag-creation .bypass_actors)" "only GitHub Actions may create release tags"
report '["update","deletion"]' "$(sent POST-protect-release-tags '[.rules[].type]')" \
  "release tags cannot be moved or deleted"
report '[]' "$(sent POST-protect-release-tags .bypass_actors)" \
  "nobody, GitHub Actions included, bypasses tag protection"
report '["refs/tags/v*"]' "$(sent POST-protect-release-tags .conditions.ref_name.include)" \
  "tag protection covers v* tags"
report '["refs/tags/v*"]' "$(sent POST-restrict-release-tag-creation .conditions.ref_name.include)" \
  "creation restriction covers v* tags"
report 3 "$(grep -c 'rulesets?includes_parents=false' "$STATE/calls")" \
  "every lookup leaves out organization rulesets"

run 11 protect-main 12 protect-release-tags 13 restrict-release-tag-creation
report 3 "$(find "$STATE/sent" -name 'PUT-*' | wc -l | tr -d ' ')" "existing rulesets are updated in place"
report 0 "$(find "$STATE/sent" -name 'POST-*' | wc -l | tr -d ' ')" "no duplicate is created"
report 1 "$(grep -c 'rulesets/12 -X PUT' "$STATE/calls")" "an update goes to the ruleset of the same name"

exit "$fail"
