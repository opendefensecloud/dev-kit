# dev-kit

A library that provides a pre-configured development environment.

Copy the files from `example/` into your project and adjust them for your needs.

## Features

- **Nix flake** with a development shell (Go, pre-commit hooks, cosign, trivy)
- **direnv** integration for automatic environment activation
- **Make targets** for common development tasks
- **tools.lock** for pinning Go binaries to specific versions

## Usage

### Make targets

The included `common.mk` provides:

| Target                      | Description                                                                                  |
| --------------------------- | -------------------------------------------------------------------------------------------- |
| `help`                      | Display all available targets                                                                |
| `clean`                     | Remove the `bin/` directory                                                                  |
| `fmt`                       | Format every file in the repository                                                          |
| `lint`                      | Check formatting, then run shellcheck and, when the repository has a `go.mod`, golangci-lint |
| `fmt-all`                   | Formatting only (what `fmt` calls)                                                           |
| `lint-all`                  | Fail if any file is not formatted (what `lint` calls)                                        |
| `mod`                       | Run `go mod tidy`, `download`, and `verify`                                                  |
| `golangci-lint`             | Run golangci-lint                                                                            |
| `shellcheck`                | Run shellcheck on shell scripts                                                              |
| `scan`                      | Scan for vulnerabilities using osv-scanner                                                   |
| `setup-local-cluster`       | Create a Kind cluster for local development                                                  |
| `repo-settings`             | Reconcile GitHub repository settings                                                         |
| `envtest-binaries-sideload` | Populate the envtest cache from upstream K8s/etcd releases                                   |
| `check-go-version`          | Assert every Go version pin in the repository agrees                                         |
| `check-dev-kit-pins`        | Assert every dev-kit reference names the same release                                        |

### Formatting and linting

Formatting is **opt-in**. Set it in the project `Makefile` before
`-include common.mk`, next to `DEV_KIT_VERSION`:

```make
DEV_KIT_FORMATTING := on
```

While it is off, no formatting runs: `fmt` does nothing beyond whatever the
project's own `fmt:` rule does, and `lint` runs `shellcheck` and
`golangci-lint` exactly as before, fetching only `.golangci.yml`.

This is opt-in because a repository that still defines its own `fmt:` or `lint:`
recipe would otherwise have `fmt-all`/`lint-all` merged in as prerequisites
silently on its next `DEV_KIT_VERSION` bump — make appends prerequisites without
warning — and start failing on every YAML, Markdown and shell file it has never
formatted. Run the one-time `make fmt-all` commit first, then switch it on
deliberately.

One formatter front-end for the whole repository. `treefmt` drives gofmt (via
`golangci-lint fmt`, so import order stays configured in one place), `yamlfmt`,
`shfmt` and `mdformat`.

```sh
make fmt     # writes
make lint    # fails on drift, then shellcheck and golangci-lint (Go repos)
```

The Go steps are conditional on a `go.mod` in the repository root: without one,
`lint` skips golangci-lint, `fmt` does not install it, `.golangci.yml` is not
fetched, and treefmt is passed `--allow-missing-formatter` so it does not insist
on a formatter it will never call. None of that needs configuring by hand.

`treefmt.toml`, `.golangci.yml` and `.editorconfig` are fetched from dev-kit at
the pinned `DEV_KIT_VERSION` the first time they are needed, and refetched when
that version changes. A repository that commits its own copy of one of these
files keeps it. The fetch rule only fires for a file that is absent, and an
alternate spelling counts as an override (`.golangci.yaml`, `.treefmt.toml`).
Add the bootstrapped ones to `.gitignore`, together with `.common.mk-configs`,
next to the existing `common.mk` entry — `.common.mk-configs` records what was
fetched so that a `DEV_KIT_VERSION` bump only ever removes files this mechanism
created, never a hand-written override that is not committed yet.

Refresh happens when the `DEV_KIT_VERSION` string changes. With a moving ref
(`main`) the configs are therefore fetched once and not refreshed again, while
`common.mk` itself keeps updating via its hourly content check.

`shfmt` reads its style from `.editorconfig`, so an editor and `make fmt` cannot
disagree about shell scripts.

Repositories extend the entry points by adding prerequisites rather than
redefining them, which keeps the recipe in `common.mk`:

```make
fmt: license-headers
lint: license-headers-check
```

### Variables

