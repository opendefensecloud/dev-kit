{
  description = "dev-kit";

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
      inputs.flake-utils.follows = "flake-utils";
    };

    gomod2nix = {
      url = "github:nix-community/gomod2nix";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-utils.follows = "flake-utils";
    };
  };

  outputs = { nixpkgs, git-hooks, go-overlay, gomod2nix, ... }@inputs: {
    lib.mkShell = { system, packages ? [], preCommitHooks ? {}, goVersion ? null, shellHook ? "", ... }:
    let
      pkgs = import nixpkgs {
        inherit system;
        overlays = [
          go-overlay.overlays.default
          gomod2nix.overlays.default
        ];
      };
      lib = pkgs.lib;
      mkDefaultAttrs = value:
        if lib.isAttrs value then
          lib.mkDefault (builtins.mapAttrs (_: v: mkDefaultAttrs v) value)
        else
          lib.mkDefault value;

      defaultPkgs = with pkgs; [
        curl
        gnumake
        jq
        kind
        kubectl
        kubernetes-helm
        shellcheck
        yq-go
      ];

      defaultHooks = {
        fmt = mkDefaultAttrs {
          enable = true;
          entry = "make fmt";
          pass_filenames = false;
        };
        lint = mkDefaultAttrs {
          enable = true;
          entry = "make lint";
          pass_filenames = false;
        };
        osv-scanner = mkDefaultAttrs {
          enable = true;
          entry = "make scan";
          files = "\\.(mod|sum)$|requirements\\.txt$";
          pass_filenames = false;
        };
        commitlint = mkDefaultAttrs {
          enable = false;
          entry = "${pkgs.commitlint}/bin/commitlint --edit";
          stages = ["commit-msg"];
          pass_filenames = false;
        };
      };
      gitHooks = git-hooks.lib.${system}.run {
        src = nixpkgs.path;
        hooks = lib.recursiveUpdate defaultHooks preCommitHooks;
      };
    in
      pkgs.mkShell {
        shellHook = gitHooks.shellHook + ''
          [[ -f .git/hooks/pre-commit.legacy ]] && rm -v .git/hooks/pre-commit.legacy
        '' + shellHook;

        packages = defaultPkgs ++ packages ++ lib.optionals (goVersion != null) [
          pkgs.go-bin.versions.${goVersion}
          pkgs.gotools
        ];
      };
  };
}
