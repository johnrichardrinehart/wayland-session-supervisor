# Resource adapters

The first supported backend is deliberately encapsulated and headless. It
proves the ownership/interface contract without claiming that physical DRM,
GPU, libinput, or ALSA handles can survive a reboot.

## Interfaces supplied to the session

The supervisor closes every uncontrolled descriptor before creating adapters.
It then supplies only these resource interfaces:

| Resource | Session interface | Supervisor-owned side |
| --- | --- | --- |
| Display/GPU | `WSS_DISPLAY_BACKEND=headless` | No physical device is opened; rendering stays in the compositor's checkpointable memory |
| Runtime | private mode-0700 `XDG_RUNTIME_DIR` | namespace, permissions, cleanup, and persistence policy |
| Wayland | socket created under the private runtime directory | socket namespace; compositor and clients are checkpointed together |
| Input | connected Unix datagram descriptor `WSS_INPUT_FD=3` | mode-0600 `control.sock` forwards injected events to descriptor 3 |
| Audio | connected Unix datagram descriptor `WSS_AUDIO_FD=4` | observer consumes stream/sample records and appends them to persistent `audio-observations.log` |
| Temporary files | private mode-0700 `TMPDIR` | namespace and cleanup |

The descriptors are passed directly with `dup2`; compositor arguments never
contain shell expansions. The inner interfaces are connected socketpairs, so
applications can consume injected input and publish audio position without
opening host evdev or ALSA devices. The outer endpoints remain in the
supervisor. A later checkpoint implementation must explicitly externalize and
reattach these endpoints; they must not be mistaken for internal Wayland
sockets.

`resources.manifest` is atomically replaced in the session state directory and
records the adapter ABI. It explicitly marks native DRM, native libinput, and
native audio unsupported. Restore compatibility must reject a checkpoint whose
resource ABI differs.

## Test evidence

The sandboxed `core-integration` check launches a compositor fixture through the
real supervisor. The fixture verifies the headless declaration and private
runtime paths, receives `key:42` through the supervisor's mode-0600 control
socket and input descriptor, and sends
`stream=test samples=500000 hash=abc` through the audio descriptor. The check
then verifies that the supervisor wrote that exact observation to the persistent
session state directory.

The cold-reboot feasibility VM separately proves that a headless compositor,
its private Wayland socket, and an existing Wayland surface can be checkpointed
and restored together. Native hardware access remains a hard error until a
backend has equivalent VM or hardware evidence.