| Variable             | Default                                    | Description                                                                                                                          |
| -------------------- | ------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------ |
| `BUILD_PATH`         | `$(shell pwd)`                             | Base directory for local binaries                                                                                                    |
| `LOCALBIN`           | `$(BUILD_PATH)/bin`                        | Directory for installed binaries                                                                                                     |
| `OSV_SCANNER_CONFIG` | `./.osv-scanner.toml`                      | Path to osv-scanner configuration                                                                                                    |
| `DEV_KIT_FORMATTING` | `off`                                      | `on` enables the shared `fmt`/`lint` formatting. Set it before `-include common.mk`                                                  |
| `DEV_KIT_CONFIGS`    | `.editorconfig .golangci.yml treefmt.toml` | Shared configs to bootstrap; set to empty to opt out. Each file is skipped automatically when the repo overrides or does not need it |
| `TREEFMT_ARGS`       | derived                                    | Extra treefmt flags. Defaults to `--allow-missing-formatter` in repos without a `go.mod`, empty otherwise                            |
| `OS`                 | `$(shell $(GO) env GOOS)`                  | Current Operating System                                                                                                             |
| `ARCH`               | `$(shell $(GO) env GOARCH)`                | Current CPU architecture                                                                                                             |

Any binary defined in your `tools.lock` is also available as a Make target
(e.g. `make $(CONTROLLER_GEN)`). Take a look at the variables defined in
common.mk for a list of pre-defined binary paths.

To include `common.mk` into your own `Makefile` use this snippet or copy the provided `Makefile` in `example/`:

```makefile
DEV_KIT_VERSION := v1.0.0
-include common.mk
common.mk:
  @[ -f .common.mk-download ] || \
		curl --fail -sSL https://raw.githubusercontent.com/opendefensecloud/dev-kit/$(DEV_KIT_VERSION)/common.mk \
		  -o .common.mk-download
	mv .common.mk-download $@
	printf '%s' '$(DEV_KIT_VERSION)' > .common.mk-version
	touch .common.mk-checked
```

Add your own targets in your project's `Makefile` like normal:

```makefile
my-target:
	@echo Hello World
```

You can override targets provided by `common.mk`:

```makefile
scan:
	@my-custom-scanner ./...
```

```console
$ make scan
Makefile:18: warning: overriding recipe for target 'scan'
common.mk:84: warning: ignoring old recipe for target 'scan'
  scanning...
```

### Go binaries

Define binaries in `tools.lock` (one per line):

```txt
cobra-cli github.com/spf13/cobra-cli@v1.3.0
```

Install and use them in your Makefile:

```makefile
COBRA := $(LOCALGOBIN)/cobra-cli
cobra: $(COBRA)
	$(COBRA) help
```

### envtest sideloading

`envtest-binaries-sideload` populates `setup-envtest`'s cache directly from
`dl.k8s.io` and the etcd GitHub releases, for Kubernetes versions that
controller-tools has not yet packaged into its `envtest-releases` index. Without
it, bumping to a fresh Kubernetes release breaks `make test` until
controller-tools catches up. It is a no-op when the version is already cached,
so it is safe as a prerequisite of your `test` target.

Set `ENVTEST_K8S_VERSION` in your own `Makefile`; `common.mk` does not default
it. Linux downloads prebuilt binaries; macOS builds `kube-apiserver` from source
when controller-tools has no archive for the requested version, which also needs
`go` on `PATH` — supplied by `goVersion`, not by the default dev shell.

### Go version consistency

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
silently ignoring it is the same drift the check exists to catch.

The Docker tag must be **patch-level** (`1.27.0`, not `1.27`). A minor-level tag
never compares equal to the other two, and Renovate cannot fold it into the same
update group, so the image silently stays behind while everything else moves.

Related: the dev shell resolves `goVersion` from `go-overlay`, which `flake.lock`
pins. A Go patch released after that lock was written does not exist in the shell
yet; the shell says so and names the fix (`nix flake update go-overlay`) rather
than failing with a missing attribute. On Renovate's Go PR,
`renovate-dev-kit-lock` runs that refresh itself.

### Keeping the dev-kit pins in step

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
the stubs in this README can be pasted as examples.

This detects drift between the pins. On dev-kit, the `protect-release-tags`
ruleset (below) refuses moving or deleting a `v*` tag, so a pinned release tag
does not change under you: a fix ships as a new release. The ruleset itself can
still be changed by an org owner, and a `DEV_KIT_VERSION` of `main` is not a tag
at all.

### Seeing what a `flake.lock` bump actually changes

