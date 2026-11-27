# Make targets

Include `common.mk` from your project `Makefile` as shown in [`example/Makefile`](../example/Makefile).
Run `make update-common-mk-bootstrap` to migrate an older `common.mk:` rule to the current format.

The included `common.mk` provides:

| Target                      | Description                                                                                                         |
| --------------------------- | ------------------------------------------------------------------------------------------------------------------- |
| `help`                      | Display all available targets                                                                                       |
| `clean`                     | Remove the `bin/` directory                                                                                         |
| `fmt`                       | Run `fmt-all` when `DEV_KIT_FORMATTING=on`, otherwise only the project's own `fmt` prerequisites                    |
| `lint`                      | Run `lint-all` when `DEV_KIT_FORMATTING=on`, then shellcheck and, when the repository has a `go.mod`, golangci-lint |
| `fmt-all`                   | Formatting only (what `fmt` calls)                                                                                  |
| `lint-all`                  | Fail if any file is not formatted (what `lint` calls)                                                               |
| `mod`                       | Run `go mod tidy`, `download`, and `verify`                                                                         |
| `golangci-lint`             | Run golangci-lint                                                                                                   |
| `shellcheck`                | Run shellcheck on shell scripts                                                                                     |
| `scan`                      | Scan for vulnerabilities using osv-scanner                                                                          |
| `setup-local-cluster`       | Create a Kind cluster for local development                                                                         |
| `repo-settings`             | Reconcile GitHub repository settings                                                                                |
| `envtest-binaries-sideload` | Populate the envtest cache from upstream K8s/etcd releases                                                          |
| `check-go-version`          | Assert every Go version pin in the repository agrees                                                                |
| `check-dev-kit-pins`        | Assert every dev-kit reference names the same release                                                               |

## Variables

| Variable             | Default                                    | Description                                                                                                                          |
| -------------------- | ------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------ |
| `BUILD_PATH`         | `$(shell pwd)`                             | Base directory for local binaries                                                                                                    |
| `LOCALBIN`           | `$(BUILD_PATH)/bin`                        | Directory for installed binaries                                                                                                     |
| `OSV_SCANNER_CONFIG` | `./.osv-scanner.toml`                      | Path to osv-scanner configuration                                                                                                    |
| `DEV_KIT_FORMATTING` | `off`                                      | `on` enables the shared `fmt`/`lint` formatting. Set it before `-include common.mk`                                                  |
| `DEV_KIT_CONFIGS`    | `.editorconfig .golangci.yml treefmt.toml` | Shared configs to bootstrap; set to empty to opt out. Each file is skipped automatically when the repo overrides or does not need it |
| `TREEFMT_ARGS`       | derived                                    | Extra treefmt flags. Defaults to `--allow-missing-formatter` in repos without a `go.mod`, empty otherwise                            |
| `OS`                 | `$(shell $(GO) env GOOS)`                  | Current Operating System                                                                                                             |
| `ARCH`               | `$(shell $(GO) env GOARCH)`                | Current CPU architecture                                                                                                             |

Any binary defined in your `tools.lock` is also available as a Make target
(e.g. `make "$(pwd)/bin/go/controller-gen"`, the value of `$(CONTROLLER_GEN)`). Take a look at the variables defined in
common.mk for a list of pre-defined binary paths.

## Extending

Add your own targets to your project `Makefile` like normal. To override a target from `common.mk`, redefine it.
Make warns about the override, which is expected:

```console
$ make scan
Makefile:18: warning: overriding recipe for target 'scan'
common.mk:84: warning: ignoring old recipe for target 'scan'
  scanning...
```

To add steps to `fmt` or `lint` without replacing their recipe, add prerequisites as shown in [Formatting and linting](FORMATTING.md).

## Go binaries

Define binaries in `tools.lock`, one `<name> <module>@<version>` per line, as in [`example/tools.lock`](../example/tools.lock).
Each one becomes a Make target under `$(LOCALGOBIN)`. [`example/Makefile`](../example/Makefile) shows how to install and call one.

## envtest sideloading

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
