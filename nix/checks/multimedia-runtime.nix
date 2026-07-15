{
  pkgs,
  self,
  system,
}:
let
  fixture = pkgs.writeShellScript "supervised-multimedia-fixture" ''
    set -euo pipefail
    test "$XDG_RUNTIME_DIR" = /run/wayland-session-supervisor/multimedia
    test "$PIPEWIRE_RUNTIME_DIR" = /run/user/1000
    test "$PULSE_SERVER" = unix:/run/user/1000/pulse/native
    test "$PULSE_RUNTIME_PATH" = /run/user/1000/pulse

    # Reproduce compositor session setup from inside the nested PID namespace.
    # A no-argument import must never relocate host user services.
    systemctl --user import-environment
    systemctl --user restart pipewire.service pipewire-pulse.service wireplumber.service

    pipewire_connected=false
    for _ in $(seq 1 20); do
      if timeout --kill-after=1s 1s ${pkgs.pipewire}/bin/pw-cli info 0 >"$WSS_SESSION_STATE_DIR/pipewire-info.txt" 2>&1; then
        pipewire_connected=true
        break
      fi
      sleep 0.1
    done
    test "$pipewire_connected" = true
    printf success >"$WSS_SESSION_STATE_DIR/pipewire.status"

    pulse_connected=false
    for _ in $(seq 1 20); do
      if timeout --kill-after=1s 1s ${pkgs.pulseaudio}/bin/pactl info >"$WSS_SESSION_STATE_DIR/pulse-info.txt" 2>&1; then
        pulse_connected=true
        break
      fi
      sleep 0.1
    done
    test "$pulse_connected" = true
    printf success >"$WSS_SESSION_STATE_DIR/pulse.status"
    systemctl --user show-environment >"$WSS_SESSION_STATE_DIR/manager-environment.txt"
    printf '%s\n' "$$" >"$WSS_SESSION_STATE_DIR/fixture.pid"
    printf ready >"$WSS_SESSION_STATE_DIR/ready"
    trap 'exit 0' TERM INT
    while true; do sleep 1; done
  '';
in
pkgs.testers.runNixOSTest {
  name = "wayland-session-supervisor-multimedia-runtime";

  nodes.machine = {
    imports = [ self.nixosModules.default ];
    users.users.test = {
      isNormalUser = true;
      uid = 1000;
      linger = true;
    };
    programs.niri.enable = true;
    services = {
      greetd.enable = true;
      pipewire = {
        enable = true;
        pulse.enable = true;
        wireplumber.enable = true;
      };
      wayland-session-supervisor = {
        enable = true;
        package = self.packages.${system}.default;
        criuPackage = self.packages.${system}.our-criu;
        sessionName = "multimedia";
        compositorCommand = [ "${fixture}" ];
      };
    };
    security.rtkit.enable = true;
    virtualisation.memorySize = 2048;
  };

  testScript = ''
    state = "/var/lib/wayland-session-supervisor/sessions/multimedia"
    launch = "systemd-run --unit=multimedia-login --service-type=exec --uid=test --setenv=XDG_RUNTIME_DIR=/run/user/1000 --setenv=DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus /run/current-system/sw/bin/wayland-session-supervisor-session"

    machine.start()
    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("user@1000.service")
    machine.succeed("systemctl --user --machine=test@.host show-environment | grep -Fx XDG_RUNTIME_DIR=/run/user/1000")
    machine.succeed(launch)
    machine.wait_until_succeeds(f"test -s {state}/ready || {{ cat {state}/session.log 2>/dev/null; cat {state}/pipewire-info.txt 2>/dev/null; cat {state}/pulse-info.txt 2>/dev/null; false; }}", timeout=45)

    machine.succeed(f"grep -Fx success {state}/pipewire.status")
    machine.succeed(f"grep -Fx success {state}/pulse.status")
    machine.succeed(f"test -s {state}/pipewire-info.txt")
    machine.succeed(f"grep -F 'Server Name:' {state}/pulse-info.txt")
    machine.succeed(f"grep -Fx XDG_RUNTIME_DIR=/run/user/1000 {state}/manager-environment.txt")
    machine.succeed(f"! grep -F /run/wayland-session-supervisor/multimedia {state}/manager-environment.txt")
    machine.succeed("systemctl --user --machine=test@.host show-environment | grep -Fx XDG_RUNTIME_DIR=/run/user/1000")
    machine.succeed("test -S /run/user/1000/pipewire-0")
    machine.succeed("test -S /run/user/1000/pulse/native")

    fixture_pid = machine.succeed(f"cat {state}/fixture.pid").strip()
    domain_cgroup = machine.succeed(f"cat {state}/cgroup.path").strip()
    machine.succeed(f"for pid in $(cat {domain_cgroup}/cgroup.procs); do grep -Eq '^NSpid:[[:space:]]+[0-9]+([[:space:]]+[0-9]+)*[[:space:]]+{fixture_pid}$' /proc/$pid/status && exit 0; done; exit 1")
    pipewire_pid = machine.succeed("pgrep -u test -xo pipewire").strip()
    pulse_pid = machine.succeed("pgrep -u test -xo pipewire-pulse").strip()
    machine.succeed(f"! grep -Fx {pipewire_pid} {domain_cgroup}/cgroup.procs")
    machine.succeed(f"! grep -Fx {pulse_pid} {domain_cgroup}/cgroup.procs")
  '';
}
