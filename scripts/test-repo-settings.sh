#!/usr/bin/env bash
set -euo pipefail

# Runs repo-settings.sh against a stub gh and checks the rulesets it sends.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TESTDIR="$(mktemp -d)"
trap 'rm -rf "$TESTDIR"' EXIT

# State: $STATE/existing holds "<id> <name>" per repository ruleset; each
# create or update is saved as $STATE/sent/<METHOD>-<name>.json. The ruleset
# named in $REJECT is refused the way GitHub refuses one, with a 422 body.
# $IMMUTABLE is the immutable releases setting GitHub reports: off (the default),
# on, or anything else for a failing lookup. $ENABLE_FAIL refuses enabling it.
mkdir -p "$TESTDIR/bin"
cat > "$TESTDIR/bin/gh" << 'GH'
#!/usr/bin/env bash
set -euo pipefail
echo "gh $*" >> "$STATE/calls"
case "$1" in
  auth | label) exit 0 ;;
  repo) echo org/repo ;;
  api)
    shift
    method=GET input="" query="" path=""
    while [ $# -gt 0 ]; do
      case "$1" in
        -X) method=$2; shift ;;
        --input) input=$2; shift ;;
        -q) query=$2; shift ;;
        --paginate) ;;
        *) path=$1 ;;
      esac
      shift
    done
    case "$method $path" in
      "GET repos/org/repo/rulesets?includes_parents=false&per_page=100")
        [ -z "${LOOKUP_FAIL:-}" ] || { echo "HTTP 502" >&2; exit 1; }
        name=$(sed -E 's/.*name=="([^"]+)".*/\1/' <<< "$query")
        awk -v n="$name" '$2 == n { print $1 }' "$STATE/existing"
        ;;
      "GET repos/org/repo/immutable-releases")
        case "${IMMUTABLE:-off}" in
          on) echo '{"enabled":true,"enforced_by_owner":false}'; [ -z "${GH_TRACE:-}" ] || echo "* Request at ..." >&2 ;;
          off) echo '{"message":"Not Found"}'; echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
          *) echo "gh: Bad Gateway (HTTP 502)" >&2; exit 1 ;;
        esac
        ;;
      "PUT repos/org/repo/immutable-releases")
        [ -z "${ENABLE_FAIL:-}" ] || { echo "gh: Conflict (HTTP 409)" >&2; exit 1; }
        : > "$STATE/immutable-releases-enabled"
        ;;
      "GET "*) echo "unexpected lookup: $path" >&2; exit 2 ;;
      "PUT repos/org/repo/rulesets/"* | "POST repos/org/repo/rulesets")
        json=$(cat "$input")
        if [ "$(jq -r .name <<< "$json")" = "${REJECT:-}" ]; then
          echo '{"message":"Validation Failed","errors":["Actor is not allowed"]}'
          exit 1
        fi
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

# common.mk's default. TAGS, ENFORCEMENT and REJECT override per run.
DEFAULT_TAGS='["v*"]'

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
    REPO_RELEASE_TAGS="${TAGS-$DEFAULT_TAGS}" REPO_RELEASE_TAGS_ENFORCEMENT="${ENFORCEMENT-active}" \
    REPO_IMMUTABLE_RELEASES="${RELEASES-true}" \
    bash "$ROOT/scripts/repo-settings.sh" > "$STATE/log" 2>&1
}

sent() { jq -c "$2" "$STATE/sent/$1.json" 2> /dev/null || echo missing; }

run
report '["update","deletion"]' "$(sent POST-protect-release-tags '[.rules[].type]')" \
  "release tags cannot be moved or deleted"
report '[]' "$(sent POST-protect-release-tags .bypass_actors)" \
  "nobody, GitHub Actions included, bypasses tag protection"
report '["refs/tags/v*"]' "$(sent POST-protect-release-tags .conditions.ref_name.include)" \
  "tag protection covers v* tags"
report 2 "$(grep -c 'api --paginate repos/org/repo/rulesets?includes_parents=false&per_page=100' "$STATE/calls")" \
  "every lookup pages through repository rulesets only"

