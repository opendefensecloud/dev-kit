#!/usr/bin/env bash
set -euo pipefail

# Runs steps from release.yml and release-draft.yml themselves (extracted with
# yq), so the test cannot drift from what CI runs, against a stub gh whose
# releases and tag refs live in files.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WF="$ROOT/.github/workflows"
TESTDIR="$(mktemp -d)"
trap 'rm -rf "$TESTDIR"' EXIT

# Keep the developer's git config (commit signing, hooks) out of the test repo.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

SHA=1111111111111111111111111111111111111111
OTHER=2222222222222222222222222222222222222222
OLDER=3333333333333333333333333333333333333333

# step <workflow> <job> <name>: prints the run script of that step.
step() {
  local run
  run="$(yq ".jobs.$2.steps[] | select(.name == \"$3\") | .run" "$WF/$1")"
  [[ -n "$run" && "$run" != null ]] || {
    echo "FAIL: step '$3' not found in $1 job $2" >&2
    exit 1
  }
  printf '%s\n' "$run"
}

# Releases: $STATE/releases/<tag>/{draft,assets}. Tag refs on the remote:
# $STATE/refs/<tag> holds the commit. $STATE/refs-fail makes ref creation
# fail, after creating the ref when it contains "created". The stub answers
# the exact queries the workflows make, with their --jq already applied.
mkdir -p "$TESTDIR/bin"
cat > "$TESTDIR/bin/gh" << 'GH'
#!/usr/bin/env bash
set -euo pipefail
echo "gh $*" >> "$STATE/calls"
rel="$STATE/releases/${3:-}"
case "$1 $2" in
  "release list")
    # Drafts only when the query asks for them, every release otherwise.
    for d in "$STATE"/releases/*/; do
      [ -d "$d" ] || continue
      if [[ "$*" != *"select(.isDraft)"* ]] || [ "$(cat "$d/draft")" = true ]; then basename "$d"; fi
    done
    ;;
  "release view")
    [ -z "${VIEW_FAIL:-}" ] || { echo "HTTP 502: Bad Gateway" >&2; exit 1; }
    [ -d "$rel" ] || { echo "release not found" >&2; exit 1; }
    case "$*" in
      *"--json isDraft "*) [ "$(cat "$rel/draft")" = true ] && echo draft || echo published ;;
      *"--json assets "*) cat "$rel/assets" ;;
      *"--json url "*) echo "https://github.com/org/repo/releases/tag/$3" ;;
      *) echo "unexpected view: $*" >&2; exit 2 ;;
    esac
    ;;
  "release create")
    if [[ "$*" == *--verify-tag* ]] && [ ! -f "$STATE/refs/$3" ]; then
      echo "tag $3 doesn't exist in the repo" >&2
      exit 1
    fi
    mkdir -p "$rel"
    echo true > "$rel/draft"
    : > "$rel/assets"
    for a in "$@"; do
      case "$a" in release-assets/*) basename "$a" >> "$rel/assets" ;; esac
    done
    ;;
  "release upload")
    for a in "$@"; do
      case "$a" in release-assets/*) ;; *) continue ;; esac
      grep -qxF "$(basename "$a")" "$rel/assets" || basename "$a" >> "$rel/assets"
    done
    ;;
  "release delete-asset")
    grep -vxF "$4" "$rel/assets" > "$rel/assets.new" || true
    mv "$rel/assets.new" "$rel/assets"
    ;;
  "release edit") ;;
  "api repos/org/repo/git/refs")
    tag=$(sed -E 's/.*ref=refs\/tags\/([^ ]+) .*/\1/' <<< "$*")
    sha=$(sed -E 's/.*sha=([0-9a-f]+).*/\1/' <<< "$*")
    if [ -f "$STATE/refs-fail" ]; then
      grep -q created "$STATE/refs-fail" && echo "$sha" > "$STATE/refs/$tag"
      exit 1
    fi
    echo "$sha" > "$STATE/refs/$tag"
    ;;
  "api repos/org/repo/git/ref/tags/"*)
    cat "$STATE/refs/${2#repos/org/repo/git/ref/tags/}" 2> /dev/null || exit 1
    ;;
  "api repos/org/repo/compare/"*)
    # <sha>...refs/tags/<tag> on a linear default branch: OLDER, SHA, OTHER.
    spec=${2#repos/org/repo/compare/}
    base=${spec%%...*} head=$(cat "$STATE/refs/${spec#*...refs/tags/}")
    pos() { case "$1" in 3333333333333333333333333333333333333333) echo 0 ;; 1111111111111111111111111111111111111111) echo 1 ;; 2222222222222222222222222222222222222222) echo 2 ;; *) echo "unknown commit $1" >&2; exit 2 ;; esac; }
    b=$(pos "$base") h=$(pos "$head")
    if [ "$h" -gt "$b" ]; then s=ahead; elif [ "$h" -lt "$b" ]; then s=behind; else s=identical; fi
    q=""
    for ((i = 1; i <= $#; i++)); do
      if [ "${!i}" = --jq ]; then j=$((i + 1)); q=${!j}; fi
    done
    jq -n --arg s "$s" '{status: $s}' | jq -r "$q"
    ;;
  "api --paginate")
    # Answers with the JSON GitHub would send and applies the caller's own
    # --jq to it, so the filter under test is the workflow's, not a copy.
    q=""
    for ((i = 1; i <= $#; i++)); do
      if [ "${!i}" = --jq ]; then j=$((i + 1)); q=${!j}; fi
    done
    case "$3" in
      */check-runs*)
        # $STATE/checks/<sha>.json: {"check_runs": [...]}. None: no runs.
        sha=$(sed -E 's|.*/commits/([0-9a-f]+)/check-runs.*|\1|' <<< "$3")
        { cat "$STATE/checks/$sha.json" 2> /dev/null || echo '{"check_runs": []}'; } | jq -r "$q"
        ;;
      repos/org/repo/git/matching-refs/tags/v)
        # The tags in $STATE/refs, as GitHub lists matching refs.
        shopt -s nullglob
        for f in "$STATE"/refs/v*; do jq -n --arg r "refs/tags/${f##*/}" '{ref: $r}'; done | jq -s . | jq -r "$q"
        ;;
      "repos/org/repo/rulesets?includes_parents=true&per_page=100")
        # $STATE/rulesets/<id>.json, listed as GitHub lists them.
        shopt -s nullglob
        jq -s '.' "$STATE"/rulesets/*.json < /dev/null | jq -r "$q"
        ;;
      *) echo "unexpected paginated call: $*" >&2; exit 2 ;;
    esac
    ;;
  "api repos/org/repo/rulesets/"*)
    id=$(sed -E 's|repos/org/repo/rulesets/([0-9]+).*|\1|' <<< "$2")
    cat "$STATE/rulesets/$id.json"
    ;;
  *) echo "unexpected gh call: $*" >&2; exit 2 ;;
esac
GH
chmod +x "$TESTDIR/bin/gh"

# A repository whose local tags are v1.0.0 and v1.1.0.
REPO="$TESTDIR/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q -b main
git -C "$REPO" -c user.email=t@example.com -c user.name=T commit -q --allow-empty -m "chore: init"
git -C "$REPO" tag v1.0.0
git -C "$REPO" tag v1.1.0

fail=0
report() { # report <want> <got> <description>
  if [[ "$2" == "$1" ]]; then echo "ok   $3"; else
    echo "FAIL $3: expected '$1', got '$2'"
    fail=1
  fi
}

# fresh: new stub state, step output and summary files, empty work dir.
fresh() {
  export STATE="$TESTDIR/state-$RANDOM$RANDOM"
  mkdir -p "$STATE/releases" "$STATE/refs" "$STATE/checks" "$STATE/rulesets" "$STATE/work"
  : > "$STATE/calls"
  export GITHUB_OUTPUT="$STATE/output" GITHUB_STEP_SUMMARY="$STATE/summary"
  : > "$GITHUB_OUTPUT"
  : > "$GITHUB_STEP_SUMMARY"
}

release() { # release <tag> <draft> [asset...]
  local d="$STATE/releases/$1"
  mkdir -p "$d"
  echo "$2" > "$d/draft"
  shift 2
  : > "$d/assets"
  for a in "$@"; do echo "$a" >> "$d/assets"; done
}

# assets <path>...: files the build handed over, under release-assets/.
assets() {
  for p in "$@"; do
    mkdir -p "$STATE/work/release-assets/$(dirname "$p")"
    echo "$p" > "$STATE/work/release-assets/$p"
  done
}

# exec_step <dir> <script> [VAR=value...]: runs the script as CI does, in
# <dir>; prints pass|fail.
exec_step() {
  local dir=$1 script=$2
  shift 2
  if (cd "$dir" && env PATH="$TESTDIR/bin:$PATH" GITHUB_REPOSITORY=org/repo "$@" \
    bash -e -c "$script" > "$STATE/log" 2>&1); then
    echo pass
  else
    echo fail
  fi
}

calls() { grep -c -- "$1" "$STATE/calls" || true; }
attached() { tr '\n' ' ' < "$STATE/releases/$1/assets" | sed 's/ $//'; }

# --- release.yml: pending draft guard ----------------------------------------

PENDING="$(step release.yml prepare "Guard - no draft release pending")"

fresh
release v1.1.0 true
report fail "$(exec_step "$REPO" "$PENDING" DRY_RUN=false)" "a cut, unpublished release blocks the next one"
report 1 "$(grep -c 'Release v1.1.0 was cut but not published' "$STATE/log")" "the block names the pending release"

fresh
release v1.1.0 true
report pass "$(exec_step "$REPO" "$PENDING" DRY_RUN=true)" "a dry run only warns about it"
report 1 "$(grep -c '::warning::' "$STATE/log")" "the dry run shows the warning"

fresh
release v1.2.0 true
report fail "$(exec_step "$REPO" "$PENDING" DRY_RUN=false)" "an untagged draft left over from v4 blocks too"
report 1 "$(grep -c 'Draft v1.2.0 has no tag' "$STATE/log")" "and says to delete it"

fresh
release v1.1.0 false
report pass "$(exec_step "$REPO" "$PENDING" DRY_RUN=false)" "a published release does not block"

# --- release.yml: tag creation -----------------------------------------------

TAG="$(step release.yml prepare "Create tag")"

fresh
report pass "$(exec_step "$REPO" "$TAG" VERSION=v1.2.0 SHA=$SHA)" "the tag is created"
report "$SHA" "$(cat "$STATE/refs/v1.2.0")" "the tag points at the dispatched commit"
report 1 "$(grep -c '^tag_created=true$' "$GITHUB_OUTPUT")" "tag_created is set"

fresh
echo created > "$STATE/refs-fail"
report pass "$(exec_step "$REPO" "$TAG" VERSION=v1.2.0 SHA=$SHA)" \
  "a failed request that still created the tag at this commit succeeds"
report 1 "$(grep -c '^tag_created=true$' "$GITHUB_OUTPUT")" "and sets tag_created"

fresh
echo plain > "$STATE/refs-fail"
echo "$OTHER" > "$STATE/refs/v1.2.0"
report fail "$(exec_step "$REPO" "$TAG" VERSION=v1.2.0 SHA=$SHA)" "a tag at another commit fails"
report 1 "$(grep -c "already points at $OTHER" "$STATE/log")" "the failure names that commit"
report 0 "$(grep -c tag_created "$GITHUB_OUTPUT")" "and sets no tag_created"

fresh
echo plain > "$STATE/refs-fail"
report fail "$(exec_step "$REPO" "$TAG" VERSION=v1.2.0 SHA=$SHA)" "a failed request without a tag fails"

# --- release.yml: nothing releasable -----------------------------------------

RELEASABLE="$(step release.yml prepare "Guard - something releasable landed")"

# guard <commit message> <event> <ref_type>: runs the guard in a fresh state
# (call fresh first) on a range holding just that commit.
guard() {
  jq -n --arg m "$1" '[{commits: [{raw_message: $m, breaking: false}]}]' > "$STATE/work/ctx.json"
  exec_step "$STATE/work" "$RELEASABLE" PREVIOUS_TAG=v1.1.0 EVENT_NAME="$2" REF_TYPE="$3"
}

fresh
report pass "$(guard "chore: tidy" push branch)" "a push with nothing releasable is skipped"
report 1 "$(grep -c '^releasable=false$' "$GITHUB_OUTPUT")" "and sets releasable=false"

fresh
report pass "$(guard "chore: tidy" schedule branch)" "a scheduled run with nothing releasable is skipped"
report 1 "$(grep -c '^releasable=false$' "$GITHUB_OUTPUT")" "and sets releasable=false"

fresh
report fail "$(guard "chore: tidy" workflow_dispatch branch)" "a dispatch with nothing releasable fails"

fresh
report fail "$(guard "chore: tidy" push tag)" "a tag push with nothing releasable fails"

fresh
report pass "$(guard "fix: it" schedule branch)" "a scheduled run with a fix proceeds"
report 1 "$(grep -c '^releasable=true$' "$GITHUB_OUTPUT")" "and sets releasable=true"

# --- release.yml: required checks --------------------------------------------

GATE="$(step release.yml prepare "Guard - required checks passed")"

# History: code (checks ran) -> docs/ -> top-level README.md -> code (no checks
# yet, as when its workflow is still queued).
GREPO="$TESTDIR/gate"
mkdir -p "$GREPO/docs"
git -C "$GREPO" init -q -b main
gcommit() { # gcommit <file>: commits a change to it, prints the commit
  echo "$RANDOM" > "$GREPO/$1"
  git -C "$GREPO" add -A
  git -C "$GREPO" -c user.email=t@example.com -c user.name=T commit -q -m "change $1"
  git -C "$GREPO" rev-parse HEAD
}
C_CODE=$(gcommit main.go)
C_DOCS=$(gcommit docs/guide.md)
C_README=$(gcommit README.md)
C_LATE=$(gcommit server.go)

checks() { # checks <commit> <name>:<status>/<conclusion>...: its check runs
  local c=$1 spec
  shift
  for spec in "$@"; do
    jq -n --arg n "${spec%%:*}" --arg s "$(cut -d/ -f1 <<< "${spec#*:}")" --arg c "$(cut -d/ -f2 <<< "${spec#*:}")" \
      '{name: $n, status: $s, conclusion: (if $c == "" then null else $c end)}'
  done | jq -s '{check_runs: .}' > "$STATE/checks/$c.json"
}
E2E='["e2e / api", "e2e / ui"]'
gate() { # gate <commit> [VAR=value...]
  local c=$1
  shift
  exec_step "$GREPO" "$GATE" SHA="$c" REQUIRED_CHECKS="$E2E" SKIP_PATHS='["docs/**", "**/*.md"]' DRY_RUN=false "$@"
}

