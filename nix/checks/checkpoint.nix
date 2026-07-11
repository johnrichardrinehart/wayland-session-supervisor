{
  pkgs,
  self,
  system,
}:
let
  fixtureSources = pkgs.lib.fileset.toSource {
    root = ../..;
    fileset = ../../tests/fixtures/wayland-state-client.c;
  };
  stateClient = pkgs.stdenv.mkDerivation {
    pname = "checkpoint-state-client";
    version = "0.1.0";
    src = fixtureSources + /tests/fixtures/wayland-state-client.c;
    dontUnpack = true;
    strictDeps = true;
    nativeBuildInputs = [ pkgs.pkg-config ];
    buildInputs = [ pkgs.wayland ];
    buildPhase = ''
      cc $(pkg-config --cflags wayland-client) "$src" \
        $(pkg-config --libs wayland-client) -o checkpoint-state-client
    '';
    installPhase = ''
      install -Dm755 checkpoint-state-client $out/bin/checkpoint-state-client
    '';
  };
  sessionLauncher = pkgs.writeShellApplication {
    name = "checkpoint-session";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.python3
      pkgs.weston
      stateClient
    ];
    text = ''
      exec 3<&- 4<&-
      export WAYLAND_DISPLAY=wayland-checkpoint
      rm -f "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY.lock"
      weston --backend=headless-backend.so --socket="$WAYLAND_DISPLAY" \
        --idle-time=0 --log="$WSS_SESSION_STATE_DIR/weston.log" &
      compositor_pid=$!
      for _ in $(seq 1 100); do
        test -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" && break
        sleep 0.05
      done
      test -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY"
      checkpoint-state-client "$WSS_SESSION_STATE_DIR/client.json" \
        supervisor-checkpoint-token &
      client_pid=$!
      printf '%s\n' "$client_pid" > "$WSS_SESSION_STATE_DIR/client.pid"
      python3 - "$WSS_SESSION_STATE_DIR/orphan.pid" <<'PY'
      import os, sys, time
      if os.fork():
          os._exit(0)
      os.setsid()
      if os.fork():
          os._exit(0)
      with open(sys.argv[1], 'w') as output:
          output.write(str(os.getpid()) + '\n')
      while True:
          time.sleep(60)
      PY
      wait "$client_pid" "$compositor_pid"
    '';
  };
  supervisor = self.packages.${system}.default;
  criu = self.packages.${system}.our-criu;
  failingCriu = pkgs.writeShellScript "failing-criu" ''
    if [ "''${1:-}" = --version ]; then
      echo 'Version: test-failure'
      exit 0
    fi
    exit 42
  '';
  command = "${sessionLauncher}/bin/checkpoint-session";
