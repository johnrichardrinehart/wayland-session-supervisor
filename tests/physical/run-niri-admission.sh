#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
usage: run-niri-admission.sh [--dry-run|--execute]

--dry-run  Validate every non-destructive physical admission prerequisite.
--execute  Start the root coordinator. This stops the production compositor,
           so the invoking graphical terminal and this agent will exit.

Execution additionally requires:
  WSS_PHYSICAL_NIRI_CONFIRM=stop-production-session
EOF
}

mode=dry-run
case ${1:---dry-run} in
    --dry-run) ;;
    --execute) mode=execute ;;
    --help|-h) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
esac
if (( $# > 1 )); then
    usage >&2
    exit 2
fi

repo=$(cd "$(dirname "$0")/../.." && pwd)
user=$(id -un)
uid=$(id -u)
boot_id=$(cat /proc/sys/kernel/random/boot_id)
gate=${WSS_PHYSICAL_ESCAPE_GATE:-${XDG_STATE_HOME:-$HOME/.local/state}/wayland-session-supervisor/physical-test/escape-gate.json}
marker=/run/wayland-session-supervisor/physical-watchdog-${uid}.env
state=${WSS_PHYSICAL_NIRI_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/wayland-session-supervisor/physical-niri-admission}
runtime=${WSS_PHYSICAL_NIRI_RUNTIME:-/run/user/${uid}/wayland-session-supervisor-physical}
config=${WSS_PHYSICAL_NIRI_CONFIG:-$repo/tests/physical/niri-minimal-safe.kdl}
wss=${WSS_PHYSICAL_WSS:-$(command -v wayland-session-supervisor)}
criu=${WSS_PHYSICAL_CRIU:-/tmp/criu-i915-worktree}
niri=${WSS_PHYSICAL_NIRI:-$(command -v niri)}
plugin=${WSS_PHYSICAL_I915_PLUGIN:-/home/john/code/dev-worktrees/github.com/checkpoint-restore/criu/i915-plugin/plugins/i915/i915_plugin.so}
production_scope=${WSS_PHYSICAL_PRODUCTION_SCOPE:-wayland-session-supervisor-default.scope}
session_id=${XDG_SESSION_ID:-$(loginctl list-sessions --no-legend | awk -v uid="$uid" '$2 == uid && $4 == "seat0" { print $1; exit }')}
vt_number=${XDG_VTNR:-$(loginctl show-session "$session_id" -p VTNr --value 2>/dev/null || true)}
timestamp=$(date -u +%Y%m%dT%H%M%SZ)
evidence=${WSS_PHYSICAL_NIRI_EVIDENCE:-/var/tmp/wss-physical-niri-admission-${timestamp}}

fail() {
    echo "physical admission refused: $*" >&2
    exit 1
}

[[ -s $gate ]] || fail "missing current-boot escape gate: $gate"
jq -e --arg boot "$boot_id" \
    '.schema == 2 and .boot_id == $boot and
     .authority == "system-manager-cgroup-kill" and .verdict == "pass"' \
    "$gate" >/dev/null || fail "escape gate is stale or incomplete"
[[ -s $marker ]] || fail "missing system-watchdog action marker"
for expected in \
    "watchdog_fired=1" \
    "boot_id=$boot_id" \
    "cgroup_kill_result=success" \
    "unit_stop_result=success" \
    "session_activate_result=success" \
    "vt_activate_result=success"; do
    grep -Fx "$expected" "$marker" >/dev/null || fail "watchdog marker lacks $expected"
done
[[ -x $wss ]] || fail "supervisor is not executable: $wss"
[[ -x $criu ]] || fail "CRIU wrapper is not executable: $criu"
[[ -f $plugin ]] || fail "i915 plugin is absent: $plugin"
[[ -x $niri ]] || fail "Niri is not executable: $niri"
"$niri" validate -c "$config" >/dev/null || fail "minimal Niri config is invalid"
grep -F 'allow-inhibiting=false' "$config" | grep -F 'quit skip-confirmation=true' >/dev/null \
    || fail "minimal Niri config lacks an uninhibitable immediate exit"
systemctl --system --machine=.host is-active --quiet sshd.service \
    || fail "sshd is not active as an independent remote control path"
ssh_connections=$(ss -Htn state established '( sport = :22 )' | wc -l)
if (( ssh_connections == 0 )); then
    fail "no established SSH control session exists; connect from another terminal or machine first"
fi
[[ $(loginctl show-user "$user" -p Linger --value) == yes ]] \
    || fail "the user manager is not lingered"
systemctl --user --machine="${user}@.host" is-active --quiet "$production_scope" \
    || fail "production compositor scope is not active"
if systemctl --user --machine="${user}@.host" is-active --quiet wss-physical-niri.service; then
    fail "a prior physical Niri service is still active"
fi

namespace_wrapper_source=
for candidate in /nix/store/*-security-wrapper-wayland-session-supervisor-*/bin/security-wrapper; do
    if [[ -f $candidate ]] && grep -aqF "$wss" "$candidate"; then
        namespace_wrapper_source=$candidate
        break
    fi
done
[[ -n $namespace_wrapper_source ]] || fail "no security wrapper targets $wss"
seatd_wrapper_source=
for candidate in /nix/store/*-security-wrapper-seatd-launch-*/bin/security-wrapper; do
    if [[ -f $candidate ]] && grep -aq '/bin/seatd-launch' "$candidate"; then
        seatd_wrapper_source=$candidate
        break
    fi
done
[[ -n $seatd_wrapper_source ]] || fail "no seatd-launch security wrapper is available"

jq -n \
    --arg mode "$mode" --arg boot_id "$boot_id" --arg user "$user" \
    --arg gate "$gate" --arg evidence "$evidence" --arg state "$state" \
    --arg runtime "$runtime" --arg wss "$wss" --arg criu "$criu" \
    --arg plugin "$plugin" --arg niri "$niri" --arg config "$config" \
    --arg namespace_wrapper "$namespace_wrapper_source" \
    --arg seatd_wrapper "$seatd_wrapper_source" \
    --arg production_scope "$production_scope" --arg session_id "$session_id" \
    --arg vt_number "$vt_number" --argjson ssh_connections "$ssh_connections" \
    '{schema: 1, mode: $mode, boot_id: $boot_id, user: $user,
      gate: $gate, evidence: $evidence, state: $state, runtime: $runtime,
      supervisor: $wss, criu: $criu, plugin: $plugin, niri: $niri,
      config: $config, namespace_wrapper_source: $namespace_wrapper,
      seatd_wrapper_source: $seatd_wrapper, production_scope: $production_scope,
      session_id: $session_id, vt_number: $vt_number,
      established_ssh_connections: $ssh_connections}'

if [[ $mode == dry-run ]]; then
    echo "PASS: physical Niri admission preflight; no DRM, input, VT, process, or service state changed"
    exit 0
fi
if [[ ${WSS_PHYSICAL_NIRI_CONFIRM:-} != stop-production-session ]]; then
    fail "set WSS_PHYSICAL_NIRI_CONFIRM=stop-production-session for --execute"
fi
if ! sudo -n true 2>/dev/null; then
    fail "refresh sudo with 'sudo true' before --execute"
fi

coordinator=wss-physical-niri-coordinator-${uid}
bash_bin=$(command -v bash)
sudo -n systemd-run --system --machine=.host \
    --unit="$coordinator" --service-type=exec --collect \
    --setenv=PATH=/run/current-system/sw/bin \
    "$bash_bin" "$repo/tests/physical/niri-admission-coordinator.sh" \
    "$user" "$state" "$runtime" "$evidence" "$wss" "$criu" \
    "$namespace_wrapper_source" "$seatd_wrapper_source" "$niri" "$config" \
    "$session_id" "$vt_number" "$production_scope" "$repo" "$plugin"

cat <<EOF
ARMED: root coordinator ${coordinator}.service
Evidence will be written to: $evidence
The production graphical scope will now stop. Reconnect through SSH or the
restored VT; do not start another compositor manually.
EOF
