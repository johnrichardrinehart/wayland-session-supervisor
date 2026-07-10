{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.wayland-session-supervisor;
in
{
  options.services.wayland-session-supervisor = {
    enable = lib.mkEnableOption "supervised Wayland session restoration";
    package = lib.mkOption {
      type = lib.types.package;
      inherit (import ../packages { inherit pkgs; }) default;
      defaultText = lib.literalExpression "wayland-session-supervisor.packages.${pkgs.system}.default";
      description = "The wayland-session-supervisor package to run.";
    };
    compositorCommand = lib.mkOption {
      type = lib.types.nonEmptyListOf lib.types.str;
      default = [ "niri" ];
      description = "Compositor executable and arguments, represented without shell interpolation.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ cfg.package ];
    systemd.services.wayland-session-supervisor = {
      description = "Wayland session supervisor";
      wantedBy = [ "graphical.target" ];
      serviceConfig = {
        ExecStart = lib.escapeShellArgs (
          [
            (lib.getExe cfg.package)
            "run"
            "--"
          ]
          ++ cfg.compositorCommand
        );
        Restart = "on-failure";
      };
    };
  };
}
