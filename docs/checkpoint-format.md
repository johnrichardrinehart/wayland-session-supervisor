# Checkpoint and compatibility format

`wayland-session-supervisor run` writes `session.json`, `session.pid`, and
`resources.manifest` under the persistent per-session state directory. The
session identity contains structured compositor argv, canonical executable
path, SHA-256 executable digest, and resource-manifest digest.

## Capture

`capture` requires the same structured compositor argv used by `run`. It:

1. validates the live session identity;
2. creates a private `.staging-<id>` checkpoint directory;
3. writes a `capturing` manifest, exact domain inventory, and complete
   per-process `diagnostics.json`;
4. verifies that every cgroup process descends from the PID-namespace init and
   invokes CRIU for that recorded checkpoint root;
5. preserves a failed capture as `failed-<id>` with its log, categorized
   `failure-analysis.json`, diagnostics, and failure status;
6. while processes remain stopped, recursively snapshots reproducible runtime
   files, directories, and FIFO metadata (`runtime-fifos.json`), then hashes
   every CRIU image and snapshot file;
7. writes and fsyncs a `complete` manifest; and
8. atomically renames the staging directory and updates `current-checkpoint`.

A failed capture never replaces `current-checkpoint` and leaves the running
session intact when CRIU itself did not dump it.

## Restore

`restore` parses a known manifest schema and performs all compatibility and
integrity checks before recreating runtime files or invoking CRIU. Unknown
schemas are rejected. It compares:

- structured compositor argv;
- canonical compositor executable and SHA-256 digest;
- resource adapter ABI digest;
- kernel release;
- CRIU version; and
- every persisted checkpoint image digest.

An incompatibility writes a unique
`restore-attempts/<attempt-id>/failure.json` inside the preserved checkpoint and
exits without creating a process tree. Subsequent attempts never overwrite it. There is no relaunch or
reconstruction fallback. Compatible restore recreates only the runtime files
recorded as reproducible and then asks the shared `our-criu` 4.2 package to
restore the exact process tree. File locks, large deleted mappings, immutable
store inode remapping, and established TCP connections whose peers are both in
the managed domain are restored explicitly.

The configurable compositor command therefore has two roles: it selects the
compositor for a new session and supplies the expected identity for restore.
Changing from `niri` to another version or an immutable store path is supported
for new sessions, but an existing checkpoint is refused unless the full
identity is compatible.

## Evidence

The `checkpoint` NixOS VM check uses the real supervisor and CRIU. It verifies:

- failed-capture evidence preservation;
- complete manifests and nonempty image digest maps;
- cold reboot with different kernel boot IDs;
- a newly invoked restore process;
- refusal of an intentionally different compositor executable before mutation;
- byte-for-byte preservation of the checkpoint manifest across failed and
  successful restore; and
- continuation of the same PID, memory-only token and counter, and existing
  Wayland connection after restore.