run 11 protect-main 12 protect-release-tags
report 2 "$(find "$STATE/sent" -name 'PUT-*' | wc -l | tr -d ' ')" "existing rulesets are updated in place"
report 0 "$(find "$STATE/sent" -name 'POST-*' | wc -l | tr -d ' ')" "no duplicate is created"
report 1 "$(grep -c 'rulesets/12 -X PUT' "$STATE/calls")" "an update goes to the ruleset of the same name"

rc=0
REJECT=protect-main run || rc=$?
report 1 "$rc" "a rejected ruleset fails the run"
report 1 "$(grep -c '^error: creating ruleset protect-main failed: .*Actor is not allowed' "$STATE/log")" \
  "a rejection shows GitHub's reason"
report missing "$(sent POST-protect-release-tags .name)" "nothing is applied after a rejection"

rc=0
LOOKUP_FAIL=1 run 11 protect-main || rc=$?
report 1 "$rc" "a failed ruleset lookup fails the run"
report 0 "$(find "$STATE/sent" -name "POST-*" | wc -l | tr -d " ")" "instead of creating a duplicate"

TAGS='["v*", "refs/tags/chart-*", ""]' run
report '["refs/tags/chart-*","refs/tags/v*"]' "$(sent POST-protect-release-tags .conditions.ref_name.include)" \
  "REPO_RELEASE_TAGS sets the patterns, short ones normalized to refs/tags/"

ENFORCEMENT=evaluate run
report '"evaluate"' "$(sent POST-protect-release-tags .enforcement)" "REPO_RELEASE_TAGS_ENFORCEMENT sets the enforcement"

TAGS='[]' run
report missing "$(sent POST-protect-release-tags .name)" "REPO_RELEASE_TAGS='[]' skips the tag ruleset"
report '"protect-main"' "$(sent POST-protect-main .name)" "and still applies the branch ruleset"

rc=0
ENFORCEMENT=enabled run || rc=$?
report 1 "$rc" "an unknown enforcement fails the run"
report 0 "$(grep -cE -- ' -X |^gh label ' "$STATE/calls")" "before anything is changed"

# --- immutable releases ---------------------------------------------------------
enabled() { [ -e "$STATE/immutable-releases-enabled" ] && echo yes || echo no; }

run
report yes "$(enabled)" "immutable releases are enabled where they are off"

IMMUTABLE=on run
report no "$(enabled)" "and left alone where they are on"

rc=0
IMMUTABLE=on GH_TRACE=1 run || rc=$?
report 0 "$rc" "a trace gh writes to stderr is not read as the setting"

rc=0
IMMUTABLE=broken run || rc=$?
report 1 "$(grep -c "merge_commit_title=PR_TITLE" "$STATE/calls")" "the settings before it are applied even when its lookup fails"

RELEASES=false run
report no "$(enabled)" "REPO_IMMUTABLE_RELEASES=false does not enable them"
report 0 "$(grep -c immutable-releases "$STATE/calls")" "and does not look the setting up"

rc=0
IMMUTABLE=broken run || rc=$?
report 1 "$rc" "a failed lookup of the setting fails the run"
report no "$(enabled)" "and is not read as off"

rc=0
ENABLE_FAIL=1 run || rc=$?
report 1 "$rc" "a refused enabling fails the run"

rc=0
RELEASES=yes run || rc=$?
report 1 "$rc" "a REPO_IMMUTABLE_RELEASES other than true or false fails the run"
report 0 "$(grep -cE -- ' -X |^gh label ' "$STATE/calls")" "before anything is changed"

# Every REPO_* variable the script documents needs a default in common.mk and
# must be passed by the make target; set -u fails the script otherwise.
while read -r var; do
  report 1 "$(grep -cE "^$var \?= " "$ROOT/common.mk")" "common.mk sets a default for $var"
  report 1 "$(grep -cF "$var='\$($var)'" "$ROOT/common.mk")" "the make target passes $var"
done < <(sed -nE 's/^#   (REPO_[A-Z_]+) .*/\1/p' "$ROOT/scripts/repo-settings.sh")

exit "$fail"
