# Deterministic reboot restoration proof

## Claim and test boundary

The acceptance test proves continuity of a single managed session domain across an
actual guest reboot. It does not infer continuity from application relaunch,
application-native session recovery, or matching screenshots.

The VM has two storage boundaries:

- an ephemeral root disk, whose boot ID changes during the test; and
- a persistent checkpoint disk, mounted at `/var/lib/wayland-session-supervisor`.

The test records `/proc/sys/kernel/random/boot_id` immediately before capture and
after the machine returns. The values must differ. The outer supervisor PID and
start time must also differ. The checkpoint ID, capture manifest hash, and
restored process identities embedded in the checkpoint must agree. The test
powers the VM down through the guest reboot operation and waits for SSH/systemd
to disappear and return; restarting services is insufficient.

All fixtures are local and immutable Nix store paths. The VM has no network
route during capture or verification. Time is represented by explicit media
positions rather than wall-clock synchronization.

## Evidence envelope

Every probe writes canonical JSON to
`/var/lib/wayland-session-supervisor/evidence/<checkpoint-id>/<phase>/<probe>.json`.
The pre-capture directory is included in the checkpoint manifest. Post-restore
probes are written only after the compositor IPC health check succeeds.

Every document includes:

```json
{
  "schema": 1,
  "checkpoint_id": "sha256:<digest>",
  "phase": "before|after",
  "boot_id": "uuid",
  "supervisor_instance_id": "uuid",
  "monotonic_probe_sequence": 1,
  "probe": "browser|terminal|shell|mpv|aplay|compositor|session",
  "observations": {}
}
```

Comparison is performed by a separate verifier after restore. The verifier
writes `verdict.json` containing each assertion, observed values, tolerance,
and pass/fail status. A probe cannot write its own verdict.

## Session identity and anti-relaunch checks

Each managed process receives a random 256-bit continuity token in anonymous
memory after startup. The token is never placed in argv, environment, files, or
application configuration. A supervisor probe reads it through a controlled
process-memory interface before capture and after restore. Matching tokens and
checkpoint process records prove that a fresh application was not substituted.

For Wayland clients, the test client also maintains an incrementing counter and
a Wayland object ID in memory. After restoration it updates its existing
surface in response to injected input. A new test client is then connected to
the restored compositor. This distinguishes restoration of existing protocol
state from merely restoring compositor metadata.

## Browser fixture

The browser is Chromium configured with native crash/session recovery disabled,
a temporary profile on the managed runtime filesystem, no network, and remote
debugging over a supervisor-owned Unix-domain endpoint. Three immutable local
HTML fixtures expose unique tab IDs in title, DOM, and a JavaScript heap object.

Before capture the test creates:

- window A on workspace `browser-left`, containing tabs `alpha` and `beta`,
  with `beta` selected and each page scrolled to a distinct marker;
- window B on workspace `browser-right`, containing tab `gamma`, with a form
  value changed only in memory; and
- distinct compositor layout coordinates/sizes for A and B.

The browser probe records the continuity token; browser process identity;
DevTools target/window/tab relationships; selected tab; URL/title; DOM marker,
scroll offset, and in-memory form value; and compositor-reported app ID,
workspace, output, geometry, and layout ordering. After restore all fields must
match. Browser-native restore is disabled, and no browser process may be
spawned during restore.

## Terminal and shell fixture

The primary exact-restoration case uses a terminal plus an interactive shell,
not tmux reconstruction. A secondary tmux probe may be added but cannot replace
the primary proof.

Before capture the terminal contains a deterministic sequence of uniquely
numbered lines exceeding one visible screen. The probe obtains visible text and
scrollback through the terminal's test/control interface and records hashes of
both plus cursor position and dimensions.

The shell is stopped at an interactive prompt after:

- changing to an immutable fixture directory;
- exporting a unique variable and defining a non-exported variable;
- defining a function and alias;
- appending unique commands to in-memory history without flushing it;
- creating a background job whose in-memory counter is sampled; and
- running `false`, leaving `$?` equal to 1 at capture.

A dedicated inherited control descriptor asks the existing shell to serialize
observations without starting another shell. The probe records environment,
non-exported variable, function/alias definitions, CWD, in-memory history tail,
job identity/counter, last exit status, terminal scrollback hash, and continuity
token. Values must match after restore before any command that would overwrite
`$?` is executed. The background counter may advance only after thaw; its
identity and pre-freeze value must remain present.

## mpv fixture

A deterministic constant-frame-rate video is generated in the Nix store with
burned-in frame numbers and no external streams. mpv runs with native resume
files disabled and a supervisor-owned IPC socket. The fixture is paused only
for the instantaneous pre-capture probe; capture records media hash, playlist,
track selection, pause state, speed, volume, frame number, precise time
position, IPC client identity, and continuity token.

