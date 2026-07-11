# Managed session and resource contract

## Process boundary

The outer supervisor is never part of a checkpoint. It owns persistent metadata,
checkpoint images, compatibility decisions, and the host-facing resource
adapters. Each restorable session is a complete process subtree in a dedicated
cgroup. The subtree starts with a session-init process and contains the
compositor, all exact-restoration clients, and session-private services.

The session starts with stdin, stdout, stderr, and every descriptor above them
closed or deliberately connected to supervisor adapters. The feasibility test
uses null standard streams because a systemd journal stream is an external Unix
socket and correctly prevents an unannotated CRIU dump. Production adapters
must be explicitly listed in the manifest; accidental external descriptors are
a capture error.

The session receives private runtime and temporary directories and runs in a
dedicated PID namespace. A stable namespace-init process is PID 1 inside that
namespace, reaps orphans, and is the CRIU checkpoint root; daemonized and
double-forked clients therefore cannot escape the process tree. Before capture,
the supervisor compares the cgroup inventory with descendants of that root and
refuses an incomplete domain. The cgroup remains the freeze, inventory, and
kill boundary.

## Resource ownership

Resources are classified before capture:

- **Internal**: both endpoints and all kernel state are inside the managed
  subtree. Wayland client/compositor socket pairs are internal and are restored
  by checkpointing the compositor and clients together.
- **Reproducible**: the supervisor recreates an equivalent resource before
  restore from manifest data, such as a private runtime directory.
- **Adapter-backed**: session processes connect to a stable, checkpointable
  inner endpoint while the outer adapter reconnects to host hardware after
  reboot. Display presentation, input injection, and audio consumption use this
  category in the test-supported backend.
- **Unsupported**: an uncheckpointable external resource without an adapter.
  Capture fails and identifies the process, descriptor, and resource class.

The supervisor owns adapter lifecycle and host permissions. A compositor never
receives an unrestricted physical DRM, evdev, udev, logind, or host audio handle
in the encapsulated backend. Native backends may later implement explicit
reacquisition, but are unsupported until independently tested.

## Capture transaction

1. Reject new launches and lock the session generation.
2. Query adapters and enumerate the cgroup/process/descriptor inventory.
3. Validate that every external resource has a declared restoration strategy.
4. Write an incomplete manifest in a new checkpoint staging directory.
5. Freeze and CRIU-dump the complete session-init tree.
6. Hash images and metadata, fsync files and directories, and atomically mark
   the manifest complete.
7. Kill the captured tree only after the durable commit; otherwise thaw it.

A failed staging directory remains diagnostic evidence and is never selected
for automatic restore.

## Restore transaction

1. Load only a complete, hash-valid checkpoint.
2. Resolve the configured compositor argv without a shell and hash the resolved
   executable and configuration.
3. Compare kernel/CRIU architecture, compositor identity and declared ABI,
   resource-adapter ABI, and required immutable store paths.
4. Refuse an incompatible checkpoint before creating the session cgroup or
   changing adapter state.
5. Recreate reproducible resources and inner adapter endpoints.
6. Restore the complete process tree into a fresh session cgroup.
7. Verify compositor IPC, existing client protocol activity, and adapter
   attachment before accepting launches.
8. Roll back newly created resources on failure while preserving checkpoint and
   restore logs.

The supervisor does not spawn a fresh compositor during exact restore. The
configured command selects what is started for a new session and supplies the
identity against which a checkpoint is validated. A changed executable may be
used for a new session, but cannot impersonate the process image in an old
checkpoint.

## Proven feasibility boundary

`checks.x86_64-linux.feasibility` builds a headless Weston compositor and a
purpose-built Wayland client. The client creates and commits a surface, stores a
unique token and counter only in process memory, and exposes a probe on SIGUSR1.
The NixOS VM test:

1. starts compositor and client in one process tree with clean standard streams;
2. records the client's PID, token, counter, and successful Wayland round trip;
3. CRIU-dumps the complete tree, including both ends of the Wayland socket;
4. shuts the guest down, starts it again, and requires a different kernel boot
   ID;
5. restores the tree from persistent disk; and
6. signals the same PID and verifies the same token, incremented in-memory
   counter, and another successful round trip on the existing connection.

This proves the central exact-restoration premise for an encapsulated headless
Wayland domain across a cold guest reboot. `application-reboot` extends it to
Sway, Chromium, foot with an interactive shell, mpv, and aplay; it also proves
restored compositor IPC, post-restore input control, and connection of a new
Wayland client. Native DRM/GPU/input/audio hardware remains outside the proven
headless adapter boundary.