fresh
report pass "$(exec_step "$GREPO" "$GATE" SHA="$C_CODE" REQUIRED_CHECKS='[]' SKIP_PATHS='[]' DRY_RUN=false)" \
  "no required checks: nothing to wait for"
report 0 "$(calls 'check-runs')" "and no lookup"

fresh
checks "$C_CODE" "e2e / api:completed/success" "e2e / ui:completed/success" "lint:completed/failure"
report pass "$(gate "$C_CODE")" "all required checks passed on the commit"

fresh
checks "$C_CODE" "e2e / api:completed/success" "e2e / ui:completed/failure"
report fail "$(gate "$C_CODE")" "a failed required check blocks"
report 1 "$(grep -c 'e2e / ui: completed/failure' "$STATE/log")" "naming it"

fresh
checks "$C_CODE" "e2e / api:completed/success" "e2e / ui:in_progress/"
report fail "$(gate "$C_CODE")" "a required check still running blocks"

fresh
checks "$C_CODE" "e2e / api:completed/success" "e2e / ui:completed/skipped"
report fail "$(gate "$C_CODE")" "a skipped required check blocks"

fresh
checks "$C_CODE" "e2e / api:completed/success"
report fail "$(gate "$C_CODE")" "a required check that never ran blocks"
report 1 "$(grep -c 'e2e / ui: missing' "$STATE/log")" "naming it as missing"

