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

The original host-seat pidfd remains deliberately unsupported because reopening
it after reboot would reconstruct an external relationship. The experimental
`services.wayland-session-supervisor.inDomainSeatAuthority` option instead
installs upstream `seatd-launch` as a dedicated setuid wrapper, forces
`LIBSEAT_BACKEND=seatd`, and places the launcher, privileged seatd child, and
Niri inside the checkpoint command tree. It conflicts with a host-global
`services.seatd` daemon. This is upstream's documented privilege model for
`seatd-launch`; Niri itself runs as the authenticated real UID.

The bounded physical run at
`/var/tmp/wss-physical-niri-admission-20260715T214728Z` proved exact equality
for the four-process namespace/cgroup and reached CRIU with physical i915/KMS
active. CRIU then refused seatd's `/dev/input/event2` file description. The
next generation therefore carries a versioned, read-only evdev admission query
and a separate input plugin. The initial subset requires empty queues, no grab,
no event filter, no force feedback, one exact device identity match, and equal
global input state. Every other state remains a conservative refusal. The
uinput ABI fixture and physical plugin round trip must pass before this option
is deployed as the normal session or any restore success is claimed.

## Bounded Niri admission

For a one-machine test, switch once from the production Niri VT to another
Linux text VT, log in, and run:

```bash
cd /home/john/code/dev-worktrees/github.com/johnrichardrinehart/wayland-session-supervisor/main
tests/physical/run-from-vt.sh --dry-run
```

The helper refuses a terminal inside the graphical supervisor domain or on the
production VT. It uses the text VT's own logind session for the harmless
current-boot watchdog proof, starts a persistent localhost SSH control
connection outside the graphical domain, then passes the production Wayland
session and VT explicitly to the admission harness. Thus no repeated manual VT
toggling is required: start the eventual `--execute` run from the text VT, and
the coordinator restores and activates the production VT after bounded
cleanup. A terminal on VT1 cannot be the observer because stopping the exact
Niri domain intentionally terminates that terminal and this agent with it.

`run-niri-admission.sh --dry-run` is non-destructive. It verifies the current
boot's schema-2 escape gate, all recovery-stage results, active SSH control,
user-manager lingering, exact temporary security-wrapper targets, both the
i915 and input CRIU plugins, and the safety config. It does not open DRM,
input, or a VT.

`--execute` is deliberately session-destructive and also requires
`WSS_PHYSICAL_NIRI_CONFIRM=stop-production-session`. It starts a root
coordinator outside the graphical process domain. The coordinator:

1. creates a blocked physical user service and obtains its cgroup;
2. arms a 180-second system-manager watchdog before releasing that service;
3. stops the production compositor scope, which terminates every graphical
   terminal and coding agent in that exact domain;
4. launches only the minimal Niri configuration through temporary,
   source-verified namespace and `seatd-launch` security wrappers;
5. runs CRIU leave-running capture under a shorter 75-second timeout;
6. stops the physical scope, cancels the watchdog only after confirmed stop,
   restores greetd/session/VT state, and writes private evidence under
   `/var/tmp/wss-physical-niri-admission-*`.

Execution is refused unless an established SSH session already exists; an
active SSH daemon alone is not an escape path. Initiate or observe the run from
that SSH session, then reconnect there after the graphical terminal exits;
never start another
compositor manually. A capture refusal is an admission diagnostic, not an
exact-restore success.
