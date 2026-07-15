{
  pkgs,
  self,
  system,
  inDomainSeatAuthority ? false,
}:
let
  fixture = pkgs.writeShellScript "authenticated-session-fixture" ''
    set -eu
    test "$(id -u)" = 1000
    test "$PULSE_SERVER" = unix:/run/user/1000/pulse/native
    printf '%s\n' "$$" > "$WSS_SESSION_STATE_DIR/fixture.pid"
    printf ready > "$WSS_SESSION_STATE_DIR/ready"
    trap 'exit 0' TERM INT
    while true; do sleep 1; done
  '';
in
pkgs.testers.runNixOSTest {
  name = "wayland-session-supervisor-authenticated-lifecycle${
    if inDomainSeatAuthority then "-in-domain-seat" else ""
  }";

  nodes.machine = {
    imports = [ self.nixosModules.default ];
    users.users.test = {
      isNormalUser = true;
      uid = 1000;
      linger = true;
      extraGroups = [ "wheel" ];
    };
    programs.niri.enable = true;
    services.greetd.enable = true;
    services.wayland-session-supervisor = {
      enable = true;
      package = self.packages.${system}.default;
      criuPackage = self.packages.${system}.our-criu;
      sessionName = "authenticated";
      compositorCommand = [ "${fixture}" ];
      inherit inDomainSeatAuthority;
    };
    systemd.user.services.graphical-session-probe = {
      description = "Prove supervised sessions activate graphical user services";
      wantedBy = [ "graphical-session.target" ];
      partOf = [ "graphical-session.target" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.coreutils}/bin/true";
        RemainAfterExit = true;
      };
    };
    security.sudo.wheelNeedsPassword = false;
    environment.systemPackages = [ pkgs.jq ];
    virtualisation.memorySize = 2048;
  };

  testScript = ''
    state = "/var/lib/wayland-session-supervisor/sessions/authenticated"
    in_domain_seat = ${if inDomainSeatAuthority then "True" else "False"}
    launch = "systemd-run --unit=authenticated-login --service-type=exec --property=Before=wayland-session-supervisor-capture.service --uid=test --setenv=XDG_RUNTIME_DIR=/run/user/1000 --setenv=DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus /run/current-system/sw/bin/wayland-session-supervisor-session"

    machine.start()
    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("user@1000.service")
    machine.succeed("install -d -o test -g users -m 0700 /run/user/1000/pulse")
    machine.succeed(launch)
    machine.wait_until_succeeds(f"test -s {state}/ready", timeout=30)
    machine.wait_until_succeeds("systemctl --user --machine=test@.host is-active --quiet graphical-session.target", timeout=30)
    machine.wait_until_succeeds("systemctl --user --machine=test@.host is-active --quiet graphical-session-probe.service", timeout=30)
    original_pid = machine.succeed(f"cat {state}/fixture.pid").strip()
    root_pid = machine.succeed(f"cat {state}/session.pid").strip()
    machine.succeed(f"test $(awk '/^Uid:/ {{print $2}}' /proc/{root_pid}/status) -eq 1000")
    if in_domain_seat:
        seatd_pid = machine.succeed("pgrep -xo seatd").strip()
        seatd_launcher_pid = machine.succeed("pgrep -xo seatd-launch").strip()
        seatd_nspid = machine.succeed(f"awk '/^NSpid:/ {{print $NF}}' /proc/{seatd_pid}/status").strip()
        seatd_launcher_nspid = machine.succeed(f"awk '/^NSpid:/ {{print $NF}}' /proc/{seatd_launcher_pid}/status").strip()
        domain_cgroup = machine.succeed(f"cat {state}/cgroup.path").strip()
        machine.succeed(f"grep -Fx {seatd_pid} {domain_cgroup}/cgroup.procs")
        machine.succeed(f"grep -Fx {seatd_launcher_pid} {domain_cgroup}/cgroup.procs")
        machine.succeed(f"test $(awk '/^Uid:/ {{print $2}}' /proc/{seatd_pid}/status) -eq 1000")
        machine.succeed(f"test $(awk '/^Uid:/ {{print $3}}' /proc/{seatd_pid}/status) -eq 0")
        machine.succeed(f"test $(awk '/^Uid:/ {{print $2}}' /proc/{seatd_launcher_pid}/status) -eq 1000")
        machine.succeed("grep -F 'export LIBSEAT_BACKEND=seatd' /nix/store/*-wayland-session-supervisor-session-inner/bin/wayland-session-supervisor-session-inner")
    machine.succeed("grep -R -F -- '--cmd' /nix/store/*-greetd.toml | grep -F wayland-session-supervisor-session")
    machine.succeed("! systemctl list-unit-files | grep -q '^wayland-session-supervisor.service'")

    boot_before = machine.succeed("cat /proc/sys/kernel/random/boot_id").strip()
    machine.shutdown()
    machine.start()
    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("user@1000.service")
    boot_after = machine.succeed("cat /proc/sys/kernel/random/boot_id").strip()
    assert boot_before != boot_after
    machine.succeed(f"test -s {state}/current-checkpoint || {{ journalctl -b -1 -u wayland-session-supervisor-capture.service --no-pager; find {state} -maxdepth 3 -type f -print; cat {state}/checkpoints/failed-*/dump.log 2>/dev/null; exit 1; }}")
    machine.succeed("install -d -o test -g users -m 0700 /run/user/1000/pulse")
    machine.succeed(launch)
    machine.wait_until_succeeds("systemctl is-active --quiet wayland-session-supervisor-restore.service", timeout=30)
    machine.wait_until_succeeds(f"test -s {state}/outer-supervisor.json", timeout=30)
    machine.wait_until_succeeds("systemctl --user --machine=test@.host is-active --quiet graphical-session.target", timeout=30)
    machine.wait_until_succeeds("systemctl --user --machine=test@.host is-active --quiet graphical-session-probe.service", timeout=30)
    restored_pid = machine.succeed(f"cat {state}/fixture.pid").strip()
    assert restored_pid == original_pid
    if in_domain_seat:
        restored_seatd_pid = machine.succeed("pgrep -xo seatd").strip()
        restored_seatd_launcher_pid = machine.succeed("pgrep -xo seatd-launch").strip()
        assert machine.succeed(f"awk '/^NSpid:/ {{print $NF}}' /proc/{restored_seatd_pid}/status").strip() == seatd_nspid
        assert machine.succeed(f"awk '/^NSpid:/ {{print $NF}}' /proc/{restored_seatd_launcher_pid}/status").strip() == seatd_launcher_nspid
        machine.succeed(f"test $(awk '/^Uid:/ {{print $2}}' /proc/{restored_seatd_pid}/status) -eq 1000")
        machine.succeed(f"test $(awk '/^Uid:/ {{print $3}}' /proc/{restored_seatd_pid}/status) -eq 0")
        machine.succeed(f"test $(awk '/^Uid:/ {{print $2}}' /proc/{restored_seatd_launcher_pid}/status) -eq 1000")
  '';
}
