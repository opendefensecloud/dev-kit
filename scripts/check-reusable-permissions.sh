#!/usr/bin/env bash
# Check that no reusable workflow asks for more GITHUB_TOKEN permissions than
# its callers hand it.
#
# Two GitHub rules make this a recurring, silent failure:
#
#   1. A called workflow can never elevate: it gets at most what the calling
#      *job* was granted.
#   2. A job-level `permissions:` block REPLACES the workflow-level one. It does
#      not merge. A job that sets only `issues: write` therefore has
#      `contents: none`, whatever the workflow level says.
#
# Breaking either fails the caller at *startup*, before any job runs, which
# creates no check run — so nothing goes red. `actionlint` exits 0 on it too.
# That combination is why this has needed three separate fixes.
#
# Callers come from two places and both are checked:
#   - in-repo:   a job with `uses: ./.github/workflows/<file>`
#   - consumers: the stubs in README.md, which is what consumers copy
#
# Checking only the README would miss an in-repo caller; checking only in-repo
# callers would miss every consumer. Both have bitten.
#
# yq is used only to turn YAML into JSON — its expression language has no
# `if`/`def` — so the rules above live in one jq program.
#
# Usage: check-reusable-permissions.sh [repo-dir]
set -euo pipefail

# yq is not on the GitHub runner image; jq is. Both are in this repository's
# dev shell, which is how CI runs this.
for bin in yq jq; do
  if ! command -v "$bin" > /dev/null 2>&1; then
    echo "error: $bin is required but not on PATH." >&2
    echo "       In this repository: nix develop --command $0" >&2
    exit 1
  fi
done

cd "${1:-.}"

WORKFLOW_DIR="${WORKFLOW_DIR:-.github/workflows}"
README="${README_FILE:-README.md}"
# Which qualified `uses:` paths count as this repository. A bare substring match
# would also select another repository's workflow that happens to share a
# filename with one of ours, and compare the wrong pair.
REPO_SLUG="${REPO_SLUG:-opendefensecloud/dev-kit}"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

: > "$tmp/docs.ndjson"

