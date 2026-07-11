{
  pkgs,
  self,
  system,
}:
let
  session = pkgs.writeShellApplication {
    name = "auto-reboot-session";
    runtimeInputs = [ pkgs.python3 ];
    text = ''
      exec python - <<'PY'
      import json, os, signal, time
      path = os.path.join(os.environ['WSS_SESSION_STATE_DIR'], 'auto-client.json')
      state = {'schema': 1, 'pid': os.getpid(), 'counter': 1, 'token': 'auto-reboot-preserved'}
      def write():
          with open(path + '.tmp', 'w') as f: json.dump(state, f)
          os.replace(path + '.tmp', path)
      def bump(*_):
          state['counter'] += 1
          write()
      signal.signal(signal.SIGUSR1, bump)
      write()
      while True: time.sleep(1)
      PY
    '';
  };
in
pkgs.testers.runNixOSTest {
  name = "wayland-session-supervisor-auto-snapshot-and-reboot";

  nodes.machine = {
    imports = [ self.nixosModules.default ];
    services.wayland-session-supervisor = {
      enable = true;
      package = self.packages.${system}.default;
      criuPackage = self.packages.${system}.our-criu;
      sessionName = "auto";
      snapshotOnSuspend = true;
      compositorCommand = [ (pkgs.lib.getExe session) ];
    };
    environment.systemPackages = [ pkgs.jq ];
    virtualisation.memorySize = 2048;
  };

  testScript = ''
    import json
    state = "/var/lib/wayland-session-supervisor/sessions/auto"
    machine.start()
    machine.wait_for_unit("wayland-session-supervisor.service", timeout=60)
    machine.wait_until_succeeds(f"test -s {state}/auto-client.json")
    before = json.loads(machine.succeed(f"cat {state}/auto-client.json"))
    machine.succeed(
      "systemctl start wayland-session-supervisor-suspend-snapshot.service || "
      "{ cat /var/lib/wayland-session-supervisor/sessions/auto/checkpoints/failed-*/dump.log; exit 1; }"
    )
    machine.succeed(f"test -s {state}/current-checkpoint && kill -0 $(cat {state}/session.pid)")
    machine.succeed("! systemctl show hibernate.target -p Wants --value | grep -q wayland-session-supervisor-suspend-snapshot")
    machine.succeed(f"for pid in $(cat /sys/fs/cgroup/system.slice/wayland-session-supervisor.service{{,/domain}}/cgroup.procs 2>/dev/null); do test \"$(awk '/^NSpid:/ {{print $NF}}' /proc/$pid/status 2>/dev/null)\" = {before['pid']} && kill -USR1 $pid && exit 0; done; exit 1")
    machine.wait_until_succeeds(f"test $(jq -r .counter {state}/auto-client.json) -eq 2", timeout=30)
    before_shutdown = json.loads(machine.succeed(f"cat {state}/auto-client.json"))
    boot_before = machine.succeed("cat /proc/sys/kernel/random/boot_id").strip()
    machine.shutdown()
    machine.start()
    machine.wait_until_succeeds(
      f"systemctl is-active wayland-session-supervisor.service || "
      f"{{ cat {state}/checkpoints/*/restore-attempts/*/restore.log >&2 2>/dev/null; false; }}",
      timeout=60,
    )
    boot_after = machine.succeed("cat /proc/sys/kernel/random/boot_id").strip()
    assert boot_before != boot_after
    machine.succeed(f"test -s {state}/current-checkpoint || {{ cat {state}/checkpoints/failed-*/dump.log; exit 1; }}")
    machine.wait_until_succeeds(
      f"test -s {state}/outer-supervisor.json || "
      f"{{ cat {state}/checkpoints/*/restore-attempts/*/restore.log >&2 2>/dev/null; false; }}",
      timeout=30,
    )
    machine.succeed(f"for pid in $(cat /sys/fs/cgroup/system.slice/wayland-session-supervisor.service{{,/domain}}/cgroup.procs 2>/dev/null); do test \"$(awk '/^NSpid:/ {{print $NF}}' /proc/$pid/status 2>/dev/null)\" = {before['pid']} && kill -USR1 $pid && exit 0; done; exit 1")
    machine.wait_until_succeeds(f"test $(jq -r .counter {state}/auto-client.json) -eq 3", timeout=30)
    after = json.loads(machine.succeed(f"cat {state}/auto-client.json"))
    assert before_shutdown['pid'] == after['pid']
    assert before_shutdown['token'] == after['token']
    assert after['counter'] == before_shutdown['counter'] + 1
    machine.succeed(f"test -s {state}/current-checkpoint")
  '';
}
