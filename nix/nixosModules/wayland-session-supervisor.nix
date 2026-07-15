{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.wayland-session-supervisor;
  packageDefault = (import ../packages { inherit pkgs; }).default;
  supportedAuthenticatedDesktop = config.services.greetd.enable && config.programs.niri.enable;
  normalUsers = lib.attrNames (lib.filterAttrs (_: account: account.isNormalUser) config.users.users);
  inferredUser = if builtins.length normalUsers == 1 then builtins.head normalUsers else null;
  user = if cfg.user != null then cfg.user else inferredUser;
  userUid = config.users.users.${user}.uid;
  authenticated = supportedAuthenticatedDesktop;
  standalone = !authenticated;
  niriCommand = [
    (lib.getExe config.programs.niri.package)
    "--config"
    "/etc/niri/config.kdl"
    "--session"
  ];
  compositorCommand = if cfg.compositorCommand == null then niriCommand else cfg.compositorCommand;
  seatdWrapperName = "wayland-session-supervisor-seatd-launch";
  # NixOS security wrappers are intentionally execute-only. This readable
  # store script can be hashed by the authenticated user and immediately execs
  # seatd-launch, so the persistent domain still starts at seatd-launch.
  seatdCommand = pkgs.writeShellScript "wayland-session-supervisor-seatd-command" ''
    exec /run/wrappers/bin/${seatdWrapperName} -- "$@"
  '';
  domainCommand =
    if cfg.inDomainSeatAuthority then [ seatdCommand ] ++ compositorCommand else compositorCommand;
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
  command = common ++ [ "--" ] ++ domainCommand;
  sessionState = "${toString cfg.stateDirectory}/sessions/${cfg.sessionName}";
  currentCheckpoint = "${sessionState}/current-checkpoint";
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
      -- ${lib.escapeShellArgs domainCommand}
  '';
  capture =
    leaveRunning:
    pkgs.writeShellScript "wayland-session-supervisor-capture" ''
      set -eu
      session=${lib.escapeShellArg sessionState}
      test -s "$session/session.pid" || exit 0
      kill -0 "$(cat "$session/session.pid")" 2>/dev/null || exit 0
      ${lib.getExe cfg.package} capture ${lib.optionalString leaveRunning "--leave-running "}${lib.escapeShellArgs command}
      ${lib.optionalString authenticated "${lib.getExe' pkgs.coreutils "chown"} -R ${lib.escapeShellArg user}:users ${lib.escapeShellArg (toString cfg.stateDirectory)}"}
    '';
  restoreBroker = pkgs.writeShellScript "wayland-session-supervisor-restore-broker" ''
    set -eu
    request=${lib.escapeShellArg "${toString cfg.runtimeDirectory}/restore-request"}
    started=${lib.escapeShellArg "${toString cfg.runtimeDirectory}/restore-started"}
    result=${lib.escapeShellArg "${toString cfg.runtimeDirectory}/restore-result"}
    rm -f "$request" "$result"
    : > "$started"
    if ${lib.getExe cfg.package} restore ${lib.escapeShellArgs command}; then
      printf '0\n' > "$result"
    else
      status=$?
      printf '%s\n' "$status" > "$result"
      exit "$status"
    fi
  '';
  systemctlProxy = pkgs.writeShellScriptBin "systemctl" ''
    has_user=false
    for argument in "$@"; do
      test "$argument" = --user && has_user=true
    done
    if $has_user && test -n "''${WSS_SESSION_NAME:-}"; then
      if printf '%s\n' "$@" | ${lib.getExe pkgs.gnugrep} -qx import-environment; then
        prefix=()
        requested=()
        import_seen=false
        import_argument_count=0
        for argument in "$@"; do
          if ! $import_seen; then
            prefix+=("$argument")
            test "$argument" != import-environment || import_seen=true
            continue
          fi
          import_argument_count=$((import_argument_count + 1))
          variable="''${argument%%=*}"
          case "$variable" in
            XDG_RUNTIME_DIR|DBUS_SESSION_BUS_ADDRESS|PIPEWIRE_RUNTIME_DIR|PULSE_SERVER|PULSE_RUNTIME_PATH|PULSE_COOKIE)
              ;;
            *) requested+=("$argument") ;;
          esac
        done

        if (( import_argument_count == 0 )); then
          # A no-argument import normally copies the entire private session
          # environment. Import only graphical discovery variables instead.
          for variable in DISPLAY WAYLAND_DISPLAY XDG_CURRENT_DESKTOP XDG_SESSION_TYPE XDG_SESSION_DESKTOP DESKTOP_SESSION NIRI_SOCKET; do
            test -v "$variable" && requested+=("$variable")
          done
        fi
        if (( ''${#requested[@]} == 0 )); then
          exit 0
        fi
        if test -n "''${WAYLAND_DISPLAY:-}" && [[ $WAYLAND_DISPLAY != /* ]]; then
          export WAYLAND_DISPLAY="$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY"
        fi
        exec ${lib.getExe' pkgs.systemd "systemctl"} --machine="$USER@.host" "''${prefix[@]}" "''${requested[@]}"
      fi
      exec ${lib.getExe' pkgs.systemd "systemctl"} --machine="$USER@.host" "$@"
    fi
    exec ${lib.getExe' pkgs.systemd "systemctl"} "$@"
  '';
  authenticatedInner = pkgs.writeShellApplication {
    name = "wayland-session-supervisor-session-inner";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.gawk
      cfg.package
      systemctlProxy
    ];
    text = ''
      cgroup_relative="$(${pkgs.gawk}/bin/awk -F: '$1 == "0" { print $3 }' /proc/self/cgroup)"
      test -n "$cgroup_relative" || { echo "cannot determine delegated user-session cgroup" >&2; exit 1; }
      cgroup="/sys/fs/cgroup$cgroup_relative/domain"
      install -d "$cgroup"

      user_runtime_dir="/run/user/$(${lib.getExe' pkgs.coreutils "id"} -u)"
      session_runtime_dir=${lib.escapeShellArg "${toString cfg.runtimeDirectory}/${cfg.sessionName}"}
      # tmpfiles owns the shared runtime root; the authenticated user owns only
      # its state and private per-session runtime directory.
      install -d -m 0700 ${lib.escapeShellArg (toString cfg.stateDirectory)} "$session_runtime_dir"
      export XDG_RUNTIME_DIR="$session_runtime_dir"
      export PULSE_SERVER="unix:$user_runtime_dir/pulse/native"
      export PULSE_RUNTIME_PATH="$user_runtime_dir/pulse"
      export PIPEWIRE_RUNTIME_DIR="$user_runtime_dir"
      for endpoint in bus systemd; do
        if test -e "$user_runtime_dir/$endpoint"; then
          ln -sfn "$user_runtime_dir/$endpoint" "$session_runtime_dir/$endpoint"
        fi
      done

      ${lib.optionalString cfg.inDomainSeatAuthority "export LIBSEAT_BACKEND=seatd"}

      if test -s ${lib.escapeShellArg currentCheckpoint}; then
        rm -f ${lib.escapeShellArg "${toString cfg.runtimeDirectory}/restore-started"} ${lib.escapeShellArg "${toString cfg.runtimeDirectory}/restore-result"}
        : > ${lib.escapeShellArg "${toString cfg.runtimeDirectory}/restore-request"}
        for _ in $(seq 1 300); do
          test ! -e ${lib.escapeShellArg "${toString cfg.runtimeDirectory}/restore-result"} || exit "$(cat ${lib.escapeShellArg "${toString cfg.runtimeDirectory}/restore-result"})"
          test ! -e ${lib.escapeShellArg "${toString cfg.runtimeDirectory}/restore-started"} || break
          sleep 0.1
        done
        test -e ${lib.escapeShellArg "${toString cfg.runtimeDirectory}/restore-started"} || { echo "restore broker did not start" >&2; exit 1; }
        while ${lib.getExe' pkgs.systemd "systemctl"} is-active --quiet wayland-session-supervisor-restore.service; do sleep 1; done
        test ! -e ${lib.escapeShellArg "${toString cfg.runtimeDirectory}/restore-result"} || exit "$(cat ${lib.escapeShellArg "${toString cfg.runtimeDirectory}/restore-result"})"
        exit 0
      fi

      exec ${lib.getExe cfg.package} run \
        --session ${lib.escapeShellArg cfg.sessionName} \
        --state-dir ${lib.escapeShellArg (toString cfg.stateDirectory)} \
        --runtime-dir ${lib.escapeShellArg (toString cfg.runtimeDirectory)} \
        --cgroup-dir "$cgroup" \
        --namespace-launcher /run/wrappers/bin/wayland-session-supervisor-namespace-launcher \
        -- ${lib.escapeShellArgs domainCommand}
    '';
  };
  authenticatedLauncher = pkgs.writeShellApplication {
    name = "wayland-session-supervisor-session";
    runtimeInputs = [ pkgs.systemd ];
    text = ''
      exec systemd-run --user --scope --collect \
        --unit=wayland-session-supervisor-${cfg.sessionName} \
        --property=Delegate=yes \
        --property=BindsTo=graphical-session.target \
        --property=Before=graphical-session.target \
        --property=Wants=graphical-session-pre.target \
        --property=After=graphical-session-pre.target \
        --property=Wants=xdg-desktop-autostart.target \
        --property=Before=xdg-desktop-autostart.target \
        ${lib.getExe authenticatedInner}
    '';
  };
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
    user = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Authenticated login user that owns the compositor; inferred when exactly one normal user exists.";
    };
    greeterPackage = lib.mkOption {
      type = lib.types.package;
      default = pkgs.tuigreet;
      defaultText = lib.literalExpression "pkgs.tuigreet";
      description = "greetd greeter used to authenticate before launching the managed session.";
    };
    greeterArguments = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "--time"
        "--remember"
        "--user-menu"
        "--asterisks"
      ];
      description = "Arguments passed to tuigreet before its supervised-session command.";
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
      type = lib.types.nullOr (lib.types.nonEmptyListOf lib.types.str);
      default = null;
      defaultText = lib.literalExpression ''[ (lib.getExe config.programs.niri.package) "--config" "/etc/niri/config.kdl" "--session" ]'';
      description = "Optional shell-free compositor argv override; enabled Niri is detected by default.";
    };
    snapshotOnSuspend = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Capture a leave-running checkpoint before suspend. Hibernate remains excluded.";
    };
    inDomainSeatAuthority = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Experimental exact-restore mode that launches a dedicated privileged seatd
        authority inside the checkpoint domain instead of retaining logind process
        references outside it. This installs the upstream seatd-launch setuid wrapper,
        forces the libseat seatd backend, and remains disabled until physical proof.
      '';
    };
  };

  config = lib.mkMerge [
    (lib.mkIf (cfg.enable && cfg.inDomainSeatAuthority) {
      assertions = [
        {
          assertion = authenticated;
          message = "inDomainSeatAuthority currently requires authenticated greetd/Niri mode";
        }
        {
          assertion = !config.services.seatd.enable;
          message = "inDomainSeatAuthority conflicts with the host-global services.seatd daemon";
        }
      ];
    })
    (lib.mkIf (cfg.enable && standalone) {
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
    })
    (lib.mkIf (cfg.enable && authenticated) {
      assertions = [
        {
          assertion = user != null && builtins.hasAttr user config.users.users;
          message = "wayland-session-supervisor requires user to be set when multiple normal users exist";
        }
        {
          assertion = config.services.greetd.enable;
          message = "authenticated wayland-session-supervisor mode requires services.greetd.enable";
        }
        {
          assertion = config.programs.niri.enable;
          message = "authenticated wayland-session-supervisor mode currently requires programs.niri.enable";
        }
      ];
      services.greetd.settings.default_session = {
        command = lib.mkForce "${
          lib.escapeShellArgs ([ (lib.getExe cfg.greeterPackage) ] ++ cfg.greeterArguments)
        } --cmd ${lib.escapeShellArg (lib.getExe authenticatedLauncher)}";
        user = lib.mkDefault "greeter";
      };
      environment.systemPackages = [
        cfg.package
        cfg.criuPackage
        authenticatedLauncher
        pkgs.util-linux
        pkgs.wtype
      ];
      security.wrappers = {
        wayland-session-supervisor-namespace-launcher = {
          source = lib.getExe cfg.package;
          owner = "root";
          group = "root";
          setuid = true;
        };
      }
      // lib.optionalAttrs cfg.inDomainSeatAuthority {
        ${seatdWrapperName} = {
          source = lib.getExe' pkgs.seatd "seatd-launch";
          owner = "root";
          group = "root";
          setuid = true;
        };
      };
      systemd = {
        services = {
          "user@".serviceConfig.Delegate = "cpu cpuset io memory pids";
          wayland-session-supervisor-restore = {
            description = "Privileged restore broker for the authenticated Wayland session";
            path = [
              pkgs.coreutils
              cfg.criuPackage
              pkgs.util-linux
              pkgs.wtype
            ];
            serviceConfig = {
              ExecStart = restoreBroker;
              TimeoutStartSec = "infinity";
            };
          };
          wayland-session-supervisor-capture = {
            description = "Capture the authenticated Wayland session before shutdown";
            wantedBy = [ "multi-user.target" ];
            after = [ "greetd.service" ] ++ lib.optional (userUid != null) "user@${toString userUid}.service";
            before = [ "shutdown.target" ];
            conflicts = [ "shutdown.target" ];
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
              Environment = "WSS_CRIU_UNPRIVILEGED=1";
              ExecStart = "${pkgs.coreutils}/bin/true";
              ExecStop = capture false;
              TimeoutStopSec = "infinity";
            };
          };
        };
        tmpfiles.rules = [
          "d ${toString cfg.stateDirectory} 0700 ${user} users -"
          "d ${toString cfg.runtimeDirectory} 0700 ${user} users -"
        ];
        paths.wayland-session-supervisor-restore = {
          wantedBy = [ "multi-user.target" ];
          pathConfig.PathExists = "${toString cfg.runtimeDirectory}/restore-request";
        };
      };
    })
    (lib.mkIf (cfg.enable && cfg.snapshotOnSuspend) {
      systemd.services.wayland-session-supervisor-suspend-snapshot = {
        description = "Checkpoint the Wayland session before suspend";
        wantedBy = [ "suspend.target" ];
        before = [ "suspend.target" ];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = capture true;
        };
      };
    })
  ];
}
