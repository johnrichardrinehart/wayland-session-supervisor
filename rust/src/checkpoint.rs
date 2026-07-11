use crate::SessionConfig;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet};
use std::ffi::{OsStr, OsString};
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Write};
use std::os::unix::fs::{FileTypeExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::process::{Command, ExitStatus};
use std::thread;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

#[derive(Debug, Clone, Serialize, Deserialize, Eq, PartialEq)]
pub struct SessionManifest {
    pub schema: u32,
    pub session_name: String,
    pub compositor_argv: Vec<String>,
    pub compositor_executable: PathBuf,
    pub compositor_sha256: String,
    pub resource_manifest_sha256: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DomainInventory {
    pub schema: u32,
    pub checkpoint_root_pid: u32,
    pub cgroup_path: PathBuf,
    pub cgroup_pids: BTreeSet<u32>,
    pub tree_pids: BTreeSet<u32>,
    pub equal: bool,
    pub error: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProcessDiagnostic {
    pub pid: u32,
    pub parent_pid: Option<u32>,
    pub namespace_pids: Vec<u32>,
    pub executable: Option<PathBuf>,
    pub command: Vec<String>,
    pub thread_count: usize,
    pub namespaces: BTreeMap<String, String>,
    pub descriptors: BTreeMap<u32, String>,
    pub resource_flags: BTreeSet<String>,
    pub inspection_errors: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DiagnosticReport {
    pub schema: u32,
    pub generated_unix_nanos: u128,
    pub boot_id: String,
    pub kernel_release: String,
    pub criu_version: String,
    pub session: String,
    pub checkpoint_root_pid: u32,
    pub domain: DomainInventory,
    pub processes: Vec<ProcessDiagnostic>,
    pub recommendations: BTreeSet<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FailureAnalysis {
    pub schema: u32,
    pub criu_exit_status: String,
    pub errors: Vec<String>,
    pub warnings: Vec<String>,
    pub recommendations: BTreeSet<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CheckpointManifest {
    pub schema: u32,
    pub checkpoint_id: String,
    pub status: String,
    pub session: SessionManifest,
    pub root_pid: u32,
    pub boot_id: String,
    pub kernel_release: String,
    pub criu_version: String,
    pub images: BTreeMap<String, String>,
    pub failure: Option<String>,
}

#[derive(Debug, Clone)]
pub struct CheckpointOptions {
    pub session_name: String,
    pub state_dir: PathBuf,
    pub runtime_dir: PathBuf,
    pub criu: OsString,
    pub compositor_argv: Vec<OsString>,
    pub leave_running: bool,
}

impl CheckpointOptions {
    pub fn parse(arguments: impl IntoIterator<Item = OsString>) -> Result<Self, String> {
        let mut arguments = arguments.into_iter();
        let mut session_name = String::from("default");
        let mut state_dir = PathBuf::from("/var/lib/wayland-session-supervisor");
        let mut runtime_dir = PathBuf::from("/run/wayland-session-supervisor");
        let mut criu = OsString::from("criu");
        let mut leave_running = false;
        loop {
            let argument = arguments
                .next()
                .ok_or_else(|| String::from("missing `--` before compositor command"))?;
            if argument == "--" {
                break;
            }
            if argument == "--leave-running" {
                leave_running = true;
                continue;
            }
            let value = arguments
                .next()
                .ok_or_else(|| format!("missing value for {}", argument.to_string_lossy()))?;
            match argument.to_str() {
                Some("--session") => {
                    session_name = value
                        .into_string()
                        .map_err(|_| String::from("session name must be UTF-8"))?;
                }
                Some("--state-dir") => state_dir = value.into(),
                Some("--runtime-dir") => runtime_dir = value.into(),
                Some("--criu") => criu = value,
                _ => return Err(format!("unknown option: {}", argument.to_string_lossy())),
            }
        }
        let compositor_argv = arguments.collect::<Vec<_>>();
        if compositor_argv.is_empty() {
            return Err(String::from("a compositor command is required"));
        }
        Ok(Self {
            session_name,
            state_dir,
            runtime_dir,
            criu,
            compositor_argv,
            leave_running,
        })
    }

    fn session_state_dir(&self) -> PathBuf {
        self.state_dir.join("sessions").join(&self.session_name)
    }
}

pub fn write_session_manifest(config: &SessionConfig, session_state_dir: &Path) -> io::Result<()> {
    let manifest = session_manifest(
        &config.session_name,
        &config.compositor_argv,
        session_state_dir,
    )?;
    write_json_atomic(&session_state_dir.join("session.json"), &manifest)
}

pub fn diagnose(options: &CheckpointOptions) -> io::Result<PathBuf> {
    let session_dir = options.session_state_dir();
    let expected: SessionManifest = read_json(&session_dir.join("session.json"))?;
    validate_expected_session(&expected, options, &session_dir)?;
    let root_pid = read_trimmed(session_dir.join("session.pid"))?
        .parse::<u32>()
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
    let inventory = inventory_domain_stable(&session_dir, root_pid)?;
    let report = collect_diagnostics(options, root_pid, inventory)?;
    let reports = session_dir.join("diagnostics");
    fs::create_dir_all(&reports)?;
    let name = format!(
        "{}-{}.json",
        report.generated_unix_nanos,
        std::process::id()
    );
    let path = reports.join(&name);
    write_json_atomic(&path, &report)?;
    write_json_atomic(
        &session_dir.join("latest-diagnostics.json"),
        &serde_json::json!({ "schema": 1, "report": format!("diagnostics/{name}") }),
    )?;
    Ok(path)
}

pub fn capture(options: &CheckpointOptions) -> io::Result<PathBuf> {
    let session_dir = options.session_state_dir();
    let expected: SessionManifest = read_json(&session_dir.join("session.json"))?;
    validate_expected_session(&expected, options, &session_dir)?;
    let root_pid = fs::read_to_string(session_dir.join("session.pid"))?
        .trim()
        .parse::<u32>()
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;

    let checkpoint_id = format!(
        "{}-{}",
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_err(io::Error::other)?
            .as_nanos(),
        std::process::id()
    );
    let checkpoints = session_dir.join("checkpoints");
    fs::create_dir_all(&checkpoints)?;
    let staging = checkpoints.join(format!(".staging-{checkpoint_id}"));
    fs::create_dir(&staging)?;
    fs::set_permissions(&staging, fs::Permissions::from_mode(0o700))?;

    let mut manifest = CheckpointManifest {
        schema: 1,
        checkpoint_id: checkpoint_id.clone(),
        status: String::from("capturing"),
        session: expected,
        root_pid,
        boot_id: read_trimmed("/proc/sys/kernel/random/boot_id")?,
        kernel_release: command_output("uname", ["-r"])?,
        criu_version: command_output(&options.criu, ["--version"])?,
        images: BTreeMap::new(),
        failure: None,
    };
    write_json_atomic(&staging.join("checkpoint.json"), &manifest)?;

    let inventory =
        inventory_domain_stable(&session_dir, root_pid).unwrap_or_else(|error| DomainInventory {
            schema: 1,
            checkpoint_root_pid: root_pid,
            cgroup_path: PathBuf::new(),
            cgroup_pids: BTreeSet::new(),
            tree_pids: BTreeSet::new(),
            equal: false,
            error: Some(error.to_string()),
        });
    write_json_atomic(&staging.join("domain-inventory.json"), &inventory)?;
    let diagnostics = collect_diagnostics(options, root_pid, inventory.clone())?;
    write_json_atomic(&staging.join("diagnostics.json"), &diagnostics)?;
    if !inventory.equal {
        manifest.status = String::from("failed");
        manifest.failure = Some(format!(
            "managed cgroup/tree mismatch: cgroup={:?}, tree={:?}, error={:?}",
            inventory.cgroup_pids, inventory.tree_pids, inventory.error
        ));
        write_json_atomic(&staging.join("checkpoint.json"), &manifest)?;
        let failed = checkpoints.join(format!("failed-{checkpoint_id}"));
        fs::rename(&staging, &failed)?;
        publish_latest_diagnostics(&session_dir, &failed, None)?;
        return Err(io::Error::other(format!(
            "{}; evidence preserved at {}",
            manifest
                .failure
                .as_deref()
                .unwrap_or("incomplete managed domain"),
            failed.display()
        )));
    }

    let mut criu = Command::new(&options.criu);
    criu.args([
        OsStr::new("dump"),
        OsStr::new("--tree"),
        OsStr::new(&root_pid.to_string()),
        OsStr::new("--images-dir"),
        staging.as_os_str(),
        OsStr::new("--shell-job"),
        OsStr::new("--file-locks"),
        // Both peers of managed loopback connections are in the domain.
        OsStr::new("--tcp-established"),
        // Managed applications can map deleted temporary files larger than CRIU's 1 MiB
        // default. Preserve those mappings as checkpoint images rather than
        // depending on volatile runtime-directory contents.
        OsStr::new("--ghost-limit"),
        OsStr::new("1073741824"),
        // Managed applications watch immutable resources below /nix/store.
        // Overlayfs file handles are not always openable directly, so use
        // the stable store path as an inode-remap search root.
        OsStr::new("--irmap-scan-path"),
        OsStr::new("/nix/store"),
        OsStr::new("--log-file"),
        OsStr::new("dump.log"),
        OsStr::new("-v2"),
    ]);
    if options.leave_running {
        criu.arg("--leave-running");
    }
    let status = criu.status()?;
    if !status.success() {
        let analysis = analyze_criu_failure(&staging.join("dump.log"), &status);
        write_json_atomic(&staging.join("failure-analysis.json"), &analysis)?;
        manifest.status = String::from("failed");
        manifest.failure = Some(format!("criu dump exited with {status}"));
        write_json_atomic(&staging.join("checkpoint.json"), &manifest)?;
        let failed = checkpoints.join(format!("failed-{checkpoint_id}"));
        fs::rename(&staging, &failed)?;
        publish_latest_diagnostics(
            &session_dir,
            &failed,
            Some(&failed.join("failure-analysis.json")),
        )?;
        return Err(io::Error::other(format!(
            "checkpoint failed; evidence preserved at {}",
            failed.display()
        )));
    }

    // A successful dump has stopped the domain, so mutable runtime files can
    // be copied at the same state point represented by the process images.
    snapshot_runtime_files(
        &options.runtime_dir.join(&options.session_name),
        &staging.join("runtime-files"),
    )?;
    manifest.images = hash_checkpoint_images(&staging)?;
    manifest.status = String::from("complete");
    write_json_atomic(&staging.join("checkpoint.json"), &manifest)?;
    let completed = checkpoints.join(&checkpoint_id);
    fs::rename(&staging, &completed)?;
    write_atomic(
        &session_dir.join("current-checkpoint"),
        checkpoint_id.as_bytes(),
    )?;
    sync_directory(&checkpoints)?;
    sync_directory(&session_dir)?;
    Ok(completed)
}

pub fn restore(options: &CheckpointOptions) -> io::Result<ExitStatus> {
    let session_dir = options.session_state_dir();
    let checkpoint_id = read_trimmed(session_dir.join("current-checkpoint")).map_err(|error| {
        io::Error::new(error.kind(), format!("read current checkpoint: {error}"))
    })?;
    let checkpoint = session_dir.join("checkpoints").join(checkpoint_id);
    let manifest: CheckpointManifest =
        read_json(&checkpoint.join("checkpoint.json")).map_err(|error| {
            io::Error::new(error.kind(), format!("read checkpoint manifest: {error}"))
        })?;
    let restore_attempt = create_restore_attempt(&checkpoint)?;
    if manifest.status != "complete" {
        return compatibility_failure(
            &session_dir,
            &checkpoint,
            &restore_attempt,
            "checkpoint status is not complete",
        );
    }
    if let Err(error) = validate_expected_session(&manifest.session, options, &session_dir) {
        return compatibility_failure(
            &session_dir,
            &checkpoint,
            &restore_attempt,
            &error.to_string(),
        );
    }
    let current_kernel = command_output("uname", ["-r"])
        .map_err(|error| io::Error::new(error.kind(), format!("query kernel release: {error}")))?;
    if current_kernel != manifest.kernel_release {
        return compatibility_failure(
            &session_dir,
            &checkpoint,
            &restore_attempt,
            &format!(
                "kernel mismatch: captured {:?}, current {:?}",
                manifest.kernel_release, current_kernel
            ),
        );
    }
    let current_criu = command_output(&options.criu, ["--version"])
        .map_err(|error| io::Error::new(error.kind(), format!("query CRIU version: {error}")))?;
    if current_criu != manifest.criu_version {
        return compatibility_failure(
            &session_dir,
            &checkpoint,
            &restore_attempt,
            &format!(
                "CRIU mismatch: captured {:?}, current {:?}",
                manifest.criu_version, current_criu
            ),
        );
    }
    verify_checkpoint_images(&checkpoint, &manifest.images).map_err(|error| {
        io::Error::new(error.kind(), format!("verify checkpoint images: {error}"))
    })?;
    let session_runtime_dir = options.runtime_dir.join(&options.session_name);
    restore_runtime_files(&checkpoint.join("runtime-files"), &session_runtime_dir).map_err(
        |error| io::Error::new(error.kind(), format!("restore runtime snapshot: {error}")),
    )?;
    crate::start_restored_adapters(&session_runtime_dir, &session_dir)
        .map_err(|error| io::Error::new(error.kind(), format!("start outer adapters: {error}")))?;
    let restored_pid_file = checkpoint.join("restore.pid");
    let restore_log = restore_attempt.join("restore.log");
    let status = Command::new(&options.criu)
        .args([
            OsStr::new("restore"),
            OsStr::new("--images-dir"),
            checkpoint.as_os_str(),
            OsStr::new("--shell-job"),
            OsStr::new("--file-locks"),
            OsStr::new("--tcp-established"),
            OsStr::new("--restore-detached"),
            OsStr::new("--pidfile"),
            restored_pid_file.as_os_str(),
            OsStr::new("--log-file"),
            restore_log.as_os_str(),
            OsStr::new("-v2"),
        ])
        .status()?;
    if !status.success() {
        let analysis = analyze_criu_failure(&restore_attempt.join("restore.log"), &status);
        let analysis_path = restore_attempt.join("failure-analysis.json");
        write_json_atomic(&analysis_path, &analysis)?;
        write_json_atomic(
            &restore_attempt.join("failure.json"),
            &serde_json::json!({
                "schema": 1,
                "kind": "criu-restore",
                "reason": format!("criu restore exited with {status}"),
            }),
        )?;
        publish_latest_diagnostics(&session_dir, &checkpoint, Some(&analysis_path))?;
        return Ok(status);
    }
    let restored_root_pid = read_trimmed(&restored_pid_file)?
        .parse::<u32>()
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
    write_json_atomic(
        &session_dir.join("outer-supervisor.json"),
        &serde_json::json!({
            "schema": 1,
            "pid": std::process::id(),
            "boot_id": read_trimmed("/proc/sys/kernel/random/boot_id")?,
            "role": "restored-session-authority",
            "restored_root_pid": restored_root_pid
        }),
    )?;
    // Remain authoritative for adapters and lifecycle after detached restore.
    while Path::new(&format!("/proc/{restored_root_pid}")).exists() {
        thread::sleep(Duration::from_millis(100));
    }
    Ok(status)
}

fn inventory_domain_stable(session_dir: &Path, root_pid: u32) -> io::Result<DomainInventory> {
    let mut latest = inventory_domain(session_dir, root_pid)?;
    for _ in 0..20 {
        if latest.equal {
            return Ok(latest);
        }
        thread::sleep(Duration::from_millis(25));
        latest = inventory_domain(session_dir, root_pid)?;
    }
    Ok(latest)
}

fn inventory_domain(session_dir: &Path, root_pid: u32) -> io::Result<DomainInventory> {
    let cgroup_path = PathBuf::from(read_trimmed(session_dir.join("cgroup.path"))?);
    let cgroup_pids = read_pid_set(&cgroup_path.join("cgroup.procs"))?;
    let tree_pids = process_tree_pids(root_pid)?;
    Ok(DomainInventory {
        schema: 1,
        checkpoint_root_pid: root_pid,
        cgroup_path,
        equal: cgroup_pids == tree_pids,
        cgroup_pids,
        tree_pids,
        error: None,
    })
}

fn collect_diagnostics(
    options: &CheckpointOptions,
    root_pid: u32,
    domain: DomainInventory,
) -> io::Result<DiagnosticReport> {
    let root_namespaces = process_namespaces(root_pid).unwrap_or_default();
    let mut recommendations = BTreeSet::new();
    if !domain.equal {
        recommendations.insert(String::from(
            "Resolve managed cgroup/tree inequality before invoking CRIU.",
        ));
    }
    let mut processes = Vec::new();
    for pid in &domain.cgroup_pids {
        let diagnostic = inspect_process(*pid, &root_namespaces);
        if diagnostic.resource_flags.contains("character-device") {
            recommendations.insert(String::from(
                "A managed process has a character-device descriptor; verify that the device is checkpointable or provide a supervisor-owned adapter.",
            ));
        }
        if diagnostic.resource_flags.contains("deleted-file") {
            recommendations.insert(String::from(
                "A managed process maps or opens deleted files; inspect CRIU ghost-file limits and retained runtime snapshots.",
            ));
        }
        if diagnostic.resource_flags.contains("nested-namespace") {
            recommendations.insert(String::from(
                "A managed process uses nested namespaces; verify support in the pinned CRIU version or explicitly disable the application's incompatible sandbox for this backend.",
            ));
        }
        processes.push(diagnostic);
    }
    Ok(DiagnosticReport {
        schema: 1,
        generated_unix_nanos: SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_err(io::Error::other)?
            .as_nanos(),
        boot_id: read_trimmed("/proc/sys/kernel/random/boot_id")?,
        kernel_release: command_output("uname", ["-r"])?,
        criu_version: command_output(&options.criu, ["--version"])?,
        session: options.session_name.clone(),
        checkpoint_root_pid: root_pid,
        domain,
        processes,
        recommendations,
    })
}

fn inspect_process(pid: u32, root_namespaces: &BTreeMap<String, String>) -> ProcessDiagnostic {
    let mut errors = Vec::new();
    let status = fs::read_to_string(format!("/proc/{pid}/status"));
    let (parent_pid, namespace_pids, thread_count) = match status {
        Ok(status) => {
            let field = |name: &str| {
                status.lines().find_map(|line| {
                    line.strip_prefix(name)
                        .and_then(|value| value.split_whitespace().next())
                })
            };
            let parent = field("PPid:").and_then(|value| value.parse().ok());
            let namespace_pids = status
                .lines()
                .find_map(|line| line.strip_prefix("NSpid:"))
                .map(|value| {
                    value
                        .split_whitespace()
                        .filter_map(|pid| pid.parse().ok())
                        .collect()
                })
                .unwrap_or_default();
            let threads = field("Threads:")
                .and_then(|value| value.parse().ok())
                .unwrap_or_default();
            (parent, namespace_pids, threads)
        }
        Err(error) => {
            errors.push(format!("status: {error}"));
            (None, Vec::new(), 0)
        }
    };
    let executable = fs::read_link(format!("/proc/{pid}/exe"))
        .map_err(|error| errors.push(format!("exe: {error}")))
        .ok();
    let command = fs::read(format!("/proc/{pid}/cmdline"))
        .map(|bytes| {
            bytes
                .split(|byte| *byte == 0)
                .filter(|part| !part.is_empty())
                .map(|part| String::from_utf8_lossy(part).into_owned())
                .collect()
        })
        .unwrap_or_else(|error| {
            errors.push(format!("cmdline: {error}"));
            Vec::new()
        });
    let namespaces = process_namespaces(pid).unwrap_or_else(|error| {
        errors.push(format!("namespaces: {error}"));
        BTreeMap::new()
    });
    let mut descriptors = BTreeMap::new();
    let mut resource_flags = BTreeSet::new();
    match fs::read_dir(format!("/proc/{pid}/fd")) {
        Ok(entries) => {
            for entry in entries.filter_map(Result::ok) {
                let Some(fd) = entry.file_name().to_str().and_then(|fd| fd.parse().ok()) else {
                    continue;
                };
                match fs::read_link(entry.path()) {
                    Ok(target) => {
                        let target = target.to_string_lossy().into_owned();
                        if target.starts_with("/dev/")
                            && !matches!(
                                target.as_str(),
                                "/dev/null" | "/dev/zero" | "/dev/random" | "/dev/urandom"
                            )
                        {
                            resource_flags.insert(String::from("character-device"));
                        }
                        if target.contains(" (deleted)") {
                            resource_flags.insert(String::from("deleted-file"));
                        }
                        if target.starts_with("socket:[") {
                            resource_flags.insert(String::from("socket"));
                        }
                        if target.starts_with("anon_inode:") {
                            resource_flags.insert(String::from("anonymous-inode"));
                        }
                        descriptors.insert(fd, target);
                    }
                    Err(error) => errors.push(format!("fd {fd}: {error}")),
                }
            }
        }
        Err(error) => errors.push(format!("fd directory: {error}")),
    }
    if namespaces
        .iter()
        .any(|(name, value)| root_namespaces.get(name).is_some_and(|root| root != value))
    {
        resource_flags.insert(String::from("nested-namespace"));
    }
    ProcessDiagnostic {
        pid,
        parent_pid,
        namespace_pids,
        executable,
        command,
        thread_count,
        namespaces,
        descriptors,
        resource_flags,
        inspection_errors: errors,
    }
}

fn process_namespaces(pid: u32) -> io::Result<BTreeMap<String, String>> {
    let mut result = BTreeMap::new();
    for entry in fs::read_dir(format!("/proc/{pid}/ns"))? {
        let entry = entry?;
        result.insert(
            entry.file_name().to_string_lossy().into_owned(),
            fs::read_link(entry.path())?.to_string_lossy().into_owned(),
        );
    }
    Ok(result)
}

fn analyze_criu_failure(log_path: &Path, status: &ExitStatus) -> FailureAnalysis {
    let contents = fs::read_to_string(log_path).unwrap_or_default();
    let errors = contents
        .lines()
        .filter(|line| line.contains("Error") || line.contains("ERROR"))
        .map(String::from)
        .collect::<Vec<_>>();
    let warnings = contents
        .lines()
        .filter(|line| line.contains("Warn") || line.contains("WARN"))
        .map(String::from)
        .collect::<Vec<_>>();
    let mut recommendations = BTreeSet::new();
    for line in &errors {
        if line.contains("nested") && line.contains("namespace") {
            recommendations.insert(String::from(
                "Nested namespace detected: identify the owning process in diagnostics.json and verify CRIU support or backend-specific sandbox compatibility.",
            ));
        }
        if line.contains("External socket") || line.contains("external socket") {
            recommendations.insert(String::from(
                "External Unix socket detected: locate the descriptor owner in diagnostics.json; do not use --ext-unix-sk when the missing peer should be inside the exact-restoration domain.",
            ));
        }
        if line.contains("Connected TCP socket") {
            recommendations.insert(String::from(
                "Connected TCP socket detected: ensure both peers belong to the managed domain before enabling established-TCP restoration.",
            ));
        }
        if line.contains("Can't dump file") || line.contains("device") {
            recommendations.insert(String::from(
                "Unsupported file or device descriptor detected: inspect per-process descriptors and add an explicit adapter or refusal rule.",
            ));
        }
    }
    FailureAnalysis {
        schema: 1,
        criu_exit_status: status.to_string(),
        errors,
        warnings,
        recommendations,
    }
}

fn read_pid_set(path: &Path) -> io::Result<BTreeSet<u32>> {
    fs::read_to_string(path)?
        .split_whitespace()
        .map(|pid| {
            pid.parse::<u32>()
                .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))
        })
        .collect()
}

fn process_tree_pids(root: u32) -> io::Result<BTreeSet<u32>> {
    let mut result = BTreeSet::from([root]);
    let mut pending = vec![root];
    while let Some(pid) = pending.pop() {
        let tasks = match fs::read_dir(format!("/proc/{pid}/task")) {
            Ok(tasks) => tasks,
            Err(error) if error.kind() == io::ErrorKind::NotFound => continue,
            Err(error) => return Err(error),
        };
        for task in tasks.filter_map(Result::ok) {
            let children = match fs::read_to_string(task.path().join("children")) {
                Ok(children) => children,
                Err(error) if error.kind() == io::ErrorKind::NotFound => continue,
                Err(error) => return Err(error),
            };
            for child in children.split_whitespace() {
                let child = child
                    .parse::<u32>()
                    .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
                if result.insert(child) {
                    pending.push(child);
                }
            }
        }
    }
    Ok(result)
}

fn validate_expected_session(
    captured: &SessionManifest,
    options: &CheckpointOptions,
    session_dir: &Path,
) -> io::Result<()> {
    let current = session_manifest(&options.session_name, &options.compositor_argv, session_dir)?;
    if &current != captured {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!(
                "session compatibility mismatch: captured={}, requested={}",
                serde_json::to_string(captured).map_err(io::Error::other)?,
                serde_json::to_string(&current).map_err(io::Error::other)?
            ),
        ));
    }
    Ok(())
}

fn session_manifest(
    session_name: &str,
    compositor_argv: &[OsString],
    session_dir: &Path,
) -> io::Result<SessionManifest> {
    let executable = resolve_executable(&compositor_argv[0])?;
    let compositor_argv = compositor_argv
        .iter()
        .map(|value| {
            value
                .clone()
                .into_string()
                .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "argv must be UTF-8"))
        })
        .collect::<io::Result<Vec<_>>>()?;
    Ok(SessionManifest {
        schema: 1,
        session_name: String::from(session_name),
        compositor_argv,
        compositor_sha256: hash_file(&executable)?,
        compositor_executable: executable,
        resource_manifest_sha256: hash_file(&session_dir.join("resources.manifest"))?,
    })
}