After restore, the existing IPC connection must answer. Media identity,
playlist, tracks, speed, and volume must match. The frame delta between capture
and the first post-restore observation must be at most 60 frames. No watch-later
file may exist and no new mpv process may be launched during restore.

## aplay fixture and audio boundary

A deterministic PCM WAV file contains a sample-index-coded waveform. aplay
writes PCM to a supervisor-owned virtual ALSA endpoint. The endpoint maintains
a ring buffer and monotonically increasing consumed-sample counter in the
managed resource adapter; the host-facing sink is outside the checkpoint and
is reconnectable.

The pre-capture probe records WAV hash and format, aplay continuity token,
ALSA stream parameters, adapter stream ID, submitted and consumed sample
positions, and a hash of the ring-buffer neighborhood. After restore, the same
stream ID must continue through the adapter and output samples must match the
expected waveform. The absolute difference between captured and first restored
consumed positions must be at most 500,000 samples. No new aplay process may be
launched during restore.

## Compositor and input fixture

The compositor command is represented as an argv array. Before capture the
probe records executable content hash, version output, argv, configuration
hash, IPC instance identity, output/workspace topology, window layout order,
and every fixture surface relationship.

After restore the existing compositor IPC endpoint must answer with the same
instance identity and topology. The supervisor injects a uniquely coded input
opaque event through its generic ingress adapter; an existing restored managed
fixture must observe it and update its in-memory counter. A new client must then
connect and create a surface without disturbing restored placement.

## Niri/Firefox/kitty/zsh proof

`checks.x86_64-linux.niri-manual-snapshot-and-reboot` is a second, independent real
reboot proof rather than an argv smoke test. Niri runs nested over a managed
headless Weston socket. Firefox is controlled through an in-domain geckodriver;
three deterministic local pages are split across a tab and a second browser
window. Before and after probes compare WebDriver handles, selected-window
identity, titles, URLs, memory-only JavaScript tokens, and Niri IPC window IDs,
application IDs, titles, and workspace IDs.

Kitty displays a tmux-attached zsh pane containing 80 deterministic lines. The
probe compares complete pane contents, tmux sessions/windows/layout and global
environment, the actual pane CWD, plus zsh PID, exported/local variables, CWD,
in-memory history digest, live background job, and last status. After restore,
Niri IPC must respond and spawn a new kitty window. Retained results are under
`tests/evidence/niri/`.

The Firefox fixture disables content, RDD, socket, utility, and GMP sandboxing:
CRIU 4.2 refuses nested IPC namespaces, and the test must not silently omit
those processes. This is an explicit test-backend limitation, not a claim that
sandboxed Firefox is currently restorable.

## Ordered VM test

1. Boot the VM and record boot ID A and supervisor instance A.
2. Disable external networking and start the managed compositor/session.
3. Start all browser, terminal/shell, mpv, aplay, and Wayland probe fixtures
   concurrently through the supervisor.
4. Arrange workspaces/windows and mutate only-in-memory state.
5. Quiesce probes, write before evidence, and capture checkpoint C.
6. Verify C is durable, request a real guest reboot, observe machine shutdown,
   and wait for the machine to boot again.
7. Record boot ID B and supervisor instance B; require A != B for both.
8. Restore C without launching replacement fixture applications.
9. Require compositor IPC readiness, then write after evidence.
10. Inject input into an existing surface and create one new client.
11. Run the independent comparator and require every assertion to pass.
12. Archive the manifest, probe documents, journal slice, process/cgroup
    inventory, spawn audit log, and verdict as the VM test output.

## Incompatibility test

A separate VM case captures with compositor fixture version A, reconfigures the
outer supervisor to request version B (different executable hash and declared
checkpoint ABI), and reboots. Restore must stop before creating or changing the
session domain, retain C byte-for-byte, and emit a structured mismatch listing
command argv, executable hash, version, configuration hash, and resource ABI.
It must not launch either fixture application set or silently reconstruct.

## Required verdict assertions

The final verifier requires:

- different boot and outer-supervisor instance IDs;
- unchanged checkpoint/manifest identity;
- no restore-time replacement process spawns;
- matching continuity tokens for every restored process;
- exact browser window/tab identities, state, and compositor placement;
- exact terminal visible/scrollback hashes and shell state;
- mpv frame delta <= 60;
- aplay consumed-sample delta <= 500000 and correct waveform continuation;
- responsive existing compositor and application IPC endpoints;
- successful input delivery to an existing surface;
- successful creation of a new post-restore surface; and
- an independently generated all-pass verdict.