fresh
checks "$C_CODE" "e2e / api:completed/success" "e2e / ui:completed/success"
report pass "$(gate "$C_DOCS")" "a docs/ commit is released on the checks of the commit before"
report 1 "$(grep -c "using that commit's checks" "$STATE/log")" "and says so"
report pass "$(gate "$C_README")" "so is a top-level *.md change (**/ matches the top level)"
report pass "$(gate "$C_DOCS" SKIP_PATHS='["docs/*"]')" "docs/* matches a file directly in docs/"
report fail "$(gate "$C_DOCS" SKIP_PATHS='["*.md"]')" "*.md does not match docs/guide.md: * stops at a / as in paths-ignore"
report fail "$(gate "$C_DOCS" SKIP_PATHS='["*"]')" "nor does *"
report pass "$(gate "$C_README" SKIP_PATHS='["*.md", "docs/*"]')" "*.md matches a top-level README.md"
report fail "$(gate "$C_README" SKIP_PATHS='["*.md"]')" "but not the docs/guide.md before it, which the gate also covers"
report pass "$(gate "$C_DOCS" SKIP_PATHS='["**/guide.md"]')" "**/ crosses directories"
report pass "$(gate "$C_DOCS" SKIP_PATHS='["docs/guide.md"]')" "a literal path, its . taken literally"
report fail "$(gate "$C_DOCS" SKIP_PATHS='["docs/guide-md"]')" "a literal path does not match another"
report fail "$(gate "$C_DOCS" SKIP_PATHS='["docs/guide.m?"]')" "an unsupported wildcard fails"
report 1 "$(grep -c 'supports only \* and \*\* wildcards, got: docs/guide.m?' "$STATE/log")" "naming the pattern"

