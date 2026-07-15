#!/usr/bin/env bash
set -euo pipefail

if (( $# != 5 )); then
    echo "usage: $0 USER UNIT CONTROL_GROUP SESSION_ID VT_NUMBER" >&2
    exit 2
fi

user=$1
unit=$2
control_group=$3
session_id=$4
vt_number=$5
uid=$(id -u "$user")
expected_prefix=/user.slice/user-${uid}.slice/user@${uid}.service/
marker=/run/wayland-session-supervisor/physical-watchdog-${uid}.env
watchdog_cgroup=$(awk -F: '$1 == "0" { print $3 }' /proc/self/cgroup)

case $unit in
    wss-physical-*.service | wss-physical-*.scope) ;;
    *)
        echo "refusing unexpected physical-test unit: $unit" >&2
        exit 2
        ;;
esac
case $control_group in
    "$expected_prefix"*) ;;
    *)
        echo "refusing cgroup outside the user's manager: $control_group" >&2
        exit 2
        ;;
esac
case $control_group in
    *..*)
        echo "refusing non-canonical cgroup path" >&2
        exit 2
        ;;
esac
if [[ -n $vt_number && ! $vt_number =~ ^[0-9]+$ ]]; then
    echo "refusing invalid VT number: $vt_number" >&2
    exit 2
fi

# cgroup.kill is the system-manager escape path and does not depend on the
# compositor, its input devices, or a responsive user manager. The user-manager
# stop then releases and resets the transient unit when that manager is alive.
cgroup_path=/sys/fs/cgroup$control_group
if [[ -e $cgroup_path/cgroup.kill ]]; then
    printf '1\n' >"$cgroup_path/cgroup.kill"
fi
systemctl --user --machine="${user}@.host" stop "$unit" || true
if [[ -n $session_id ]]; then
    loginctl activate "$session_id" || true
fi
if [[ -n $vt_number ]]; then
    chvt "$vt_number" || true
fi

install -d -o root -g root -m 0755 /run/wayland-session-supervisor
printf 'watchdog_fired=1\nunit=%s\nuser=%s\ncontrol_group=%s\nsession_id=%s\nvt_number=%s\nwatchdog_cgroup=%s\nboot_id=%s\nfired_utc=%s\n' \
    "$unit" "$user" "$control_group" "$session_id" "$vt_number" \
    "$watchdog_cgroup" "$(cat /proc/sys/kernel/random/boot_id)" \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$marker"
chmod 0644 "$marker"
