# Resource adapters

The test-supported backend is deliberately encapsulated and headless. The
supervisor is application- and file-format-agnostic: it never parses browser,
terminal, media, audio, or video state. CRIU checkpoints those processes and
their data as opaque kernel/process state.

## Interfaces supplied to the session

The supervisor closes uncontrolled inherited descriptors and owns these generic
boundaries:

| Boundary | Session interface | Outer-supervisor ownership |
| --- | --- | --- |
| Display/GPU | `WSS_DISPLAY_BACKEND=headless` | no physical device is opened; renderer state stays in the checkpoint domain |
| Runtime | private mode-0700 `XDG_RUNTIME_DIR` | namespace, permissions, snapshot, and restoration |
| Wayland | compositor socket in the private runtime directory | compositor and both socket peers are checkpointed together |
| Ingress | append-only `adapter-ingress.log` | mode-0600 `control.sock` accepts opaque datagrams and appends them unchanged |
| Egress | `WSS_EGRESS_SPOOL`, an opaque append spool | private path creation, snapshot, and restoration; the supervisor does not interpret bytes |
| Temporary files | private mode-0700 `TMPDIR` | namespace and cleanup |

The application VM assigns test meanings to opaque ingress and egress bytes,
but that interpretation exists only in its fixtures and verifier. The Rust
supervisor contains no audio, video, mpv, aplay, browser, terminal, or media
logic.

`resources.manifest` records this generic adapter ABI. Native DRM, libinput,
and host audio device access remain unsupported because those host handles do
not cross the exact-restoration boundary. A changed adapter ABI causes
compatibility refusal before runtime mutation.

## Test evidence

`core-integration` sends an opaque payload through `control.sock`, verifies its
unchanged ingress record, writes unrelated opaque bytes to the egress spool,
and verifies descriptor hygiene and private paths. `application-reboot`
independently interprets deterministic PCM bytes written by its fixture,
validates them against generated media, and proves that a newly started outer
supervisor can deliver another opaque ingress event after reboot.
