{
  pkgs,
  self,
  system,
}:
let
  supervisor = self.packages.${system}.default;
  fixture = pkgs.writeShellScript "unprivileged-session-fixture" ''
    set -eu
    test "$(id -u)" = 1000
    test "$(stat -c %u /run/wrappers/bin/sudo)" = 0
    sudo -n true
    busctl --user list >/dev/null
    printf '%s\n' "$$" > "$WSS_SESSION_STATE_DIR/fixture.pid"
    printf ready > "$WSS_SESSION_STATE_DIR/ready"
    trap 'exit 0' TERM INT
    while true; do sleep 1; done
  '';
  launcher = pkgs.writeShellScript "unprivileged-session-launcher" ''
    set -eu
    cgroup_relative="$(${pkgs.gawk}/bin/awk -F: '$1 == "0" { print $3 }' /proc/self/cgroup)"
    cgroup="/sys/fs/cgroup$cgroup_relative/domain"
    ${pkgs.coreutils}/bin/install -d "$cgroup"
    exec ${supervisor}/bin/wayland-session-supervisor run \
      --session unprivileged \
      --state-dir /tmp/wss-state \
      --runtime-dir /run/user/1000/wss-runtime \
      --cgroup-dir "$cgroup" \
      --namespace-launcher /run/wrappers/bin/wss-namespace-launcher \
      -- ${fixture}
  '';
in
pkgs.testers.runNixOSTest {
  name = "wayland-session-supervisor-unprivileged-session";

  nodes.machine = {
    users.users.test = {
      isNormalUser = true;
      uid = 1000;
      linger = true;
      extraGroups = [ "wheel" ];
    };
    security.sudo.wheelNeedsPassword = false;
    security.wrappers.wss-namespace-launcher = {
      source = "${supervisor}/bin/wayland-session-supervisor";
      owner = "root";
      group = "root";
      setuid = true;
    };
    environment.systemPackages = [ pkgs.systemd ];
  };

  testScript = ''
    machine.start()
    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("user@1000.service")
    machine.succeed("install -d -o test -g users -m 0700 /tmp/wss-state /run/user/1000/wss-runtime")
    user_env = "runuser -u test -- env XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus"
    machine.succeed(
      f"{user_env} systemd-run --user --unit=wss-unprivileged --service-type=exec "
      f"--property=Delegate=yes ${launcher}"
    )
    ready = "/tmp/wss-state/sessions/unprivileged/ready"
    machine.wait_until_succeeds(f"test -f {ready}")
    root_pid = machine.succeed("cat /tmp/wss-state/sessions/unprivileged/session.pid").strip()
    machine.succeed(f"test $(awk '/^Uid:/ {{print $2}}' /proc/{root_pid}/status) -eq 1000")
    machine.succeed(f"grep -Eq '^ *0 +0 +4294967295 *$' /proc/{root_pid}/uid_map")
    machine.succeed(f"test $(awk '/^NSpid:/ {{print NF-1}}' /proc/{root_pid}/status) -ge 2")
    cgroup = machine.succeed("cat /tmp/wss-state/sessions/unprivileged/cgroup.path").strip()
    machine.succeed(f"test -f {cgroup}/cgroup.procs")
    machine.succeed(f"{user_env} systemctl --user stop wss-unprivileged.service")
  '';
}