fresh
checks "$C_CODE" "e2e / api:completed/success" "e2e / ui:completed/success"
report fail "$(gate "$C_LATE")" "a code commit whose checks have not started is not released on older ones"
report 1 "$(grep -c 'server.go changed since' "$STATE/log")" "naming the change"

fresh
checks "$C_CODE" "e2e / api:completed/success" "e2e / ui:completed/success"
report fail "$(gate "$C_DOCS" SKIP_PATHS='[]')" "without skip paths, a commit without checks blocks"

fresh
checks "$C_CODE" "e2e / api:completed/failure" "e2e / ui:completed/success"
report fail "$(gate "$C_DOCS")" "a docs commit after a red commit blocks"

fresh
checks "$C_CODE" "e2e / api:completed/success" "e2e / ui:in_progress/"
report pass "$(gate "$C_CODE" DRY_RUN=true)" "a dry run only reports unfinished checks"
report 1 "$(grep -c '::notice::Not releasable yet' "$STATE/log")" "as a notice"

fresh
report fail "$(gate "$C_CODE" REQUIRED_CHECKS='"e2e"')" "required_checks that is not a JSON array fails"
report fail "$(gate "$C_CODE" SKIP_PATHS='[""]')" "an empty skip path fails"

# --- release.yml: burned tags, version and notes -----------------------------

command -v git-cliff > /dev/null || {
  echo "FAIL: git-cliff is required (test-actions.yml installs the version release.yml pins)" >&2
  exit 1
}

BURNED_STEP="$(step release.yml prepare "Find burned release tags")"
CTX="$(step release.yml prepare "Read release context")"
VERSION_STEP="$(step release.yml prepare "Compute version")"
NOTES="$(step release.yml prepare "Render release notes")"

