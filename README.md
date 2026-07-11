# wayland-session-supervisor

A supervisor for checkpointing and restoring a controlled Wayland session domain across reboot.

The supervisor implements exact process-image restoration; relaunching applications is never represented as restoration. See [architecture](docs/architecture.md), [checkpoint format](docs/checkpoint-format.md), [state proof](docs/state-proof.md), [resource adapters](docs/resource-adapters.md), and [Nix source closures](docs/nix-source-closures.md), and the [requirement-to-evidence map](docs/verification-map.md).

## Development

Enter the nix-direnv environment or run:

```console
nix develop
nix flake check
```

The flake exposes the package, NixOS module, formatter, development shell, and checks. Development-only `git-hooks.nix` and `treefmt-nix` inputs are isolated in a flake-parts partition.

## CLI

Commands take a structured compositor argv after `--`; no shell evaluates it:

```console
wayland-session-supervisor run --session desktop -- /run/current-system/sw/bin/sway --unsupported-gpu
wayland-session-supervisor capture --session desktop -- /run/current-system/sw/bin/sway --unsupported-gpu
wayland-session-supervisor restore --session desktop -- /run/current-system/sw/bin/sway --unsupported-gpu
```

`--state-dir`, `--runtime-dir`, and `--cgroup-dir` select explicit ownership boundaries. Restore requires the same argv and executable identity and rejects incompatibility before mutating runtime or process state.

## Runtime requirements

The executable intentionally resolves the following runtime tools through `PATH`:

- `unshare` and `setsid` from `util-linux`: support the non-kernel/synthetic-cgroup integration path. Production kernel-cgroup sessions use `clone3(CLONE_NEWPID | CLONE_INTO_CGROUP)` so PID 1 is born atomically in the managed cgroup; the dependency remains explicit for the supported fallback path.
- `criu`: captures and restores the complete process tree. The application VM currently requires CRIU 4.2; Nixpkgs CRIU 4.1.1 fails its Sway workload during page transfer.
- `uname` from `coreutils`: records and validates kernel compatibility.
- The configured compositor executable when its first argv element is a name rather than an immutable path.

The NixOS module puts `util-linux`, `criu`, and `coreutils` on the service `PATH`. Direct CLI users must provide them explicitly; no ambient fallback or shell interpolation is used.

Creating PID namespaces and checkpointing processes require the corresponding Linux capabilities. The provided NixOS service runs with the required authority and delegates its cgroup.

## License

MIT
