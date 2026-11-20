# GitHub Actions

The repo ships composite actions that consuming repositories reference directly.
Pin them to a SHA with a version comment, as the action-pin check requires.
The `<40-char-sha>` placeholders in `example/` are not copy-pasteable: substitute real digests.

| Action                           | Description                                             |
| -------------------------------- | ------------------------------------------------------- |
| `.github/actions/setup-nix`      | Install upstream Nix and enable the shared Cachix cache |
| `.github/actions/get-go-version` | Extract the Go version from `flake.nix`                 |
| `.github/actions/diff-check`     | Fail if a command left uncommitted changes behind       |

`setup-nix` replaces the two-step Nix installer + Cachix preamble that every
job needs before it can use `nix develop` as its shell. Secrets are not visible
inside a composite action, so the caller passes them in, as in
[`example/.github/workflows/ci.yml`](../example/.github/workflows/ci.yml).

| Input                | Default            | Description                                                       |
| -------------------- | ------------------ | ----------------------------------------------------------------- |
| `cachix-name`        | `opendefensecloud` | Cachix cache to use                                               |
| `cachix-auth-token`  | `''`               | Auth token; empty falls back to a read-only cache, as on fork PRs |
| `cachix-signing-key` | `''`               | Signing key; empty disables pushing to the cache                  |

## Governance workflows

The org-wide checks and automations are reusable workflows. A consuming repo
keeps one small stub per workflow, copied from
[`example/.github/workflows/`](../example/.github/workflows/), which sets the triggers and the permissions
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

[`example/.github/workflows/action-pins.yml`](../example/.github/workflows/action-pins.yml):

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

[`example/.github/workflows/conventional-commits.yml`](../example/.github/workflows/conventional-commits.yml):

On pull requests, it also fails when any non-merge commit is a conventional
breaking change (`type!` or `type(scope)!`) but the PR title is not breaking.
The title becomes the merge commit subject (`repo-settings.sh` sets
`merge_commit_title=PR_TITLE`), so this keeps the release notes and version
bump aligned. Merge commits are ignored, so a merge from the base branch cannot
force the title to change.

[`example/.github/workflows/osv-scanner.yml`](../example/.github/workflows/osv-scanner.yml):

[`example/.github/workflows/issues-add-labels.yaml`](../example/.github/workflows/issues-add-labels.yaml):

[`example/.github/workflows/issues-add-to-project.yml`](../example/.github/workflows/issues-add-to-project.yml):

`.github/workflows/renovate-dev-kit-lock.yml` commits a relocked `flake.lock`
to the Renovate PRs that change `flake.nix` but can't update the lock:
`renovate/dev-kit` and `renovate/major-dev-kit` (`nix flake lock` for the
bumped tag) and `renovate/go-version` (`nix flake update go-overlay`, so the
new `goVersion` exists in the shell; if go-overlay does not carry it yet, the
job fails and can be re-run later). It commits as the org's dev-kit GitHub App, so the commit
is signed and starts CI; any other PR skips it. See
[`example/.github/workflows/renovate-dev-kit-lock.yml`](../example/.github/workflows/renovate-dev-kit-lock.yml).

A job from a reusable workflow reports as `<stub job> / <called job>`, so
`REPO_STATUS_CHECKS` needs the new names after switching to a stub, e.g.
`action-pins / Check action pins`,
`action-pins / Audit action pins`, `conventional-commits / PR Title` and
`conventional-commits / Commit Messages`. osv-scanner nests Google's reusable
workflow one level deeper, so its scan reports as
`osv-scanner / scan-pr / osv-scan`. Update the list and rerun `make repo-settings` in the same change, or the old
names stay required and never report.