in
pkgs.testers.runNixOSTest {
  name = "wayland-session-supervisor-checkpoint";

  nodes.machine = {
    virtualisation.memorySize = 2048;
    environment.systemPackages = [
      pkgs.coreutils
      criu
      pkgs.jq
      supervisor
    ];
  };

  testScript = ''
    import json

    state = "/var/lib/wayland-session-supervisor"
    runtime = "/run/wayland-session-supervisor"
    command = "${command}"
    common = f"--session checkpoint --state-dir {state} --"

    machine.start()
    machine.wait_for_unit("multi-user.target")
    boot_before = machine.succeed("cat /proc/sys/kernel/random/boot_id").strip()
    machine.succeed("mkdir /sys/fs/cgroup/wss-checkpoint")
    machine.succeed(
      "systemd-run --unit=wss-checkpoint --service-type=exec "
      "--property=StandardOutput=null --property=StandardError=null "
      f"${supervisor}/bin/wayland-session-supervisor run "
      f"--session checkpoint --state-dir {state} --runtime-dir {runtime} "
      f"--cgroup-dir /sys/fs/cgroup/wss-checkpoint -- {command}"
    )
    client_json = f"{state}/sessions/checkpoint/client.json"
    machine.wait_until_succeeds(f"test -s {client_json} && test -s {state}/sessions/checkpoint/session.pid && test -s {state}/sessions/checkpoint/cgroup.path")
    machine.succeed("systemctl is-active wss-checkpoint.service")
    machine.wait_until_succeeds(f"test -s {state}/sessions/checkpoint/orphan.pid")
    orphan_namespace_pid = machine.succeed(f"cat {state}/sessions/checkpoint/orphan.pid").strip()
    machine.succeed(f"for pid in $(cat /sys/fs/cgroup/wss-checkpoint/cgroup.procs); do test \"$(awk '/^NSpid:/ {{print $NF}}' /proc/$pid/status 2>/dev/null)\" = {orphan_namespace_pid} && echo $pid > /tmp/orphan-host.pid && exit 0; done; exit 1")
    before = json.loads(machine.succeed(f"cat {client_json}"))
    diagnostic_path = machine.succeed(f"${supervisor}/bin/wayland-session-supervisor diagnose {common} {command}").strip().split()[-1]
    diagnostic = json.loads(machine.succeed(f"cat {diagnostic_path}"))
    assert diagnostic["schema"] == 1
    assert diagnostic["domain"]["equal"]
    assert diagnostic["checkpoint_root_pid"] == diagnostic["domain"]["checkpoint_root_pid"]
    assert len(diagnostic["processes"]) >= 3
    latest_diagnostics = json.loads(machine.succeed(f"cat {state}/sessions/checkpoint/latest-diagnostics.json"))
    assert diagnostic_path.endswith(latest_diagnostics["report"])
    # An unrelated process placed in the managed cgroup is outside the
    # namespace-init tree and must make capture fail before CRIU runs.
    machine.succeed("systemd-run --unit=wss-outside sleep 300")
    machine.succeed("systemctl show wss-outside.service -p MainPID --value > /tmp/outside.pid")
    machine.succeed("cat /tmp/outside.pid > /sys/fs/cgroup/wss-checkpoint/cgroup.procs")
    machine.fail(f"${supervisor}/bin/wayland-session-supervisor capture {common} {command}")
    machine.succeed(
      f"jq -e --argjson pid $(cat /tmp/outside.pid) '.equal == false and "
      f"(.cgroup_pids | index($pid) != null) and (.tree_pids | index($pid) == null)' "
      f"{state}/sessions/checkpoint/checkpoints/failed-*/domain-inventory.json"
    )
    machine.succeed("kill $(cat /tmp/outside.pid)")
    machine.wait_until_succeeds("! grep -Fxq $(cat /tmp/outside.pid) /sys/fs/cgroup/wss-checkpoint/cgroup.procs")

    machine.fail(
      f"${supervisor}/bin/wayland-session-supervisor capture "
      f"--criu ${failingCriu} {common} {command}"
    )
    machine.succeed(
      f"jq -e '.status == \"failed\"' "
      f"{state}/sessions/checkpoint/checkpoints/failed-*/checkpoint.json"
    )
    machine.succeed(f"jq -e '.schema == 1 and .criu_exit_status != \"\"' {state}/sessions/checkpoint/checkpoints/failed-*/failure-analysis.json")
    machine.succeed(f"nsenter -t $(cat {state}/sessions/checkpoint/session.pid) -p kill -0 $(cat {state}/sessions/checkpoint/client.pid)")

    machine.succeed(
      f"${supervisor}/bin/wayland-session-supervisor capture {common} {command} || "
      f"{{ tail -100 {state}/sessions/checkpoint/checkpoints/failed-*/dump.log; exit 1; }}"
    )
    machine.wait_until_succeeds("systemctl is-failed wss-checkpoint.service")
    checkpoint_path = machine.succeed(
      f"printf '%s/checkpoints/%s' {state}/sessions/checkpoint "
      f"$(cat {state}/sessions/checkpoint/current-checkpoint)"
    ).strip()
    machine.succeed(f"jq -e --argjson orphan $(cat /tmp/orphan-host.pid) '.equal == true and .cgroup_pids == .tree_pids and (.tree_pids | index($orphan) != null)' {checkpoint_path}/domain-inventory.json")
    manifest = json.loads(machine.succeed(f"cat {checkpoint_path}/checkpoint.json"))
    assert manifest["status"] == "complete"
    assert manifest["images"]
    checkpoint_hash = machine.succeed(
      f"sha256sum {checkpoint_path}/checkpoint.json | cut -d' ' -f1"
    ).strip()

    machine.shutdown()
    machine.start()
    machine.wait_for_unit("multi-user.target")
    boot_after = machine.succeed("cat /proc/sys/kernel/random/boot_id").strip()
    assert boot_before != boot_after
    machine.fail(
      f"${supervisor}/bin/wayland-session-supervisor restore {common} /run/current-system/sw/bin/false"
    )
    failure = json.loads(machine.succeed(f"cat {checkpoint_path}/restore-failure.json"))
    assert failure["kind"] == "incompatible"
    assert "compatibility mismatch" in failure["reason"]
    assert machine.succeed(
      f"sha256sum {checkpoint_path}/checkpoint.json | cut -d' ' -f1"
    ).strip() == checkpoint_hash

    machine.succeed(
      "systemd-run --unit=wss-restored --service-type=exec "
      "--setenv=PATH=${
        pkgs.lib.makeBinPath [
          pkgs.coreutils
          criu
        ]
      } "
      f"${supervisor}/bin/wayland-session-supervisor restore {common} {command}"
    )
    machine.wait_until_succeeds(f"jq -e '.role == \"restored-session-authority\" and .boot_id == \"{boot_after}\"' {state}/sessions/checkpoint/outer-supervisor.json")
    machine.succeed("systemctl is-active wss-restored.service")
    assert machine.succeed(
      f"sha256sum {checkpoint_path}/checkpoint.json | cut -d' ' -f1"
    ).strip() == checkpoint_hash
    client_pid = machine.succeed(
      f"cat {state}/sessions/checkpoint/client.pid"
    ).strip()
    machine.wait_until_succeeds(f"for pid in $(cat /sys/fs/cgroup/wss-checkpoint/cgroup.procs); do n=$(awk '/^NSpid:/ {{print $NF}}' /proc/$pid/status 2>/dev/null); if test \"$n\" = {client_pid}; then kill -USR1 $pid && exit 0; fi; done; exit 1")
    machine.wait_until_succeeds(f"test $(jq -r .counter {client_json}) -eq 23064")
    after = json.loads(machine.succeed(f"cat {client_json}"))
    assert after["pid"] == before["pid"]
    assert after["token"] == before["token"]
    assert after["counter"] == before["counter"] + 1
    assert after["roundtrip_result"] >= 0
    machine.succeed("mkdir -p /tmp/checkpoint-evidence")
    machine.succeed(f"cp {checkpoint_path}/{{checkpoint.json,diagnostics.json,domain-inventory.json,restore-failure.json}} /tmp/checkpoint-evidence/")
    machine.succeed(f"find {state}/sessions/checkpoint/checkpoints/failed-* -name failure-analysis.json -exec cp {{}} /tmp/checkpoint-evidence/failure-analysis.json \\; -quit")
    machine.succeed(f"cp {state}/sessions/checkpoint/outer-supervisor.json /tmp/checkpoint-evidence/")
    machine.succeed(f"jq -n --argjson namespace_pid {orphan_namespace_pid} --argjson host_pid $(cat /tmp/orphan-host.pid) '{{schema:1,kind:\"double-forked-orphan\",namespace_pid:$namespace_pid,host_pid:$host_pid,present_in_equal_inventory:true}}' > /tmp/checkpoint-evidence/orphan.json")
    machine.succeed(f"find {state}/sessions/checkpoint/checkpoints/failed-* -name domain-inventory.json -exec jq -e '.equal == false' {{}} \\; -exec cp {{}} /tmp/checkpoint-evidence/refused-domain-inventory.json \\; -quit")
    machine.succeed("cat > /tmp/checkpoint-evidence/continuity-before.json <<'EOF'\n" + json.dumps(before, sort_keys=True, indent=2) + "\nEOF")
    machine.succeed("cat > /tmp/checkpoint-evidence/continuity-after.json <<'EOF'\n" + json.dumps(after, sort_keys=True, indent=2) + "\nEOF")
    machine.succeed(f"jq -n --arg before '{boot_before}' --arg after '{boot_after}' '{{schema:1,boot_before:$before,boot_after:$after,rebooted:($before != $after),verdict:\"pass\"}}' > /tmp/checkpoint-evidence/verdict.json")
    machine.copy_from_machine("/tmp/checkpoint-evidence", "")
  '';
}
