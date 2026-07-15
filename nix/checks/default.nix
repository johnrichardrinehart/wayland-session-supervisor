{
  pkgs,
  self,
  system,
}:
{
  package = self.packages.${system}.default;
  cargo-test = self.packages.${system}.default;
  manual-snapshot-and-reboot = import ./manual-snapshot-and-reboot.nix { inherit pkgs self system; };
  auto-snapshot-and-reboot = import ./auto-snapshot-and-reboot.nix { inherit pkgs self system; };
  niri-manual-snapshot-and-reboot = import ./niri-manual-snapshot-and-reboot.nix {
    inherit pkgs self system;
  };
  checkpoint = import ./checkpoint.nix { inherit pkgs self system; };
  unprivileged-session = import ./unprivileged-session.nix { inherit pkgs self system; };
  authenticated-lifecycle = import ./authenticated-lifecycle.nix { inherit pkgs self system; };
  in-domain-seat-authority-lifecycle = import ./authenticated-lifecycle.nix {
    inherit pkgs self system;
    inDomainSeatAuthority = true;
  };
  in-domain-seat-authority = import ./in-domain-seat-authority.nix { inherit pkgs self system; };
  core-integration =
    pkgs.runCommand "wayland-session-supervisor-core-integration"
      {
        nativeBuildInputs = [
          pkgs.bash
          pkgs.python3
          (pkgs.writeShellScriptBin "unshare" ''
            while test "$1" != --; do shift; done
            shift
            test "$1" = setsid && shift
            test "$1" = -- && shift
            "$@" &
            wait $!
          '')
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
            import time

            assert not os.path.exists("/proc/self/fd/9")
            assert os.environ["XDG_RUNTIME_DIR"] == "'"$PWD"'/runtime/integration"
            assert os.environ["TMPDIR"] == "'"$PWD"'/runtime/integration/tmp"
            assert os.environ["WSS_SESSION_STATE_DIR"] == "'"$PWD"'/state/sessions/integration"
            assert os.environ["WSS_DISPLAY_BACKEND"] == "headless"
            control = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
            control.sendto(b"key:42", os.environ["WSS_CONTROL_SOCKET"])
            ingress_log = os.path.join(os.environ["XDG_RUNTIME_DIR"], "adapter-ingress.log")
            for _ in range(100):
                if os.path.exists(ingress_log) and open(ingress_log, "rb").read() == b"key:42\n": break
                time.sleep(.01)
            else: raise AssertionError("ingress adapter did not persist event")
            with open(os.environ["WSS_EGRESS_SPOOL"], "ab") as spool:
                spool.write(b"opaque-test-payload")
          '
        test -s fake-cgroup/cgroup.procs
        grep -Fx "key:42" runtime/integration/adapter-ingress.log
        test "$(cat runtime/integration/adapter-egress.stream)" = opaque-test-payload

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
  feasibility = import ./feasibility.nix { inherit pkgs self system; };
}
