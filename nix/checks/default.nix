{
  pkgs,
  self,
  system,
}:
{
  package = self.packages.${system}.default;
  cargo-test =
    pkgs.runCommand "wayland-session-supervisor-cargo-test"
      {
        nativeBuildInputs = [
          pkgs.cargo
          pkgs.stdenv.cc
        ];
      }
      ''
        cp -r ${self}/rust source
        chmod -R u+w source
        cd source
        cargo test --offline
        touch $out
      '';
}
