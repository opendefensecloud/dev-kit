{
  description = "Example development flake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    go-overlay = {
      url = "github:purpleclay/go-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    dev-kit = {
      url = "github:opendefensecloud/dev-kit";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.go-overlay.follows = "go-overlay";
    };
  };

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
