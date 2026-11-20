# Formatting and linting

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
Ignore the bootstrapped files as in [`example/.gitignore`](../example/.gitignore).
`.common.mk-configs` records what was
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
