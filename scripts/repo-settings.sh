#!/usr/bin/env bash

set -euo pipefail

# Reconcile a repository's GitHub settings: labels, merge strategy, secret
# scanning, branch protection ruleset and release tag ruleset.
#
# All configuration is passed through environment variables. Defaults are the
# single source of truth in common.mk and are always passed by the make target;
# an unset variable here is a configuration error (set -u).
#   REPO_ADMIN_BYPASS                      when "false", org admins cannot bypass the ruleset
#   REPO_REQUIRED_APPROVING_REVIEW_COUNT   number of approving reviews required to merge
#   REPO_REQUIRE_CODE_OWNER_REVIEW         require an approving review from code owners
#   REPO_REQUIRE_BRANCH_UP_TO_DATE         require branches up to date (requires status checks)
#   REPO_STATUS_CHECKS                     JSON array of required status-check contexts
#   REPO_RULESET_BRANCHES                  JSON array of additional branch patterns
#   REPO_ALLOW_MERGE_COMMIT                allow merge commits in the merge strategy and ruleset
#   REPO_ALLOW_SQUASH_MERGE                allow squash merging
#   REPO_ALLOW_REBASE_MERGE                allow rebase merging
#   REPO_REQUIRE_LAST_PUSH_APPROVAL        require the most recent push to be approved before merging
#   REPO_RELEASE_TAGS                      JSON array of tag patterns nobody may move or delete; [] skips
#   REPO_RELEASE_TAGS_ENFORCEMENT          that ruleset's enforcement: active, evaluate or disabled
#   GH, JQ                                 commands used to talk to GitHub and build JSON

"$GH" auth status > /dev/null 2>&1 || {
  echo "error: gh is not authenticated; run 'gh auth login'" >&2
  exit 1
}

REPO=$("$GH" repo view --json nameWithOwner -q .nameWithOwner) || {
  echo "error: not a GitHub repository" >&2
  exit 1
}

REPO_STATUS_CHECKS_EFFECTIVE=$(echo "$REPO_STATUS_CHECKS" | "$JQ" -c '[.[] | select((type == "string") and (length > 0))]')
REPO_RULESET_BRANCHES_EFFECTIVE=$(echo "$REPO_RULESET_BRANCHES" | "$JQ" -c '[.[] |
  select((type == "string") and (length > 0)) |
  if startswith("~") or startswith("refs/") then .
  else "refs/heads/" + . end] |
  ["~DEFAULT_BRANCH"] + . | unique')
REPO_RELEASE_TAGS_EFFECTIVE=$(echo "$REPO_RELEASE_TAGS" | "$JQ" -c '[.[] |
  select((type == "string") and (length > 0)) |
  if startswith("refs/") then . else "refs/tags/" + . end] | unique')

case "$REPO_RELEASE_TAGS_ENFORCEMENT" in
  active | evaluate | disabled) ;;
  *)
    echo "error: REPO_RELEASE_TAGS_ENFORCEMENT must be active, evaluate or disabled, got '$REPO_RELEASE_TAGS_ENFORCEMENT'" >&2
    exit 1
    ;;
esac

if [ "$REPO_REQUIRE_BRANCH_UP_TO_DATE" = "true" ] &&
  [ "$REPO_STATUS_CHECKS_EFFECTIVE" = "[]" ]; then
  echo "error: REPO_REQUIRE_BRANCH_UP_TO_DATE=true requires at least one value in REPO_STATUS_CHECKS" >&2
  exit 1
fi

allowed_merge_methods=$(
  # shellcheck disable=SC2016 # $variables belong to jq, not the shell
  "$JQ" -cn \
    --argjson merge "$REPO_ALLOW_MERGE_COMMIT" \
    --argjson squash "$REPO_ALLOW_SQUASH_MERGE" \
    --argjson rebase "$REPO_ALLOW_REBASE_MERGE" \
    '[
      if $merge  then "merge"  else empty end,
      if $squash then "squash" else empty end,
      if $rebase then "rebase" else empty end
    ]
    '
)

if [ "$allowed_merge_methods" = "[]" ]; then
  echo "error: at least one merge method must be allowed" >&2
  exit 1
fi

echo "Reconciling settings for $REPO..."

echo "  Syncing labels..."
while IFS=';' read -r name color desc; do
  [ -z "$name" ] && continue
  "$GH" label create "$name" --repo "$REPO" --color "$color" --description "$desc" --force 2> /dev/null
done << 'EOF'
bug;d73a4a;Something isn't working
duplicate;cfd3d7;This issue or pull request already exists
good first issue;7057ff;Good for newcomers
help wanted;008672;Extra attention is needed
invalid;e4e669;This doesn't seem right
question;37326e;Further information is requested
wontfix;ffffff;This will not be worked on
chore;ededed;A routine task or common potentially re-occurring task
feature;a2eeef;New feature or request
ok-to-helm;0e8a16;PR is allowed to build an publish helm chart
dependencies;0366d6;Pull requests that update a dependency file
needs-triage;eab668;Issue that has not been reviewed
needs-update;f9a03f;Issue that is outdated or incomplete and needs an update
ok-to-image;0e8a16;PR is allowed to run container build
ok-to-test;0e8a16;PR is allowed to be tested
EOF

echo "  Configuring merge strategy..."
"$GH" api "repos/$REPO" -X PATCH \
  -f allow_merge_commit="$REPO_ALLOW_MERGE_COMMIT" \
  -f allow_squash_merge="$REPO_ALLOW_SQUASH_MERGE" \
  -f allow_rebase_merge="$REPO_ALLOW_REBASE_MERGE" \
  -f delete_branch_on_merge=true \
  -f allow_auto_merge=true > /dev/null

