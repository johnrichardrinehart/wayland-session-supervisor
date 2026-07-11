# wayland-session-supervisor

A supervisor for checkpointing and restoring a controlled Wayland session domain across reboot.

The project is under active development. Exact restoration, resource adapters, compatibility policy, and the deterministic NixOS VM evidence suite are tracked in `docs/` and `nix/checks/` as they are implemented. Relaunching applications is not considered exact restoration.

## Development

Enter the nix-direnv environment or run:

```console
nix develop
nix flake check
```

The flake exposes the package, NixOS module, formatter, development shell, and checks. Development-only `git-hooks.nix` and `treefmt-nix` inputs are isolated in a flake-parts partition.

## Runtime requirements

The executable intentionally resolves the following runtime tools through `PATH`:

- `unshare` from `util-linux`: creates the dedicated PID namespace and keeps a namespace-init process as the reaper and checkpoint root.
- `criu`: captures and restores the complete process tree. The application VM currently requires CRIU 4.2; Nixpkgs CRIU 4.1.1 fails its Sway workload during page transfer.
- `uname` from `coreutils`: records and validates kernel compatibility.
- The configured compositor executable when its first argv element is a name rather than an immutable path.

The NixOS module puts `util-linux`, `criu`, and `coreutils` on the service `PATH`. Direct CLI users must provide them explicitly; no ambient fallback or shell interpolation is used.

Creating PID namespaces and checkpointing processes require the corresponding Linux capabilities. The provided NixOS service runs with the required authority and delegates its cgroup.

## License

MIT