# History as the shared cliff.toml reads it, merge commits only:
# v1.0.0 (released) -> feat PR -> v1.1.0 (tagged, never released) -> fix PR.
BREPO="$TESTDIR/burned"
git -C "$TESTDIR" init -q -b main burned
bgit() { git -C "$BREPO" -c user.email=t@example.com -c user.name=T "$@"; }
bpr() { # bpr <title> <n>: merges a one-commit PR branch
  bgit switch -q -c "pr$2"
  bgit commit -q --allow-empty -m "$1"
  bgit switch -q main
  bgit merge -q --no-ff -m "$1 (#$2)" "pr$2"
}
bgit commit -q --allow-empty -m "chore: init"
bgit tag v1.0.0
bpr "feat: shipped in the burned tag" 1
bgit tag v1.1.0
bpr "fix: landed after it" 2
bgit switch -q -c side
bgit commit -q --allow-empty -m "unrelated"
bgit tag v9.0.0
bgit switch -q main
bgit tag vnext

out() { sed -n "s/^$1=//p" "$GITHUB_OUTPUT" | tail -n1; }

fresh
release v1.0.0 false
report pass "$(exec_step "$BREPO" "$BURNED_STEP")" "burned tags are found"
report "v1.1.0" "$(out burned)" "a tag on the branch without a release is burned; unrelated and non-version tags are not"
report '^(v1\.1\.0)$' "$(out ignore)" "and becomes an anchored, escaped --ignore-tags pattern"

fresh
release v1.0.0 false
release v1.1.0 false
report pass "$(exec_step "$BREPO" "$BURNED_STEP")" "with every tag released"
report "" "$(out burned)" "nothing is burned"
report "" "$(out ignore)" "and nothing is ignored"

fresh
report pass "$(exec_step "$BREPO" "$BURNED_STEP")" "without any release"
report "v1.0.0 v1.1.0" "$(out burned)" "every version tag on the branch is burned"

# A second release after the burned one: v1.1.1 shipped v1.1.0's changes,
# then v1.1.2 is tagged and never released either.
SREPO="$TESTDIR/shipped"
git clone -q "$BREPO" "$SREPO"
sgit() { git -C "$SREPO" -c user.email=t@example.com -c user.name=T "$@"; }
sgit tag v1.1.1
sgit commit -q --allow-empty -m "fix: after the next release"
sgit tag v1.1.2
sgit commit -q --allow-empty -m "fix: after that"

fresh
release v1.0.0 false
release v1.1.1 false
report pass "$(exec_step "$SREPO" "$BURNED_STEP")" "after a release that shipped a burned tag"
report "v1.1.2" "$(out burned)" "the shipped burned tag is not burned any more, a newer one is"

fresh
release v1.0.0 false
release v1.1.1 false
release v1.1.2 false
report pass "$(exec_step "$SREPO" "$BURNED_STEP")" "with the newer one released too"
report "" "$(out burned)" "nothing is burned"

fresh
report pass "$(exec_step "$BREPO" "$CTX" CLIFF_CONFIG="$ROOT/cliff.toml" IGNORE_TAGS='^(v1\.1\.0)$')" \
  "the context is read with the burned tag ignored"
report v1.0.0 "$(out previous)" "the previous release is the last released tag"
report v1.1.0 "$(out computed)" "the bump counts the burned tag's feat"
report "landed after it (#2)|shipped in the burned tag (#1)|" \
  "$(jq -r '.[0].commits[].message' "$BREPO/ctx.json" | sort | tr '\n' '|')" \
  "the burned tag's commits are part of this release"

fresh
report pass "$(exec_step "$BREPO" "$CTX" CLIFF_CONFIG="$ROOT/cliff.toml" IGNORE_TAGS=)" \
  "without burned tags, the context is read as before"
report v1.1.0 "$(out previous)" "from the newest tag"
report "landed after it (#2)|" "$(jq -r '.[0].commits[].message' "$BREPO/ctx.json" | tr '\n' '|')" \
  "with only the commits after it"

fresh
report pass "$(exec_step "$BREPO" "$VERSION_STEP" INPUT_VERSION= COMPUTED_VERSION=v1.1.0)" \
  "a computed version taken by a burned tag"
report v1.1.1 "$(out version)" "moves on to the next free patch"
report 1 "$(grep -c 'v1.1.0 is taken' "$STATE/log")" "and says so"

fresh
report fail "$(exec_step "$BREPO" "$VERSION_STEP" INPUT_VERSION=v1.1.0 COMPUTED_VERSION=v1.1.0)" \
  "an explicit version that is taken fails"

fresh
report pass "$(exec_step "$BREPO" "$VERSION_STEP" INPUT_VERSION= COMPUTED_VERSION=v1.2.0)" "a free version"
report v1.2.0 "$(out version)" "is used as computed"

fresh
report fail "$(exec_step "$BREPO" "$VERSION_STEP" INPUT_VERSION='v1.2.0;x' COMPUTED_VERSION=)" \
  "a version that is not a valid tag fails"

