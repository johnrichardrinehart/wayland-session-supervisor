# Requirement-to-evidence map

| Requirement | Implementation | Executable/retained evidence |
| --- | --- | --- |
| `repo` repository and worktree lifecycle | managed clone and `main` worktree | `tests/evidence/repository-bootstrap.json` |
| flake-parts development partition, package, module, hooks, formatter, CI | `flake.nix`, `dev/flake.nix`, `nix/flake/dev-partition.nix`, `.github/workflows/ci.yml` | `nix flake check`; `tests/evidence/derivation-stability.json` |
| narrow source closures | explicit package and fixture `lib.fileset` sources | `docs/nix-source-closures.md`; derivation identity probes in retained evidence |
| structured compositor argv and descriptor hygiene | `SessionConfig`, direct `Command` execution, descriptor closure | Rust unit tests and `core-integration` |
| dedicated PID namespace init and complete cgroup tree | `clone3(CLONE_NEWPID | CLONE_INTO_CGROUP)`, internal PID-1 reaper, pre-dump set equality | `checkpoint` refusal test; `tests/evidence/domain-inventory.json`; `tests/evidence/checkpoint/orphan.json`; `tests/evidence/checkpoint/refused-domain-inventory.json` |
| opaque resource boundaries | private runtime/Wayland namespace, generic ingress log and egress spool | `docs/resource-adapters.md`; `core-integration`; application input/spool records |
| atomic exact checkpoint and compatibility-first restore | staged manifests, hashes, schema/identity checks, no relaunch branch | `tests/evidence/checkpoint/checkpoint.json` and `restore-failure.json` |
| real reboot and new outer authority | persistent CRIU images; restore process remains authoritative and recreates opaque adapters | both retained verdicts and `outer-supervisor.json` records |
| browser windows, tabs, selected tabs, page memory, placement | Chromium CDP/Sway probes and Firefox WebDriver/Niri IPC probes | `tests/evidence/{before,after}.json`; `tests/evidence/niri/niri-{before,after}.json` |
| terminal/tmux and shell continuity | complete canonical terminal contents (only trailing empty cells removed), 120-line scrollback hash, tmux sessions/windows/panes, namespace PID-to-actual-CWD join, full global environment, and shell fixture state | retained before/after evidence contains identical 120-entry `terminal.contents`, line counts, and full-content hashes |
| mpv tolerance | deterministic 30-fps FFV1 media and IPC frame probe | retained before/after evidence; VM assertion ±60 frames |
| aplay tolerance and waveform | deterministic PCM, opaque supervisor-owned spool, independent WAV/hash validation | retained before/after evidence; VM assertion ±500,000 samples |
| compositor IPC, restored clients, injected input, new client | Sway IPC/input path and Niri IPC with post-restore kitty creation | `application-reboot` and `niri-application-reboot` assertions and retained verdict/outer records |
| Niri application domain | nested Niri+Weston, Firefox windows/tabs/memory, kitty contents, tmux, zsh, complete cgroup tree, real reboot | `tests/evidence/niri/`; `checks.x86_64-linux.niri-application-reboot` |
| changed command refusal without corruption | intentionally requests `/run/current-system/sw/bin/false`, hashes manifest before/after | `tests/evidence/checkpoint/restore-failure.json`; checkpoint VM |
| formatting, lint, static analysis, unit/integration and VM checks | flake checks plus Rust and Nix tooling | final verification commands recorded in commit trailers and CI |

The retained JSON is output copied from successful NixOS VM derivations, not a
hand-authored expected fixture. Host-visible PIDs naturally change across a
reboot; namespace-local PIDs, process state, protocol identities, and memory
values are the continuity identities.
