# Diagnostics and compatibility reports

The supervisor keeps machine-readable evidence for workloads that are not yet
restorable. Diagnostics never relaunch or reconstruct applications.

## Safe preflight report

While a managed session is running, use the same session and compositor argv as
`run`:

```console
wayland-session-supervisor diagnose \
  --session desktop \
  --state-dir "$XDG_STATE_HOME/wayland-session-supervisor" \
  --runtime-dir "$XDG_RUNTIME_DIR/wayland-session-supervisor" \
  -- niri --config /etc/niri/config.kdl --session
```

This does not freeze processes or invoke CRIU. It writes a mode-0600 JSON report
under `sessions/<name>/diagnostics/` and atomically updates
`latest-diagnostics.json`. The report contains:

- boot, kernel, and pinned CRIU identity;
- cgroup/checkpoint-tree equality;
- every managed PID, parent PID, namespace PID chain, executable, argv, and
  thread count;
- namespace inode identities;
- every open descriptor target;
- flags for devices, deleted files, sockets, anonymous inodes, and nested
  namespaces; and
- actionable recommendations for resource classes likely to require a new
  adapter, refusal rule, or CRIU capability.

Command lines and descriptor paths can contain sensitive local information.
Reports are private by default; review and redact them before sharing.

## Failed capture analysis

Every capture staging directory includes `diagnostics.json` before CRIU runs.
If CRIU fails, the retained `failed-<id>/` directory additionally contains:

- `dump.log`: complete CRIU output;
- `failure-analysis.json`: extracted error/warning lines and categorized next
  actions;
- `domain-inventory.json`: the exact cgroup and tree PID sets; and
- `checkpoint.json`: command/resource identity and failure status.

The analyzer recognizes common unsupported boundaries such as nested
namespaces, external Unix sockets, connected TCP sockets, and device/file
descriptors. Recommendations remain conservative: for example, an external
Unix socket should not be hidden with `--ext-unix-sk` when its peer was supposed
to be part of the exact checkpoint domain.

Failed captures never replace `current-checkpoint`, so reports can be retained
for regression fixtures and compared as support improves.
