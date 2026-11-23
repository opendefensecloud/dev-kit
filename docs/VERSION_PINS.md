# Version pins

## Go version consistency

A Go project pins its version in up to three places, and a bump that updates only
some of them fails in a workflow that does not mention the file that is wrong:

| File         | Pin                        | What it drives       |
| ------------ | -------------------------- | -------------------- |
| `go.mod`     | `go <version>`             | the language version |
| `flake.nix`  | `goVersion = "<version>";` | the dev shell and CI |
| `Dockerfile` | `FROM ... golang:<tag>`    | the build image      |

`check-go-version` asserts they agree, skipping any file the repository does not
have — a library without a `Dockerfile` still passes. **Every tracked Dockerfile
is read**, not just the one at the root, so adding one does not mean remembering
to register it. Override `GO_MOD`, `FLAKE_NIX` or `DOCKERFILE` (a space-separated
list) for a non-default layout.

A file that exists but whose pin cannot be parsed is an error, never a skip —
silently ignoring it is the same drift the check exists to catch. The one
exception is a `flake.nix` with no `goVersion` assignment at all: that shell does
not pin Go, so the file is skipped.

The Docker tag must be **patch-level** (`1.27.0`, not `1.27`). A minor-level tag
never compares equal to the other two, and Renovate cannot fold it into the same
update group, so the image silently stays behind while everything else moves.

Related: the dev shell resolves `goVersion` from `go-overlay`, which `flake.lock`
pins. A Go patch released after that lock was written does not exist in the shell
yet; the shell says so and names the fix (`nix flake update go-overlay`) rather
than failing with a missing attribute. On Renovate's Go PR,
`renovate-dev-kit-lock` runs that refresh itself.

## Keeping the dev-kit pins in step

A consumer pins dev-kit in up to four places:

| Where                | Pin               | Can it change?             |
| -------------------- | ----------------- | -------------------------- |
| `.github/workflows/` | `@<sha> # <tag>`  | no                         |
| `Makefile`           | `DEV_KIT_VERSION` | a release tag: protected   |
| `flake.nix`          | the flake input   | a release tag: protected   |
| `flake.lock`         | the resolved rev  | no, but rewritten by `nix` |

`check-dev-kit-pins` asserts they all name the same release. Add it to your `lint`
target; absent sources are skipped, so a consumer without a flake still passes.
Override `WORKFLOWS`, `DEV_KIT_MAKEFILE`, `FLAKE_NIX` or `FLAKE_LOCK` for a
non-default layout.

Why the lock matters: `flake.nix` pins by **tag**, and the lock turns that tag into
a commit — a conversion `renovate-dev-kit-lock` performs unattended. A tag moved
between a release and a relock would be adopted with no meaningful review, since
the visible diff is a `narHash`, and this flake is the shell your CI runs in.
Comparing the lock against the workflow pins turns that into a failed check.

A reference that is not `@<sha> # vX.Y.Z` fails the check rather than being
skipped: one the comparison cannot read is how drift gets in unseen, and a
tag-pinned reference is mutable besides. Commented-out references are ignored, so
the stubs in `example/` can be pasted as they are.

This detects drift between the pins. On dev-kit, the `protect-release-tags`
ruleset (below) refuses moving or deleting a `v*` tag, so a pinned release tag
does not change under you: a fix ships as a new release. The ruleset itself can
still be changed by an org owner, and a `DEV_KIT_VERSION` of `main` is not a tag
at all.

## Seeing what a `flake.lock` bump actually changes

A lock bump is unreviewable as a diff: one opaque `rev` for `nixpkgs` moves every
package in the shell — the Go toolchain, `golangci-lint`, `treefmt`, `kubectl`.
Renovate's weekly `lockFileMaintenance` refreshes every input at once and is
merged by a human who has nothing to look at.

`flake-closure-diff.yml` builds the shell both sides of the change and posts the
package-level difference to the job summary. Advisory — it reports, it never fails
on a difference. Copy
[`example/.github/workflows/flake-closure-diff.yml`](../example/.github/workflows/flake-closure-diff.yml).

Pass `attribute` for a shell that is not `devShells.x86_64-linux.default` (no `.#`
prefix — both sides are addressed as `<path>#<attribute>`). The base side usually
comes from the cache, since it is what the last run built.
