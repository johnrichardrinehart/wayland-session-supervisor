#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
usage: run-from-vt.sh [--dry-run|--execute]

Prepare a local text VT as the independent physical-test control path, prove
the current-boot watchdog, establish a persistent localhost SSH observer, and
run the physical Niri admission harness.

Run this from a logged-in text VT other than Niri's production VT. Execution
also requires:
  WSS_PHYSICAL_NIRI_CONFIRM=stop-production-session

Close the persistent observer later with the command printed by this script.
EOF
}

mode=${1:---dry-run}
case $mode in
    --dry-run | --execute) ;;
    --help | -h)
        usage
        exit 0
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac
if (( $# > 1 )); then
    usage >&2
    exit 2
fi

fail() {
    echo "VT physical admission refused: $*" >&2
    exit 1
}

repo=$(cd "$(dirname "$0")/../.." && pwd)
uid=$(id -u)
tty_path=$(tty) || fail "standard input is not a terminal"
if [[ $tty_path =~ ^/dev/tty([0-9]+)$ ]]; then
    control_vt=${BASH_REMATCH[1]}
else
    fail "run from a Linux text VT, not $tty_path"
fi

self_cgroup=$(awk -F: '$1 == "0" { print $3 }' /proc/self/cgroup)
if [[ $self_cgroup == *wayland-session-supervisor-* ]]; then
    fail "the control shell is inside the supervised graphical domain"
fi

control_session=
production_session=
production_vt=
while read -r session _; do
    [[ -n $session ]] || continue
    session_user=$(loginctl show-session "$session" -p User --value 2>/dev/null || true)
    session_seat=$(loginctl show-session "$session" -p Seat --value 2>/dev/null || true)
    session_tty=$(loginctl show-session "$session" -p TTY --value 2>/dev/null || true)
    session_type=$(loginctl show-session "$session" -p Type --value 2>/dev/null || true)
    [[ $session_user == "$uid" && $session_seat == seat0 ]] || continue
    if [[ $session_tty == "tty$control_vt" ]]; then
        control_session=$session
    fi
    if [[ $session_type == wayland ]]; then
        if [[ -n $production_session ]]; then
            fail "multiple seat0 Wayland sessions are present"
        fi
        production_session=$session
        production_vt=$(loginctl show-session "$session" -p VTNr --value)
    fi
done < <(loginctl list-sessions --no-legend)

[[ -n $control_session ]] || fail "cannot identify the login session for tty$control_vt"
[[ -n $production_session && -n $production_vt ]] \
    || fail "cannot identify the production seat0 Wayland session"
[[ $control_vt != "$production_vt" ]] \
    || fail "the control shell must not use production VT$production_vt"

printf 'control session: %s (VT%s)\n' "$control_session" "$control_vt"
printf 'production session: %s (VT%s)\n' "$production_session" "$production_vt"

sudo -v
XDG_SESSION_ID=$control_session XDG_VTNR=$control_vt \
    "$repo/tests/physical/prove-watchdog.sh"

observer_dir=/run/user/$uid/wayland-session-supervisor-physical-observer
observer_socket=$observer_dir/control
install -d -m 0700 "$observer_dir"
if ! ssh -S "$observer_socket" -O check localhost >/dev/null 2>&1; then
    rm -f "$observer_socket"
    ssh -MNf \
        -S "$observer_socket" \
        -o ControlMaster=yes \
        -o ExitOnForwardFailure=yes \
        -o ServerAliveInterval=15 \
        -o ServerAliveCountMax=4 \
        localhost
fi
ssh -S "$observer_socket" -O check localhost >/dev/null
ssh_connections=$(ss -Htn state established '( sport = :22 )' | wc -l)
(( ssh_connections > 0 )) || fail "localhost SSH observer did not become established"

printf 'SSH observer: established (%s server-side connection(s))\n' "$ssh_connections"
printf 'close observer: ssh -S %q -O exit localhost\n' "$observer_socket"

export XDG_SESSION_ID=$production_session
export XDG_VTNR=$production_vt
exec "$repo/tests/physical/run-niri-admission.sh" "$mode"