# Burned prereleases, in a repository of their own.
PREPO="$TESTDIR/pre"
git -C "$TESTDIR" init -q -b main pre
git -C "$PREPO" -c user.email=t@example.com -c user.name=T commit -q --allow-empty -m "chore: init"
for t in v2.0.0-rc1 v2.0.0-rc2 v2.0.0-alpha.9 v2.0.0-beta; do git -C "$PREPO" tag "$t"; done

fresh
report pass "$(exec_step "$PREPO" "$VERSION_STEP" INPUT_VERSION= COMPUTED_VERSION=v2.0.0-rc1)" \
  "a computed prerelease taken by burned tags"
report v2.0.0-rc3 "$(out version)" "moves on to the next free number at its end"

fresh
report pass "$(exec_step "$PREPO" "$VERSION_STEP" INPUT_VERSION= COMPUTED_VERSION=v2.0.0-alpha.9)" \
  "a dotted prerelease number"
report v2.0.0-alpha.10 "$(out version)" "is counted on numerically"

fresh
report fail "$(exec_step "$PREPO" "$VERSION_STEP" INPUT_VERSION= COMPUTED_VERSION=v2.0.0-beta)" \
  "a taken prerelease without a number at its end fails"
report 1 "$(grep -c 'Pass an explicit version' "$STATE/log")" "and asks for an explicit version"

fresh
report pass "$(exec_step "$BREPO" "$NOTES" VERSION=v1.1.1 SHA="$SHA" CLIFF_CONFIG="$ROOT/cliff.toml" \
  PREVIOUS_TAG=v1.0.0 IGNORE_TAGS='^(v1\.1\.0)$' BURNED=v1.1.0)" "notes are rendered"
report 1 "$(grep -c 'shipped in the burned tag' "$BREPO/release-notes/notes.md")" "with the burned tag's changes"
report 1 "$(grep -c 'landed after it' "$BREPO/release-notes/notes.md")" "and the ones after it"
report 1 "$(grep -c '^> v1.1.0 was tagged but never released' "$BREPO/release-notes/notes.md")" \
  "and a line naming the burned version"

# --- release.yml: release tag protection -------------------------------------

PROTECT="$(step release.yml prepare "Guard - release tags are protected")"
ruleset() { # ruleset <id> <target> <enforcement> <include json> <exclude json> <rules json>
  jq -n --argjson id "$1" --arg t "$2" --arg e "$3" --argjson inc "$4" --argjson exc "$5" --argjson rules "$6" \
    '{id: $id, name: "rs\($id)", target: $t, enforcement: $e,
      conditions: {ref_name: {include: $inc, exclude: $exc}},
      rules: [$rules[] | {type: .}]}' > "$STATE/rulesets/$1.json"
}
protect() { exec_step "$REPO" "$PROTECT" VERSION=v1.2.0 DRY_RUN=false "$@"; }

fresh
report fail "$(protect)" "without a tag ruleset, nothing is tagged"
report 1 "$(grep -c "make repo-settings" "$STATE/log")" "and the error says how to add one"

fresh
report pass "$(protect DRY_RUN=true)" "a dry run only warns"

fresh
ruleset 7 branch active '["~DEFAULT_BRANCH"]' '[]' '["update","deletion"]'
ruleset 8 tag active '["refs/tags/v*"]' '[]' '["update","deletion"]'
report pass "$(protect)" "an active ruleset refusing update and deletion of v* tags protects"
report 1 "$(grep -c 'protected by ruleset rs8' "$STATE/log")" "and is named"

fresh
ruleset 8 tag active '["~ALL"]' '[]' '["deletion","update","creation"]'
report pass "$(protect)" "~ALL protects too"

fresh
ruleset 8 tag evaluate '["refs/tags/v*"]' '[]' '["update","deletion"]'
report fail "$(protect)" "a ruleset in evaluate mode does not protect"

fresh
ruleset 8 tag active '["refs/tags/v*"]' '[]' '["update"]'
report fail "$(protect)" "a ruleset that still allows deletion does not protect"

fresh
ruleset 8 tag active '["refs/tags/v*"]' '["refs/tags/v1.2.*"]' '["update","deletion"]'
report fail "$(protect)" "a ruleset that excludes this tag does not protect it"

fresh
ruleset 8 tag active '["refs/tags/chart-*"]' '[]' '["update","deletion"]'
report fail "$(protect)" "a ruleset for other tags does not protect it"

fresh
ruleset 9 branch active '["~ALL"]' '[]' '["update","deletion"]'
report fail "$(protect)" "a branch ruleset does not protect tags"

# bypass <id> <jq update>: amends a stored ruleset.
bypass() { jq "$2" "$STATE/rulesets/$1.json" > "$STATE/rs.tmp" && mv "$STATE/rs.tmp" "$STATE/rulesets/$1.json"; }

fresh
ruleset 8 tag active '["refs/tags/v*"]' '[]' '["update","deletion"]'
bypass 8 '.bypass_actors = [{actor_type: "RepositoryRole", actor_id: 5, bypass_mode: "always"}]'
report fail "$(protect)" "a ruleset with bypass actors does not protect"
report 1 "$(grep -c 'rs8 has bypass actors' "$STATE/log")" "and says why"

