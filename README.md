# dev-kit

Development tools for [opendefense.cloud](https://github.com/opendefensecloud) projects.

## What is this?

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
- `make fmt` - format code
- `make lint` - run linters
- `make test` - run tests
- `make build` - build the project
- `make generate` - run code generation

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

## Documentation

- [Nix](https://nixos.org) - Package manager and dev environment
- [direnv](https://direnv.net) - Environment variable loader
- [go-overlay](https://github.com/purpleclay/go-overlay) - Go tooling for Nix
