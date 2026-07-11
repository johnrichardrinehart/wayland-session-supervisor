{
  pkgs,
  self,
  system,
}:
let
  supervisor = self.packages.${system}.default;
  # CRIU 4.1.1 truncates a Sway page-transfer pipe at 408 of 440 pages.
  # Keep the newer backend local to this feasibility check until Nixpkgs
  # advances its default package.
  criu = pkgs.criu.overrideAttrs (old: {
    version = "4.2";
    # Upstream's descriptor generation has a parallel Make dependency race.
    enableParallelBuilding = false;
    postPatch = (old.postPatch or "") + ''
      substituteInPlace images/Makefile \
        --replace-fail 'protoc --proto_path=/usr/include --proto_path=$(obj)/ --c_out=$(obj)/ $<' \
        'protoc --proto_path=$(obj)/ --c_out=$(obj)/ $(DESCRIPTOR_DIR)/descriptor.proto'
    '';
    src = pkgs.fetchFromGitHub {
      owner = "checkpoint-restore";
      repo = "criu";
      rev = "v4.2";
      hash = "sha256-yZWIpCNTRG0LNGt01BvT3ILl3elzKtCfRKWR0rzJqAU=";
    };
  });
  pages = pkgs.runCommand "wss-browser-pages" { } ''
        mkdir -p $out
        for name in alpha beta gamma; do
          cat > $out/$name.html <<EOF
    <!doctype html><title>wss-$name</title><style>body{height:4000px}</style>
    <h1 id=id>wss-$name</h1><input id=memory><script>
    window.wssMemory = "memory-$name"; memory.value = window.wssMemory;
    scrollTo(0, { alpha: 311, beta: 622, gamma: 933 }["$name"]);
    </script>
    EOF
        done
  '';
  media =
    pkgs.runCommand "wss-deterministic-media" { nativeBuildInputs = [ pkgs.ffmpeg-headless ]; }
      ''
        mkdir -p $out
        ffmpeg -hide_banner -loglevel error -f lavfi -i testsrc2=size=320x180:rate=30 \
          -t 600 -c:v ffv1 $out/frames.mkv
        ffmpeg -hide_banner -loglevel error -f lavfi \
          -i 'sine=frequency=997:sample_rate=48000:duration=1800' -c:a pcm_s16le $out/samples.wav
      '';
  shellFixture = self + /tests/fixtures/application-shell.sh;
  session = pkgs.writeShellApplication {
    name = "application-session";
    runtimeInputs = with pkgs; [
      alsa-utils
      chromium
      coreutils
      curl
      dbus
      findutils
      foot
      jq
      mpv
      python3
      socat
      sway-unwrapped
      swaybg
      tmux
    ];
    text = ''
            exec 3<&- 4<&-
            export WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1
            export WLR_RENDERER=pixman
            export XDG_CURRENT_DESKTOP=sway
            state=$WSS_SESSION_STATE_DIR
            runtime=$XDG_RUNTIME_DIR
            exec >>"$state/application.log" 2>&1
            set -x
            cat > "$state/sway.conf" <<EOF
      output HEADLESS-1 resolution 1280x720
      xwayland disable
      seat seat0 fallback true
      workspace browser-left output HEADLESS-1
      workspace browser-right output HEADLESS-1
      for_window [title="wss-alpha"] floating enable, move position 10 20, resize set 600 500, move workspace browser-left
      for_window [title="wss-gamma"] floating enable, move position 650 30, resize set 600 500, move workspace browser-right
      EOF
            ${pkgs.sway-unwrapped}/bin/sway --unsupported-gpu -c "$state/sway.conf" -V >"$state/sway.log" 2>&1 &
            for _ in $(seq 1 200); do
              SWAYSOCK=$(find "$runtime" -maxdepth 1 -name 'sway-ipc.*.sock' -print -quit)
              test -n "$SWAYSOCK" && break
              sleep .05
            done
            test -n "$SWAYSOCK" || { cat "$state/sway.log" >&2; exit 1; }
            export SWAYSOCK
            printf '%s\n' "$SWAYSOCK" > "$state/swaysock"
            WAYLAND_DISPLAY=$(basename "$(find "$runtime" -maxdepth 1 -type s -name 'wayland-[0-9]*' -print -quit)")
            export WAYLAND_DISPLAY
            swaymsg -t get_version >/dev/null

            # The managed domain must not retain connections to host D-Bus
            # daemons that disappear at reboot. Chromium tolerates unavailable
            # buses and keeps the tested page/session state internally.
            export DBUS_SYSTEM_BUS_ADDRESS="unix:path=$runtime/no-system-bus"
            export DBUS_SESSION_BUS_ADDRESS="unix:path=$runtime/no-session-bus"
            export NO_AT_BRIDGE=1
            mkdir -p "$runtime/chromium" "$state/chromium"
            chromium --ozone-platform=wayland --no-sandbox --no-zygote --single-process --disable-gpu --disable-dev-shm-usage \
              --disable-background-networking --disable-component-update --disable-sync \
              --disable-features=Translate,MediaRouter --no-first-run --no-default-browser-check \
              --disable-session-crashed-bubble --user-data-dir="$runtime/chromium" \
              --remote-debugging-port=9222 --remote-allow-origins=http://127.0.0.1:9222 --new-window \
              "file://${pages}/alpha.html" "file://${pages}/beta.html" >"$state/chromium.log" 2>&1 &
            for _ in $(seq 1 200); do curl -fsS http://127.0.0.1:9222/json/version >/dev/null && break; sleep .05; done
            chromium --ozone-platform=wayland --no-sandbox --user-data-dir="$runtime/chromium" \
              --new-window "file://${pages}/gamma.html" >/dev/null 2>&1 || true

            mkfifo "$runtime/shell-control"
            # Keep the tmux server as a real child of the managed domain;
            # normal auto-start daemonization reparents it outside --tree.
            tmux -D -S "$runtime/tmux.sock" >"$state/tmux.log" 2>&1 &
            for _ in $(seq 1 200); do test -S "$runtime/tmux.sock" && break; sleep .05; done
            tmux -S "$runtime/tmux.sock" new-session -d \
              "exec ${pkgs.bash}/bin/bash -x ${shellFixture} $state/shell.json $runtime/shell-control 2>$state/shell-error.log"
            foot --log-level=error -- \
              tmux -S "$runtime/tmux.sock" attach-session \
              >"$state/terminal.log" 2>&1 &

            mpv --no-config --vo=null --ao=null --pause --start=4 --input-ipc-server="$runtime/mpv.sock" \
              --no-resume-playback --loop-file=inf "${media}/frames.mkv" >/dev/null 2>&1 &

            mkfifo "$runtime/audio.pcm"
            cat > "$state/asound.conf" <<EOF
      pcm.null { type null; }
      pcm.!default { type file; slave.pcm "null"; file "$runtime/audio.pcm"; format "raw"; }
      EOF
            python3 - "$runtime/audio.pcm" "$state/audio.json" <<'PY' &
      import json, os, sys, time
      fifo, probe = sys.argv[1:]
      count = 0
      with open(fifo, 'rb', buffering=0) as source:
          while True:
              chunk = source.read(9600)
              if not chunk: break
              count += len(chunk) // 2
              temporary = probe + '.tmp'
              with open(temporary, 'w') as output:
                  json.dump({'pid': os.getpid(), 'stream_id': 'wss-aplay-stream', 'consumed_samples': count}, output)
              os.replace(temporary, probe)
              time.sleep(len(chunk) / 2 / 48000)
      PY
            ALSA_CONFIG_PATH="$state/asound.conf" aplay -q "${media}/samples.wav" &

            wait
    '';
  };
  probe =
    pkgs.writers.writePython3Bin "application-probe"
      {
        libraries = [ pkgs.python3Packages.websocket-client ];
        flakeIgnore = [
          "E121"
          "E128"
          "E231"
          "E302"
          "E305"
          "E401"
          "E501"
          "E701"
        ];
      }
      ''
        import hashlib, json, os, subprocess, sys, urllib.request
        from websocket import create_connection

        phase, destination = sys.argv[1:]
        def command(*args):
            return subprocess.check_output(args, text=True)
        targets = json.load(urllib.request.urlopen('http://127.0.0.1:9222/json/list'))
        tabs = []
        for target in targets:
            if target.get('type') != 'page' or 'wss-' not in target.get('title', ""):
                continue
            ws = create_connection(target['webSocketDebuggerUrl'])
            ws.send(json.dumps({'id': 1, 'method': 'Runtime.evaluate', 'params': {
              'expression': 'JSON.stringify({memory:window.wssMemory,value:memory.value,scrollY:scrollY})',
              'returnByValue': True}}))
            while True:
                reply = json.loads(ws.recv())
                if reply.get('id') == 1: break
            state = json.loads(reply['result']['result']['value'])
            ws.send(json.dumps({'id': 2, 'method': 'Browser.getWindowForTarget', 'params': {'targetId': target['id']}}))
            while True:
                window = json.loads(ws.recv())
                if window.get('id') == 2: break
            ws.close()
            tabs.append({'title': target['title'], 'url': target['url'], 'window_id': window['result']['windowId'], **state})
        tabs.sort(key=lambda item: item['title'])
        tree = json.loads(command('swaymsg', '-s', open('/var/lib/wayland-session-supervisor/sessions/apps/swaysock').read().strip(), '-r', '-t', 'get_tree'))
        placements = []
        def visit(node, workspace=None):
            if node.get('type') == 'workspace': workspace = node.get('name')
            if (node.get('name') or "").startswith('wss-'):
                placements.append({'title': node['name'], 'workspace': workspace, 'rect': node['rect']})
            for child in node.get('nodes', []) + node.get('floating_nodes', []): visit(child, workspace)
        visit(tree)
        text = command('tmux', '-S', '/run/wayland-session-supervisor/apps/tmux.sock', 'capture-pane', '-p', '-S', '-')
        shell = json.load(open('/var/lib/wayland-session-supervisor/sessions/apps/shell.json'))
        query = json.dumps({'command': ['get_property', 'time-pos']}) + chr(10)
        mpv_time = float(json.loads(subprocess.check_output(['socat', '-', 'UNIX-CONNECT:/run/wayland-session-supervisor/apps/mpv.sock'], input=query, text=True))['data'])
        audio = json.load(open('/var/lib/wayland-session-supervisor/sessions/apps/audio.json'))
        evidence = {'schema': 1, 'phase': phase, 'browser': {'tabs': tabs, 'placements': sorted(placements, key=lambda x:x['title'])},
          'terminal': {'text_sha256': hashlib.sha256(text.encode()).hexdigest(), 'contains_first': 'terminal-scrollback-line-001' in text, 'contains_last': 'terminal-scrollback-line-120' in text},
          'shell': shell, 'mpv': {'time': mpv_time, 'frame': round(mpv_time * 30), 'media': '${media}/frames.mkv'},
          'aplay': audio}
        with open(destination + '.tmp', 'w') as output: json.dump(evidence, output, sort_keys=True, indent=2)
        os.replace(destination + '.tmp', destination)
      '';
  command = "${session}/bin/application-session";