fn resolve_executable(command: &OsStr) -> io::Result<PathBuf> {
    let candidate = Path::new(command);
    if candidate.components().count() > 1 {
        return fs::canonicalize(candidate);
    }
    let path = std::env::var_os("PATH")
        .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "PATH is unset"))?;
    for directory in std::env::split_paths(&path) {
        let candidate = directory.join(command);
        if candidate.is_file() {
            return fs::canonicalize(candidate);
        }
    }
    Err(io::Error::new(
        io::ErrorKind::NotFound,
        format!("executable {:?} was not found on PATH", command),
    ))
}

fn snapshot_runtime_files(source: &Path, destination: &Path) -> io::Result<()> {
    fn copy_tree(
        root: &Path,
        source: &Path,
        destination: &Path,
        fifos: &mut Vec<String>,
    ) -> io::Result<()> {
        fs::create_dir(destination)?;
        for entry in fs::read_dir(source)? {
            let entry = entry?;
            let target = destination.join(entry.file_name());
            let file_type = entry.file_type()?;
            if file_type.is_dir() {
                copy_tree(root, &entry.path(), &target, fifos)?;
            } else if file_type.is_file() {
                fs::copy(entry.path(), target)?;
            } else if file_type.is_fifo() {
                fifos.push(
                    entry
                        .path()
                        .strip_prefix(root)
                        .map_err(io::Error::other)?
                        .to_string_lossy()
                        .into_owned(),
                );
            }
        }
        Ok(())
    }
    let mut fifos = Vec::new();
    copy_tree(source, source, destination, &mut fifos)?;
    write_json_atomic(&destination.join("runtime-fifos.json"), &fifos)?;
    sync_directory(destination)
}

