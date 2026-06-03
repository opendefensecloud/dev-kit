#!/usr/bin/env bash
set -euo pipefail

GO_VERSION="$(sed -nE 's/^[[:space:]]*goVersion[[:space:]]*=[[:space:]]*"([0-9]+\.[0-9]+\.[0-9]+)";[[:space:]]*$/\1/p' flake.nix)"
if [ "$(printf '%s\n' "$GO_VERSION" | sed '/^$/d' | wc -l)" -ne 1 ]; then
  echo "::error::Expected exactly one goVersion assignment in flake.nix"
  exit 1
fi
echo "version=$GO_VERSION" >> "$GITHUB_OUTPUT"
