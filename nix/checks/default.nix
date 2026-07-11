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
          -- ${pkgs.bash}/bin/bash -c '
            test ! -e /proc/$$/fd/9
            test "$XDG_RUNTIME_DIR" = "'"$PWD"'/runtime/integration"
            test "$TMPDIR" = "'"$PWD"'/runtime/integration/tmp"
            test "$WSS_SESSION_STATE_DIR" = "'"$PWD"'/state/sessions/integration"
          '
        test -s fake-cgroup/cgroup.procs

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