fresh
ruleset 8 tag active '["refs/tags/v*"]' '[]' '["update","deletion"]'
bypass 8 '.current_user_can_bypass = "always"'
report fail "$(protect)" "a ruleset this workflow can bypass does not protect"

fresh
ruleset 8 tag active '["refs/tags/v*"]' '[]' '["update","deletion"]'
bypass 8 '.bypass_actors = [] | .current_user_can_bypass = "never"'
report pass "$(protect)" "an empty bypass list that the workflow cannot bypass protects"

fresh
ruleset 7 tag active '["refs/tags/v*"]' '[]' '["update","deletion"]'
bypass 7 '.current_user_can_bypass = "always"'
ruleset 8 tag active '["refs/tags/v*"]' '[]' '["update","deletion"]'
report pass "$(protect)" "another ruleset without bypass still protects"
report 1 "$(grep -c 'protected by ruleset rs8' "$STATE/log")" "and is the one named"

# --- release.yml: what a dry run does ----------------------------------------

stepif() { yq ".jobs.$2.steps[] | select(.name == \"$3\") | .if" "$WF/$1"; }
for s in "Create tag" "Hand over release notes"; do
  report 1 "$(stepif release.yml prepare "$s" | grep -c '!inputs.dry_run')" "a dry run skips '$s'"
done
report 0 "$(grep -c 'gh release \(create\|edit\|upload\)' "$WF/release.yml")" \
  "release.yml creates no release"
order=$(yq '.jobs.prepare.steps[].name' "$WF/release.yml" | grep -nE '^(Guard - required checks passed|Guard - release tags are protected|Hand over release notes|Create tag)$' | cut -d: -f2 | tr '\n' '|')
report "Guard - required checks passed|Guard - release tags are protected|Hand over release notes|Create tag|" "$order" \
  "checks and tag protection come before anything is handed over or tagged"
report true "$(yq '.jobs.prepare.steps[] | select(.name == "Hand over release notes") | .with.overwrite' "$WF/release.yml")" \
  "a re-run can hand the notes over again"

# --- the caller wiring in release-self.yml -----------------------------------

caller_expr() { yq "$1" "$WF/release-self.yml" | sed -E 's/^\$\{\{ (.*) \}\}$/\1/'; }
report "github.event_name != 'workflow_dispatch' || inputs.dry_run" "$(caller_expr '.jobs.release.with.dry_run')" \
  "a push is always a dry run"
report "needs.release.outputs.tag_created == 'true'" "$(caller_expr '.jobs.draft.if')" \
  "the draft job runs only after a tag was created"
report "needs.release.outputs.sha" "$(caller_expr '.jobs.draft.with.sha')" "the draft job gets the tagged commit"
report "read" "$(caller_expr '.jobs.release.permissions.checks')" "the release job may read check runs"
report 1 "$(caller_expr '.concurrency.group' | grep -c "'release-preview'")" "push previews do not share the release group"

# --- release-draft.yml -------------------------------------------------------

DRAFT="$(step release-draft.yml draft "Create or update draft release")"
work() {
  mkdir -p "$STATE/work/release-notes"
  echo notes > "$STATE/work/release-notes/notes.md"
  echo "$STATE/work"
}
draft() { # draft <version> <assets_artifact> [VAR=value...]: tag at $SHA unless set up otherwise
  local v=$1 a=$2
  shift 2
  [ -f "$STATE/refs/$v" ] || echo "$SHA" > "$STATE/refs/$v"
  exec_step "$(work)" "$DRAFT" VERSION="$v" SHA="$SHA" ASSETS_ARTIFACT="$a" "$@"
}

fresh
assets bin/tool-linux-amd64 bin/tool-darwin-arm64 checksums.txt
report pass "$(draft v1.2.0 release-assets)" "a new draft is created"
report 1 "$(calls 'release create v1.2.0 --repo org/repo --draft --verify-tag')" \
  "as a draft of the existing tag"
report "tool-darwin-arm64 tool-linux-amd64 checksums.txt" "$(attached v1.2.0)" \
  "with every file of the artifact, flattened"
report 1 "$(grep -c 'releases/tag/v1.2.0' "$GITHUB_STEP_SUMMARY")" "the summary links the draft"

fresh
report pass "$(draft v1.2.0 '')" "without assets, the draft has notes only"
report "" "$(attached v1.2.0)" "and no files"

fresh
echo "$OTHER" > "$STATE/refs/v1.2.0"
assets tool
report fail "$(draft v1.2.0 release-assets)" "a tag that points elsewhere than the built commit fails"
report 1 "$(grep -c "points at '$OTHER', not $SHA" "$STATE/log")" "naming both commits"
report 0 "$(calls 'release \(create\|edit\|upload\)')" "and nothing is drafted"

fresh
assets tool
report fail "$(exec_step "$(work)" "$DRAFT" VERSION=v1.2.0 SHA="$SHA" ASSETS_ARTIFACT=release-assets)" \
  "a missing tag fails"
