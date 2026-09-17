#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
TESTDIR="$(mktemp -d)"
trap 'rm -rf "$TESTDIR"' EXIT

cd "$TESTDIR"

run_test() {
  local name="$1"
  local expected_rc="$2"
  local expected_output="$3"

  echo "=== $name ==="
  local output rc
  set +e
  output="$("$ROOT/check-go-version.sh" 2>&1)"
  rc=$?
  set -e
  if [ -n "$output" ]; then
    echo "$output"
  fi
  if [ "$rc" -ne "$expected_rc" ]; then
    echo "FAIL: expected exit code $expected_rc, got $rc"
    exit 1
  fi
  if echo "$output" | grep -q "$expected_output"; then
    echo "PASS"
  else
    echo "FAIL: expected output to contain '$expected_output'"
    exit 1
  fi
  echo
}

reset() {
  rm -f go.mod flake.nix Dockerfile
}

write_go_mod()    { printf 'module example.com/x\n\ngo %s\n' "$1" > go.mod; }
write_flake()     { printf '{\n  outputs = {\n    devShells.default = mkShell {\n      goVersion = "%s";\n    };\n  };\n}\n' "$1" > flake.nix; }
# The literal `--platform=$BUILDPLATFORM` matters: it is what Solar and ARC
# write, and the extraction has to skip the flag to reach the image tag.
write_dockerfile() {
  cat > Dockerfile <<'EOF'
# Build the manager binary
FROM --platform=$BUILDPLATFORM golang:__TAG__ AS builder
RUN make build
EOF
  sed -i "s|__TAG__|$1${2:-}|" Dockerfile
}

# --- all three agree -------------------------------------------------------
reset
write_go_mod 1.27.0
write_flake 1.27.0
write_dockerfile 1.27.0 "@sha256:0d1d3a794be25f809dd2cb3160d8c73276c4056a9f8242a138e908ddeee7b6b6"
run_test "all three pins agree" 0 "Go version pins agree: 1.27.0"

# --- go.mod disagrees with flake.nix ---------------------------------------
reset
write_go_mod 1.27.1
write_flake 1.27.0
run_test "go.mod and flake.nix disagree" 1 "Go version pins disagree"

# --- the Dockerfile is the one left behind ---------------------------------
reset
write_go_mod 1.27.0
write_flake 1.27.0
write_dockerfile 1.26.6 "@sha256:0d1d3a794be25f809dd2cb3160d8c73276c4056a9f8242a138e908ddeee7b6b6"
run_test "Dockerfile left behind" 1 "Dockerfile 1.26.6"

# --- minor-level docker tag: the ARC #483 case -----------------------------
reset
write_go_mod 1.26.6
write_flake 1.26.6
write_dockerfile 1.26 "@sha256:0d1d3a794be25f809dd2cb3160d8c73276c4056a9f8242a138e908ddeee7b6b6"
run_test "minor-level golang tag is rejected" 1 "a patch-level tag is required"

# --- library repository: no Dockerfile -------------------------------------
reset
write_go_mod 1.27.0
write_flake 1.27.0
run_test "library repo without a Dockerfile" 0 "Go version pins agree: 1.27.0"

# --- go.mod only -----------------------------------------------------------
reset
write_go_mod 1.27.0
run_test "go.mod alone" 0 "Go version pins agree: 1.27.0"

# --- two golang tags in one Dockerfile -------------------------------------
reset
write_go_mod 1.27.0
write_flake 1.27.0
cat > Dockerfile <<'EOF'
FROM --platform=$BUILDPLATFORM golang:1.27.0 AS builder
FROM golang:1.26.6 AS tools
EOF
run_test "conflicting golang tags in one Dockerfile" 1 "pins more than one Go version"

# --- variant tags: the version is what has to agree, not the base image -----
reset
write_go_mod 1.25.7
write_flake 1.25.7
write_dockerfile 1.25.7-alpine3.22
run_test "variant tag agrees on the version" 0 "Go version pins agree: 1.25.7"

reset
write_go_mod 1.26.6
write_flake 1.26.6
write_dockerfile 1.26-alpine
run_test "minor-level variant tag is rejected" 1 "a patch-level tag is required"

reset
write_go_mod 1.27.0
write_flake 1.27.0
write_dockerfile latest
run_test "non-version tag is rejected" 1 "cannot read a Go version from the golang tag"

# --- two stages, same version, different base ------------------------------
reset
write_go_mod 1.27.0
write_flake 1.27.0
cat > Dockerfile <<'EOF'
FROM --platform=$BUILDPLATFORM golang:1.27.0 AS builder
FROM golang:1.27.0-alpine3.22 AS tools
EOF
run_test "same version, different variants" 0 "Go version pins agree: 1.27.0"

# --- lowercase FROM: valid Dockerfile syntax -------------------------------
reset
write_go_mod 1.27.0
write_flake 1.27.0
cat > Dockerfile <<'EOF'
from golang:1.26.6 AS builder
EOF
run_test "lowercase from is not skipped" 1 "Dockerfile 1.26.6"

# --- indented FROM: leading whitespace is ignored by Docker ----------------
reset
write_go_mod 1.27.0
write_flake 1.27.0
cat > Dockerfile <<'EOF'
  FROM golang:1.26.6 AS builder
EOF
run_test "indented FROM is not skipped" 1 "Dockerfile 1.26.6"

# --- a go directive that cannot be parsed is an error, not a skip ----------
reset
write_flake 1.27.0
printf 'module example.com/x\n\ngo 1.27.0 // pinned\n' > go.mod
run_test "unparseable go directive" 1 "cannot read a Go version from the go directive"

# --- a goVersion that is not patch-level is an error, not a skip ----------
reset
write_go_mod 1.27.0
printf '{\n  goVersion = "1.27";\n}\n' > flake.nix
run_test "non patch-level goVersion" 1 "cannot read a Go version from goVersion"

# --- nothing to check ------------------------------------------------------
reset
run_test "no Go pins at all" 0 "nothing to check"

echo "All tests passed"
