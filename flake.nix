{
  description = "odc development environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";

    git-hooks = {
      url = "github:cachix/git-hooks.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    go-overlay = {
      url = "github:purpleclay/go-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.git-hooks.follows = "git-hooks";
    };

    gomod2nix = {
      url = "github:nix-community/gomod2nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { nixpkgs, flake-utils, ... }@inputs:
    flake-utils.lib.eachDefaultSystem (system: let
      pkgs = import nixpkgs {
        inherit system;
        overlays = [
          inputs.go-overlay.overlays.default
          inputs.gomod2nix.overlays.default
        ];
      };

      goVersion = "1.26.2";
      go = pkgs.go-bin.versions.${goVersion};

      pre-commit-check = inputs.git-hooks.lib.${system}.run {
        src = ./.;
        hooks = {
          gofmt.enable = true;

          fmt = {
            enable = true;
            entry = "make fmt";
            pass_filenames = false;
          };

          lint = {
            enable = true;
            entry = "make lint";
            pass_filenames = false;
          };

          osv-scanner = {
            enable = true;
            entry = "make scan";
            files = "\\.(mod|sum)$|requirements\\.txt$";
            pass_filenames = false;
          };
        };
      };
    in {
      devShells.default = pkgs.mkShell {
        inherit (pre-commit-check) shellHook;
        packages = with pkgs; [
          curl
          fluxcd
          gnumake
          go
          gotools
          jq
          kind
          kubectl
          kubernetes-helm
          shellcheck
          yq-go
        ];
      };

      checks.pre-commit-check = pre-commit-check;
    }
  );
}
