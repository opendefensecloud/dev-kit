#!/usr/bin/env bash
set -euo pipefail

# Runs upload-release-assets.sh against a stub gh whose release state lives in
# files, so a test can publish or move the draft mid-upload.

ROOT="$(cd "$(dirname "$0")" && pwd)"
TESTDIR="$(mktemp -d)"
trap 'rm -rf "$TESTDIR"' EXIT

SHA=1111111111111111111111111111111111111111
OTHER=2222222222222222222222222222222222222222

mkdir -p "$TESTDIR/bin"
# State: $STATE/draft (true|false), $STATE/target, $STATE/missing (exists =
# no release). $STATE/on-upload, if present, is run by `gh release upload`.
cat > "$TESTDIR/bin/gh" << 'GH'
#!/usr/bin/env bash
set -euo pipefail
echo "gh $*" >> "$STATE/calls"
case "$1 $2" in
  "release view")
    [ ! -e "$STATE/missing" ] || exit 1
    echo "$(cat "$STATE/draft") $(cat "$STATE/target")"
    ;;
  "release edit") ;;
  "release upload")
    if [ -e "$STATE/on-upload" ]; then bash "$STATE/on-upload"; fi
    ;;
  *) echo "unexpected gh call: $*" >&2; exit 2 ;;
esac
GH
chmod +x "$TESTDIR/bin/gh"

fail=0

# run <want: pass|fail> <description> <draft> <target> [files] [on-upload]
run() {
  local want=$1 desc=$2 got out
  export STATE="$TESTDIR/state-$RANDOM"
  mkdir -p "$STATE"
  echo "$3" > "$STATE/draft"
  echo "$4" > "$STATE/target"
  [ -z "${6:-}" ] || echo "$6" > "$STATE/on-upload"

  if out=$(cd "$TESTDIR/work" && PATH="$TESTDIR/bin:$PATH" TAG=v1.2.3 SHA="${SHA_OVERRIDE:-$SHA}" \
    FILES="${5:-bin/app-*
checksums.txt}" GITHUB_REPOSITORY=org/repo bash "$ROOT/upload-release-assets.sh" 2>&1); then
    got=pass
  else
    got=fail
  fi

  if [ "$got" = "$want" ]; then
    echo "ok   $desc"
  else
    echo "FAIL $desc: expected $want, got $got"
    printf "     %s\n" "$out"
    fail=1
  fi
  LAST_OUT=$out
  LAST_CALLS=$(cat "$STATE/calls" 2> /dev/null || true)
}

mkdir -p "$TESTDIR/work/bin"
touch "$TESTDIR/work/bin/app-linux" "$TESTDIR/work/bin/app-darwin" \
  "$TESTDIR/work/checksums.txt" "$TESTDIR/work/with space.txt"

# has <text> <pattern> / lacks <text> <pattern>: assert on the last run.
has() { grep -q -- "$2" <<< "$1" || bad "expected '$2' in: $1"; }
lacks() { if grep -q -- "$2" <<< "$1"; then bad "unexpected '$2' in: $1"; fi; }
bad() {
  echo "FAIL $*"
  fail=1
}

run pass "uploads to a draft that targets the built commit" true "$SHA"
has "$LAST_CALLS" 'release upload v1.2.3 bin/app-darwin bin/app-linux checksums.txt --repo org/repo --clobber'
has "$LAST_CALLS" 'release edit v1.2.3 --repo org/repo --title v1.2.3'

run fail "refuses a published release" false "$SHA"
has "$LAST_OUT" 'was published before the upload'
lacks "$LAST_CALLS" 'release edit'
lacks "$LAST_CALLS" 'release upload'

run fail "refuses a draft moved to another commit" true "$OTHER"
has "$LAST_OUT" "now targets $OTHER"
lacks "$LAST_CALLS" 'release upload'

run fail "refuses a draft that targets a branch" true main

# The stub runs this itself, so it expands $STATE there.
# shellcheck disable=SC2016
run fail "reports a release published during the upload" true "$SHA" "" 'echo false > "$STATE/draft"'
has "$LAST_OUT" 'was published during the upload'
lacks "$LAST_CALLS" 'release edit'

run fail "fails when a pattern matches nothing" true "$SHA" "bin/app-*
provenance/*.intoto.jsonl"
lacks "$LAST_CALLS" 'release upload'

run pass "keeps a path with spaces whole" true "$SHA" "with space.txt"
has "$LAST_CALLS" 'release upload v1.2.3 with space.txt --repo'

SHA_OVERRIDE=1111111 run fail "rejects a short sha" true 1111111
unset SHA_OVERRIDE

export STATE="$TESTDIR/missing"
mkdir -p "$STATE"
touch "$STATE/missing"
if (cd "$TESTDIR/work" && PATH="$TESTDIR/bin:$PATH" TAG=v1.2.3 SHA=$SHA FILES=checksums.txt \
  GITHUB_REPOSITORY=org/repo bash "$ROOT/upload-release-assets.sh" > /dev/null 2>&1); then
  bad "a missing release passed"
else
  echo "ok   fails when the release does not exist"
fi

exit "$fail"
