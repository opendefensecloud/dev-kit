# Contributing to dev-kit

## Commit Convention

This project follows the [Conventional Commits](https://www.conventionalcommits.org/) specification. Both PR titles and individual commit messages are validated in CI.

### Format

```
<type>(optional scope): <description>
```

### Allowed Types

| Type       | Purpose                                              |
| ---------- | ---------------------------------------------------- |
| `feat`     | A new feature                                        |
| `fix`      | A bug fix                                            |
| `docs`     | Documentation changes                                |
| `chore`    | Maintenance tasks (deps, CI config, etc.)            |
| `refactor` | Code changes that neither fix a bug nor add a feature |
| `test`     | Adding or updating tests                             |
| `ci`       | CI/CD pipeline changes                               |
| `perf`     | Performance improvements                             |
| `revert`   | Reverting a previous commit                          |

### Examples

```
feat: add commitlint pre-commit hook
fix: use recursive merge for hook overrides
docs: document default git hooks
chore(deps): update nixpkgs input
refactor: extract mkDefaultAttrs helper
```

### Breaking Changes

Append `!` after the type/scope to indicate a breaking change:

```
feat!: change mkShell interface
refactor!: rename preCommitHooks parameter
```
