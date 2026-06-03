#!/usr/bin/env bash
set -euo pipefail

if [ -z "$(git status --porcelain --untracked-files=all)" ]; then
  echo "::notice::✅ Working tree is clean."
else
  echo "::error::❌ Working tree is dirty. Commit or stash the changes below."
  echo ""
  echo "Changed files:"
  git status --short --untracked-files=all
  exit 1
fi
