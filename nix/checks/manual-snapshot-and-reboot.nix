{
  pkgs,
  self,
  system,
}:
let
  supervisor = self.packages.${system}.default;
  # Nixpkgs CRIU 4.1.1 truncates this workload's page-transfer pipe.
  criu = self.packages.${system}.our-criu;
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
  shellSources = pkgs.lib.fileset.toSource {
    root = ../..;
    fileset = ../../tests/fixtures/application-shell.sh;
  };
  shellFixture = shellSources + /tests/fixtures/application-shell.sh;
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
            mkdir -p /var/lib/wayland-session-supervisor/shell-cwd
            # Keep the tmux server as a real child of the managed domain;
            # normal auto-start daemonization reparents it outside --tree.
            tmux -D -S "$runtime/tmux.sock" >"$state/tmux.log" 2>&1 &
            for _ in $(seq 1 200); do test -S "$runtime/tmux.sock" && break; sleep .05; done
            tmux -S "$runtime/tmux.sock" new-session -d -c /var/lib/wayland-session-supervisor/shell-cwd \
              "exec ${pkgs.bash}/bin/bash -x ${shellFixture} $state/shell.json $runtime/shell-control 2>$state/shell-error.log"
            tmux -S "$runtime/tmux.sock" set-environment -g WSS_TMUX_ENV preserved-across-reboot
            foot --log-level=error -- \
              tmux -S "$runtime/tmux.sock" attach-session \
              >"$state/terminal.log" 2>&1 &
            # Child shell expands the restored environment.
            # shellcheck disable=SC2016
            foot --log-level=error --title=restored-input-target --app-id=restored-input-target -- \
              ${pkgs.bash}/bin/bash -c 'printf "input-ready\\n"; IFS= read -r value; printf "%s" "$value" > "$WSS_SESSION_STATE_DIR/input-delivered"' \
              >"$state/input-target.log" 2>&1 &

            mpv --no-config --vo=null --ao=null --pause --start=4 --input-ipc-server="$runtime/mpv.sock" \
              --no-resume-playback --loop-file=inf "${media}/frames.mkv" >/dev/null 2>&1 &

            python3 - "$runtime/adapter-ingress.log" "$state/input.json" <<'PY' &
      import json, os, sys, time
      events, probe = sys.argv[1:]
      offset = 0
      counter = 0
      while True:
          try:
              with open(events) as source:
                  source.seek(offset)
                  for line in source:
                      counter += 1
                      temporary = probe + '.tmp'
                      with open(temporary, 'w') as output:
                          json.dump({'pid': os.getpid(), 'counter': counter, 'last_event': line.strip()}, output)
                      os.replace(temporary, probe)
                  offset = source.tell()
          except FileNotFoundError:
              pass
          time.sleep(.05)
      PY

            mkfifo "$runtime/audio.pcm"
            cat > "$state/asound.conf" <<EOF
      pcm.null { type null; }
      pcm.!default { type file; slave.pcm "null"; file "$runtime/audio.pcm"; format "raw"; }
      EOF
            python3 - "$runtime/audio.pcm" "$WSS_EGRESS_SPOOL" "$state/audio.json" <<'PY' &
      import hashlib, json, os, sys, time
      fifo, spool_path, probe = sys.argv[1:]
      count = 0
      with open(fifo, 'rb', buffering=0) as source, open(spool_path, 'ab', buffering=0) as spool:
          while True:
              chunk = source.read(9600)
              if not chunk: break
              spool.write(chunk)
              count += len(chunk) // 2
              temporary = probe + '.tmp'
              with open(temporary, 'w') as output:
                  json.dump({'pid': os.getpid(), 'stream_id': 'wss-aplay-stream', 'consumed_samples': count,
                    'chunk_samples': len(chunk) // 2, 'waveform_sha256': hashlib.sha256(chunk).hexdigest(),
                    'adapter_spool_bytes': spool.tell()}, output)
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
        import hashlib, json, os, subprocess, sys, urllib.request, wave
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
              'expression': 'JSON.stringify({memory:window.wssMemory,value:memory.value,scrollY:scrollY,visibility:document.visibilityState})',
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
        windows = []
        for window_id in sorted(set(tab['window_id'] for tab in tabs)):
            members = [tab['title'] for tab in tabs if tab['window_id'] == window_id]
            selected = [tab['title'] for tab in tabs if tab['window_id'] == window_id and tab['visibility'] == 'visible']
            windows.append({'window_id': window_id, 'tabs': members, 'selected_tabs': selected})
        chromium = []
        for proc in os.listdir('/proc'):
            if not proc.isdigit(): continue
            try:
                cmdline = open(f'/proc/{proc}/cmdline', 'rb').read().decode(errors='replace')
                if 'chromium' in cmdline and '--user-data-dir=' in cmdline:
                    stat = open(f'/proc/{proc}/stat').read().split()
                    nspid = [line for line in open(f'/proc/{proc}/status') if line.startswith('NSpid:')][0].split()[-1]
                    chromium.append({'host_pid': int(proc), 'namespace_pid': int(nspid), 'starttime': int(stat[21]), 'cmdline_sha256': hashlib.sha256(cmdline.encode()).hexdigest()})
            except (FileNotFoundError, ProcessLookupError, PermissionError): pass
        tree = json.loads(command('swaymsg', '-s', open('/var/lib/wayland-session-supervisor/sessions/apps/swaysock').read().strip(), '-r', '-t', 'get_tree'))
        placements = []
        def visit(node, workspace=None):
            if node.get('type') == 'workspace': workspace = node.get('name')
            if (node.get('name') or "").startswith('wss-'):
                placements.append({'title': node['name'], 'workspace': workspace, 'rect': node['rect']})
            for child in node.get('nodes', []) + node.get('floating_nodes', []): visit(child, workspace)
        visit(tree)
        text = command('tmux', '-S', '/run/wayland-session-supervisor/apps/tmux.sock', 'capture-pane', '-p', '-S', '-')
        tmux_socket = '/run/wayland-session-supervisor/apps/tmux.sock'
        panes = []
        for row in command('tmux', '-S', tmux_socket, 'list-panes', '-a', '-F', '#{session_name}|#{window_index}|#{pane_index}|#{pane_pid}').splitlines():
            session_name, window_index, pane_index, namespace_pid = row.split('|')
            actual_cwd = None
            for proc in os.listdir('/proc'):
                if not proc.isdigit(): continue
                try:
                    nspid = [line for line in open(f'/proc/{proc}/status') if line.startswith('NSpid:')][0].split()[-1]
                    cgroup = open(f'/proc/{proc}/cgroup').read()
                    if nspid == namespace_pid and '/wss-apps' in cgroup:
                        actual_cwd = os.readlink(f'/proc/{proc}/cwd')
                        break
                except (FileNotFoundError, ProcessLookupError, PermissionError): pass
            panes.append({'session': session_name, 'window_index': int(window_index), 'pane_index': int(pane_index), 'namespace_pid': int(namespace_pid), 'cwd': actual_cwd})
        tmux_state = {
          'sessions': command('tmux', '-S', tmux_socket, 'list-sessions', '-F', '#{session_name}|#{session_windows}|#{session_attached}').splitlines(),
          'windows': command('tmux', '-S', tmux_socket, 'list-windows', '-a', '-F', '#{session_name}|#{window_index}|#{window_name}|#{window_panes}|#{window_layout}').splitlines(),
          'panes': panes,
          'environment': sorted(command('tmux', '-S', tmux_socket, 'show-environment', '-g').splitlines()),
        }
        tmux = json.dumps(tmux_state, sort_keys=True)
        terminal_lines = text.splitlines()
        while terminal_lines and not terminal_lines[-1]: terminal_lines.pop()
        terminal_text = chr(10).join(terminal_lines)
        scrollback = [line for line in terminal_lines if line.startswith('terminal-scrollback-line-')]
        shell = json.load(open('/var/lib/wayland-session-supervisor/sessions/apps/shell.json'))
        query = json.dumps({'command': ['get_property', 'time-pos']}) + chr(10)
        mpv_time = float(json.loads(subprocess.check_output(['socat', '-', 'UNIX-CONNECT:/run/wayland-session-supervisor/apps/mpv.sock'], input=query, text=True))['data'])
        audio = json.load(open('/var/lib/wayland-session-supervisor/sessions/apps/audio.json'))
        with wave.open('${media}/samples.wav', 'rb') as source:
            expected = source.readframes(audio['consumed_samples'])[-audio['chunk_samples'] * 2:]
        audio['expected_waveform_sha256'] = hashlib.sha256(expected).hexdigest()
        audio['waveform_valid'] = audio['waveform_sha256'] == audio['expected_waveform_sha256']
        with open('/run/wayland-session-supervisor/apps/adapter-egress.stream', 'rb') as spool:
            spool.seek(audio['adapter_spool_bytes'] - audio['chunk_samples'] * 2)
            audio['adapter_spool_sha256'] = hashlib.sha256(spool.read(audio['chunk_samples'] * 2)).hexdigest()
        audio['adapter_spool_valid'] = audio['adapter_spool_sha256'] == audio['waveform_sha256']
        input_state = json.load(open('/var/lib/wayland-session-supervisor/sessions/apps/input.json'))
        evidence = {'schema': 1, 'phase': phase, 'browser': {'tabs': tabs, 'windows': windows, 'placements': sorted(placements, key=lambda x:x['title']), 'processes': sorted(chromium, key=lambda x:x['namespace_pid'])},
          'terminal': {'contents': terminal_lines, 'text_sha256': hashlib.sha256(terminal_text.encode()).hexdigest(), 'line_count': len(terminal_lines), 'scrollback_sha256': hashlib.sha256(chr(10).join(scrollback).encode()).hexdigest(), 'scrollback_line_count': len(scrollback), 'contains_first': 'terminal-scrollback-line-001' in text, 'contains_last': 'terminal-scrollback-line-120' in text, 'tmux_sha256': hashlib.sha256(tmux.encode()).hexdigest(), 'tmux_state': tmux_state},
          'shell': shell, 'mpv': {'time': mpv_time, 'frame': round(mpv_time * 30), 'media': '${media}/frames.mkv'},
          'aplay': audio, 'input': input_state}
        with open(destination + '.tmp', 'w') as output: json.dump(evidence, output, sort_keys=True, indent=2)
        os.replace(destination + '.tmp', destination)
      '';
  command = "${session}/bin/application-session";