fn restore_runtime_files(source: &Path, destination: &Path) -> io::Result<()> {
    fn copy_tree(source: &Path, destination: &Path) -> io::Result<()> {
        fs::create_dir_all(destination)?;
        fs::set_permissions(destination, fs::Permissions::from_mode(0o700))?;
        for entry in fs::read_dir(source)? {
            let entry = entry?;
            if entry.file_name() == "runtime-fifos.json" {
                continue;
            }
            let target = destination.join(entry.file_name());
            if entry.file_type()?.is_dir() {
                copy_tree(&entry.path(), &target)?;
            } else if entry.file_type()?.is_file() {
                fs::copy(entry.path(), target)?;
            }
        }
        Ok(())
    }
    copy_tree(source, destination)?;
    let fifo_manifest = source.join("runtime-fifos.json");
    if fifo_manifest.exists() {
        let fifos: Vec<String> = read_json(&fifo_manifest)?;
        for fifo in fifos {
            let path = destination.join(fifo);
            let path =
                std::ffi::CString::new(path.as_os_str().as_encoded_bytes()).map_err(|_| {
                    io::Error::new(io::ErrorKind::InvalidInput, "FIFO path contains NUL")
                })?;
            // SAFETY: path is a valid, NUL-terminated pathname.
            if unsafe { libc::mkfifo(path.as_ptr(), 0o644) } == -1 {
                return Err(io::Error::last_os_error());
            }
        }
    }
    sync_directory(destination)
}

