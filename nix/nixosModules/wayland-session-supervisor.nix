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
    sessionName = lib.mkOption {
      type = lib.types.strMatching "[A-Za-z0-9._-]+";
      default = "default";
      description = "Stable name of the managed session domain.";
    };
    stateDirectory = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/wayland-session-supervisor";
      description = "Persistent checkpoint and session metadata directory.";
    };
    runtimeDirectory = lib.mkOption {
      type = lib.types.path;
      default = "/run/wayland-session-supervisor";
      description = "Private runtime root supplied to the compositor.";
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
      path = [
        pkgs.coreutils
        pkgs.criu
        pkgs.util-linux
      ];
      serviceConfig = {
        ExecStart = lib.escapeShellArgs (
          [
            (lib.getExe cfg.package)
            "run"
            "--session"
            cfg.sessionName
            "--state-dir"
            cfg.stateDirectory
            "--runtime-dir"
            cfg.runtimeDirectory
            "--cgroup-dir"
            "/sys/fs/cgroup/system.slice/wayland-session-supervisor.service/domain"
            "--"
          ]
          ++ cfg.compositorCommand
        );
        Delegate = true;
        DelegateSubgroup = "supervisor";
        KillMode = "control-group";
        Restart = "on-failure";
        StateDirectory = "wayland-session-supervisor";
        RuntimeDirectory = "wayland-session-supervisor";
        StateDirectoryMode = "0700";
        RuntimeDirectoryMode = "0700";
      };
    };
  };
}
