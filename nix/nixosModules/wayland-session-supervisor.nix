{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.wayland-session-supervisor;
  packageDefault = (import ../packages { inherit pkgs; }).default;
  cgroup = "/sys/fs/cgroup/system.slice/wayland-session-supervisor.service/domain";
  common = [
    "--session"
    cfg.sessionName
    "--state-dir"
    (toString cfg.stateDirectory)
    "--runtime-dir"
    (toString cfg.runtimeDirectory)
    "--criu"
    (lib.getExe' cfg.criuPackage "criu")
  ];
  command = common ++ [ "--" ] ++ cfg.compositorCommand;
  currentCheckpoint = "${toString cfg.stateDirectory}/sessions/${cfg.sessionName}/current-checkpoint";
  start = pkgs.writeShellScript "wayland-session-supervisor-start" ''
    set -eu
    if test -s ${lib.escapeShellArg currentCheckpoint}; then
      exec ${lib.getExe cfg.package} restore ${lib.escapeShellArgs command}
    fi
    install -d ${lib.escapeShellArg cgroup}
    exec ${lib.getExe cfg.package} run \
      --session ${lib.escapeShellArg cfg.sessionName} \
      --state-dir ${lib.escapeShellArg (toString cfg.stateDirectory)} \
      --runtime-dir ${lib.escapeShellArg (toString cfg.runtimeDirectory)} \
      --cgroup-dir ${lib.escapeShellArg cgroup} \
      -- ${lib.escapeShellArgs cfg.compositorCommand}
  '';
  capture =
    leaveRunning:
    pkgs.writeShellScript "wayland-session-supervisor-capture" ''
      set -eu
      session=${lib.escapeShellArg "${toString cfg.stateDirectory}/sessions/${cfg.sessionName}"}
      test -s "$session/session.pid" || exit 0
      kill -0 "$(cat "$session/session.pid")" 2>/dev/null || exit 0
      exec ${lib.getExe cfg.package} capture ${lib.optionalString leaveRunning "--leave-running "}${lib.escapeShellArgs command}
    '';
in
{
  options.services.wayland-session-supervisor = {
    enable = lib.mkEnableOption "supervised Wayland session restoration";
    package = lib.mkOption {
      type = lib.types.package;
      default = packageDefault;
      defaultText = lib.literalExpression "wayland-session-supervisor.packages.${pkgs.system}.default";
      description = "The wayland-session-supervisor package to run.";
    };
    criuPackage = lib.mkOption {
      type = lib.types.package;
      default = pkgs.our-criu or (pkgs.callPackage ../packages/criu.nix { });
      defaultText = lib.literalExpression "pkgs.our-criu";
      description = "CRIU package used for checkpoint and restore.";
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
    snapshotOnSuspend = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Capture a leave-running checkpoint before suspend. Hibernate remains excluded.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ cfg.package ];
    systemd.services.wayland-session-supervisor = {
      description = "Wayland session supervisor with automatic reboot persistence";
      wantedBy = [
        "graphical.target"
        "multi-user.target"
      ];
      after = [ "systemd-user-sessions.service" ];
      path = [
        pkgs.coreutils
        cfg.criuPackage
        pkgs.util-linux
        pkgs.wtype
      ];
      serviceConfig = {
        ExecStart = start;
        ExecStop = capture false;
        Delegate = true;
        KillMode = "control-group";
        TimeoutStopSec = "infinity";
        StateDirectory = "wayland-session-supervisor";
        RuntimeDirectory = "wayland-session-supervisor";
        StateDirectoryMode = "0700";
        RuntimeDirectoryMode = "0700";
      };
    };

    systemd.services.wayland-session-supervisor-suspend-snapshot = lib.mkIf cfg.snapshotOnSuspend {
      description = "Checkpoint the Wayland session before suspend";
      wantedBy = [ "suspend.target" ];
      before = [ "suspend.target" ];
      after = [ "wayland-session-supervisor.service" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = capture true;
      };
    };
  };
}