in
pkgs.testers.runNixOSTest {
  name = "wayland-session-supervisor-application-reboot";
  nodes.machine = {
    virtualisation.memorySize = 6144;
    virtualisation.cores = 4;
    boot.kernel.sysctl = {
      "fs.pipe-max-size" = 4194304;
      # Chromium keeps many IPC pipes open. Do not let the per-user soft quota
      # shrink CRIU's page-transfer pipes while the process tree is frozen.
      "fs.pipe-user-pages-soft" = 0;
      "fs.pipe-user-pages-hard" = 0;
    };
    environment.systemPackages = [
      criu
      pkgs.jq
      pkgs.socat
      pkgs.sway
      pkgs.tmux
      probe
      supervisor
    ];
  };
  testScript = ''
    import json
    state = "/var/lib/wayland-session-supervisor"
    common = f"--session apps --state-dir {state} --"
    command = "${command}"
    machine.start()
    machine.wait_for_unit("multi-user.target")
    boot_before = machine.succeed("cat /proc/sys/kernel/random/boot_id").strip()
    machine.succeed("systemd-run --unit=wss-apps --service-type=exec --property=StandardOutput=null --property=StandardError=null "
      f"${supervisor}/bin/wayland-session-supervisor run --session apps --state-dir {state} --runtime-dir /run/wayland-session-supervisor -- {command}")
    machine.sleep(30)
    machine.succeed("systemctl is-active wss-apps.service || { cat /var/lib/wayland-session-supervisor/sessions/apps/sway.log; exit 1; }")
    machine.sleep(30)
    machine.succeed("test -S /run/wayland-session-supervisor/apps/mpv.sock && test -s /var/lib/wayland-session-supervisor/sessions/apps/audio.json || { cat /var/lib/wayland-session-supervisor/sessions/apps/{application,chromium,sway}.log; exit 1; }")
    machine.wait_until_succeeds("test $(curl -s http://127.0.0.1:9222/json/list | jq '[.[]|select(.title|startswith(\"wss-\"))]|length') -eq 3")
    machine.succeed("test -s /var/lib/wayland-session-supervisor/sessions/apps/shell.json || { cat /var/lib/wayland-session-supervisor/sessions/apps/{terminal,shell-error}.log; ps auxww; ${pkgs.tmux}/bin/tmux -S /run/wayland-session-supervisor/apps/tmux.sock capture-pane -p -S - || true; exit 1; }")
    machine.succeed("tmux -S /run/wayland-session-supervisor/apps/tmux.sock send-keys 'kill -USR1 $$' Enter; sleep 1")
    machine.succeed("application-probe before /var/lib/wayland-session-supervisor/before.json")
    before = json.loads(machine.succeed("cat /var/lib/wayland-session-supervisor/before.json"))
    assert len(before['browser']['tabs']) == 3
    assert len(set(tab['window_id'] for tab in before['browser']['tabs'])) == 2
    assert before['terminal']['contains_first'] and before['terminal']['contains_last']
    machine.succeed(f"${supervisor}/bin/wayland-session-supervisor capture {common} {command} || {{ tail -100 {state}/sessions/apps/checkpoints/failed-*/dump.log; exit 1; }}")
    machine.wait_until_succeeds("systemctl is-failed wss-apps.service")
    machine.shutdown()
    machine.start()
    machine.wait_for_unit("multi-user.target")
    assert boot_before != machine.succeed("cat /proc/sys/kernel/random/boot_id").strip()
    machine.succeed(f"${supervisor}/bin/wayland-session-supervisor restore {common} {command} || (cat {state}/sessions/apps/checkpoints/$(cat {state}/sessions/apps/current-checkpoint)/restore.log; false)")
    machine.wait_until_succeeds("curl -fsS http://127.0.0.1:9222/json/list >/dev/null")
    machine.succeed("application-probe after /var/lib/wayland-session-supervisor/after.json")
    after = json.loads(machine.succeed("cat /var/lib/wayland-session-supervisor/after.json"))
    assert before['browser'] == after['browser'], (before['browser'], after['browser'])
    assert after['terminal']['contains_first'] and after['terminal']['contains_last'], after['terminal']
    assert before['shell'] == after['shell'], (before['shell'], after['shell'])
    assert abs(before['mpv']['frame'] - after['mpv']['frame']) <= 60
    assert before['mpv']['media'] == after['mpv']['media']
    assert before['aplay']['pid'] == after['aplay']['pid']
    assert before['aplay']['stream_id'] == after['aplay']['stream_id']
    assert abs(before['aplay']['consumed_samples'] - after['aplay']['consumed_samples']) <= 500000
    machine.succeed("mkdir -p /tmp/evidence && cp /var/lib/wayland-session-supervisor/{before,after}.json /tmp/evidence/ && touch /tmp/evidence/verdict-pass")
  '';
}