fn hash_checkpoint_images(directory: &Path) -> io::Result<BTreeMap<String, String>> {
    fn visit(
        root: &Path,
        directory: &Path,
        hashes: &mut BTreeMap<String, String>,
    ) -> io::Result<()> {
        for entry in fs::read_dir(directory)? {
            let entry = entry?;
            let path = entry.path();
            if path.is_dir() {
                visit(root, &path, hashes)?;
            } else if path.is_file() {
                let relative = path.strip_prefix(root).map_err(io::Error::other)?;
                let name = relative.to_string_lossy().into_owned();
                if name != "checkpoint.json" && !name.ends_with(".log") {
                    hashes.insert(name, hash_file(&path)?);
                }
            }
        }
        Ok(())
    }

    let mut hashes = BTreeMap::new();
    visit(directory, directory, &mut hashes)?;
    Ok(hashes)
}

fn verify_checkpoint_images(
    directory: &Path,
    expected: &BTreeMap<String, String>,
) -> io::Result<()> {
    for (name, expected_hash) in expected {
        let actual = hash_file(&directory.join(name))?;
        if &actual != expected_hash {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!("checkpoint image hash mismatch for {name}"),
            ));
        }
    }
    Ok(())
}

fn hash_file(path: &Path) -> io::Result<String> {
    let mut input = File::open(path)?;
    let mut hasher = Sha256::new();
    let mut buffer = [0_u8; 65536];
    loop {
        let size = input.read(&mut buffer)?;
        if size == 0 {
            break;
        }
        hasher.update(&buffer[..size]);
    }
    Ok(format!("{:x}", hasher.finalize()))
}