echo "  Enabling secret scanning..."
"$GH" api "repos/$REPO" -X PATCH \
  --input <(echo '{"security_and_analysis":{"secret_scanning":{"status":"enabled"}}}') > /dev/null

RULESET_JSON=$(
  # shellcheck disable=SC2016 # $variables belong to jq, not the shell
  "$JQ" -cn \
    --argjson branches "$REPO_RULESET_BRANCHES_EFFECTIVE" \
    --argjson checks "$REPO_STATUS_CHECKS_EFFECTIVE" \
    --argjson approvals "$REPO_REQUIRED_APPROVING_REVIEW_COUNT" \
    --argjson codeOwner "$REPO_REQUIRE_CODE_OWNER_REVIEW" \
    --argjson adminBypass "$REPO_ADMIN_BYPASS" \
    --argjson upToDate "$REPO_REQUIRE_BRANCH_UP_TO_DATE" \
    --argjson allowedMergeMethods "$allowed_merge_methods" \
    --argjson requireLastPushApproval "$REPO_REQUIRE_LAST_PUSH_APPROVAL" \
    '{ name: "protect-main", target: "branch", enforcement: "active",
       conditions: { ref_name: { include: $branches, exclude: [] } },
       rules: ([
         { type: "deletion" },
         { type: "non_fast_forward" },
         { type: "creation" },
         { type: "required_signatures" },
         { type: "pull_request", parameters: {
           required_approving_review_count: $approvals,
           dismiss_stale_reviews_on_push: true,
           required_reviewers: [],
           require_code_owner_review: $codeOwner,
           require_last_push_approval: $requireLastPushApproval,
           required_review_thread_resolution: true,
           allowed_merge_methods: $allowedMergeMethods
         } }
       ] + (if ($checks | length > 0) then
         [{ type: "required_status_checks", parameters: {
           strict_required_status_checks_policy: $upToDate,
           required_status_checks: [$checks | .[] | { context: . }]
         } }] else [] end)),
       bypass_actors: (if $adminBypass then [{ actor_type: "OrganizationAdmin", bypass_mode: "always" }] else [] end)
     }'
)

echo "  Configuring branch protection ruleset..."
echo "    branches: $REPO_RULESET_BRANCHES_EFFECTIVE"
echo "    approvals: $REPO_REQUIRED_APPROVING_REVIEW_COUNT"
echo "    code owner review: $REPO_REQUIRE_CODE_OWNER_REVIEW"
echo "    branch up-to-date: $REPO_REQUIRE_BRANCH_UP_TO_DATE"
echo "    required status checks: $REPO_STATUS_CHECKS_EFFECTIVE"
echo "    admin bypass: $REPO_ADMIN_BYPASS"

# upsert_ruleset <json>: creates or updates the repository ruleset named in
# <json>. includes_parents=false keeps an organization ruleset of the same name
# out of the lookup; it cannot be updated through the repository endpoint. A
# failed lookup stops the run: read as "no ruleset", it would POST a duplicate.
upsert_ruleset() {
  local json=$1 name existing out
  name=$(echo "$json" | "$JQ" -r .name)
  existing=$("$GH" api --paginate "repos/$REPO/rulesets?includes_parents=false&per_page=100" \
    -q ".[] | select(.name==\"$name\") | .id") || {
    echo "error: looking up ruleset $name failed" >&2
    return 1
  }
  # gh prints GitHub's reason for a rejection (the "errors" list) on stdout.
  if [ -n "$existing" ]; then
    out=$("$GH" api "repos/$REPO/rulesets/$existing" -X PUT --input <(echo "$json")) ||
      {
        echo "error: updating ruleset $name failed: $out" >&2
        return 1
      }
    echo "    Updated existing ruleset $name (id: $existing)"
  else
    out=$("$GH" api "repos/$REPO/rulesets" -X POST --input <(echo "$json")) ||
      {
        echo "error: creating ruleset $name failed: $out" >&2
        return 1
      }
    echo "    Created new ruleset $name"
  fi
}

upsert_ruleset "$RULESET_JSON"

# protect-release-tags: nobody, workflows and admins included, moves or deletes
# a release tag. Creation stays open: GitHub refuses GitHub Actions as a bypass
# actor, so a ruleset cannot reserve tag creation for the release workflow.
if [ "$REPO_RELEASE_TAGS_EFFECTIVE" = "[]" ]; then
  echo "  Release tag ruleset skipped (REPO_RELEASE_TAGS is empty)"
else
  echo "  Configuring release tag ruleset..."
  echo "    tags: $REPO_RELEASE_TAGS_EFFECTIVE"
  echo "    enforcement: $REPO_RELEASE_TAGS_ENFORCEMENT"
  # shellcheck disable=SC2016 # $variables belong to jq, not the shell
  upsert_ruleset "$("$JQ" -cn \
    --argjson tags "$REPO_RELEASE_TAGS_EFFECTIVE" \
    --arg enforcement "$REPO_RELEASE_TAGS_ENFORCEMENT" \
    '{ name: "protect-release-tags", target: "tag", enforcement: $enforcement,
       conditions: { ref_name: { include: $tags, exclude: [] } },
       rules: [ { type: "update" }, { type: "deletion" } ],
       bypass_actors: [] }')"
fi

echo "  Configuring merge commit settings..."
"$GH" api "repos/$REPO" -X PATCH \
  -f merge_commit_title=PR_TITLE \
  -f merge_commit_message=PR_BODY > /dev/null

echo "Done."
