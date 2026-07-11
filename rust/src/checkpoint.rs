use crate::SessionConfig;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use std::ffi::{OsStr, OsString};
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Write};
use std::os::unix::fs::{FileTypeExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::process::{Command, ExitStatus};
use std::time::{SystemTime, UNIX_EPOCH};

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
}

impl CheckpointOptions {
    pub fn parse(arguments: impl IntoIterator<Item = OsString>) -> Result<Self, String> {
        let mut arguments = arguments.into_iter();
        let mut session_name = String::from("default");
        let mut state_dir = PathBuf::from("/var/lib/wayland-session-supervisor");
        let mut runtime_dir = PathBuf::from("/run/wayland-session-supervisor");
        let mut criu = OsString::from("criu");
        loop {
            let argument = arguments
                .next()
                .ok_or_else(|| String::from("missing `--` before compositor command"))?;
            if argument == "--" {
                break;
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
    let status = Command::new(&options.criu)
        .args([
            OsStr::new("dump"),
            OsStr::new("--tree"),
            OsStr::new(&root_pid.to_string()),
            OsStr::new("--images-dir"),
            staging.as_os_str(),
            OsStr::new("--shell-job"),
            OsStr::new("--file-locks"),
            // Chromium maps deleted temporary files larger than CRIU's 1 MiB
            // default. Preserve those mappings as checkpoint images rather than
            // depending on volatile runtime-directory contents.
            OsStr::new("--ghost-limit"),
            OsStr::new("1073741824"),
            // Chromium watches immutable resources below /nix/store. Overlayfs
            // file handles are not always openable directly, so provide the
            // stable path as an inode-remap search root.
            OsStr::new("--irmap-scan-path"),
            OsStr::new("/nix/store"),
            OsStr::new("--log-file"),
            OsStr::new("dump.log"),
            OsStr::new("-v2"),
        ])
        .status()?;
    if !status.success() {
        manifest.status = String::from("failed");
        manifest.failure = Some(format!("criu dump exited with {status}"));
        write_json_atomic(&staging.join("checkpoint.json"), &manifest)?;
        let failed = checkpoints.join(format!("failed-{checkpoint_id}"));
        fs::rename(&staging, &failed)?;
        return Err(io::Error::other(format!(
            "checkpoint failed; evidence preserved at {}",
            failed.display()
        )));
    }

    // A successful dump has stopped the domain, so mutable browser databases
    // and socket-parent directories can now be copied at the same state point
    // represented by the process images.
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
    let checkpoint_id = read_trimmed(session_dir.join("current-checkpoint"))?;
    let checkpoint = session_dir.join("checkpoints").join(checkpoint_id);
    let manifest: CheckpointManifest = read_json(&checkpoint.join("checkpoint.json"))?;
    if manifest.status != "complete" {
        return compatibility_failure(&checkpoint, "checkpoint status is not complete");
    }
    if let Err(error) = validate_expected_session(&manifest.session, options, &session_dir) {
        return compatibility_failure(&checkpoint, &error.to_string());
    }
    let current_kernel = command_output("uname", ["-r"])?;
    if current_kernel != manifest.kernel_release {
        return compatibility_failure(
            &checkpoint,
            &format!(
                "kernel mismatch: captured {:?}, current {:?}",
                manifest.kernel_release, current_kernel
            ),
        );
    }
    let current_criu = command_output(&options.criu, ["--version"])?;
    if current_criu != manifest.criu_version {
        return compatibility_failure(
            &checkpoint,
            &format!(
                "CRIU mismatch: captured {:?}, current {:?}",
                manifest.criu_version, current_criu
            ),
        );
    }
    verify_checkpoint_images(&checkpoint, &manifest.images)?;
    restore_runtime_files(
        &checkpoint.join("runtime-files"),
        &options.runtime_dir.join(&options.session_name),
    )?;

    Command::new(&options.criu)
        .args([
            OsStr::new("restore"),
            OsStr::new("--images-dir"),
            checkpoint.as_os_str(),
            OsStr::new("--shell-job"),
            OsStr::new("--file-locks"),
            OsStr::new("--restore-detached"),
            OsStr::new("--log-file"),
            OsStr::new("restore.log"),
            OsStr::new("-v2"),
        ])
        .status()
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

fn compatibility_failure<T>(checkpoint: &Path, reason: &str) -> io::Result<T> {
    #[derive(Serialize)]
    struct Failure<'a> {
        schema: u32,
        kind: &'a str,
        reason: &'a str,
    }
    write_json_atomic(
        &checkpoint.join("restore-failure.json"),
        &Failure {
            schema: 1,
            kind: "incompatible",
            reason,
        },
    )?;
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
