#!/usr/bin/env bash
# Assert that every place this repository pins the Go version agrees.
#
# Sources, each optional — a repository that lacks one is simply not checked:
#
#   go.mod      `go <version>`                  the language version
#   flake.nix   `goVersion = "<version>";`      the dev shell and CI toolchain
#   Dockerfile  `FROM ... golang:<tag>`         the build image
#
# Disagreement between them is the failure mode behind every Go bump: Renovate
# updates some of the pins, and CI then fails somewhere else entirely with an
# error that does not mention the file that is actually wrong.
#
# The Docker tag must be patch-level (1.27.0, not 1.27). A minor-level tag never
# compares equal to the other two, and Renovate cannot fold it into the same
# update group, so the image silently stays behind.
set -euo pipefail

GO_MOD="${GO_MOD:-go.mod}"
FLAKE_NIX="${FLAKE_NIX:-flake.nix}"
DOCKERFILE="${DOCKERFILE:-Dockerfile}"

labels=()
versions=()
files=()

record() {
  labels+=("$1")
  versions+=("$2")
  files+=("$3")
}

# A file that does not exist is skipped on purpose — a library has no
# Dockerfile. A file that *does* exist but whose pin cannot be parsed is an
# error, never a skip: silently ignoring it is the same silent drift this script
# exists to catch.

# go.mod — `go 1.27.0`. The `toolchain` directive is a different line and is
# deliberately not read.
if [ -f "$GO_MOD" ]; then
  candidate="$(sed -nE 's/^[[:space:]]*go[[:space:]]+([^[:space:]].*)$/\1/p' "$GO_MOD")"
  if [ -n "$candidate" ]; then
    v="$(printf '%s\n' "$candidate" | sed -nE 's/^([0-9]+\.[0-9]+(\.[0-9]+)?)[[:space:]]*$/\1/p')"
    if [ -z "$v" ]; then
      echo "error: cannot read a Go version from the go directive in $GO_MOD:" >&2
      printf '%s\n' "$candidate" | sed 's/^/  go /' >&2
      exit 1
    fi
    record "go.mod" "$v" "$GO_MOD"
  fi
fi

# flake.nix — same expression the get-go-version action reads.
if [ -f "$FLAKE_NIX" ]; then
  candidate="$(sed -nE 's/^[[:space:]]*goVersion[[:space:]]*=[[:space:]]*(.*)$/\1/p' "$FLAKE_NIX")"
  if [ "$(printf '%s\n' "$candidate" | sed '/^$/d' | wc -l)" -gt 1 ]; then
    echo "error: expected at most one goVersion assignment in $FLAKE_NIX, found:" >&2
    printf '%s\n' "$candidate" | sed 's/^/  goVersion = /' >&2
    exit 1
  fi
  if [ -n "$candidate" ]; then
    v="$(printf '%s\n' "$candidate" | sed -nE 's/^"([0-9]+\.[0-9]+\.[0-9]+)";[[:space:]]*$/\1/p')"
    if [ -z "$v" ]; then
      echo "error: cannot read a Go version from goVersion in $FLAKE_NIX:" >&2
      printf '%s\n' "$candidate" | sed 's/^/  goVersion = /' >&2
      echo "       Expected a patch-level version, as in: goVersion = \"1.27.0\";" >&2
      exit 1
    fi
    record "flake.nix" "$v" "$FLAKE_NIX"
  fi
fi

# Dockerfile — every `golang:<tag>` builder stage, digest suffix stripped.
# Instruction keywords are case-insensitive and leading whitespace is ignored,
# so `from golang:…` and an indented `FROM` are valid and must be seen.
if [ -f "$DOCKERFILE" ]; then
  mapfile -t tags < <(awk '
    toupper($1) == "FROM" {
      image = ""
      for (i = 2; i <= NF; i++) {
        if ($i ~ /^--/) continue
        image = $i
        break
      }
      if (image ~ /^golang:/) {
        sub(/^golang:/, "", image)
        sub(/@.*/, "", image)
        print image
      }
    }' "$DOCKERFILE" | sort -u)
  if [ "${#tags[@]}" -gt 1 ]; then
    echo "error: $DOCKERFILE pins more than one golang tag: ${tags[*]}" >&2
    exit 1
  fi
  if [ "${#tags[@]}" -eq 1 ]; then
    record "Dockerfile" "${tags[0]}" "$DOCKERFILE"
    if ! [[ "${tags[0]}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      echo "error: $DOCKERFILE pins golang:${tags[0]} — a patch-level tag is required." >&2
      echo "       A minor-level tag never matches go.mod or flake.nix, and Renovate" >&2
      echo "       cannot group it with the other Go pins, so the image stays behind." >&2
      exit 1
    fi
  fi
fi

if [ "${#versions[@]}" -eq 0 ]; then
  echo "note: no Go version pins found in $GO_MOD, $FLAKE_NIX or $DOCKERFILE — nothing to check" >&2
  exit 0
fi

for i in "${!versions[@]}"; do
  if [ "${versions[$i]}" != "${versions[0]}" ]; then
    echo "error: Go version pins disagree." >&2
    for j in "${!versions[@]}"; do
      printf '       %-10s %s  (%s)\n' "${labels[$j]}" "${versions[$j]}" "${files[$j]}" >&2
    done
    echo "       All of them must name the same version." >&2
    exit 1
  fi
done

echo "Go version pins agree: ${versions[0]} (${labels[*]})"