# A file this script cannot parse has to stop it. Skipping one quietly turns a
# real failure into a pass: the broken caller simply disappears, and its callee
# is then reported as "nothing calls it".
for f in "$WORKFLOW_DIR"/*.y*ml; do
  [ -f "$f" ] || continue
  if ! yq -o=json -I=0 '.' "$f" > "$tmp/doc.json" 2> "$tmp/yqerr"; then
    echo "error: cannot parse $f as YAML:" >&2
    sed 's/^/       /' "$tmp/yqerr" >&2
    exit 1
  fi
  jq -c --arg name "$(basename "$f")" --arg label "$f" \
    '{name: $name, label: $label, local: true, doc: .}' \
    < "$tmp/doc.json" >> "$tmp/docs.ndjson"
done

if [ -f "$README" ]; then
  # Split the README's fenced yaml blocks out so each can be parsed on its own.
  awk -v d="$tmp" '
    /^```yaml$/ { n++; inb = 1; next }
    /^```$/     { inb = 0; next }
    inb && n    { print > (d "/readme-block-" n ".yaml") }
  ' "$README"
  for b in "$tmp"/readme-block-*.yaml; do
    [ -f "$b" ] || continue
    if ! yq -o=json -I=0 '.' "$b" > "$tmp/doc.json" 2> "$tmp/yqerr"; then
      # A README may hold illustrative fragments that do not stand alone. One
      # that calls our workflows may not: that is the snippet consumers copy,
      # so it has to be checkable.
      if grep -qF "$REPO_SLUG/.github/workflows/" "$b"; then
        echo "error: a yaml block in $README calls $REPO_SLUG but does not parse:" >&2
        sed 's/^/       /' "$tmp/yqerr" >&2
        sed 's/^/       | /' "$b" >&2
        exit 1
      fi
      continue
    fi
    jq -c --arg label "$README (stub)" \
      'select(type == "object" and has("jobs")) | {name: null, label: $label, local: false, doc: .}' \
      < "$tmp/doc.json" >> "$tmp/docs.ndjson"
  done
fi

jq -rs --arg slug "$REPO_SLUG" '
  def lvl: {"none": 1, "read": 2, "write": 3}[.] // 0;

  # `permissions: read-all` and `permissions: write-all` are valid at both the
  # workflow and the job level. Normalising them onto a wildcard key lets one
  # lookup rule cover every case: a grant of read-all answers any single scope,
  # while a *request* for read-all is satisfied only by a caller that also
  # granted every scope.
  def norm:
    if . == null then null
    elif type == "string" then
      (if . == "read-all" then {"*": "read"}
       elif . == "write-all" then {"*": "write"}
       else {} end)
    else . end;

  # What a grant gives for one scope, falling back to a wildcard grant.
  def at($k): (.[$k] // .["*"] // "none");

  # Strongest request per key across a list of permission maps. A caller grant
  # caps the called workflow at every level, so the maximum is what matters.
  def strongest(maps): reduce (maps | .[] | to_entries[]) as $e ({};
    if ($e.value | lvl) > ((.[$e.key] // "none") | lvl) then .[$e.key] = $e.value else . end);

  # A calling job gets its own block when it has one, the workflow-level block
  # otherwise. Checked against null, not with `//`: an explicit
  # `permissions: {}` grants nothing and must not fall back to the workflow.
  def grant($top): (if .permissions != null then .permissions else $top end) | norm;

  . as $docs

  # callee name -> the strongest permissions it asks for anywhere
  | [ $docs[]
      | select(.local and (.doc.jobs != null) and ((.doc["on"] // {}) | has("workflow_call")))
      | { name: .name,
          requires: strongest([ ((.doc.permissions | norm) // {}) ]
                              + [ .doc.jobs[] | ((.permissions | norm) // {}) ]) }
    ] as $callees

  # every (caller job -> callee) edge, with the effective grant of that job
  | [ $docs[]
      | .label as $label
      | (.doc.permissions) as $top
      | (.doc.jobs // {}) | to_entries[]
      | . as $j
      | (.value.uses // "") as $uses
      | select(($uses | startswith("./.github/workflows/"))
               or ($uses | startswith($slug + "/.github/workflows/")))
      | { callee: ($uses | sub("@.*"; "") | sub(".*/"; "")),
          label:  "\($label) (\($j.key))",
          grant:  ($j.value | grant($top)) }
    ] as $edges

  | $callees[]
  | . as $callee
  | [ $edges[] | select(.callee == $callee.name) ] as $mine
  | if ($mine | length) == 0 then
      "WARN|\($callee.name)|nothing calls it in this repo or the README|"
    else
      $mine[]
      | if .grant == null then
          "WARN|\($callee.name)|\(.label)|declares no permissions, so the repository default decides"
        else
          .grant as $g
          | [ $callee.requires | to_entries[]
              | .key as $k
              | .value as $v
              | select(($v | lvl) > (($g | at($k)) | lvl))
              | (if $k == "*" then "all scopes" else $k end) as $label
              | "\($label): wants \($v), caller grants \($g | at($k))"
            ] as $bad
          | if ($bad | length) == 0
            then "ok|\($callee.name)|\(.label)|"
            else "FAIL|\($callee.name)|\(.label)|\($bad | join("; "))"
            end
        end
    end
' "$tmp/docs.ndjson" > "$tmp/report"

if [ ! -s "$tmp/report" ]; then
  echo "error: found no reusable workflows under $WORKFLOW_DIR." >&2
  exit 1
fi

rc=0
while IFS='|' read -r status callee label detail; do
  if [ "$status" = "FAIL" ]; then rc=1; fi
  if [ -n "$detail" ]; then
    printf '%-5s %-30s %s -- %s\n' "$status" "$callee" "$label" "$detail"
  else
    printf '%-5s %-30s %s\n' "$status" "$callee" "$label"
  fi
done < "$tmp/report"

if [ "$rc" -ne 0 ]; then
  cat >&2 << 'EOF'

A called workflow cannot ask for more than its calling job was granted, and a
job-level `permissions:` block replaces the workflow-level one instead of
merging. Either drop the request from the called workflow, or widen the calling
job -- listing every key it needs, not only the one that is missing.
EOF
fi

exit "$rc"
