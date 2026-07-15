# Physical compositor test safety

Physical compositor tests take DRM master and exclusive input control. They are
disabled until every gate below passes; a successful GPU/KMS fixture is not a
substitute for these controls.

## Required gates

1. Run `tests/physical/prove-watchdog.sh`. Its systemd timer and service live in
   a cgroup separate from the bounded victim and must stop that victim without
   input from the compositor session. The resulting private
   `escape-gate.json` is valid only for its recorded boot ID.
2. Validate `tests/physical/niri-minimal-safe.kdl`. Its immediate
   `Super+Shift+E` and `Ctrl+Alt+Delete` exits are non-inhibitable and skip the
   confirmation dialog. Tests must not replace this file with an empty or
   production configuration.
3. Arm the independent watchdog before opening DRM or evdev. The physical scope
   must have a finite deadline, and CRIU itself must run under a shorter bounded
   timeout.
4. Prove a control path outside the physical scope by stopping a harmless dummy
   scope through the same user manager. An untested VT key chord is not an
   out-of-band control path.
5. Preserve the original logind session ID. Watchdog cleanup stops the physical
   scope and asks logind to reactivate that session before writing its private
   marker.
6. Keep the graphical production session stopped and verify no Niri process
   remains before test acquisition. Never run two seat-owning compositors.

## Current blocker

The first physical Niri admission run retained a pidfd supplied by the host
seat/session stack. Its PID namespace is outside the supervised process domain.
Reopening that pidfd after reboot would reconstruct an external relationship,
which the exact-restore contract forbids. A future physical harness must first
place the seat authority and its process references inside the checkpoint
domain or obtain explicit design review for a different model.

Accordingly this repository intentionally provides no command that launches a
physical compositor yet. `prove-watchdog.sh` is safe to run because its victim
is only `sleep`; it does not open DRM, evdev, or a TTY.
