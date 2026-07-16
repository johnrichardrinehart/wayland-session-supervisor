#!/usr/bin/env bash
set -euo pipefail

repo=$(cd "$(dirname "$0")/../.." && pwd)
state=${WSS_PHYSICAL_TEST_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/wayland-session-supervisor/physical-test}
user=$(id -un)
uid=$(id -u)
victim=wss-physical-watchdog-victim.service
watchdog=wss-physical-watchdog-${uid}
timer=${watchdog}.timer
marker=/run/wayland-session-supervisor/physical-watchdog-${uid}.env
verdict=$state/escape-gate.json
session_id=${XDG_SESSION_ID:-}
vt_number=${XDG_VTNR:-}
machine="${user}@.host"
user_systemctl=(systemctl --user --machine="$machine")
user_systemd_run=(systemd-run --user --machine="$machine")
sleep_bin=$(command -v sleep)
bash_bin=$(command -v bash)

if ! sudo -n true 2>/dev/null; then
    echo "the system-manager watchdog requires a current sudo credential; run 'sudo true' and retry" >&2
    exit 1
fi

cleanup() {
    "${user_systemctl[@]}" stop "$victim" >/dev/null 2>&1 || true
    "${user_systemctl[@]}" reset-failed "$victim" >/dev/null 2>&1 || true
    sudo -n systemctl --system --machine=.host stop "$timer" "${watchdog}.service" >/dev/null 2>&1 || true
    sudo -n systemctl --system --machine=.host reset-failed "$timer" "${watchdog}.service" >/dev/null 2>&1 || true
}
trap cleanup EXIT
cleanup
install -d -m 0700 "$state"
sudo -n rm -f "$marker"
rm -f "$verdict"

"${user_systemd_run[@]}" --unit="$victim" --service-type=exec \
    "$sleep_bin" 300 >/dev/null
victim_cgroup=$("${user_systemctl[@]}" show "$victim" -p ControlGroup --value)
if [[ -z $victim_cgroup ]]; then
    echo "victim cgroup is unavailable" >&2
    exit 1
fi

# Arm the system-manager timer only after the target cgroup is known. The
# physical launcher uses the same sequence before its target can open devices.
sudo -n systemd-run --system --machine=.host \
    --unit="$watchdog" --on-active=2s \
    --service-type=oneshot --collect --property=TimeoutStartSec=20s \
    --setenv=PATH=/run/current-system/sw/bin \
    "$bash_bin" "$repo/tests/physical/watchdog-action.sh" \
    "$user" "$victim" "$victim_cgroup" "$session_id" "$vt_number" \
    >/dev/null

for _ in $(seq 1 600); do
    if ! "${user_systemctl[@]}" is-active --quiet "$victim" && [[ -s $marker ]]; then
        break
    fi
    sleep 0.1
done
if "${user_systemctl[@]}" is-active --quiet "$victim" || [[ ! -s $marker ]]; then
    echo "independent system watchdog did not prove victim termination within 60 seconds" >&2
    sudo -n journalctl --machine=.host -u "${watchdog}.service" --no-pager >&2 || true
    exit 1
fi

grep -Fx 'watchdog_fired=1' "$marker" >/dev/null
grep -Fx 'cgroup_kill_result=success' "$marker" >/dev/null
grep -Fx 'unit_stop_result=success' "$marker" >/dev/null
if [[ -n $session_id ]]; then
    grep -Fx 'session_activate_result=success' "$marker" >/dev/null
fi
if [[ -n $vt_number ]]; then
    grep -Fx 'vt_activate_result=success' "$marker" >/dev/null
fi
watchdog_cgroup=$(awk -F= '$1 == "watchdog_cgroup" { print $2 }' "$marker")
recorded_boot=$(awk -F= '$1 == "boot_id" { print $2 }' "$marker")
boot_id=$(cat /proc/sys/kernel/random/boot_id)
if [[ -z $watchdog_cgroup || $victim_cgroup == "$watchdog_cgroup" ]]; then
    echo "system watchdog and victim must have independent cgroups" >&2
    exit 1
fi
if [[ $watchdog_cgroup != /system.slice/* ]]; then
    echo "watchdog did not execute under the system manager: $watchdog_cgroup" >&2
    exit 1
fi
if [[ $recorded_boot != "$boot_id" ]]; then
    echo "watchdog evidence belongs to another boot" >&2
    exit 1
fi

printf '{\n  "schema": 2,\n  "boot_id": "%s",\n  "victim_cgroup": "%s",\n  "watchdog_cgroup": "%s",\n  "timeout_seconds": 2,\n  "authority": "system-manager-cgroup-kill",\n  "verdict": "pass"\n}\n' \
    "$boot_id" "$victim_cgroup" "$watchdog_cgroup" >"$verdict"
chmod 0600 "$verdict"
printf 'PASS: independent system watchdog terminated bounded victim; evidence=%s\n' "$verdict"
