{
  pkgs,
  self,
  ...
}:
pkgs.testers.runNixOSTest {
  name = "wayland-session-supervisor-physical-watchdog";

  nodes.machine = {
    users.users.test = {
      isNormalUser = true;
      uid = 1000;
      extraGroups = [ "wheel" ];
    };
    users.users.test.linger = true;
    security.sudo.wheelNeedsPassword = false;
    environment.systemPackages = [
      pkgs.coreutils
      pkgs.jq
      pkgs.sudo
      pkgs.systemd
      pkgs.util-linux
    ];
  };

  testScript = ''
    machine.start()
    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("user@1000.service")
    machine.succeed("install -d -o test -g users -m 0700 /run/user/1000 /home/test/.local/state /run/wayland-session-supervisor")
    machine.succeed("unshare --pid --fork --mount-proc -- su - test -c 'XDG_RUNTIME_DIR=/run/user/1000 ${self}/tests/physical/prove-watchdog.sh'")
    evidence = "/home/test/.local/state/wayland-session-supervisor/physical-test/escape-gate.json"
    machine.succeed(f"jq -e '.schema == 2 and .authority == \"system-manager-cgroup-kill\" and .verdict == \"pass\" and (.watchdog_cgroup | startswith(\"/system.slice/\")) and (.victim_cgroup | startswith(\"/user.slice/\"))' {evidence}")
    machine.succeed("grep -Fx watchdog_fired=1 /run/wayland-session-supervisor/physical-watchdog-1000.env")
    machine.succeed("grep -Fx cgroup_kill_result=success /run/wayland-session-supervisor/physical-watchdog-1000.env")
    machine.succeed("grep -Fx unit_stop_result=success /run/wayland-session-supervisor/physical-watchdog-1000.env")
    machine.succeed("test $(stat -c %U:%G:%a /run/wayland-session-supervisor) = test:users:700")
    machine.succeed("! systemctl --user --machine=test@.host is-active --quiet wss-physical-watchdog-victim.service")
  '';
}