in
pkgs.testers.runNixOSTest {
  name = "wayland-session-supervisor-manual-snapshot-and-reboot";
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
      pkgs.coreutils
      pkgs.jq
      pkgs.socat
      pkgs.sway
      pkgs.tmux
      pkgs.wtype
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
    machine.succeed("mkdir /sys/fs/cgroup/wss-apps")
    machine.succeed("systemd-run --unit=wss-apps --service-type=exec --property=StandardOutput=null --property=StandardError=null "
      f"${supervisor}/bin/wayland-session-supervisor run --session apps --state-dir {state} --runtime-dir /run/wayland-session-supervisor "
      f"--cgroup-dir /sys/fs/cgroup/wss-apps -- {command}")
    machine.sleep(30)
    machine.succeed("systemctl is-active wss-apps.service || { cat /var/lib/wayland-session-supervisor/sessions/apps/sway.log; exit 1; }")
    machine.succeed("swaymsg -s $(cat /var/lib/wayland-session-supervisor/sessions/apps/swaysock) -t get_tree | jq -e '.. | objects | select(.app_id? == \"restored-input-target\")' || { cat /var/lib/wayland-session-supervisor/sessions/apps/input-target.log; exit 1; }")
    machine.sleep(30)
    machine.succeed("test -S /run/wayland-session-supervisor/apps/mpv.sock && test -s /var/lib/wayland-session-supervisor/sessions/apps/audio.json || { cat /var/lib/wayland-session-supervisor/sessions/apps/{application,chromium,sway}.log; exit 1; }")
    machine.wait_until_succeeds("test $(curl -s http://127.0.0.1:9222/json/list | jq '[.[]|select(.title|startswith(\"wss-\"))]|length') -eq 3")
    machine.succeed("test -s /var/lib/wayland-session-supervisor/sessions/apps/shell.json || { cat /var/lib/wayland-session-supervisor/sessions/apps/{terminal,shell-error}.log; ps auxww; ${pkgs.tmux}/bin/tmux -S /run/wayland-session-supervisor/apps/tmux.sock capture-pane -p -S - || true; exit 1; }")
    machine.succeed("printf 'key:before-capture' | socat - UNIX-SENDTO:/run/wayland-session-supervisor/apps/control.sock")
    machine.wait_until_succeeds(f"jq -e '.counter == 1 and .last_event == \"key:before-capture\"' {state}/sessions/apps/input.json")
    machine.wait_until_succeeds(f"test $(stat -c %s /run/wayland-session-supervisor/apps/adapter-egress.stream) -eq $(jq -r .adapter_spool_bytes {state}/sessions/apps/audio.json)")
    machine.succeed("application-probe before /var/lib/wayland-session-supervisor/before.json")
    before = json.loads(machine.succeed("cat /var/lib/wayland-session-supervisor/before.json"))
    assert len(before['browser']['tabs']) == 3
    assert len(set(tab['window_id'] for tab in before['browser']['tabs'])) == 2
    assert before['terminal']['contains_first'] and before['terminal']['contains_last']
    assert before['terminal']['tmux_state']['panes'][0]['cwd'] == '/var/lib/wayland-session-supervisor/shell-cwd'
    assert 'WSS_TMUX_ENV=preserved-across-reboot' in before['terminal']['tmux_state']['environment']
    machine.succeed(f"${supervisor}/bin/wayland-session-supervisor capture {common} {command} || {{ tail -100 {state}/sessions/apps/checkpoints/failed-*/dump.log; exit 1; }}")
    machine.wait_until_succeeds("systemctl is-failed wss-apps.service")
    machine.shutdown()
    machine.start()
    machine.wait_for_unit("multi-user.target")
    assert boot_before != machine.succeed("cat /proc/sys/kernel/random/boot_id").strip()
    boot_after = machine.succeed("cat /proc/sys/kernel/random/boot_id").strip()
    machine.succeed("systemd-run --unit=wss-apps-restored --service-type=exec "
      "--setenv=PATH=${
        pkgs.lib.makeBinPath [
          pkgs.coreutils
          pkgs.wtype
          criu
        ]
      } "
      f"${supervisor}/bin/wayland-session-supervisor restore {common} {command}")
    machine.wait_until_succeeds(f"jq -e '.role == \"restored-session-authority\" and .boot_id == \"{boot_after}\"' {state}/sessions/apps/outer-supervisor.json")
    machine.succeed("systemctl is-active wss-apps-restored.service")
    machine.wait_until_succeeds("curl -fsS http://127.0.0.1:9222/json/list >/dev/null")
    swaysock = machine.succeed(f"cat {state}/sessions/apps/swaysock").strip()
    machine.succeed(f"swaymsg -s {swaysock} -r -t get_seats | jq -e '.[0].devices != null'")
    machine.succeed("printf 'key:after-restore' | socat - UNIX-SENDTO:/run/wayland-session-supervisor/apps/control.sock")
    machine.wait_until_succeeds(f"jq -e '.counter == 2 and .last_event == \"key:after-restore\"' {state}/sessions/apps/input.json")
    machine.succeed(f"swaymsg -s {swaysock} '[app_id=\"restored-input-target\"] focus'")
    machine.wait_until_succeeds(f"swaymsg -s {swaysock} -r -t get_tree | jq -e '.. | objects | select(.app_id? == \"restored-input-target\" and .focused == true)'")
    machine.succeed("printf 'restored-through-sway' | socat - UNIX-SENDTO:/run/wayland-session-supervisor/apps/input.sock")
    machine.succeed(f"for _ in $(seq 1 100); do grep -Fx 'restored-through-sway' {state}/sessions/apps/input-delivered && exit 0; sleep .1; done; cat /run/wayland-session-supervisor/apps/input-adapter.log >&2; cat {state}/sessions/apps/input-target.log >&2; exit 1")
    machine.wait_until_succeeds(f"test $(stat -c %s /run/wayland-session-supervisor/apps/adapter-egress.stream) -eq $(jq -r .adapter_spool_bytes {state}/sessions/apps/audio.json)")
    machine.succeed("XDG_RUNTIME_DIR=/run/wayland-session-supervisor/apps WAYLAND_DISPLAY=wayland-1 ${pkgs.foot}/bin/foot --title post-restore-client ${pkgs.coreutils}/bin/sleep 300 >/dev/null 2>&1 &")
    machine.wait_until_succeeds(f"swaymsg -s {swaysock} -r -t get_tree | jq -e '.. | objects | select(.name? == \"post-restore-client\")'")
    machine.succeed("application-probe after /var/lib/wayland-session-supervisor/after.json")
    after = json.loads(machine.succeed("cat /var/lib/wayland-session-supervisor/after.json"))
    before_browser = {key: value for key, value in before['browser'].items() if key != 'processes'}
    after_browser = {key: value for key, value in after['browser'].items() if key != 'processes'}
    assert before_browser == after_browser, (before_browser, after_browser)
    before_processes = [(p['namespace_pid'], p['cmdline_sha256']) for p in before['browser']['processes']]
    after_processes = [(p['namespace_pid'], p['cmdline_sha256']) for p in after['browser']['processes']]
    assert before_processes == after_processes, (before_processes, after_processes)
    assert before['terminal']['text_sha256'] == after['terminal']['text_sha256'], (before['terminal'], after['terminal'])
    assert before['terminal']['line_count'] == after['terminal']['line_count'], (before['terminal'], after['terminal'])
    assert before['terminal']['scrollback_sha256'] == after['terminal']['scrollback_sha256'], (before['terminal'], after['terminal'])
    assert before['terminal']['scrollback_line_count'] == after['terminal']['scrollback_line_count'] == 120, (before['terminal'], after['terminal'])
    assert before['terminal']['tmux_state'] == after['terminal']['tmux_state']
    assert before['shell'] == after['shell'], (before['shell'], after['shell'])
    assert abs(before['mpv']['frame'] - after['mpv']['frame']) <= 60
    assert before['mpv']['media'] == after['mpv']['media']
    assert before['aplay']['waveform_valid'] and after['aplay']['waveform_valid']
    assert before['aplay']['adapter_spool_valid'] and after['aplay']['adapter_spool_valid']
    assert before['aplay']['pid'] == after['aplay']['pid']
    assert before['aplay']['stream_id'] == after['aplay']['stream_id']
    assert abs(before['aplay']['consumed_samples'] - after['aplay']['consumed_samples']) <= 500000
    assert before['input']['pid'] == after['input']['pid']
    assert after['input']['counter'] == before['input']['counter'] + 1
    machine.succeed(f"mkdir -p /tmp/evidence && cp {state}/{{before,after}}.json /tmp/evidence/ && cp {state}/sessions/apps/outer-supervisor.json /tmp/evidence/")
    machine.succeed(f"cp {state}/sessions/apps/checkpoints/$(cat {state}/sessions/apps/current-checkpoint)/domain-inventory.json /tmp/evidence/")
    machine.succeed(f"jq -n --arg before '{boot_before}' --arg after '{boot_after}' '{{schema:1,boot_before:$before,boot_after:$after,rebooted:($before != $after),input_via_compositor:true,input_payload:\"restored-through-sway\",verdict:\"pass\"}}' > /tmp/evidence/verdict.json")
    machine.copy_from_machine("/tmp/evidence", "")
  '';
}
