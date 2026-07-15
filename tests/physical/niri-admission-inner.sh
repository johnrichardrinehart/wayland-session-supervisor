#!/usr/bin/env bash
set -euo pipefail

if (( $# != 10 )); then
    echo "usage: $0 STATE RUNTIME ARMED WSS CRIU NAMESPACE_WRAPPER SEATD_WRAPPER NIRI CONFIG SESSION_NAME" >&2
    exit 2
fi

state=$1
runtime=$2
armed=$3
wss=$4
criu=$5
namespace_wrapper=$6
seatd_wrapper=$7
niri=$8
config=$9
session_name=${10}
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

export LIBSEAT_BACKEND=seatd
export XDG_SESSION_TYPE=wayland
exec "$wss" run \
    --session "$session_name" \
    --state-dir "$state/supervisor" \
    --runtime-dir "$runtime" \
    --criu "$criu" \
    --cgroup-dir "$cgroup" \
    --namespace-launcher "$namespace_wrapper" \
    -- "$seatd_command" "$niri" --config "$config"
