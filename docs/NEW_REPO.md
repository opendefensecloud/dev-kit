# New Repository Setup

This guide walks through setting up a new repository in the opendefensecloud organization with dev-kit integration.

## 1. Create the repository

Create the repo on GitHub (via UI or `gh repo create`) under the `opendefensecloud` organization. Select `Apache-2.0` as the license.

## 2. Bootstrap the dev environment

Copy the files from `example/` into your project root and adjust them:

- **`flake.nix`** — Set `goVersion`, add extra `packages`, and configure `preCommitHooks` as needed. If your project does not use Go, omit `goVersion`.
- **`Makefile`** — Pin `DEV_KIT_VERSION` to a release tag (e.g. `v1.0.0`). Implement the `fmt` and `lint` targets or disable their pre-commit hooks in `flake.nix`.
- **`tools.lock`** — Add any Go tool dependencies your project needs (one per line: `<name> <module>@<version>`).
- **`renovate.json`** — Copy as-is. The custom managers handle `DEV_KIT_VERSION` in your Makefile and entries in `tools.lock`.

Add an `.envrc` for direnv integration:

```bash
#!/usr/bin/env bash
export DIRENV_WARN_TIMEOUT=20s
use flake
```

After copying, run `direnv allow` to activate the dev shell.

## 3. Configure repository settings

Run:

```sh
make repo-settings
```

This reconciles labels, merge strategy (merge commits only, auto-merge enabled, delete branch on merge), secret scanning, and the `protect-main` branch ruleset. See `make help` for details.

## 4. Set up GitHub organization secrets

The following secrets must be whitelisted for your repository at the organization level
(Settings > Secrets and variables > Actions > Repository access):

| Secret               | Used by                            |
| -------------------- | ---------------------------------- |
| `ADD_TO_PROJECT_PAT` | `issues-add-to-project` workflow   |

If your project uses private runners, whitelist the repository in the runner group settings
(Settings > Actions > Runner groups).

## 5. Copy GitHub workflows

Copy the relevant workflows from `.github/workflows/` in this repository:

| Workflow                        | Purpose                                                 |
| ------------------------------- | ------------------------------------------------------- |
| `conventional-commits.yml`      | Validates PR titles and commit messages against Conventional Commits |
| `issues-add-labels.yaml`        | Automatically adds `needs-triage` label to new issues   |
| `issues-add-to-project.yml`     | Adds new issues and PRs to the org project board        |
| `release-drafter.yaml`          | Drafts release notes from merged PRs                    |

If using release-drafter, also copy `.github/release-drafter.yml` (the config file).

If using commitlint (recommended), copy `.commitlintrc.yml` to your project root and enable the hook in `flake.nix`:

```nix
preCommitHooks = {
  commitlint.enable = true;
};
```

## 6. Add the pull request template

Copy `.github/pull_request_template.md` from this repository into your project. It provides a
standard structure for PR descriptions across the organization:

```
.github/
  pull_request_template.md
```

## 7. Check Renovate onboarding

Renovate should automatically open an onboarding PR once `renovate.json` is present.
Verify that:

- The onboarding PR appears and the dependency dashboard is created.
- The custom managers detect `DEV_KIT_VERSION` in your Makefile and entries in `tools.lock`.
- If your project has a `go.mod`, standard Go module updates are picked up as well.

If Renovate is not enabled, check that the Renovate GitHub App is installed for the organization and has access to your repository.

## 8. Final checklist

- [ ] `direnv allow` works and drops you into the dev shell
- [ ] `make help` lists all available targets
- [ ] `make repo-settings` ran successfully
- [ ] GitHub workflows are in place and passing
- [ ] Renovate onboarding PR has been merged
- [ ] Organization secrets are whitelisted for the repo
- [ ] Private runners are whitelisted (if applicable)
