# Diagnostics and compatibility reports

The supervisor keeps machine-readable evidence for workloads that are not yet
restorable. Diagnostics never relaunch or reconstruct applications.

## Automatic reports

No user action is required. Every checkpoint attempt records diagnostics before
CRIU runs. Capture refusal, CRIU dump failure, compatibility refusal during
restore, and CRIU restore failure atomically update `latest-diagnostics.json`
to identify the relevant report and failure analysis.

The report contains:

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
If a CRIU dump fails, the retained `failed-<id>/` directory additionally contains:

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

Every restore invocation gets a unique private directory under
`checkpoints/<id>/restore-attempts/<attempt-id>/`. Compatibility refusals retain
`failure.json` there before any mutable restore action. CRIU restore failures
retain `restore.log`, `failure.json` with `kind: criu-restore`, and
`failure-analysis.json`. No prior restore attempt is overwritten; only the
`latest-diagnostics.json` pointer is replaced.

Failed captures never replace `current-checkpoint`, so reports can be retained
for regression fixtures and compared as support improves. The standalone
`diagnose` subcommand remains available for developers, but is not part of the
normal user workflow.
