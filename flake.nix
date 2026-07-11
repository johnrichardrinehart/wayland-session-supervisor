{
  description = "Checkpoint and restore supervised Wayland sessions";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{ self, flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      imports = [ inputs.flake-parts.flakeModules.partitions ];

      partitionedAttrs = {
        checks = "dev";
        devShells = "dev";
        formatter = "dev";
      };

      partitions.dev = {
        extraInputsFlake = ./dev;
        module = import ./nix/flake/dev-partition.nix;
      };

      perSystem =
        {
          pkgs,
          system,
          ...
        }:
        {
          packages = import ./nix/packages { inherit pkgs; };
          apps.default = {
            type = "app";
            program = "${self.packages.${system}.default}/bin/wayland-session-supervisor";
            meta.description = "Run the Wayland session supervisor";
          };
        };

      flake = {
        nixosModules = import ./nix/nixosModules;
        overlays.default = import ./nix/overlays;
      };
    };
}
