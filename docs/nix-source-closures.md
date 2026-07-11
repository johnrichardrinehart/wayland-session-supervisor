# Nix source closures

Derivations include only inputs they consume.

- The Rust package uses `lib.fileset.toSource` over `rust/Cargo.toml`, `rust/Cargo.lock`, and `rust/src/*.rs`. Documentation, checks, fixtures, and repository metadata cannot rebuild it.
- VM fixture derivations use one-file `lib.fileset` sources. Each VM check therefore depends on its own Nix expression, its explicitly referenced fixture, the package, and declared Nix packages—not the complete repository source.
- `checks.package` and `checks.cargo-test` intentionally share the package derivation.
- The formatter executable is configuration-only and has no repository source input.
- The treefmt check intentionally consumes every file selected by treefmt because those files are the check's actual inputs. A formatted-file edit should change that check; it must not change unrelated build or VM derivations.
- Development hooks similarly consume the files they lint when invoked; their tool wrappers remain configuration-only.

## Stability evidence

The source-closure audit recorded derivation paths before and after an added comment in `nix/checks/checkpoint.nix`:

| Output | Stable across unrelated checkpoint edit? |
| --- | --- |
| package / cargo-test | yes |
| core-integration | yes |
| feasibility | yes |
| application-reboot | yes |
| formatter executable | yes |
| treefmt check | intentionally no: the edited Nix file is an actual formatter input |

The application-reboot derivation remained
`/nix/store/15v10m942hl1n3fj08yih7l6x2l2firg-vm-test-run-wayland-session-supervisor-application-reboot.drv`.

Positive controls were also run:

- Editing `tests/fixtures/application-shell.sh` changed application-reboot from `15v10…` to `aicpbc…`.
- Editing `README.md` left the package at `w5hg6…`.
- Editing `rust/src/main.rs` changed the package from `w5hg6…` to `n272z…`.

These probes used temporary edits that were restored immediately. They establish both isolation and sensitivity: unrelated files are absent, while actual inputs remain effective.
