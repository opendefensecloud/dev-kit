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

| Target                | Description                                 |
| ---                   | ---                                         |
| `help`                | Display all available targets               |
| `clean`               | Remove the `bin/` directory                 |
| `mod`                 | Run `go mod tidy`, `download`, and `verify` |
| `golangci-lint`       | Run golangci-lint                           |
| `shellcheck`          | Run shellcheck on shell scripts             |
| `scan`                | Scan for vulnerabilities using osv-scanner  |
| `setup-local-cluster` | Create a Kind cluster for local development |

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
	curl -sSL https://raw.githubusercontent.com/opendefensecloud/dev-kit/$(DEV_KIT_VERSION)/common.mk -o $@
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

### Default git hooks

The dev shell installs the following git hooks automatically:

| Hook         | Stage        | Description                                     |
| ---          | ---          | ---                                             |
| `fmt`        | `pre-commit` | Runs `make fmt`                                 |
| `lint`       | `pre-commit` | Runs `make lint`                                |
| `osv-scanner`| `pre-commit` | Runs `make scan` on dependency file changes     |
| `commitlint` | `commit-msg` | Validates commit messages against [Conventional Commits](https://www.conventionalcommits.org/) (disabled by default) |

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

All default hooks can be disabled per-project via `preCommitHooks` (see below).

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
            osv-scanner = {
              enable = false;  # disable default pre-commit hooks
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
