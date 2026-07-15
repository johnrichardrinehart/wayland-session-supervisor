{
  pkgs,
  self,
  system,
}:
let
  evaluate =
    inDomainSeatAuthority:
    import (pkgs.path + "/nixos/lib/eval-config.nix") {
      inherit system;
      modules = [
        self.nixosModules.default
        {
          users.users.test = {
            isNormalUser = true;
            uid = 1000;
          };
          programs.niri.enable = true;
          services.greetd.enable = true;
          services.wayland-session-supervisor = {
            enable = true;
            user = "test";
            package = self.packages.${system}.default;
            criuPackage = self.packages.${system}.our-criu;
            inherit inDomainSeatAuthority;
          };
        }
      ];
    };
  enabled = (evaluate true).config;
  disabled = (evaluate false).config;
  wrapperName = "wayland-session-supervisor-seatd-launch";
  expectedSource = pkgs.lib.getExe' pkgs.seatd "seatd-launch";
  findLauncher =
    configuration:
    pkgs.lib.findFirst (
      package: pkgs.lib.getName package == "wayland-session-supervisor-session"
    ) (throw "authenticated session launcher is missing") configuration.environment.systemPackages;
  enabledLauncher = findLauncher enabled;
  disabledLauncher = findLauncher disabled;
in
assert enabled.security.wrappers.${wrapperName}.source == expectedSource;
assert enabled.security.wrappers.${wrapperName}.setuid;
assert !(builtins.hasAttr wrapperName disabled.security.wrappers);
pkgs.runCommand "wayland-session-supervisor-in-domain-seat-authority" { } ''
  test ${pkgs.lib.escapeShellArg enabled.security.wrappers.${wrapperName}.source} = \
    ${pkgs.lib.escapeShellArg expectedSource}
  enabled_inner=$(grep -Eo '/nix/store/[^ ]+-wayland-session-supervisor-session-inner/bin/wayland-session-supervisor-session-inner' \
    ${enabledLauncher}/bin/wayland-session-supervisor-session)
  disabled_inner=$(grep -Eo '/nix/store/[^ ]+-wayland-session-supervisor-session-inner/bin/wayland-session-supervisor-session-inner' \
    ${disabledLauncher}/bin/wayland-session-supervisor-session)
  grep -F 'export LIBSEAT_BACKEND=seatd' "$enabled_inner"
  seatd_command=$(grep -Eo '/nix/store/[^ ]+-wayland-session-supervisor-seatd-command' "$enabled_inner")
  grep -F 'exec /run/wrappers/bin/${wrapperName} -- "$@"' "$seatd_command"
  ! grep -F 'export LIBSEAT_BACKEND=seatd' "$disabled_inner"
  ! grep -F 'wayland-session-supervisor-seatd-command' "$disabled_inner"
  ! grep -F '/run/wrappers/bin/${wrapperName}' "$disabled_inner"
  touch "$out"
''
