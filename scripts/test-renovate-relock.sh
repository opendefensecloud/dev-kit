#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
TESTDIR="$(mktemp -d)"
trap 'rm -rf "$TESTDIR"' EXIT

# A stand-in for nix: what each subcommand does is set per test through
# FAKE_* variables, and every call is appended to $TESTDIR/calls.
mkdir "$TESTDIR/bin"
cat > "$TESTDIR/bin/nix" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "$*" >> "$FAKE_CALLS"
bump() { jq --arg n "$1" '.nodes[$n].locked.rev = "new"' flake.lock > flake.lock.tmp && mv flake.lock.tmp flake.lock; }
case "$*" in
  "flake lock")                [ -z "${FAKE_LOCK_BUMPS:-}" ] || bump "$FAKE_LOCK_BUMPS" ;;
  "flake update go-overlay")   [ -z "${FAKE_OVERLAY_NEWER:-}" ] || bump go-overlay ;;
  "eval --impure --raw --expr builtins.currentSystem") printf x86_64-linux ;;
  "eval --raw .#devShells.x86_64-linux.default.drvPath")
    if [ -n "${FAKE_GO_MISSING:-}" ]; then
      echo "error: dev-kit: Go 1.27.9 is not in the locked go-overlay." >&2
      exit 1
    fi
    printf /nix/store/fake-dev-shell.drv ;;
  *) echo "fake nix: unexpected: $*" >&2; exit 2 ;;
esac
EOF
chmod +x "$TESTDIR/bin/nix"
export PATH="$TESTDIR/bin:$PATH"
export FAKE_CALLS="$TESTDIR/calls"

cd "$TESTDIR"
git init -q repo
cd repo
git config user.email "test@test"
git config user.name "Test"

# A consumer's lock: dev-kit and go-overlay as root inputs, unless $1 is
# "no-overlay".
reset() {
  if [ "${1:-}" = no-overlay ]; then
    echo '{"nodes":{"root":{"inputs":{"dev-kit":"dev-kit"}},"dev-kit":{"locked":{"rev":"old"}}}}' > flake.lock
  else
    echo '{"nodes":{"root":{"inputs":{"dev-kit":"dev-kit","go-overlay":"go-overlay"}},"dev-kit":{"locked":{"rev":"old"}},"go-overlay":{"locked":{"rev":"old"}}}}' > flake.lock
  fi
  git add flake.lock
  git commit -q --no-gpg-sign --allow-empty -m lock
  : > "$FAKE_CALLS"
  unset FAKE_LOCK_BUMPS FAKE_OVERLAY_NEWER FAKE_GO_MISSING
}

# run_test <name> <expected rc> <expected stdout> <head-ref>
run_test() {
  local name="$1" expected_rc="$2" expected_out="$3" head_ref="$4"
  echo "=== $name ==="
  local out rc
  set +e
  out="$("$ROOT/renovate-relock.sh" "$head_ref" 2> "$TESTDIR/stderr")"
  rc=$?
  set -e
  cat "$TESTDIR/stderr"
  echo "$out"
  if [ "$rc" -ne "$expected_rc" ]; then
    echo "FAIL: expected exit code $expected_rc, got $rc"
    exit 1
  fi
  if [ "$(printf '%s' "$out" | tr '\n' ' ')" != "$expected_out" ]; then
    echo "FAIL: expected stdout '$expected_out'"
    exit 1
  fi
  echo "PASS"
  echo
}

called() {
  if ! grep -qxF "$1" "$FAKE_CALLS"; then
    echo "FAIL: nix $1 was not called"
    exit 1
  fi
}
not_called() {
  if grep -qxF "$1" "$FAKE_CALLS"; then
    echo "FAIL: nix $1 was called"
    exit 1
  fi
}

# --- dev-kit branch --------------------------------------------------------
reset
export FAKE_LOCK_BUMPS=dev-kit
run_test "dev-kit tag bumped: relocked" 0 "what=dev-kit changed=true" renovate/dev-kit
not_called "flake update go-overlay"

reset
run_test "dev-kit lock current: nothing to commit" 0 "what=dev-kit changed=false" renovate/dev-kit

# --- Go version branch -----------------------------------------------------
reset
export FAKE_OVERLAY_NEWER=1
run_test "go-overlay behind: refreshed" 0 "what=go-overlay changed=true" renovate/go-version
called "flake update go-overlay"
called "eval --raw .#devShells.x86_64-linux.default.drvPath"

reset
run_test "go-overlay current: nothing to commit" 0 "what=go-overlay changed=false" renovate/go-version

reset
export FAKE_OVERLAY_NEWER=1 FAKE_GO_MISSING=1
run_test "go-overlay lacks the Go version: fails" 1 "" renovate/go-version
grep -q '::error::' "$TESTDIR/stderr" || {
  echo "FAIL: no ::error:: annotation"
  exit 1
}

reset no-overlay
run_test "no go-overlay input: only flake lock" 0 "what=dev-kit changed=false" renovate/go-version
not_called "flake update go-overlay"

# --- a custom Go branch name -----------------------------------------------
reset
export FAKE_OVERLAY_NEWER=1
echo "=== go-branch argument is honoured ==="
out="$("$ROOT/renovate-relock.sh" renovate/golang renovate/golang 2> /dev/null)"
[ "$(printf '%s' "$out" | tr '\n' ' ')" = "what=go-overlay changed=true" ] || {
  echo "FAIL: $out"
  exit 1
}
echo "PASS"
echo

echo "All tests passed"