fn publish_latest_diagnostics(
    session_dir: &Path,
    checkpoint: &Path,
    analysis: Option<&Path>,
) -> io::Result<()> {
    let report = checkpoint.join("diagnostics.json");
    let relative_report = report.strip_prefix(session_dir).map_err(io::Error::other)?;
    let relative_analysis = analysis
        .map(|path| path.strip_prefix(session_dir).map(Path::to_path_buf))
        .transpose()
        .map_err(io::Error::other)?;
    write_json_atomic(
        &session_dir.join("latest-diagnostics.json"),
        &serde_json::json!({
            "schema": 1,
            "report": relative_report,
            "failure_analysis": relative_analysis,
        }),
    )
}

fn create_restore_attempt(checkpoint: &Path) -> io::Result<PathBuf> {
    let attempts = checkpoint.join("restore-attempts");
    fs::create_dir_all(&attempts)?;
    let id = format!(
        "{}-{}",
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_err(io::Error::other)?
            .as_nanos(),
        std::process::id()
    );
    let attempt = attempts.join(id);
    fs::create_dir(&attempt)?;
    fs::set_permissions(&attempt, fs::Permissions::from_mode(0o700))?;
    Ok(attempt)
}

fn compatibility_failure<T>(
    session_dir: &Path,
    checkpoint: &Path,
    restore_attempt: &Path,
    reason: &str,
) -> io::Result<T> {
    #[derive(Serialize)]
    struct Failure<'a> {
        schema: u32,
        kind: &'a str,
        reason: &'a str,
    }
    let failure = restore_attempt.join("failure.json");
    write_json_atomic(
        &failure,
        &Failure {
            schema: 1,
            kind: "incompatible",
            reason,
        },
    )?;
    publish_latest_diagnostics(session_dir, checkpoint, Some(&failure))?;
    Err(io::Error::new(
        io::ErrorKind::InvalidInput,
        format!("restore refused before mutation: {reason}"),
    ))
}

