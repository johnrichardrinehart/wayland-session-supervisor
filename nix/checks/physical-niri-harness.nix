{
  pkgs,
  self,
  ...
}:
pkgs.runCommand "wayland-session-supervisor-physical-niri-harness"
  {
    nativeBuildInputs = [
      pkgs.bash
      pkgs.niri
      pkgs.shellcheck
    ];
  }
  ''
    scripts=(
      ${self}/tests/physical/run-niri-admission.sh
      ${self}/tests/physical/run-from-vt.sh
      ${self}/tests/physical/niri-admission-coordinator.sh
      ${self}/tests/physical/niri-admission-inner.sh
      ${self}/tests/physical/prove-watchdog.sh
      ${self}/tests/physical/watchdog-action.sh
    )
    bash -n "''${scripts[@]}"
    shellcheck "''${scripts[@]}"
    bash ${self}/tests/physical/run-niri-admission.sh --help >/dev/null
    bash ${self}/tests/physical/run-from-vt.sh --help >/dev/null
    grep -F 'the control shell must not use production VT' \
      ${self}/tests/physical/run-from-vt.sh
    grep -F 'ControlMaster=yes' ${self}/tests/physical/run-from-vt.sh
    grep -F 'XDG_SESSION_ID=$production_session' ${self}/tests/physical/run-from-vt.sh
    niri validate -c ${self}/tests/physical/niri-minimal-safe.kdl
    grep -F 'Super+Shift+E allow-inhibiting=false { quit skip-confirmation=true; }' \
      ${self}/tests/physical/niri-minimal-safe.kdl
    grep -F -- '--on-active=180s' ${self}/tests/physical/niri-admission-coordinator.sh
    grep -F -- '--property=Delegate=yes' ${self}/tests/physical/niri-admission-coordinator.sh
    grep -F -- 'timeout --kill-after=5s 75s' ${self}/tests/physical/niri-admission-coordinator.sh
    grep -F 'cgroup.procs' ${self}/tests/physical/niri-admission-coordinator.sh
    ! grep -F -- '--criu' ${self}/tests/physical/niri-admission-inner.sh
    grep -F 'WSS_PHYSICAL_NIRI_CONFIRM=stop-production-session' \
      ${self}/tests/physical/run-niri-admission.sh
    grep -F 'no established SSH control session exists' \
      ${self}/tests/physical/run-niri-admission.sh
    touch "$out"
  ''
