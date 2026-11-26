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

This reconciles labels, merge strategy (merge commits only by default, configurable via the `REPO_ALLOW_*` variables, which also restrict the ruleset's allowed merge methods; at least one must be enabled; auto-merge disabled, delete branch on merge), last-push-approval requirements (`REPO_REQUIRE_LAST_PUSH_APPROVAL`), secret scanning, and the `protect-main` branch ruleset. See `make help` for details.

The branch protection ruleset is configurable via make variables, e.g.:

```sh
make repo-settings REPO_STATUS_CHECKS='["CI","lint"]' REPO_REQUIRE_BRANCH_UP_TO_DATE=true REPO_RULESET_BRANCHES='["release/*"]'
```

See [REPO_SETTINGS.md](REPO_SETTINGS.md) for the full list of `REPO_*` variables.

## 4. Set up GitHub organization secrets

The following secrets must be whitelisted for your repository at the organization level
(Settings > Secrets and variables > Actions > Repository access):

| Secret               | Used by                                          |
| -------------------- | ------------------------------------------------ |
| `ADD_TO_PROJECT_PAT` | `issues-add-to-project` workflow                 |
| `CACHIX_AUTH_TOKEN`  | any job using the `setup-nix` action (see below) |
| `CACHIX_SIGNING_KEY` | any job using the `setup-nix` action (see below) |

If your project uses private runners, whitelist the repository in the runner group settings
(Settings > Actions > Runner groups).

## 5. Copy GitHub workflows

Copy the stubs you need from [`example/.github/workflows/`](../example/.github/workflows/) and pin each `uses:` to a real SHA.
The stubs call dev-kit's reusable workflows, so their checks report under the names
[GitHub Actions](GITHUB_ACTIONS.md#governance-workflows) says to require. Do not copy dev-kit's own `.github/workflows/` files.

### Nix-based CI

Jobs that run inside the dev shell should use the shared `setup-nix` composite action
rather than installing Nix themselves. It installs Nix and enables the org Cachix cache in
two steps. Secrets are not visible inside a composite action, so the caller passes them, as in
[`example/.github/workflows/ci.yml`](../example/.github/workflows/ci.yml).

Both Cachix secrets are org-level (see step 4). On fork pull requests they are unavailable
and cachix-action falls back to a read-only cache, which is the intended behaviour.

If using commitlint (recommended), copy [`example/.commitlintrc.yml`](../example/.commitlintrc.yml) to your project root and enable the hook in `flake.nix`:

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
