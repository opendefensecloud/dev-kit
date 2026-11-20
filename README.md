# dev-kit

Shared development environment for opendefensecloud repositories: a Nix dev
shell, common Make targets, shared formatter and linter configs, reusable
GitHub workflows and a release pipeline.

## Features

- **Nix flake** with a development shell (Go, pre-commit hooks, cosign, trivy)
- **direnv** integration for automatic environment activation
- **Make targets** for common development tasks, shared via `common.mk`
- **Formatting and linting** for Go, YAML, shell and Markdown through treefmt
- **tools.lock** for pinning Go binaries to specific versions
- **Version pin checks** that keep Go and dev-kit versions in step
- **Repository settings**, **governance workflows** and **releases** shared across the organization

## Quick start

Copy the files from [`example/`](example/) into your project and adjust them.
[New repository setup](docs/NEW_REPO.md) walks through every step.

```sh
direnv allow   # enter the dev shell
make help      # list all targets
```

## Documentation

| Topic                                        | Contents                                              |
| -------------------------------------------- | ----------------------------------------------------- |
| [New repository setup](docs/NEW_REPO.md)     | Bootstrapping a repository with dev-kit               |
| [Make targets](docs/MAKE.md)                 | Targets, variables, extending, Go tools, envtest      |
| [Formatting and linting](docs/FORMATTING.md) | `make fmt` / `make lint` and the shared configs       |
| [Version pins](docs/VERSION_PINS.md)         | Go version and dev-kit pin checks, `flake.lock` diffs |
| [Dev shell](docs/DEV_SHELL.md)               | `mkShell` options, git hooks, vulnerability scanning  |
| [Repository settings](docs/REPO_SETTINGS.md) | `make repo-settings` and its `REPO_*` variables       |
| [GitHub Actions](docs/GITHUB_ACTIONS.md)     | Composite actions and the governance workflow stubs   |
| [Releases](docs/RELEASES.md)                 | The shared release workflows and how to call them     |
| [Design decisions](docs/DESIGN_DECISIONS.md) | Why Nix and Make, and what we moved away from         |
| [Contributing](docs/CONTRIBUTING.md)         | Commit conventions for this repository                |

## Links

- [Nix](https://nixos.org) - Package manager and dev environment
- [direnv](https://direnv.net) - Environment variable loader
- [go-overlay](https://github.com/purpleclay/go-overlay) - Go tooling for Nix
