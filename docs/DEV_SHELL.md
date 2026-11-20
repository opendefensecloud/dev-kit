# Dev shell

## Default git hooks

The dev shell installs the following git hooks automatically:

| Hook          | Stage        | Description                                                                                                               |
| ------------- | ------------ | ------------------------------------------------------------------------------------------------------------------------- |
| `fmt`         | `pre-commit` | Runs `make fmt`                                                                                                           |
| `lint`        | `pre-commit` | Runs `make lint`                                                                                                          |
| `osv-scanner` | `pre-commit` | Runs `make scan` on dependency file changes (disabled by default — see [Vulnerability scanning](#vulnerability-scanning)) |
| `commitlint`  | `commit-msg` | Validates commit messages against [Conventional Commits](https://www.conventionalcommits.org/) (disabled by default)      |

To enable the `commitlint` hook, set `commitlint.enable = true` in `preCommitHooks` and copy [`example/.commitlintrc.yml`](../example/.commitlintrc.yml) to the project root.

All hooks can be enabled or disabled per-project via `preCommitHooks`.

## Vulnerability scanning

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

## Customizing the dev shell

Modify `flake.nix` to adjust the Go version, packages, and pre-commit hooks.
[`example/flake.nix`](../example/flake.nix) shows each option.
