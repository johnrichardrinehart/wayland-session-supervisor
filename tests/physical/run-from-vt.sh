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

supervisor_cgroup=$(systemctl --user show \
    wayland-session-supervisor-default.scope -p ControlGroup --value)
[[ $supervisor_cgroup == /user.slice/* ]] \
    || fail "the production supervisor has no expected user cgroup"
supervisor_domain=/sys/fs/cgroup$supervisor_cgroup/domain
[[ -r $supervisor_domain/cgroup.procs ]] \
    || fail "the production supervisor domain cgroup is unavailable"

production_session=
while read -r domain_pid; do
    [[ $domain_pid =~ ^[0-9]+$ && -r /proc/$domain_pid/environ ]] || continue
    domain_session=$(
        tr '\0' '\n' < "/proc/$domain_pid/environ" 2>/dev/null \
            | sed -n 's/^XDG_SESSION_ID=//p' \
            | head -n 1 \
            || true
    )
    [[ -n $domain_session ]] || continue
    if [[ -n $production_session && $production_session != "$domain_session" ]]; then
        fail "the supervised domain contains multiple logind session identities"
    fi
    production_session=$domain_session
done < "$supervisor_domain/cgroup.procs"
[[ -n $production_session ]] \
    || fail "cannot identify XDG_SESSION_ID in the supervised production domain"

control_session=
production_vt=
production_session_seen=false
while read -r session _; do
    [[ -n $session ]] || continue
    session_user=$(loginctl show-session "$session" -p User --value 2>/dev/null || true)
    session_seat=$(loginctl show-session "$session" -p Seat --value 2>/dev/null || true)
    session_tty=$(loginctl show-session "$session" -p TTY --value 2>/dev/null || true)
    [[ $session_user == "$uid" && $session_seat == seat0 ]] || continue
    if [[ $session_tty == "tty$control_vt" ]]; then
        control_session=$session
    fi
    if [[ $session == "$production_session" ]]; then
        production_session_seen=true
        production_vt=$(loginctl show-session "$session" -p VTNr --value)
    fi
done < <(loginctl list-sessions --no-legend)

[[ -n $control_session ]] || fail "cannot identify the login session for tty$control_vt"
[[ $production_session_seen == true && -n $production_vt ]] \
    || fail "the supervised production session is not a seat0 login session"
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
