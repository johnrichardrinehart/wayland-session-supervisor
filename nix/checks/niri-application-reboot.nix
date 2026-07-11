{
  pkgs,
  self,
  system,
}:
let
  pythonIgnores = [
    "E128"
    "E201"
    "E202"
    "E225"
    "E226"
    "E231"
    "E302"
    "E305"
    "E401"
    "E501"
    "E701"
    "E702"
  ];
  criu = self.packages.${system}.our-criu;
  pages = pkgs.runCommand "niri-firefox-pages" { } ''
    mkdir -p $out
    cat >$out/alpha.html <<'EOF'
    <!doctype html><title>niri-alpha</title><h1>alpha</h1><script>window.memoryOnly='alpha-memory-token';</script>
    EOF
    cat >$out/beta.html <<'EOF'
    <!doctype html><title>niri-beta</title><h1>beta</h1><script>window.memoryOnly='beta-memory-token';</script>
    EOF
    cat >$out/gamma.html <<'EOF'
    <!doctype html><title>niri-gamma</title><h1>gamma</h1><script>window.memoryOnly='gamma-memory-token';</script>
    EOF
  '';
  zshFixture = pkgs.writeText "niri-zsh-fixture.zsh" ''
    setopt interactivecomments
    mkdir -p /var/lib/wayland-session-supervisor/niri-zsh-cwd
    cd /var/lib/wayland-session-supervisor/niri-zsh-cwd
    export WSS_ZSH_EXPORTED=preserved-zsh-environment
    typeset WSS_ZSH_LOCAL=preserved-zsh-local
    for n in {001..080}; do print -r -- "niri-kitty-scrollback-$n"; done
    print -s 'print niri-zsh-history-alpha'
    sleep 100000 &
    WSS_ZSH_JOB=$!
    false
    WSS_ZSH_STATUS=$?
    write_state() {
      print -r -- "{\"pid\":$$,\"cwd\":\"$PWD\",\"exported\":\"$WSS_ZSH_EXPORTED\",\"local\":\"$WSS_ZSH_LOCAL\",\"job_pid\":$WSS_ZSH_JOB,\"job_alive\":true,\"last_status\":$WSS_ZSH_STATUS,\"history\":\"$(fc -l -2 | sha256sum | cut -d' ' -f1)\"}" > "$WSS_SESSION_STATE_DIR/zsh.json.tmp"
      mv "$WSS_SESSION_STATE_DIR/zsh.json.tmp" "$WSS_SESSION_STATE_DIR/zsh.json"
    }
    TRAPUSR1() { write_state }
    write_state
    while read -r value; do [[ $value == exit ]] && break; done < "$XDG_RUNTIME_DIR/zsh-control"
  '';
  firefoxDriver =
    pkgs.writers.writePython3Bin "niri-firefox-driver" { flakeIgnore = pythonIgnores; }
      ''
        import http.client, json, os, subprocess, time
        state = os.environ['WSS_SESSION_STATE_DIR']
        runtime = os.environ['XDG_RUNTIME_DIR']
        os.makedirs(runtime + '/firefox-profile', exist_ok=True)
        gecko = subprocess.Popen(['${pkgs.geckodriver}/bin/geckodriver', '--host', '127.0.0.1', '--port', '4444', '--profile-root', runtime])
        def request(method, path, body=None):
            for _ in range(200):
                try:
                    conn = http.client.HTTPConnection('127.0.0.1', 4444, timeout=120)
                    conn.request(method, path, json.dumps(body) if body is not None else None, {'Content-Type': 'application/json'})
                    reply = json.loads(conn.getresponse().read())
                    if 'value' in reply:
                        if isinstance(reply['value'], dict) and 'error' in reply['value']:
                            raise RuntimeError(reply['value'])
                        return reply['value']
                except (OSError, json.JSONDecodeError): pass
                time.sleep(.05)
            raise RuntimeError((method, path))
        capabilities = {'capabilities': {'alwaysMatch': {'browserName': 'firefox', 'moz:firefoxOptions': {'binary': '${pkgs.firefox}/bin/firefox', 'args': ['-profile', runtime + '/firefox-profile', '--no-sandbox'], 'prefs': {'security.sandbox.content.level': 0, 'security.sandbox.rdd.level': 0, 'security.sandbox.socket.process.level': 0, 'security.sandbox.utility.level': 0}}}}}
        created = request('POST', '/session', capabilities)
        session = created['sessionId']
        base = '/session/' + session
        request('POST', base + '/url', {'url': 'file://${pages}/alpha.html'})
        first = request('GET', base + '/window')
        second = request('POST', base + '/window/new', {'type': 'tab'})['handle']
        request('POST', base + '/window', {'handle': second}); request('POST', base + '/url', {'url': 'file://${pages}/beta.html'})
        third = request('POST', base + '/window/new', {'type': 'window'})['handle']
        request('POST', base + '/window', {'handle': third}); request('POST', base + '/url', {'url': 'file://${pages}/gamma.html'})
        with open(state + '/firefox-session.json', 'w') as output: json.dump({'session': session, 'geckodriver_pid': gecko.pid, 'handles': [first, second, third], 'selected': third}, output)
        gecko.wait()
      '';
  niriConfig = pkgs.writeText "niri-test-config.kdl" ''
    input {
      keyboard {
        xkb {
          layout "us"
        }
      }
    }
    layout {
      gaps 8
    }
    animations {
      off
    }
    prefer-no-csd
    hotkey-overlay {
      skip-at-startup
    }
  '';
  session = pkgs.writeShellApplication {
    name = "niri-application-session";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.findutils
      pkgs.firefox
      pkgs.geckodriver
      pkgs.jq
      pkgs.kitty
      pkgs.niri
      pkgs.python3
      pkgs.tmux
      pkgs.weston
      pkgs.zsh
      firefoxDriver
    ];
    text = ''
      # Force the nested software renderer to use checkpointable shared memory
      # rather than retaining the host-created udmabuf character device.
      rm -f /dev/udmabuf
      export DBUS_SYSTEM_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/no-system-bus"
      export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/no-session-bus"
      export NO_AT_BRIDGE=1
      export WAYLAND_DISPLAY=host-wayland
      weston --backend=headless-backend.so --renderer=gl --socket=$WAYLAND_DISPLAY --idle-time=0 --log="$WSS_SESSION_STATE_DIR/weston.log" &
      for _ in $(seq 1 200); do test -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" && break; sleep .05; done
      niri --config ${niriConfig} >"$WSS_SESSION_STATE_DIR/niri.log" 2>&1 &
      niri_pid=$!
      for _ in $(seq 1 200); do
        niri_socket=$(find "$XDG_RUNTIME_DIR" -maxdepth 1 -type s -name 'niri*.sock' -print -quit)
        test -n "$niri_socket" && break
        sleep .05
      done
      test -n "$niri_socket"
      export NIRI_SOCKET=$niri_socket
      printf '%s\n' "$niri_socket" > "$WSS_SESSION_STATE_DIR/niri.socket"
      for _ in $(seq 1 200); do
        child_display=$(find "$XDG_RUNTIME_DIR" -maxdepth 1 -type s -name 'wayland-*' ! -name host-wayland -printf '%f\n' | head -1)
        test -n "$child_display" && break
        sleep .05
      done
      export WAYLAND_DISPLAY=$child_display
      mkfifo "$XDG_RUNTIME_DIR/zsh-control"
      mkdir -p /var/lib/wayland-session-supervisor/niri-zsh-cwd
      tmux -D -S "$XDG_RUNTIME_DIR/niri-tmux.sock" >"$WSS_SESSION_STATE_DIR/tmux.log" 2>&1 &
      for _ in $(seq 1 100); do test -S "$XDG_RUNTIME_DIR/niri-tmux.sock" && break; sleep .05; done
      tmux -S "$XDG_RUNTIME_DIR/niri-tmux.sock" new-session -d -c /var/lib/wayland-session-supervisor/niri-zsh-cwd "exec zsh ${zshFixture}"
      tmux -S "$XDG_RUNTIME_DIR/niri-tmux.sock" set-environment -g WSS_NIRI_TMUX_ENV preserved
      kitty --class niri-kitty --title niri-kitty -- tmux -S "$XDG_RUNTIME_DIR/niri-tmux.sock" attach >"$WSS_SESSION_STATE_DIR/kitty.log" 2>&1 &
      MOZ_ENABLE_WAYLAND=1 MOZ_DISABLE_CONTENT_SANDBOX=1 MOZ_DISABLE_RDD_SANDBOX=1 \
        MOZ_DISABLE_GMP_SANDBOX=1 MOZ_DISABLE_SOCKET_PROCESS_SANDBOX=1 \
        MOZ_DISABLE_UTILITY_SANDBOX=1 niri-firefox-driver >"$WSS_SESSION_STATE_DIR/firefox-driver.log" 2>&1 &
      wait "$niri_pid"
    '';
  };
  probe = pkgs.writers.writePython3Bin "niri-application-probe" { flakeIgnore = pythonIgnores; } ''
    import hashlib, http.client, json, os, subprocess, sys
    phase, destination = sys.argv[1:]
    state = '/var/lib/wayland-session-supervisor/sessions/niri'
    runtime = '/run/wayland-session-supervisor/niri'
    saved = json.load(open(state + '/firefox-session.json'))
    base = '/session/' + saved['session']
    def request(method, path, body=None):
        conn = http.client.HTTPConnection('127.0.0.1', 4444, timeout=5)
        conn.request(method, path, json.dumps(body) if body is not None else None, {'Content-Type': 'application/json'})
        return json.loads(conn.getresponse().read())['value']
    handles = request('GET', base + '/window/handles')
    selected = request('GET', base + '/window')
    tabs = []
    for handle in handles:
        request('POST', base + '/window', {'handle': handle})
        tabs.append({'handle': handle, 'title': request('GET', base + '/title'), 'url': request('GET', base + '/url'), 'memory': request('POST', base + '/execute/sync', {'script': 'return window.memoryOnly', 'args': []})})
    request('POST', base + '/window', {'handle': selected})
    env = sorted(subprocess.check_output(['tmux','-S',runtime+'/niri-tmux.sock','show-environment','-g'],text=True).splitlines())
    sessions = subprocess.check_output(['tmux','-S',runtime+'/niri-tmux.sock','list-sessions','-F','#{session_name}|#{session_windows}'],text=True).splitlines()
    windows = subprocess.check_output(['tmux','-S',runtime+'/niri-tmux.sock','list-windows','-a','-F','#{session_name}|#{window_index}|#{window_name}|#{window_panes}|#{window_layout}'],text=True).splitlines()
    pane = subprocess.check_output(['tmux','-S',runtime+'/niri-tmux.sock','list-panes','-a','-F','#{pane_pid}'],text=True).strip()
    cwd = None
    for proc in os.listdir('/proc'):
        if not proc.isdigit(): continue
        try:
            nspid = [x for x in open('/proc/'+proc+'/status') if x.startswith('NSpid:')][0].split()[-1]
            if nspid == pane and '/wss-niri' in open('/proc/'+proc+'/cgroup').read(): cwd = os.readlink('/proc/'+proc+'/cwd'); break
        except (OSError, IndexError): pass
    contents = subprocess.check_output(['tmux','-S',runtime+'/niri-tmux.sock','capture-pane','-p','-S','-'],text=True).splitlines()
    while contents and not contents[-1]: contents.pop()
    niri_socket = open(state + '/niri.socket').read().strip()
    niri_windows = json.loads(subprocess.check_output(['niri','msg','--json','windows'],env={**os.environ,'NIRI_SOCKET':niri_socket},text=True))
    evidence = {'schema':1,'phase':phase,'firefox':{'handles':handles,'selected':selected,'tabs':sorted(tabs,key=lambda x:x['title'])},'kitty':{'contents':contents,'sha256':hashlib.sha256(chr(10).join(contents).encode()).hexdigest()},'zsh':json.load(open(state+'/zsh.json')),'tmux':{'sessions':sessions,'windows':windows,'environment':env,'pane_pid':int(pane),'cwd':cwd},'niri':{'windows':sorted([{'id':w['id'],'title':w.get('title'),'app_id':w.get('app_id'),'workspace_id':w.get('workspace_id')} for w in niri_windows],key=lambda x:x['id'])}}
    with open(destination,'w') as output: json.dump(evidence,output,sort_keys=True,indent=2)
  '';
  supervisor = self.packages.${system}.default;
  command = "${session}/bin/niri-application-session";