A lock bump is unreviewable as a diff: one opaque `rev` for `nixpkgs` moves every
package in the shell — the Go toolchain, `golangci-lint`, `treefmt`, `kubectl`.
Renovate's weekly `lockFileMaintenance` refreshes every input at once and is
merged by a human who has nothing to look at.

`flake-closure-diff.yml` builds the shell both sides of the change and posts the
package-level difference to the job summary. Advisory — it reports, it never fails
on a difference:

```yaml
name: Flake closure diff
on:
  pull_request:
    paths: ["flake.lock", "flake.nix"]
permissions:
  contents: read
jobs:
  closure-diff:
    uses: opendefensecloud/dev-kit/.github/workflows/flake-closure-diff.yml@<40-char-sha> # <tag>
    secrets:
      cachix-auth-token: ${{ secrets.CACHIX_AUTH_TOKEN }}
      cachix-signing-key: ${{ secrets.CACHIX_SIGNING_KEY }}
```

Pass `attribute` for a shell that is not `devShells.x86_64-linux.default` (no `.#`
prefix — both sides are addressed as `<path>#<attribute>`). The base side usually
comes from the cache, since it is what the last run built.

### Repository settings

Run `make repo-settings` to reconcile your GitHub repository with the organization's standard configuration. This target is idempotent and requires the `gh` CLI to be authenticated.

It configures:

