{ pkgs }:
let
  inherit (pkgs) lib;
  source = lib.fileset.toSource {
    root = ../..;
    fileset = lib.fileset.unions [
      ../../rust/Cargo.lock
      ../../rust/Cargo.toml
      (lib.fileset.fileFilter (file: file.hasExt "rs") ../../rust/src)
    ];
  };
  package = pkgs.rustPlatform.buildRustPackage {
    pname = "wayland-session-supervisor";
    version = "0.1.0";
    src = source;
    cargoRoot = "rust";
    buildAndTestSubdir = "rust";
    cargoLock.lockFile = ../../rust/Cargo.lock;

    meta = {
      description = "Checkpoint and restore supervised Wayland sessions";
      homepage = "https://github.com/johnrichardrinehart/wayland-session-supervisor";
      license = pkgs.lib.licenses.mit;
      mainProgram = "wayland-session-supervisor";
      platforms = pkgs.lib.platforms.linux;
    };
  };
in
{
  default = package;
  wayland-session-supervisor = package;
}
