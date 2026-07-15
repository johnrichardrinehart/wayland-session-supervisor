# Physical compositor test safety

Physical compositor tests take DRM master and exclusive input control. They are
disabled until every gate below passes; a successful GPU/KMS fixture is not a
substitute for these controls.

## Required gates

1. Refresh sudo authentication with `sudo true`, then run
   `tests/physical/prove-watchdog.sh`. Its timer and action run under the system
   manager, outside the bounded user victim. The action writes the victim's
   `cgroup.kill`, stops its transient unit, and restores the recorded session
   and VT without compositor input. The resulting private `escape-gate.json`
   is valid only for its recorded boot ID.
2. Validate `tests/physical/niri-minimal-safe.kdl`. Its immediate
   `Super+Shift+E` and `Ctrl+Alt+Delete` exits are non-inhibitable and skip the
   confirmation dialog. Tests must not replace this file with an empty or
   production configuration.
3. Arm the independent watchdog before opening DRM or evdev. The physical scope
   must have a finite deadline, and CRIU itself must run under a shorter bounded
   timeout.
4. Prove the system-manager control path against a harmless dummy unit before
   any physical launch. A same-user-manager stop or an untested VT key chord is
   not an independent out-of-band control path.
5. Preserve the original logind session ID. Watchdog cleanup stops the physical
   scope and asks logind to reactivate that session before writing its private
   marker.
6. Keep the graphical production session stopped and verify no Niri process
   remains before test acquisition. Never run two seat-owning compositors.

## Current blocker

The first physical Niri admission run retained a pidfd supplied by the host
seat/session stack. Its PID namespace is outside the supervised process domain.
Reopening that pidfd after reboot would reconstruct an external relationship,
which the exact-restore contract forbids. The experimental
`services.wayland-session-supervisor.inDomainSeatAuthority` option is the
fail-closed candidate: it installs upstream `seatd-launch` as a dedicated
setuid wrapper, forces `LIBSEAT_BACKEND=seatd`, and places the seatd launcher,
its privileged seatd child, and Niri inside the checkpoint command tree. It
conflicts with a host-global `services.seatd` daemon and is off by default.
This is upstream's documented privilege model for `seatd-launch`; Niri itself
runs as the authenticated real UID.

The option has configuration-level and VM reboot proof: CRIU restores the
mixed-credential seatd tree with exact namespace-local PIDs and credentials.
It must not be enabled on the physical target until seatd socket/device
identity, rollback, and physical restore behavior pass without external
process references. Accordingly this repository intentionally provides no
command that launches a physical compositor yet. `prove-watchdog.sh` is safe to run because
its victim is only `sleep`; it does not open DRM, evdev, or a TTY.
