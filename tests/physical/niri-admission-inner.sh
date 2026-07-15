#!/usr/bin/env bash
set -euo pipefail

if (( $# != 9 )); then
    echo "usage: $0 STATE RUNTIME ARMED WSS NAMESPACE_WRAPPER SEATD_WRAPPER NIRI CONFIG SESSION_NAME" >&2
    exit 2
fi

state=$1
runtime=$2
armed=$3
wss=$4
namespace_wrapper=$5
seatd_wrapper=$6
niri=$7
config=$8
session_name=$9
cgroup_rel=$(awk -F: '$1 == "0" { print $3 }' /proc/self/cgroup)
cgroup=/sys/fs/cgroup${cgroup_rel}/domain
seatd_command=$state/seatd-command.sh

mkdir -p "$cgroup"
cat >"$seatd_command" <<EOF
#!/usr/bin/env bash
set -euo pipefail
export LIBSEAT_BACKEND=seatd
exec ${seatd_wrapper@Q} -- "\$@"
EOF
chmod 0700 "$seatd_command"

for _ in $(seq 1 600); do
    [[ -e $armed ]] && break
    sleep 0.1
done
if [[ ! -e $armed ]]; then
    echo "physical admission was never armed" >&2
    exit 1
fi

# The production session imports its display into the persistent user manager.
# A physical Niri transient must not inherit that socket and select its nested
# Wayland backend after the production compositor has been stopped.
unset WAYLAND_DISPLAY DISPLAY WAYLAND_SOCKET
export LIBSEAT_BACKEND=seatd
export XDG_SESSION_TYPE=wayland
exec "$wss" run \
    --session "$session_name" \
    --state-dir "$state/supervisor" \
    --runtime-dir "$runtime" \
    --cgroup-dir "$cgroup" \
    --namespace-launcher "$namespace_wrapper" \
    -- "$seatd_command" "$niri" --config "$config"
