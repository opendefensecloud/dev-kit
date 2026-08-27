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

| Target                      | Description                                                |
| ---                         | ---                                                        |
| `help`                      | Display all available targets                              |
| `clean`                     | Remove the `bin/` directory                                |
| `mod`                       | Run `go mod tidy`, `download`, and `verify`                |
| `golangci-lint`             | Run golangci-lint                                          |
| `shellcheck`                | Run shellcheck on shell scripts                            |
| `scan`                      | Scan for vulnerabilities using osv-scanner                 |
| `setup-local-cluster`       | Create a Kind cluster for local development                |
| `repo-settings`             | Reconcile GitHub repository settings                       |
| `envtest-binaries-sideload` | Populate the envtest cache from upstream K8s/etcd releases |

### Variables

| Variable             | Default                     | Description                       |
| ---                  | ---                         | ---                               |
| `BUILD_PATH`         | `$(shell pwd)`              | Base directory for local binaries |
| `LOCALBIN`           | `$(BUILD_PATH)/bin`         | Directory for installed binaries  |
| `OSV_SCANNER_CONFIG` | `./.osv-scanner.toml`       | Path to osv-scanner configuration |
| `OS`                 | `$(shell $(GO) env GOOS)`   | Current Operating System          |
| `ARCH`               | `$(shell $(GO) env GOARCH)` | Current CPU architecture          |

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

### Repository settings

Run `make repo-settings` to reconcile your GitHub repository with the organization's standard configuration. This target is idempotent and requires the `gh` CLI to be authenticated.

It configures:

- **Labels** — creates/updates the standard set of issue and PR labels
- **Merge strategy** — merge commits only by default, configurable via `REPO_ALLOW_MERGE_COMMIT`, `REPO_ALLOW_SQUASH_MERGE`, `REPO_ALLOW_REBASE_MERGE` (these also restrict the ruleset's allowed merge methods; at least one must be enabled or `repo-settings` fails); auto-merge enabled, delete branch on merge
- **Secret scanning** — enabled
- **Branch protection** — a "protect-main" ruleset on the default branch (and any `REPO_RULESET_BRANCHES` patterns): requires PRs with 1 approval, dismisses stale reviews, requires review thread resolution, enforces commit signatures, requires approval of the latest push when `REPO_REQUIRE_LAST_PUSH_APPROVAL` is `true`, prevents direct pushes/deletions/non-fast-forwards

The repository settings are configurable via make variables (set them in your `Makefile` or pass them on the command line, e.g. `make repo-settings REPO_STATUS_CHECKS='["CI","lint"]' REPO_RULESET_BRANCHES='["release/*"]'`):

| Variable                               | Default | Description                                                                                                                                                                                                               |
| ---                                    | ---     | ---                                                                                                                                                                                                                       |
| `REPO_ALLOW_MERGE_COMMIT`              | `true`  | Allow merge commits in the merge strategy                                                                                                                                                                                 |
| `REPO_ALLOW_SQUASH_MERGE`              | `false` | Allow squash merging                                                                                                                                                                                                      |
| `REPO_ALLOW_REBASE_MERGE`              | `false` | Allow rebase merging                                                                                                                                                                                                      |
| `REPO_REQUIRE_LAST_PUSH_APPROVAL`      | `false` | Require the most recent push to be approved before merging                                                                                                                                                                |
| `REPO_ADMIN_BYPASS`                    | `true`  | When `false`, org admins cannot bypass the ruleset                                                                                                                                                                        |
| `REPO_REQUIRED_APPROVING_REVIEW_COUNT` | `1`     | Number of approving reviews required to merge                                                                                                                                                                             |
| `REPO_REQUIRE_CODE_OWNER_REVIEW`       | `false` | Require an approving review from code owners                                                                                                                                                                              |
| `REPO_REQUIRE_BRANCH_UP_TO_DATE`       | `false` | Require branches to be up to date before merging (needs at least one `REPO_STATUS_CHECKS` value; `repo-settings` fails otherwise)                                                                                         |
| `REPO_STATUS_CHECKS`                   | `[]`    | JSON array of status-check contexts that must pass (e.g. `["CI","Check action pins"]`); each job name is used as-is, so contexts with spaces work; the `required_status_checks` rule is only added when this is non-empty |
| `REPO_RULESET_BRANCHES`                | `[]`    | JSON array of additional branch patterns the ruleset applies to (e.g. `["release/*"]`); short names are normalized to `refs/heads/...`; the default branch is always protected                                            |

### Default git hooks

The dev shell installs the following git hooks automatically:

| Hook          | Stage        | Description                                                                                                               |
| ---           | ---          | ---                                                                                                                       |
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
