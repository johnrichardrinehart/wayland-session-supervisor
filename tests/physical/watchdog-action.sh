#!/usr/bin/env bash
set -euo pipefail

if (( $# != 3 )); then
    echo "usage: $0 UNIT MARKER SESSION_ID" >&2
    exit 2
fi

unit=$1
marker=$2
session_id=$3
watchdog_cgroup=$(awk -F: '$1 == "0" { print $3 }' /proc/self/cgroup)

systemctl --user stop "$unit"
if [[ -n $session_id ]]; then
    loginctl activate "$session_id" || true
fi
install -d -m 0700 "$(dirname "$marker")"
printf 'watchdog_fired=1\nunit=%s\nsession_id=%s\nwatchdog_cgroup=%s\nboot_id=%s\nfired_utc=%s\n' \
    "$unit" "$session_id" "$watchdog_cgroup" \
    "$(cat /proc/sys/kernel/random/boot_id)" \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$marker"
chmod 0600 "$marker"