report 0 "$(calls 'release create')" "before a draft is created"

fresh
release v1.2.0-rc1 true
report pass "$(draft v1.2.0-rc1 '')" "a prerelease draft is accepted"
report 1 "$(calls 'release edit v1.2.0-rc1 .*--prerelease=true')" "and marked as a prerelease"

fresh
release v1.2.0 true tool-linux-amd64 stale-from-v4.tar.gz
assets tool-linux-amd64 tool-darwin-arm64
report pass "$(draft v1.2.0 release-assets)" "a re-run updates the existing draft"
report 0 "$(calls 'release create')" "instead of creating another"
report 1 "$(calls 'release upload v1.2.0 --repo org/repo --clobber')" "replacing assets of the same name"
report "tool-linux-amd64 tool-darwin-arm64" "$(attached v1.2.0)" "and dropping assets this build did not make"

fresh
release v1.2.0 false tool-linux-amd64
assets tool-linux-amd64
report fail "$(draft v1.2.0 release-assets)" "a published release fails"
report 0 "$(calls 'release \(create\|edit\|upload\|delete-asset\)')" "and is left untouched"

fresh
release v1.2.0 true tool
assets tool
report fail "$(draft v1.2.0 release-assets VIEW_FAIL=1)" "a failed release lookup fails"
report 0 "$(calls 'release create')" "instead of being taken for a missing release"

fresh
mkdir -p "$STATE/work/release-assets"
report fail "$(draft v1.2.0 release-assets)" "an empty asset artifact fails"
report 0 "$(calls 'release create')" "before any draft exists"

fresh
assets linux/tool darwin/tool
report fail "$(draft v1.2.0 release-assets)" "two files with the same name fail"
report 1 "$(grep -c 'several files named: tool' "$STATE/log")" "naming the clash"
report 0 "$(calls 'release create')" "before any draft exists"

for name in "My App.zip" ".hidden" "tool." "tool@1"; do
  fresh
  assets "$name"
  report fail "$(draft v1.2.0 release-assets)" "a file GitHub would rename fails: '$name'"
  report 0 "$(calls 'release create')" "before any draft exists"
done

# Against an existing draft: a name with a newline splits into two valid
# lines ("My", "App.zip") unless each name is checked whole.
fresh
release v1.2.0 true tool
assets $'My\nApp.zip'
report fail "$(draft v1.2.0 release-assets)" "a file name with a newline fails on a re-run"
report 1 "$(grep -c "would rename: \$'My\\\\nApp.zip'" "$STATE/log")" "naming it quoted"
report 0 "$(calls 'release \(edit\|upload\|delete-asset\)')" "and the draft is left untouched"
report "tool" "$(attached v1.2.0)" "with its assets"

fresh
release v1.2.0 true tool_v1.2.0-linux.tar.gz
assets tool_v1.2.0-linux.tar.gz
report pass "$(draft v1.2.0 release-assets)" "a name of letters, digits, . _ and - is kept"
report "tool_v1.2.0-linux.tar.gz" "$(attached v1.2.0)" "and not deleted as stale on a re-run"

# Overtaken: run A tagged v1.2.0 and failed; run B then cut v1.2.1. A re-run
# of A's failed jobs reaches the draft job with v1.2.0.
fresh
echo "$SHA" > "$STATE/refs/v1.2.1"
report fail "$(draft v1.2.0 '')" "a re-run overtaken by a newer tag is not drafted"
report 1 "$(grep -c 'v1.2.0 was superseded: v1.2.1' "$STATE/log")" "naming the newer tag"
report 0 "$(calls 'release create')" "and no draft is created"

fresh
release v1.2.1 true
report fail "$(draft v1.2.0 '')" "a pending draft blocks drafting another"
report 0 "$(calls 'release create')" "and no draft is created"

fresh
echo "$SHA" > "$STATE/refs/v1.2.0-rc1"
echo "$SHA" > "$STATE/refs/v1.1.9"
report pass "$(draft v1.2.0 '')" "older tags and own prereleases do not count as newer"

fresh
echo "$SHA" > "$STATE/refs/v1.2.0"
report fail "$(draft v1.2.0-rc1 '')" "a prerelease is overtaken by its final version"

fresh
echo "$OTHER" > "$STATE/refs/v1.2.1"
report fail "$(draft v1.2.0 '')" "a newer tag on a later commit overtakes"

# A mistaken explicit v2.0.0 was tagged and abandoned; the next run cut v1.1.1.
fresh
echo "$OLDER" > "$STATE/refs/v2.0.0"
report pass "$(draft v1.1.1 '')" "a higher tag on an earlier commit does not overtake"
report 1 "$(calls 'release create v1.1.1')" "and the draft is created"

fresh
echo "$OTHER" > "$STATE/refs/v1.1.1"
report fail "$(draft v2.0.0 '')" "a lower tag on a later commit overtakes"
report 1 "$(grep -c 'v2.0.0 was superseded: v1.1.1' "$STATE/log")" "naming it"

exit "$fail"
