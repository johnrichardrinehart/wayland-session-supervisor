{
  pkgs,
  self,
  system,
}:
let
  stateClient = pkgs.stdenv.mkDerivation {
    pname = "checkpoint-state-client";
    version = "0.1.0";
    src = self + /tests/fixtures/wayland-state-client.c;
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
      wait "$client_pid" "$compositor_pid"
    '';
  };
  supervisor = self.packages.${system}.default;
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
      pkgs.criu
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
    machine.succeed(
      "systemd-run --unit=wss-checkpoint --service-type=exec "
      "--property=StandardOutput=null --property=StandardError=null "
      f"${supervisor}/bin/wayland-session-supervisor run "
      f"--session checkpoint --state-dir {state} --runtime-dir {runtime} -- {command}"
    )
    client_json = f"{state}/sessions/checkpoint/client.json"
    machine.wait_until_succeeds(f"test -s {client_json}")
    before = json.loads(machine.succeed(f"cat {client_json}"))
    supervisor_pid = machine.succeed(
      "systemctl show wss-checkpoint.service -p MainPID --value"
    ).strip()

    machine.fail(
      f"${supervisor}/bin/wayland-session-supervisor capture "
      f"--criu ${failingCriu} {common} {command}"
    )
    machine.succeed(
      f"jq -e '.status == \"failed\"' "
      f"{state}/sessions/checkpoint/checkpoints/failed-*/checkpoint.json"
    )
    machine.succeed(f"kill -0 $(cat {state}/sessions/checkpoint/client.pid)")

    machine.succeed(
      f"${supervisor}/bin/wayland-session-supervisor capture {common} {command}"
    )
    machine.wait_until_succeeds("systemctl is-failed wss-checkpoint.service")
    checkpoint_path = machine.succeed(
      f"printf '%s/checkpoints/%s' {state}/sessions/checkpoint "
      f"$(cat {state}/sessions/checkpoint/current-checkpoint)"
    ).strip()
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
    restore_caller = machine.succeed("echo $$").strip()
    assert restore_caller != supervisor_pid

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
      f"${supervisor}/bin/wayland-session-supervisor restore {common} {command} || "
      f"{{ cat {checkpoint_path}/restore.log; exit 1; }}"
    )
    assert machine.succeed(
      f"sha256sum {checkpoint_path}/checkpoint.json | cut -d' ' -f1"
    ).strip() == checkpoint_hash
    client_pid = machine.succeed(
      f"cat {state}/sessions/checkpoint/client.pid"
    ).strip()
    machine.succeed(f"kill -USR1 {client_pid}")
    machine.wait_until_succeeds(f"test $(jq -r .counter {client_json}) -eq 23064")
    after = json.loads(machine.succeed(f"cat {client_json}"))
    assert after["pid"] == before["pid"]
    assert after["token"] == before["token"]
    assert after["counter"] == before["counter"] + 1
    assert after["roundtrip_result"] >= 0
  '';
}
