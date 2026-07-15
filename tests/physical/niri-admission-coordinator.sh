#!/usr/bin/env bash
set -euo pipefail

if (( $# != 15 )); then
    echo "usage: $0 USER STATE RUNTIME EVIDENCE WSS CRIU NAMESPACE_WRAPPER_SOURCE SEATD_WRAPPER_SOURCE NIRI CONFIG SESSION_ID VT_NUMBER PRODUCTION_SCOPE REPO PLUGIN" >&2
    exit 2
fi

user=$1
state=$2
runtime=$3
evidence=$4
wss=$5
criu=$6
namespace_wrapper_source=$7
seatd_wrapper_source=$8
niri=$9
config=${10}
session_id=${11}
vt_number=${12}
production_scope=${13}
repo=${14}
plugin_path=${15}
uid=$(id -u "$user")
user_manager="${user}@.host"
physical_unit="wss-physical-niri.service"
watchdog="wss-physical-niri-watchdog-${uid}"
watchdog_timer=${watchdog}.timer
namespace_wrapper=/run/wrappers/bin/wss-physical-namespace-launcher
seatd_wrapper=/run/wrappers/bin/wss-physical-seatd-launch
armed=$state/armed
session_name=physical-niri
capture_status=not-run
physical_started=false
physical_cgroup=
watchdog_armed=false
cleanup_complete=false

log() {
    printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "$evidence/coordinator.log"
}

stop_physical() {
    if $physical_started; then
        if timeout --kill-after=2s 15s systemctl --user --machine="$user_manager" stop "$physical_unit"; then
            physical_started=false
            return 0
        fi
        # A failed command can mean the transient unit already exited and was
        # collected. Treat that as stopped only when its delegated cgroup is
        # absent or demonstrably empty.
        if ! systemctl --user --machine="$user_manager" is-active --quiet "$physical_unit" 2>/dev/null \
            && { [[ -z $physical_cgroup || ! -e /sys/fs/cgroup$physical_cgroup/cgroup.procs ]] \
                || ! grep -q . "/sys/fs/cgroup$physical_cgroup/cgroup.procs"; }; then
            physical_started=false
            return 0
        fi
        return 1
    fi
}

cancel_watchdog() {
    if $watchdog_armed; then
        systemctl --system --machine=.host stop "$watchdog_timer" "${watchdog}.service" >/dev/null 2>&1 || true
        systemctl --system --machine=.host reset-failed "$watchdog_timer" "${watchdog}.service" >/dev/null 2>&1 || true
        watchdog_armed=false
    fi
}

cleanup() {
    local status=$?
    trap - EXIT INT TERM
    if stop_physical; then
        cancel_watchdog
        rm -f "$namespace_wrapper" "$seatd_wrapper"
        cleanup_complete=true
    else
        log "physical unit did not stop; leaving independent watchdog armed"
    fi
    if ! systemctl --system --machine=.host is-active --quiet greetd.service; then
        timeout --kill-after=2s 10s systemctl --system --machine=.host start greetd.service >/dev/null 2>&1 || true
    fi
    if [[ -n $session_id ]]; then
        timeout --kill-after=2s 5s loginctl activate "$session_id" >/dev/null 2>&1 || true
    fi
    if [[ -n $vt_number ]]; then
        timeout --kill-after=2s 5s chvt "$vt_number" >/dev/null 2>&1 || true
    fi
    jq -n \
        --arg boot_id "$(cat /proc/sys/kernel/random/boot_id)" \
        --arg capture_status "$capture_status" \
        --argjson coordinator_status "$status" \
        --argjson cleanup_complete "$cleanup_complete" \
        '{schema: 1, boot_id: $boot_id, capture_status: $capture_status,
          coordinator_status: $coordinator_status, cleanup_complete: $cleanup_complete}' \
        >"$evidence/verdict.json.tmp"
    mv "$evidence/verdict.json.tmp" "$evidence/verdict.json"
    chown -R "$user:users" "$evidence" "$state" "$runtime" 2>/dev/null || true
    exit "$status"
}
trap cleanup EXIT INT TERM

install -d -o "$user" -g users -m 0700 "$state" "$runtime" "$evidence"
: >"$evidence/coordinator.log"
chmod 0600 "$evidence/coordinator.log"
rm -f "$armed"

if ! grep -aqF "$wss" "$namespace_wrapper_source"; then
    echo "namespace security wrapper does not target $wss" >&2
    exit 1
fi
if ! grep -aq '/bin/seatd-launch' "$seatd_wrapper_source"; then
    echo "seatd security wrapper has no seatd-launch target" >&2
    exit 1
fi
if [[ -e $namespace_wrapper || -e $seatd_wrapper ]]; then
    echo "temporary physical wrapper name already exists" >&2
    exit 1
fi
install -o root -g root -m 4755 "$namespace_wrapper_source" "$namespace_wrapper"
install -o root -g root -m 4755 "$seatd_wrapper_source" "$seatd_wrapper"

module_path=$(modinfo -n i915)
[[ -f $plugin_path ]] || {
    echo "i915 plugin disappeared before metadata capture: $plugin_path" >&2
    exit 1
}
jq -n \
    --arg boot_id "$(cat /proc/sys/kernel/random/boot_id)" \
    --arg kernel "$(uname -r)" \
    --arg pci "$(lspci -Dnn -s 0000:00:02.0)" \
    --arg wss "$wss" \
    --arg wss_sha256 "$(sha256sum "$wss" | awk '{print $1}')" \
    --arg criu "$criu" \
    --arg criu_version "$($criu --version | head -1)" \
    --arg niri "$niri" \
    --arg niri_version "$($niri --version)" \
    --arg config_sha256 "$(sha256sum "$config" | awk '{print $1}')" \
    --arg i915_module_sha256 "$(sha256sum "$module_path" | awk '{print $1}')" \
    --arg plugin_sha256 "$(sha256sum "$plugin_path" | awk '{print $1}')" \
    --arg namespace_wrapper_sha256 "$(sha256sum "$namespace_wrapper_source" | awk '{print $1}')" \
    --arg seatd_wrapper_sha256 "$(sha256sum "$seatd_wrapper_source" | awk '{print $1}')" \
    '{schema: 1, boot_id: $boot_id, kernel: $kernel, pci: $pci,
      supervisor: {path: $wss, sha256: $wss_sha256},
      criu: {path: $criu, version: $criu_version},
      niri: {path: $niri, version: $niri_version, config_sha256: $config_sha256},
      i915_module_sha256: $i915_module_sha256, plugin_sha256: $plugin_sha256,
      wrappers: {namespace_sha256: $namespace_wrapper_sha256,
                 seatd_sha256: $seatd_wrapper_sha256}}' >"$evidence/metadata.json"