in
pkgs.testers.runNixOSTest {
  name = "wayland-session-supervisor-niri-application-reboot";
  nodes.machine = {
    hardware.graphics.enable = true;
    virtualisation = {
      memorySize = 6144;
      cores = 4;
      diskSize = 12288;
    };
    boot.kernel.sysctl = {
      "kernel.unprivileged_userns_clone" = 1;
      "fs.pipe-user-pages-soft" = 0;
      "fs.pipe-user-pages-hard" = 0;
    };
    environment.systemPackages = [
      criu
      pkgs.coreutils
      pkgs.jq
      pkgs.niri
      pkgs.socat
      pkgs.tmux
      pkgs.wtype
      probe
      supervisor
    ];
  };
  testScript = ''
    import json
    state = "/var/lib/wayland-session-supervisor"
    runtime = "/run/wayland-session-supervisor"
    command = "${command}"
    common = f"--session niri --state-dir {state} --"
    machine.start(); machine.wait_for_unit("multi-user.target")
    boot_before = machine.succeed("cat /proc/sys/kernel/random/boot_id").strip()
    machine.succeed("mkdir /sys/fs/cgroup/wss-niri")
    machine.succeed("systemd-run --unit=wss-niri --service-type=exec --property=StandardOutput=null --property=StandardError=null " f"${supervisor}/bin/wayland-session-supervisor run --session niri --state-dir {state} --runtime-dir {runtime} --cgroup-dir /sys/fs/cgroup/wss-niri -- {command}")
    machine.sleep(20)
    machine.succeed(f"systemctl is-active wss-niri.service || {{ cat {state}/sessions/niri/{{niri,weston,firefox-driver,kitty}}.log 2>/dev/null; exit 1; }}")
    machine.sleep(30)
    machine.succeed(f"test -S {runtime}/niri/niri-tmux.sock && test -s {state}/sessions/niri/firefox-session.json && test -s {state}/sessions/niri/zsh.json || {{ cat {state}/sessions/niri/{{niri,firefox-driver,kitty,tmux}}.log 2>/dev/null; ls -la {state}/sessions/niri {runtime}/niri; exit 1; }}")
    machine.wait_until_succeeds(f"NIRI_SOCKET=$(cat {state}/sessions/niri/niri.socket) niri msg --json windows | jq -e 'length >= 3'")
    machine.succeed(f"niri-application-probe before {state}/niri-before.json")
    before = json.loads(machine.succeed(f"cat {state}/niri-before.json"))
    assert len(before['firefox']['handles']) == 3
    assert [x['title'] for x in before['firefox']['tabs']] == ['niri-alpha','niri-beta','niri-gamma']
    assert before['kitty']['contents'] == [f'niri-kitty-scrollback-{n:03}' for n in range(1,81)]
    assert before['tmux']['cwd'] == '/var/lib/wayland-session-supervisor/niri-zsh-cwd'
    assert 'WSS_NIRI_TMUX_ENV=preserved' in before['tmux']['environment']
    machine.succeed(f"${supervisor}/bin/wayland-session-supervisor capture {common} {command} || {{ tail -100 {state}/sessions/niri/checkpoints/failed-*/dump.log; exit 1; }}")
    machine.shutdown(); machine.start(); machine.wait_for_unit("multi-user.target")
    boot_after = machine.succeed("cat /proc/sys/kernel/random/boot_id").strip(); assert boot_before != boot_after
    machine.succeed("systemd-run --unit=wss-niri-restored --service-type=exec --setenv=PATH=${
      pkgs.lib.makeBinPath [
        pkgs.coreutils
        criu
        pkgs.niri
        pkgs.wtype
      ]
    } " f"${supervisor}/bin/wayland-session-supervisor restore {common} {command}")
    machine.wait_until_succeeds(f"jq -e '.role == \"restored-session-authority\" and .boot_id == \"{boot_after}\"' {state}/sessions/niri/outer-supervisor.json")
    machine.wait_until_succeeds(f"NIRI_SOCKET=$(cat {state}/sessions/niri/niri.socket) niri msg --json windows | jq -e 'length >= 3'")
    machine.succeed(f"niri-application-probe after {state}/niri-after.json")
    after = json.loads(machine.succeed(f"cat {state}/niri-after.json"))
    assert before['firefox'] == after['firefox'], (before['firefox'],after['firefox'])
    assert before['kitty'] == after['kitty'], (before['kitty'],after['kitty'])
    assert before['zsh'] == after['zsh'], (before['zsh'],after['zsh'])
    assert before['tmux'] == after['tmux'], (before['tmux'],after['tmux'])
    assert before['niri'] == after['niri'], (before['niri'],after['niri'])
    machine.succeed(f"NIRI_SOCKET=$(cat {state}/sessions/niri/niri.socket) niri msg action spawn -- kitty --class niri-post-restore --title niri-post-restore sleep 300")
    machine.wait_until_succeeds(f"NIRI_SOCKET=$(cat {state}/sessions/niri/niri.socket) niri msg --json windows | jq -e '.[]|select(.app_id == \"niri-post-restore\")'")
    machine.succeed(f"mkdir -p /tmp/niri-evidence; cp {state}/niri-{{before,after}}.json /tmp/niri-evidence/; cp {state}/sessions/niri/outer-supervisor.json /tmp/niri-evidence/")
    machine.succeed(f"jq -n --arg before '{boot_before}' --arg after '{boot_after}' '{{schema:1,boot_before:$before,boot_after:$after,rebooted:($before != $after),verdict:\"pass\"}}' >/tmp/niri-evidence/verdict.json")
    machine.copy_from_machine("/tmp/niri-evidence","")
  '';
}
