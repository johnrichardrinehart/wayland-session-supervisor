{ inputs, self, ... }:
{
  imports = [
    inputs.git-hooks.flakeModule
    inputs.treefmt-nix.flakeModule
  ];

  perSystem =
    {
      config,
      pkgs,
      system,
      ...
    }:
    {
      treefmt = {
        # `self` is string-like inside this partition, so use the equally
        # explicit builtins.path filter rather than passing it to lib.fileset.
        projectRoot = builtins.path {
          path = self;
          name = "wayland-session-supervisor-treefmt-source";
          filter = path: type: type == "directory" || builtins.match ".*\\.(nix|rs|ya?ml)$" path != null;
        };
        projectRootFile = "flake.nix";
        programs = {
          nixfmt.enable = true;
          rustfmt.enable = true;
          yamlfmt.enable = true;
        };
      };

      # Cargo hooks use the developer's populated registry cache. The package
      # and explicit flake checks remain fully sandboxed.
      pre-commit.check.enable = false;
      pre-commit.settings.hooks = {
        treefmt.enable = true;
        deadnix.enable = true;
        statix.enable = true;
        cargo-check = {
          enable = true;
          entry = "${pkgs.cargo}/bin/cargo check --manifest-path rust/Cargo.toml --all-targets";
          files = "\\.rs$";
          pass_filenames = false;
        };
        clippy = {
          enable = true;
          entry = toString (
            pkgs.writeShellScript "clippy-hook" ''
              export PATH=${
                pkgs.lib.makeBinPath [
                  pkgs.cargo
                  pkgs.clippy
                  pkgs.rustc
                ]
              }:$PATH
              cargo clippy --manifest-path rust/Cargo.toml --all-targets -- -D warnings
            ''
          );
          files = "\\.rs$";
          pass_filenames = false;
        };
      };

      checks = import ../checks {
        inherit
          pkgs
          self
          system
          ;
      };

      devShells.default = pkgs.mkShell {
        packages = with pkgs; [
          cargo
          clippy
          rust-analyzer
          rustc
          rustfmt
        ];
        shellHook = config.pre-commit.installationScript;
      };
    };
}
