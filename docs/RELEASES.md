# Releases

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

## Using the reusable workflows

The caller owns the triggers and inputs and chains the two workflows. Copy
[`example/.github/workflows/release.yml`](../example/.github/workflows/release.yml), or see
[`.github/workflows/release-self.yml`](../.github/workflows/release-self.yml) for the caller used by this repo. The `inputs` context is empty on `push`, so the caller selects each value by event; passing an empty string to a boolean input fails workflow validation. The concurrency block runs one release at a time and never cancels a running one (it may already have tagged). It is not a queue: GitHub keeps one run pending, and a newer dispatch replaces it, which is harmless since a pending run has tagged nothing. Push previews get their own group, so a merge cannot replace a pending release dispatch.

## Required checks

`required_checks` names the check runs, as shown on the commit, that must have passed on the released commit itself before it is tagged. A check that failed, is still running, was skipped or never ran blocks the release; a dry run only reports it. A name with several runs on the commit (the same workflow also triggered by `release` or `schedule`, say) must have passed in all of them. Typically these are the e2e jobs.

The required checks must run on every push to the default branch: drop `paths-ignore` from the push trigger of the workflow running them (keeping it on `pull_request` is fine), and don't require a job that a condition can skip. Otherwise a documentation-only commit can never be released.

## Attaching release assets

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

## Requirements

- **Shared `cliff.toml`**: No config file is needed by default. The workflow checks out `cliff.toml` from dev-kit at the same commit as the reusable workflow and uses it. Pass `cliff_config` to use a repository-specific file instead; the bundled notes guard then falls back to best-effort checks for that override. While unreleased tags exist, the workflow passes them as `--ignore-tags`, which replaces an `ignore_tags` set in that file.
- **Release-notes check**: The workflow checks out its own tooling at the commit that defines it (`job.workflow_sha`) and runs the bundled `check-release-notes` action, so consumers do not need to copy the check. `job.workflow_*` is available on github.com, not GHES.
- **Permissions**: `release.yml` needs `contents: write` and `checks: read`, `release-draft.yml` needs `contents: write`. The asset build needs neither.
- **Default branch only**: Releases must be cut from the repository's default branch: a run from any other branch or from a tag is refused. A specific version, a release candidate such as `v1.2.0-rc1` included, is set with the `version` input. No version tag may sit on a later commit than the run's, so re-running an old run after a newer one tagged is refused: start a new run instead. Dry runs only warn about that.
- **Merge commits**: The shared config renders the merge commits on the default branch. A commit pushed directly to the branch is reported by the notes guard and fails the release unless `force` is set. Squash and rebase merges are treated the same way.
- **Prior release tag**: The repository must already have a release tag. git-cliff derives the changelog boundary from the previous tag, and the workflow fails if there is none. Passing an explicit `version` does not bypass this.
- **Nothing releasable**: If no `feat`, `fix`, `perf` or breaking change landed since the previous tag, a push or scheduled run succeeds with a notice. A manual run fails unless `version` is supplied.
- **One release at a time**: A manual run fails while any draft release exists; a dry run warns. A draft whose tag exists is a release that was cut but not published: publish it, or delete the draft (its tag becomes a burned tag, below).
- **Protected release tags**: No tag is created unless an active tag ruleset without bypass actors refuses moving and deleting it (`make repo-settings` adds `protect-release-tags`); a dry run warns. GitHub shows a ruleset's bypass actors only to its admins, so the check sees them only where it can, and otherwise checks that the workflow itself cannot bypass it. The draft is checked against its tag once, when it is created; only a tag that cannot move keeps assets and tag matching until someone publishes. `release-draft.yml` also refuses to draft a tag that does not point at the commit the assets were built from.
- **Burned tags**: The tag is created before anything is built, so a run can leave a tag that is never released: the wrong commit was dispatched, the build cannot pass on that commit, or a failed run was not re-run in time. Such a tag stays (it cannot be deleted) but nothing was shipped from it. Delete its draft, if any, and run the release again: tags without a release are ignored as release boundaries, so the next release's notes, notes check and version bump start at the last released tag, the computed version skips taken numbers, and the notes name the burned version. Once a release has shipped its changes, a burned tag no longer counts. A commit carries at most one unreleased tag: to release the commit of a burned tag under another version, wait for the next commit. A further version on a released commit must rank above the ones there. Never reuse a burned number with an explicit `version`; it is refused anyway.
- **Recovery**: If the asset build or the draft job fails, use **Re-run failed jobs**: the tag already exists, so the rebuild uses the same commit; the draft job creates or updates the same draft, and drops assets the rebuild did not produce. A re-run that a later release run has overtaken (it found this tag without a release and cut the next version) is refused, as is drafting while another draft is pending. **Re-run all jobs** cannot recover a release, since the version computation then finds its own tag, and runs older than 30 days cannot be re-run at all. Either way the tag is burned: delete the draft and release again.
- **Publishing**: Prerelease versions (containing `-`) are marked as prereleases automatically. Publishing triggers downstream workflows (Docker, Helm, docs), which build from the tag.

## Known gaps

- `gh release create` creates the draft before uploading its files, so the draft is briefly visible without all assets. Publish only after the run has finished. If the release is immutable, remaining uploads fail; otherwise, assets can still change after publication.

## Upgrading from v4

1. **Protect release tags and delete every draft release** first. Run `make repo-settings` as an admin with this version of dev-kit; v5 refuses to tag without `protect-release-tags`. A v4 draft has no tag and points at whichever commit the last push run left it on; publishing it would ship its old assets. v5 refuses to release while one exists.
2. Drop inputs `create_tag` and `retry_assets_for` and output `draft_updated` from the caller, including any `run-name` that refers to them, and any tag trigger: runs from a tag are refused.
3. Pass `dry_run: true` on push, use the concurrency block from the example caller, grant `checks: read`, set `required_checks`, and add the `draft` job. Drop `paths-ignore` from the push trigger of the workflow running the required checks.
4. With assets: upload them as an artifact from a job between the two calls instead of to the release.
