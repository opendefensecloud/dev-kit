#!/usr/bin/env bash
# Build the versioned docs site into site/public.
#
#   /                    the current checkout, labelled "main"
#   /versions/<tag>/     each published release whose tree has a site/
#
# Versions are published releases, not tags: a burned tag (docs/RELEASES.md)
# has no release and gets no docs. Each release is built from its own site/
# and docs/, so its pages describe what that release ships. The version
# dropdown is injected into every build as site/config/_default/menus.toml,
# which Hugo merges with hugo.toml, so even an old release lists the newest.
#
# Only the current checkout fails on a Hugo warning. A released tree cannot be
# fixed anymore, and a newer Hugo deprecating something in it must not block
# every later deploy.
#
# ponytail: every release is rebuilt on every run, seconds each; build only the
# latest patch per minor if that ever gets slow.
#
# Needs git, gh (authenticated, GH_TOKEN in CI), hugo and go.
set -euo pipefail

BASE_URL="${BASE_URL:-https://opendefensecloud.github.io/dev-kit}"
BASE_URL="${BASE_URL%/}"
out="$PWD/site/public"

tags=()
while read -r t; do
  if git cat-file -e "$t:site/hugo.toml" 2> /dev/null; then tags+=("$t"); fi
done < <(gh release list --exclude-drafts --limit 200 --json tagName -q '.[].tagName')

tmp="$(mktemp -d)"
cleanup() {
  for t in "${tags[@]}"; do git worktree remove --force "$tmp/$t" 2> /dev/null || true; done
  rm -rf "$tmp" site/config/_default/menus.toml
}
trap cleanup EXIT

# The dropdown, labelled with the version being built. Omitted until a release
# has docs, since a menu with "main" as its only entry says nothing.
menu() {
  [ "${#tags[@]}" -gt 0 ] || return 0
  printf '[[main]]\n  identifier = "versions"\n  name = "%s"\n  weight = 4\n' "$1"
  printf '[[main]]\n  parent = "versions"\n  name = "main"\n  url = "%s/"\n' "$BASE_URL"
  for t in "${tags[@]}"; do
    printf '[[main]]\n  parent = "versions"\n  name = "%s"\n  url = "%s/versions/%s/"\n' "$t" "$BASE_URL" "$t"
  done
}

# build <tree> <label> <base url> <destination> [hugo flags...]
build() {
  local tree="$1" label="$2" base="$3" dest="$4"
  shift 4
  mkdir -p "$tree/site/config/_default"
  menu "$label" > "$tree/site/config/_default/menus.toml"
  # ref: links to repository files point at the version being read.
  HUGO_PARAMS_REF="$label" hugo build --source "$tree/site" --minify \
    --baseURL "$base" --destination "$dest" "$@"
}

rm -rf "$out"
build . main "$BASE_URL/" "$out" --panicOnWarning
for t in "${tags[@]}"; do
  git worktree add --quiet --detach "$tmp/$t" "$t"
  build "$tmp/$t" "$t" "$BASE_URL/versions/$t/" "$out/versions/$t"
done
