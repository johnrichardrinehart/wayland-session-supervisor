#!/usr/bin/env bash
set -euo pipefail

repo=$(cd "$(dirname "$0")/../.." && pwd)
state=${WSS_PHYSICAL_TEST_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/wayland-session-supervisor/physical-test}
victim=wss-physical-watchdog-victim.service
watchdog=wss-physical-watchdog.service
timer=wss-physical-watchdog.timer
marker=$state/watchdog-fired.env
verdict=$state/escape-gate.json
session_id=${XDG_SESSION_ID:-}
machine="$(id -un)@.host"
systemctl=(systemctl --user --machine="$machine")
systemd_run=(systemd-run --user --machine="$machine")
sleep_bin=$(command -v sleep)

cleanup() {
    "${systemctl[@]}" stop "$timer" "$watchdog" "$victim" >/dev/null 2>&1 || true
    "${systemctl[@]}" reset-failed "$timer" "$watchdog" "$victim" >/dev/null 2>&1 || true
}
trap cleanup EXIT
cleanup
install -d -m 0700 "$state"
rm -f "$marker" "$verdict"

"${systemd_run[@]}" --unit="$victim" --service-type=exec \
    "$sleep_bin" 300 >/dev/null
victim_cgroup=$("${systemctl[@]}" show "$victim" -p ControlGroup --value)
"${systemd_run[@]}" --unit=wss-physical-watchdog --on-active=2s \
    --service-type=oneshot \
    "$repo/tests/physical/watchdog-action.sh" "$victim" "$marker" "$session_id" \
    >/dev/null
if [[ -z $victim_cgroup ]]; then
    echo "victim cgroup is unavailable" >&2
    exit 1
fi

for _ in $(seq 1 100); do
    if ! "${systemctl[@]}" is-active --quiet "$victim" && [[ -s $marker ]]; then
        break
    fi
    sleep 0.1
done
if "${systemctl[@]}" is-active --quiet "$victim" || [[ ! -s $marker ]]; then
    echo "independent watchdog did not terminate the victim" >&2
    exit 1
fi

grep -Fx 'watchdog_fired=1' "$marker" >/dev/null
watchdog_cgroup=$(awk -F= '$1 == "watchdog_cgroup" { print $2 }' "$marker")
if [[ -z $watchdog_cgroup || $victim_cgroup == "$watchdog_cgroup" ]]; then
    echo "watchdog and victim must have independent cgroups" >&2
    exit 1
fi
boot_id=$(cat /proc/sys/kernel/random/boot_id)
printf '{\n  "schema": 1,\n  "boot_id": "%s",\n  "victim_cgroup": "%s",\n  "watchdog_cgroup": "%s",\n  "timeout_seconds": 2,\n  "verdict": "pass"\n}\n' \
    "$boot_id" "$victim_cgroup" "$watchdog_cgroup" >"$verdict"
chmod 0600 "$verdict"
printf 'PASS: independent watchdog terminated bounded victim; evidence=%s\n' "$verdict"
