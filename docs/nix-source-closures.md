# Nix source closures

Derivations include only inputs they consume.

- The Rust package uses `lib.fileset.toSource` over `rust/Cargo.toml`, `rust/Cargo.lock`, and `rust/src/*.rs`. Documentation, checks, fixtures, and repository metadata cannot rebuild it.
- `packages.our-criu` is defined once in `nix/packages/criu.nix` and exported through `overlays.default` as `pkgs.our-criu`; checks and the NixOS module reuse that derivation rather than carrying local overrides.
- VM fixture derivations use one-file `lib.fileset` sources. Each VM check depends on its own Nix expression, explicitly referenced fixtures, packages, and generated inputs—not the complete repository source.
- `checks.package` and `checks.cargo-test` intentionally share the package derivation.
- The formatter executable is configuration-only and has no repository source input.
- Treefmt receives an explicit extension-filtered `builtins.path` because `self` is string-like inside the development partition and cannot be passed to `lib.fileset`. Only `.nix`, `.rs`, `.yml`, and `.yaml` files enter that check; retained JSON evidence and documentation cannot invalidate it.
- Development hook wrappers are configuration-only; hooks consume only their configured file classes when invoked.

## Stability evidence

`tests/evidence/derivation-stability.json` is the authoritative, machine-readable
matrix. It records final derivation paths for packages, formatter, development
shell/hooks, and every check, then records temporary mutation probes for actual
inputs and unrelated tracked evidence. The matrix specifically proves that:

- changing `nix/checks/checkpoint.nix` does not change either application reboot check;
- changing the corresponding application expression or fixture does change its check;
- changing Rust changes the package and package-dependent checks;
- changing development/treefmt configuration changes formatter, development, and treefmt outputs; and
- changing retained JSON evidence changes none of those derivations.

All temporary mutations are restored before verification. This establishes both
isolation and sensitivity without embedding stale store paths in prose.