log "starting blocked physical service"
systemd-run --user --machine="$user_manager" \
    --unit="$physical_unit" --service-type=exec --collect \
    --property=Delegate=yes --property=TimeoutStopSec=15s \
    --setenv=PATH=/run/current-system/sw/bin \
    "$repo/tests/physical/niri-admission-inner.sh" \
    "$state" "$runtime" "$armed" "$wss" \
    "$namespace_wrapper" "$seatd_wrapper" "$niri" "$config" "$session_name" \
    >"$evidence/physical-systemd-run.log" 2>&1
physical_started=true
physical_cgroup=$(systemctl --user --machine="$user_manager" show "$physical_unit" -p ControlGroup --value)
case $physical_cgroup in
    "/user.slice/user-${uid}.slice/user@${uid}.service/"*) ;;
    *)
        echo "physical service escaped the user's manager cgroup: $physical_cgroup" >&2
        exit 1
        ;;
esac

log "arming independent 180-second system watchdog"
systemd-run --system --machine=.host \
    --unit="$watchdog" --on-active=180s --service-type=oneshot --collect \
    --property=TimeoutStartSec=20s --setenv=PATH=/run/current-system/sw/bin \
    /run/current-system/sw/bin/bash "$repo/tests/physical/watchdog-action.sh" \
    "$user" "$physical_unit" "$physical_cgroup" "$session_id" "$vt_number" \
    >"$evidence/watchdog-systemd-run.log" 2>&1
watchdog_armed=true
systemctl --system --machine=.host is-active --quiet "$watchdog_timer"

log "stopping the production compositor scope"
timeout --kill-after=2s 20s systemctl --user --machine="$user_manager" stop "$production_scope"
for _ in $(seq 1 200); do
    if ! pgrep -x niri >/dev/null; then
        break
    fi
    sleep 0.1
done
if pgrep -x niri >/dev/null; then
    echo "a Niri process remains after stopping the production scope" >&2
    exit 1
fi

log "releasing the physical service after watchdog admission"
install -o "$user" -g users -m 0600 /dev/null "$armed"
session_dir=$state/supervisor/sessions/$session_name
for _ in $(seq 1 300); do
    if [[ -s $session_dir/session.pid ]] && pgrep -x niri >/dev/null; then
        break
    fi
    sleep 0.1
done
if [[ ! -s $session_dir/session.pid ]] || ! pgrep -x niri >/dev/null; then
    echo "physical Niri did not become ready" >&2
    exit 1
fi
root_pid=$(cat "$session_dir/session.pid")
sleep 3
managed_cgroup=
if [[ -s $session_dir/cgroup.path ]]; then
    managed_cgroup=$(cat "$session_dir/cgroup.path")
fi
if ! kill -0 "$root_pid" 2>/dev/null || ! pgrep -x niri >/dev/null \
    || [[ -z $managed_cgroup || ! -s $managed_cgroup/cgroup.procs ]]; then
    echo "physical Niri exited or lost its delegated cgroup before capture" >&2
    exit 1
fi

ps -eo pid,ppid,uid,euid,stat,comm,args >"$evidence/processes-before-capture.txt"
find "/proc/$root_pid/fd" -maxdepth 1 -type l -printf '%f %l\n' >"$evidence/root-fds.txt" 2>/dev/null || true
log "capturing the leave-running physical Niri domain"
set +e
timeout --kill-after=5s 75s "$wss" capture --leave-running \
    --session "$session_name" \
    --state-dir "$state/supervisor" \
    --runtime-dir "$runtime" \
    --criu "$criu" \
    -- "$state/seatd-command.sh" "$niri" --config "$config" \
    >"$evidence/capture.stdout" 2>"$evidence/capture.stderr"
capture_rc=$?
set -e
if (( capture_rc == 0 )); then
    capture_status=success
else
    capture_status="refused-${capture_rc}"
fi
printf '%s\n' "$capture_rc" >"$evidence/capture.status"
find "$state/supervisor/sessions/$session_name" -maxdepth 4 -type f -print \
    >"$evidence/session-files.txt"
log "capture result: $capture_status"