- **Labels** — creates/updates the standard set of issue and PR labels
- **Merge strategy** — merge commits only by default, configurable via `REPO_ALLOW_MERGE_COMMIT`, `REPO_ALLOW_SQUASH_MERGE`, `REPO_ALLOW_REBASE_MERGE` (these also restrict protect-main's allowed merge methods; at least one must be enabled or `repo-settings` fails); auto-merge enabled, delete branch on merge
- **Secret scanning** — enabled
- **Branch protection** — a "protect-main" ruleset on the default branch (and any `REPO_RULESET_BRANCHES` patterns): requires PRs with 1 approval, dismisses stale reviews, requires review thread resolution, enforces commit signatures, requires approval of the latest push when `REPO_REQUIRE_LAST_PUSH_APPROVAL` is `true`, prevents direct pushes/deletions/non-fast-forwards
- **Release tags** — the "protect-release-tags" ruleset refuses moving or deleting tags matching `REPO_RELEASE_TAGS` (`v*` by default), for workflows and repository admins too. Creating tags stays open, so releases keep tagging. There is deliberately no admin bypass: a botched release is fixed with the next patch, not by retagging.

The repository settings are configurable via make variables (set them in your `Makefile` or pass them on the command line, e.g. `make repo-settings REPO_STATUS_CHECKS='["CI","lint"]' REPO_RULESET_BRANCHES='["release/*"]'`):

| Variable                               | Default  | Description                                                                                                                                                                                                                             |
| -------------------------------------- | -------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `REPO_ALLOW_MERGE_COMMIT`              | `true`   | Allow merge commits in the merge strategy                                                                                                                                                                                               |
| `REPO_ALLOW_SQUASH_MERGE`              | `false`  | Allow squash merging                                                                                                                                                                                                                    |
| `REPO_ALLOW_REBASE_MERGE`              | `false`  | Allow rebase merging                                                                                                                                                                                                                    |
| `REPO_REQUIRE_LAST_PUSH_APPROVAL`      | `false`  | Require the most recent push to be approved before merging                                                                                                                                                                              |
| `REPO_ADMIN_BYPASS`                    | `true`   | When `false`, org admins cannot bypass the protect-main ruleset                                                                                                                                                                         |
| `REPO_REQUIRED_APPROVING_REVIEW_COUNT` | `1`      | Number of approving reviews required to merge                                                                                                                                                                                           |
| `REPO_REQUIRE_CODE_OWNER_REVIEW`       | `false`  | Require an approving review from code owners                                                                                                                                                                                            |
| `REPO_REQUIRE_BRANCH_UP_TO_DATE`       | `false`  | Require branches to be up to date before merging (needs at least one `REPO_STATUS_CHECKS` value; `repo-settings` fails otherwise)                                                                                                       |
| `REPO_STATUS_CHECKS`                   | `[]`     | JSON array of status-check contexts that must pass (e.g. `["CI","action-pins / Check action pins"]`); each job name is used as-is, so contexts with spaces work; the `required_status_checks` rule is only added when this is non-empty |
| `REPO_RULESET_BRANCHES`                | `[]`     | JSON array of additional branch patterns protect-main applies to (e.g. `["release/*"]`); short names are normalized to `refs/heads/...`; the default branch is always protected                                                         |
| `REPO_RELEASE_TAGS`                    | `["v*"]` | JSON array of tag patterns nobody may move or delete; short names are normalized to `refs/tags/...`; `[]` skips protect-release-tags                                                                                                    |
| `REPO_RELEASE_TAGS_ENFORCEMENT`        | `active` | Enforcement of the protect-release-tags ruleset: `active`, `evaluate` (report only) or `disabled`                                                                                                                                       |

### GitHub Actions

The repo ships composite actions that consuming repositories reference directly.
Pin them to a SHA with a version comment, as the action-pin check requires. The
`<40-char-sha>` placeholders below are not copy-pasteable — substitute real digests:

| Action                           | Description                                             |
| -------------------------------- | ------------------------------------------------------- |
| `.github/actions/setup-nix`      | Install upstream Nix and enable the shared Cachix cache |
| `.github/actions/get-go-version` | Extract the Go version from `flake.nix`                 |
| `.github/actions/diff-check`     | Fail if a command left uncommitted changes behind       |

`setup-nix` replaces the two-step Nix installer + Cachix preamble that every
job needs before it can use `nix develop` as its shell. Secrets are not visible
inside a composite action, so the caller passes them in:

```yaml
jobs:
  build:
    runs-on: ubuntu-24.04
    defaults:
      run:
        shell: nix develop --command bash -e {0}
    steps:
      - uses: actions/checkout@<40-char-sha> # v7
      - name: Set up nix
        uses: opendefensecloud/dev-kit/.github/actions/setup-nix@<40-char-sha> # <tag>
        with:
          cachix-auth-token: ${{ secrets.CACHIX_AUTH_TOKEN }}
          cachix-signing-key: ${{ secrets.CACHIX_SIGNING_KEY }}
      - run: make test
```

| Input                | Default            | Description                                                       |
| -------------------- | ------------------ | ----------------------------------------------------------------- |
| `cachix-name`        | `opendefensecloud` | Cachix cache to use                                               |
| `cachix-auth-token`  | `''`               | Auth token; empty falls back to a read-only cache, as on fork PRs |
| `cachix-signing-key` | `''`               | Signing key; empty disables pushing to the cache                  |

### Governance workflows

The org-wide checks and automations are reusable workflows. A consuming repo
keeps one small stub per workflow, which sets the triggers and the permissions
and calls dev-kit. Pin each stub to a SHA like any other action; Renovate bumps
them together with `DEV_KIT_VERSION`.

| Workflow                    | Stub triggers                                                      | Needs                           |
| --------------------------- | ------------------------------------------------------------------ | ------------------------------- |
| `action-pins.yml`           | `pull_request`, `workflow_dispatch`                                |                                 |
| `conventional-commits.yml`  | `pull_request` (opened, edited, synchronize, reopened)             | `.commitlintrc.yml` in the repo |
| `osv-scanner.yml`           | `pull_request`, `push` to main, weekly                             | optional `scan-args` input      |
| `issues-add-labels.yaml`    | `issues` (opened, reopened)                                        |                                 |
| `issues-add-to-project.yml` | `issues`, `pull_request` (opened)                                  | `ADD_TO_PROJECT_PAT` secret     |
| `renovate-auto-approve.yml` | `pull_request` (opened, reopened, synchronize, labeled, unlabeled) | see the header of the workflow  |
| `renovate-dev-kit-lock.yml` | `pull_request` (opened, synchronize, reopened)                     | `DEV_KIT_BOT_APP_*` org secrets |

No stub triggers on `merge_group`, as no repo uses a merge queue. A repo that
turns one on must add the trigger to every stub whose check it requires, and
must not require `osv-scanner / scan-pr / osv-scan`: that PR scan diffs
against `$GITHUB_BASE_REF`, which is empty in a merge queue (see
`osv-scanner.yml`).

`.github/workflows/action-pins.yml`:

```yaml
name: Action Pins
on:
  pull_request:
  workflow_dispatch:
permissions:
  contents: read
jobs:
  action-pins:
    uses: opendefensecloud/dev-kit/.github/workflows/action-pins.yml@<40-char-sha> # <tag>
```

It reports two checks, `action-pins / Check action pins` and
`action-pins / Audit action pins`; require both. Every pin must read
`uses: <action>@<sha> # <version>`, with nothing after the version. On pull
requests `Check action pins` also fails when a pin's SHA changes but its version
does not, since that means upstream moved the tag or the PR swapped the SHA. The
version should therefore be a full release tag (`# v7.0.1`, not `# v7`): a major
tag moves with every release, so each digest update would trip the check. Neither
`# zizmor: ignore[...]` comments nor a `zizmor.yml` turn a finding off. On pull
requests the audit only covers pins the PR changes; a `workflow_dispatch` run
audits every pin, e.g. when a repo adopts the workflow. The header of the
workflow lists what each check fails on.

`.github/workflows/conventional-commits.yml`:

```yaml
name: Conventional Commits
on:
  pull_request:
    branches: ["main"]
    types: [opened, edited, synchronize, reopened]
permissions:
  pull-requests: read
jobs:
  conventional-commits:
    uses: opendefensecloud/dev-kit/.github/workflows/conventional-commits.yml@<40-char-sha> # <tag>
```

On pull requests, it also fails when any non-merge commit is a conventional
breaking change (`type!` or `type(scope)!`) but the PR title is not breaking.
The title becomes the merge commit subject (`repo-settings.sh` sets
`merge_commit_title=PR_TITLE`), so this keeps the release notes and version
bump aligned. Merge commits are ignored, so a merge from the base branch cannot
force the title to change.

`.github/workflows/osv-scanner.yml`:

```yaml
name: OSV-Scanner
on:
  pull_request:
    branches: ["main"]
  schedule:
    - cron: "12 12 * * 1"
  push:
    branches: ["main"]
permissions:
  contents: read
jobs:
  osv-scanner:
    permissions:
      actions: read
      security-events: write
      contents: read
    uses: opendefensecloud/dev-kit/.github/workflows/osv-scanner.yml@<40-char-sha> # <tag>
    # with:
    #   scan-args: |-
    #     --include-git-root
    #     --config ./.osv-scanner.toml
    #     -r
    #     ./
```

`.github/workflows/issues-add-labels.yaml`:

```yaml
name: Label issues
on:
  issues:
    types: [opened, reopened]
permissions:
  contents: read
jobs:
  label:
    permissions:
      issues: write
    uses: opendefensecloud/dev-kit/.github/workflows/issues-add-labels.yaml@<40-char-sha> # <tag>
```

`.github/workflows/issues-add-to-project.yml`:

```yaml
name: Add issues to project
on:
  issues:
    types: [opened]
  pull_request:
    types: [opened]
permissions:
  contents: read
jobs:
  add-to-project:
    permissions: {}
    uses: opendefensecloud/dev-kit/.github/workflows/issues-add-to-project.yml@<40-char-sha> # <tag>
    secrets:
      ADD_TO_PROJECT_PAT: ${{ secrets.ADD_TO_PROJECT_PAT }}
```

`.github/workflows/renovate-dev-kit-lock.yml` commits a relocked `flake.lock`
to the Renovate PRs that change `flake.nix` but can't update the lock:
`renovate/dev-kit` and `renovate/major-dev-kit` (`nix flake lock` for the
bumped tag) and `renovate/go-version` (`nix flake update go-overlay`, so the
new `goVersion` exists in the shell; if go-overlay does not carry it yet, the
job fails and can be re-run later). It commits as the org's dev-kit GitHub App, so the commit
is signed and starts CI; any other PR skips it:

```yaml
name: Relock dev-kit
on:
  pull_request:
    branches: ["main"]
    types: [opened, synchronize, reopened]
permissions:
  contents: read
jobs:
  relock:
    uses: opendefensecloud/dev-kit/.github/workflows/renovate-dev-kit-lock.yml@<40-char-sha> # <tag>
    secrets:
      DEV_KIT_BOT_APP_CLIENT_ID: ${{ secrets.DEV_KIT_BOT_APP_CLIENT_ID }}
      DEV_KIT_BOT_APP_PRIVATE_KEY: ${{ secrets.DEV_KIT_BOT_APP_PRIVATE_KEY }}
```

A job from a reusable workflow reports as `<stub job> / <called job>`, so
`REPO_STATUS_CHECKS` needs the new names after switching to a stub, e.g.
`action-pins / Check action pins`,
`action-pins / Audit action pins`, `conventional-commits / PR Title` and
`conventional-commits / Commit Messages`. osv-scanner nests Google's reusable
workflow one level deeper, so its scan reports as
`osv-scanner / scan-pr / osv-scan`. Update the list and rerun `make repo-settings` in the same change, or the old
names stay required and never report.

### Default git hooks

The dev shell installs the following git hooks automatically:

| Hook          | Stage        | Description                                                                                                               |
| ------------- | ------------ | ------------------------------------------------------------------------------------------------------------------------- |
| `fmt`         | `pre-commit` | Runs `make fmt`                                                                                                           |
| `lint`        | `pre-commit` | Runs `make lint`                                                                                                          |
| `osv-scanner` | `pre-commit` | Runs `make scan` on dependency file changes (disabled by default — see [Vulnerability scanning](#vulnerability-scanning)) |
| `commitlint`  | `commit-msg` | Validates commit messages against [Conventional Commits](https://www.conventionalcommits.org/) (disabled by default)      |

To enable the `commitlint` hook, set `commitlint.enable = true` in `preCommitHooks` and add a `.commitlintrc.yml` to the project root:

```yaml
extends:
  - "@commitlint/config-conventional"
rules:
  type-enum:
    - 2
    - always
    - - feat
      - fix
      - docs
      - chore
      - refactor
      - test
      - ci
      - perf
      - revert
```

All hooks can be enabled or disabled per-project via `preCommitHooks` (see below).

### Vulnerability scanning

The `osv-scanner` hook is **disabled by default**. `make scan` resolves every
dependency against the osv.dev API, which adds roughly a minute to any commit
that touches `go.mod`, `go.sum`, or `requirements.txt` — slow enough that it
discourages small, frequent commits.

Run vulnerability scanning in CI instead, on a schedule and on every pull
request. If your project has no CI-side scan, opt back in per-project:

```nix
preCommitHooks = {
  osv-scanner.enable = true;
};
```

### Customizing the dev shell

Modify `flake.nix` to adjust Go version, packages, and pre-commit hooks:

```nix
{
  [...]

  outputs = { nixpkgs, flake-utils, dev-kit, ... }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
      in
      {
        devShells.default = dev-kit.lib.mkShell {
          inherit system;
          goVersion = "1.26.2";  # Install go with a custom version
          packages = [  # add additional packages to the dev shell
            pkgs.cosign
            pkgs.trivy
          ];
          preCommitHooks = {
            custom = {  # add custom pre-commit hooks
              enable = true;
              entry = "my-custom-script";
            };
            lint = {
              enable = false;  # disable default pre-commit hooks
            };
            osv-scanner = {
              enable = true;  # enable hooks that are off by default
            };
          };
        };
      }
    );
}
```

### Release workflow

Two shared workflows cut a release: `release.yml` computes version and notes
with git-cliff, checks the notes, checks that the commit passed its required
checks (e2e, typically) and tags it; `release-draft.yml` then creates the draft
release with those notes and the caller's assets in one step. In between, a
caller with assets builds them from the tagged commit. Publishing the draft
triggers repo-specific delivery (Docker, Helm, docs). Notes are rendered from
merge commits and grouped by conventional type using the shared `cliff.toml` in
dev-kit, so consumers do not keep their own copy.

To release:

1. Wait until the required checks on the default branch have passed.
2. **Run workflow** on the default branch (version optional, `dry_run` unchecked).
3. Wait for the run to finish: the job summary links the complete draft.
4. Review the draft and click **Publish**.

No release object exists between releases. A push to the default branch runs
as a dry run and previews the next version, the notes and the state of the
required checks in its job summary.

#### Using the reusable workflows

The caller owns the triggers and inputs and chains the two workflows:

```yaml
concurrency:
  group: ${{ github.event_name == 'workflow_dispatch' && 'release' || 'release-preview' }}
  cancel-in-progress: ${{ github.event_name != 'workflow_dispatch' }}

jobs:
  release:
    uses: opendefensecloud/dev-kit/.github/workflows/release.yml@<40-char-sha> # <tag>
    permissions:
      contents: write # create the tag
      checks: read # required_checks
    with:
      version: ${{ github.event_name == 'workflow_dispatch' && inputs.version || '' }}
      dry_run: ${{ github.event_name != 'workflow_dispatch' || inputs.dry_run }}
      force: ${{ github.event_name == 'workflow_dispatch' && inputs.force }}
      required_checks: '["test-e2e / test-e2e"]'

  draft:
    needs: release
    if: ${{ needs.release.outputs.tag_created == 'true' }}
    uses: opendefensecloud/dev-kit/.github/workflows/release-draft.yml@<40-char-sha> # <tag>
    permissions:
      contents: write # create the draft release
    with:
      version: ${{ needs.release.outputs.version }}
      sha: ${{ needs.release.outputs.sha }}
```

See [`.github/workflows/release-self.yml`](.github/workflows/release-self.yml) for the complete caller used by this repo. The `inputs` context is empty on `push`, so the caller selects each value by event; passing an empty string to a boolean input fails workflow validation. The concurrency block runs one release at a time and never cancels a running one (it may already have tagged). It is not a queue: GitHub keeps one run pending, and a newer dispatch replaces it, which is harmless since a pending run has tagged nothing. Push previews get their own group, so a merge cannot replace a pending release dispatch.

#### Required checks

`required_checks` names the check runs, as shown on the commit, that must have passed before a commit is tagged. A check that failed, is still running, was skipped or never ran blocks the release; a dry run only reports it. Typically these are the e2e jobs that run on every push to the default branch.

Those jobs usually skip documentation-only pushes (`paths-ignore`). Set `checks_skip_paths` to the same globs (default `["docs/**", "**/*.md"]`). They match as in GitHub's path filters: `*` stops at a `/`, `**` crosses it, and a leading `**/` also matches at the top level; `?`, `+`, `[]` and `!` are refused. A commit without the checks is then released on those of the nearest earlier commit that ran them, but only if every change since that commit matches `checks_skip_paths`. A code commit whose checks have not started yet therefore fails the run instead of being released on an older result. Use `'[]'` when the checks run on every push.

#### Attaching release assets

Add a build job between the two calls. It checks out the tagged commit, builds, and hands the files over as a workflow artifact; it needs no `contents: write`. Name the artifact in `assets_artifact`:

```yaml
  assets:
    needs: release
    if: ${{ needs.release.outputs.tag_created == 'true' }}
    runs-on: ubuntu-26.04
    permissions:
      contents: read
      id-token: write # keyless signing
      attestations: write # build provenance
    steps:
      - uses: actions/checkout@<40-char-sha> # v7
        with:
          ref: ${{ needs.release.outputs.sha }}
          persist-credentials: false
      # ... build, sign, attest into dist/ ...
      - uses: actions/upload-artifact@<40-char-sha> # v7
        with:
          name: release-assets
          path: dist/
          if-no-files-found: error
          overwrite: true # a re-run uploads again into the same run

  draft:
    needs: [release, assets]
    if: ${{ needs.release.outputs.tag_created == 'true' }}
    uses: opendefensecloud/dev-kit/.github/workflows/release-draft.yml@<40-char-sha> # <tag>
    permissions:
      contents: write
    with:
      version: ${{ needs.release.outputs.version }}
      sha: ${{ needs.release.outputs.sha }}
      assets_artifact: release-assets
```

Every file in the artifact becomes one release asset, so file names must be unique across subdirectories and use only letters, digits, `.`, `_` and `-`, not starting or ending with `.`; GitHub would rename others. `release-notes` is the artifact name `release.yml` hands the notes over in; don't use it for your own. Pin both workflows to the same dev-kit commit: they share that hand-off.

#### Requirements

- **Shared `cliff.toml`**: No config file is needed by default. The workflow checks out `cliff.toml` from dev-kit at the same commit as the reusable workflow and uses it. Pass `cliff_config` to use a repository-specific file instead; the bundled notes guard then falls back to best-effort checks for that override.
- **Release-notes check**: The workflow checks out its own tooling at the commit that defines it (`job.workflow_sha`) and runs the bundled `check-release-notes` action, so consumers do not need to copy the check. `job.workflow_*` is available on github.com, not GHES.
- **Permissions**: `release.yml` needs `contents: write` and `checks: read`, `release-draft.yml` needs `contents: write`. The asset build needs neither.
- **Default branch only**: Releases must be cut from the repository's default branch. A branch trigger must name the default branch; a tag trigger is accepted only when the tag points at a commit on it. Other triggers are rejected.
- **Merge commits**: The shared config renders the merge commits on the default branch. A commit pushed directly to the branch is reported by the notes guard and fails the release unless `force` is set. Squash and rebase merges are treated the same way.
- **Prior release tag**: The repository must already have a release tag. git-cliff derives the changelog boundary from the previous tag, and the workflow fails if there is none. Passing an explicit `version` does not bypass this.
- **Nothing releasable**: If no `feat`, `fix`, `perf` or breaking change landed since the previous tag, a push or scheduled run succeeds with a notice. A manual run fails unless `version` is supplied.
- **One release at a time**: A manual run fails while any draft release exists; a dry run warns. A draft whose tag exists is a release that was cut but not published: publish it, or delete the draft (its tag becomes a burned tag, below).
- **Protected release tags**: No tag is created unless an active tag ruleset without bypass actors refuses moving and deleting it (`make repo-settings` adds `protect-release-tags`); a dry run warns. GitHub shows a ruleset's bypass actors only to its admins, so the check sees them only where it can, and otherwise checks that the workflow itself cannot bypass it. The draft is checked against its tag once, when it is created; only a tag that cannot move keeps assets and tag matching until someone publishes. `release-draft.yml` also refuses to draft a tag that does not point at the commit the assets were built from.
- **Burned tags**: The tag is created before anything is built, so a run can leave a tag that is never released: the wrong commit was dispatched, the build cannot pass on that commit, or a failed run was not re-run in time. Such a tag stays (it cannot be deleted) but nothing was shipped from it. Delete its draft, if any, and run the release again: tags without a release are ignored as release boundaries, so the next release's notes, notes check and version bump start at the last released tag, the computed version skips taken numbers, and the notes name the burned version. Once a release has shipped its changes, a burned tag no longer counts. Never reuse a burned number with an explicit `version`; it is refused anyway.
- **Recovery**: If the asset build or the draft job fails, use **Re-run failed jobs**: the tag already exists, so the rebuild uses the same commit; the draft job creates or updates the same draft, and drops assets the rebuild did not produce. A re-run that a later release run has overtaken (it found this tag without a release and cut the next version) is refused, as is drafting while another draft is pending. **Re-run all jobs** cannot recover a release, since the version computation then finds its own tag, and runs older than 30 days cannot be re-run at all. Either way the tag is burned: delete the draft and release again.
- **Publishing**: Prerelease versions (containing `-`) are marked as prereleases automatically. Publishing triggers downstream workflows (Docker, Helm, docs), which build from the tag.

#### Known gaps

- `gh release create` creates the draft before uploading its files, so the draft is briefly visible without all assets. Publish only after the run has finished. If the release is immutable, remaining uploads fail; otherwise, assets can still change after publication.

#### Upgrading from v4

1. **Protect release tags and delete every draft release** first. Run `make repo-settings` as an admin with this version of dev-kit; v5 refuses to tag without `protect-release-tags`. A v4 draft has no tag and points at whichever commit the last push run left it on; publishing it would ship its old assets. v5 refuses to release while one exists.
2. Drop inputs `create_tag` and `retry_assets_for` and output `draft_updated` from the caller, including any `run-name` that refers to them.
3. Pass `dry_run: true` on push, use the concurrency block above, grant `checks: read`, set `required_checks` (and `checks_skip_paths` if they differ from the default), and add the `draft` job.
4. With assets: upload them as an artifact from a job between the two calls instead of to the release.

## Design Decisions

### Why Nix?

Nix provides reproducible, declarative development environments. It ensures
that every developer (and CI) operates in an identical environment, eliminating
"works on my machine" issues. Nix also enables us to share modules and overlays
across projects, reducing duplication and maintaining consistency.

### Why Make over alternatives?

We evaluated several build tools:

- **magefile**: While Go-native, it is not ideal for scripting workflows that
  primarily orchestrate external binaries.

- **just**: Offers a modern syntax but lacks a built-in module sharing system.
  Migrating our Make ecosystem to just would swap one tool for another without
  meaningful architectural gains.

Make remains pragmatic: it is universally available and familiar to most
developers. While it has its quirks — tabs for indentation, the occasional `$`
escape — it provides all the features we need. The `curl common.mk` pattern
effectively gives us a module system without introducing a new dependency.

### Why not devenv?

We used [devenv](https://devenv.sh) for some time but moved away due to its
dependency on an additional binary and the complexity it introduced during
upgrades.

### Why not Go's tool directive?

Go 1.24's `tool` directive in `go.mod` pulls tooling into the local Go module
ecosystem. This often leads to dependency conflicts, as tools compiled together
with the project can clash with the project's own dependencies.

## Documentation

- [Nix](https://nixos.org) - Package manager and dev environment
- [direnv](https://direnv.net) - Environment variable loader
- [go-overlay](https://github.com/purpleclay/go-overlay) - Go tooling for Nix
