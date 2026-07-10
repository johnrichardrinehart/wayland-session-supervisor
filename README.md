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

## License

MIT
