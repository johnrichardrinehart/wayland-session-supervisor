{
  pkgs,
  self,
  system,
}:
{
  package = self.packages.${system}.default;
  cargo-test = self.packages.${system}.default;
  core-integration =
    pkgs.runCommand "wayland-session-supervisor-core-integration"
      {
        nativeBuildInputs = [
          pkgs.bash
          pkgs.python3
          self.packages.${system}.default
        ];
      }
      ''
        mkdir state runtime fake-cgroup
        : > fake-cgroup/cgroup.procs
        exec 9</dev/null
        wayland-session-supervisor run \
          --session integration \
          --state-dir "$PWD/state" \
          --runtime-dir "$PWD/runtime" \
          --cgroup-dir "$PWD/fake-cgroup" \
          -- ${pkgs.python3}/bin/python -c '
            import os
            import socket

            assert not os.path.exists("/proc/self/fd/9")
            assert os.environ["XDG_RUNTIME_DIR"] == "'"$PWD"'/runtime/integration"
            assert os.environ["TMPDIR"] == "'"$PWD"'/runtime/integration/tmp"
            assert os.environ["WSS_SESSION_STATE_DIR"] == "'"$PWD"'/state/sessions/integration"
            assert os.environ["WSS_DISPLAY_BACKEND"] == "headless"
            control = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
            control.sendto(b"key:42", os.environ["WSS_CONTROL_SOCKET"])
            input_adapter = socket.socket(fileno=int(os.environ["WSS_INPUT_FD"]))
            assert input_adapter.recv(128) == b"key:42"
            audio_adapter = socket.socket(fileno=int(os.environ["WSS_AUDIO_FD"]))
            audio_adapter.send(b"stream=test samples=500000 hash=abc")
          '
        test -s fake-cgroup/cgroup.procs
        for attempt in $(seq 1 100); do
          test -s state/sessions/integration/audio-observations.log && break
          sleep 0.01
        done
        grep -Fx "stream=test samples=500000 hash=abc" \
          state/sessions/integration/audio-observations.log

        wayland-session-supervisor run \
          --session lifecycle \
          --state-dir "$PWD/state" \
          --runtime-dir "$PWD/runtime" \
          -- ${pkgs.bash}/bin/bash -c '
            trap "printf terminated > '"$PWD"'/terminated; exit 0" TERM
            while true; do sleep 0.05; done
          ' &
        supervisor_pid=$!
        sleep 0.2
        kill -TERM "$supervisor_pid"
        wait "$supervisor_pid" || true
        test "$(cat terminated)" = terminated
        touch $out
      '';
  feasibility = import ./feasibility.nix { inherit pkgs self; };
}
