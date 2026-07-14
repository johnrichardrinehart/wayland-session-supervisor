{
  pkgs,
  self,
  system,
}:
let
  criu = self.packages.${system}.our-criu;
  fixtureSources = pkgs.lib.fileset.toSource {
    root = ../..;
    fileset = ../../tests/fixtures/wayland-state-client.c;
  };
  stateClient = pkgs.stdenv.mkDerivation {
    pname = "wayland-state-client";
    version = "0.1.0";
    src = fixtureSources + /tests/fixtures/wayland-state-client.c;
    dontUnpack = true;
    strictDeps = true;
    nativeBuildInputs = [ pkgs.pkg-config ];
    buildInputs = [ pkgs.wayland ];
    buildPhase = ''
      cc $(pkg-config --cflags wayland-client) "$src" \
        $(pkg-config --libs wayland-client) -o wayland-state-client
    '';
    installPhase = ''
      install -Dm755 wayland-state-client $out/bin/wayland-state-client
    '';
  };
  sessionLauncher = pkgs.writeShellApplication {
    name = "feasibility-session";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.weston
      stateClient
    ];
    text = ''
      install -d -m 0700 /var/lib/wayland-session-supervisor/runtime
      export XDG_RUNTIME_DIR=/var/lib/wayland-session-supervisor/runtime
      export WAYLAND_DISPLAY=wayland-feasibility
      rm -f "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY.lock"

      weston --backend=headless-backend.so --socket="$WAYLAND_DISPLAY" \
        --idle-time=0 --log=/var/lib/wayland-session-supervisor/weston.log &
      compositor_pid=$!
      for _ in $(seq 1 100); do
        test -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" && break
        sleep 0.05
      done
      test -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY"

      wayland-state-client /var/lib/wayland-session-supervisor/client.json \
        exact-state-token-5d27cce1 &
      client_pid=$!
      printf '%s\n' "$client_pid" > /var/lib/wayland-session-supervisor/client.pid
      printf '%s\n' "$$" > /var/lib/wayland-session-supervisor/session.pid
      wait "$client_pid" "$compositor_pid"
    '';
  };
in
pkgs.testers.runNixOSTest {
  name = "wayland-session-supervisor-feasibility";

  nodes.machine = {
    virtualisation.memorySize = 2048;
    environment.systemPackages = [
      criu
      pkgs.jq
      sessionLauncher
    ];
    systemd.tmpfiles.rules = [
      "d /var/lib/wayland-session-supervisor 0700 root root -"
    ];
  };

  testScript = ''
    import json

    machine.start()
    machine.wait_for_unit("multi-user.target")
    boot_before = machine.succeed("cat /proc/sys/kernel/random/boot_id").strip()

    # Keep exact restored PIDs above the deterministic post-reboot service range.
    machine.succeed(
      "while test $(cat /proc/sys/kernel/ns_last_pid) -lt 4096; do "
      "/run/current-system/sw/bin/true; done"
    )
    machine.succeed(
      "systemd-run --unit=wss-feasibility --service-type=exec "
      "--property=StandardOutput=null --property=StandardError=null "
      "${sessionLauncher}/bin/feasibility-session"
    )
    machine.wait_until_succeeds("test -s /var/lib/wayland-session-supervisor/client.json")
    before = json.loads(machine.succeed("cat /var/lib/wayland-session-supervisor/client.json"))
    assert before["token"] == "exact-state-token-5d27cce1"
    assert before["counter"] == 0x5A17
    assert before["roundtrip_result"] >= 0

    machine.succeed("rm -rf /var/lib/wayland-session-supervisor/checkpoint")
    machine.succeed("mkdir -m 0700 /var/lib/wayland-session-supervisor/checkpoint")
    machine.succeed(
      "criu dump --tree $(cat /var/lib/wayland-session-supervisor/session.pid) "
      "--images-dir /var/lib/wayland-session-supervisor/checkpoint "
      "--shell-job --file-locks --log-file dump.log -v4 || "
      "{ cat /var/lib/wayland-session-supervisor/checkpoint/dump.log; exit 1; }"
    )
    machine.succeed("test -s /var/lib/wayland-session-supervisor/checkpoint/inventory.img")

    machine.shutdown()
    machine.start()
    machine.wait_for_unit("multi-user.target")
    boot_after = machine.succeed("cat /proc/sys/kernel/random/boot_id").strip()
    assert boot_before != boot_after, (boot_before, boot_after)

    machine.succeed(
      "criu restore --images-dir /var/lib/wayland-session-supervisor/checkpoint "
      "--shell-job --file-locks --restore-detached --log-file restore.log -v4 || "
      "{ cat /var/lib/wayland-session-supervisor/checkpoint/restore.log; exit 1; }"
    )
    client_pid = machine.succeed("cat /var/lib/wayland-session-supervisor/client.pid").strip()
    machine.succeed(f"kill -USR1 {client_pid}")
    machine.wait_until_succeeds(
      "test $(jq -r .counter /var/lib/wayland-session-supervisor/client.json) -eq 23064"
    )
    after = json.loads(machine.succeed("cat /var/lib/wayland-session-supervisor/client.json"))
    assert after["pid"] == before["pid"], (before, after)
    assert after["token"] == before["token"]
    assert after["counter"] == before["counter"] + 1
    assert after["roundtrip_result"] >= 0
  '';
}