fn command_output<I, S>(program: impl AsRef<OsStr>, arguments: I) -> io::Result<String>
where
    I: IntoIterator<Item = S>,
    S: AsRef<OsStr>,
{
    let output = Command::new(program).args(arguments).output()?;
    if !output.status.success() {
        return Err(io::Error::other(format!(
            "identity command failed with {}",
            output.status
        )));
    }
    String::from_utf8(output.stdout)
        .map(|value| value.trim().to_owned())
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))
}

fn read_trimmed(path: impl AsRef<Path>) -> io::Result<String> {
    fs::read_to_string(path).map(|value| value.trim().to_owned())
}

fn read_json<T: for<'de> Deserialize<'de>>(path: &Path) -> io::Result<T> {
    serde_json::from_reader(File::open(path)?).map_err(io::Error::other)
}

fn write_json_atomic(path: &Path, value: &impl Serialize) -> io::Result<()> {
    let bytes = serde_json::to_vec_pretty(value).map_err(io::Error::other)?;
    write_atomic(path, &bytes)
}

fn write_atomic(path: &Path, bytes: &[u8]) -> io::Result<()> {
    let temporary = path.with_extension("tmp");
    let mut output = OpenOptions::new()
        .create(true)
        .truncate(true)
        .write(true)
        .mode(0o600)
        .open(&temporary)?;
    output.write_all(bytes)?;
    output.write_all(b"\n")?;
    output.sync_all()?;
    fs::rename(&temporary, path)?;
    if let Some(parent) = path.parent() {
        sync_directory(parent)?;
    }
    Ok(())
}

fn sync_directory(path: &Path) -> io::Result<()> {
    File::open(path)?.sync_all()
}
