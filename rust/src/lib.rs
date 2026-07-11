pub mod checkpoint;

use checkpoint::write_session_manifest;
use std::ffi::{OsStr, OsString};
use std::fs::{self, OpenOptions};
use std::io::{self, Write};
use std::os::fd::AsRawFd;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};
use std::os::unix::net::UnixDatagram;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, ExitStatus};
use std::sync::atomic::{AtomicI32, Ordering};
use std::thread;
use std::time::Duration;

static PENDING_SIGNAL: AtomicI32 = AtomicI32::new(0);

#[derive(Debug, Clone, Eq, PartialEq)]
pub struct SessionConfig {
    pub session_name: String,
    pub state_dir: PathBuf,
    pub runtime_dir: PathBuf,
    pub cgroup_dir: Option<PathBuf>,
    pub compositor_argv: Vec<OsString>,
}

impl SessionConfig {
    pub fn parse(arguments: impl IntoIterator<Item = OsString>) -> Result<Self, String> {
        let mut arguments = arguments.into_iter();
        let mut session_name = String::from("default");
        let mut state_dir = PathBuf::from("/var/lib/wayland-session-supervisor");
        let mut runtime_dir = PathBuf::from("/run/wayland-session-supervisor");
        let mut cgroup_dir = None;

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
                Some("--cgroup-dir") => cgroup_dir = Some(value.into()),
                _ => return Err(format!("unknown option: {}", argument.to_string_lossy())),
            }
        }

        validate_session_name(&session_name)?;
        let compositor_argv: Vec<_> = arguments.collect();
        if compositor_argv.is_empty() {
            return Err(String::from("a compositor command is required"));
        }

        Ok(Self {
            session_name,
            state_dir,
            runtime_dir,
            cgroup_dir,
            compositor_argv,
        })
    }
}

#[derive(Debug)]
pub struct SessionDomain {
    config: SessionConfig,
    session_state_dir: PathBuf,
    session_runtime_dir: PathBuf,
}

impl SessionDomain {
    pub fn prepare(config: SessionConfig) -> io::Result<Self> {
        ensure_private_directory(&config.state_dir, 0o700)?;
        ensure_private_directory(&config.runtime_dir, 0o700)?;

        let session_state_dir = config.state_dir.join("sessions").join(&config.session_name);
        let session_runtime_dir = config.runtime_dir.join(&config.session_name);
        ensure_private_directory(&session_state_dir, 0o700)?;
        ensure_private_directory(&session_runtime_dir, 0o700)?;
        ensure_private_directory(&session_runtime_dir.join("tmp"), 0o700)?;
        write_resource_manifest(&session_state_dir)?;
        write_session_manifest(&config, &session_state_dir)?;

        if let Some(cgroup_dir) = &config.cgroup_dir {
            ensure_cgroup_directory(cgroup_dir)?;
        }

        Ok(Self {
            config,
            session_state_dir,
            session_runtime_dir,
        })
    }

    pub fn spawn(&self) -> io::Result<Child> {
        close_uncontrolled_descriptors()?;
        let adapters =
            ResourceAdapters::create(&self.session_runtime_dir, &self.session_state_dir)?;
        let input_fd = adapters.input_child.as_raw_fd();
        let audio_fd = adapters.audio_child.as_raw_fd();
        // util-linux keeps a namespace-init process as PID 1 while the
        // configured command runs as its child. PID 1 reaps daemonized and
        // double-forked descendants, keeping the complete domain below the
        // single host-visible checkpoint root recorded in session.pid.
        let mut command = Command::new("unshare");
        command
            .args([
                OsStr::new("--pid"),
                OsStr::new("--fork"),
                OsStr::new("--kill-child=TERM"),
                OsStr::new("--"),
                OsStr::new("setsid"),
                OsStr::new("--"),
            ])
            .args(&self.config.compositor_argv);
        command
            .env("XDG_RUNTIME_DIR", &self.session_runtime_dir)
            .env("TMPDIR", self.session_runtime_dir.join("tmp"))
            .env("WSS_SESSION_NAME", &self.config.session_name)
            .env("WSS_SESSION_STATE_DIR", &self.session_state_dir)
            .env("WSS_DISPLAY_BACKEND", "headless")
            .env("WSS_INPUT_FD", "3")
            .env("WSS_AUDIO_FD", "4")
            .env(
                "WSS_CONTROL_SOCKET",
                self.session_runtime_dir.join("control.sock"),
            );

        // SAFETY: this closure calls only async-signal-safe descriptor and
        // process-group operations before exec.
        unsafe {
            command.pre_exec(move || {
                if libc::setpgid(0, 0) == -1 || libc::dup2(input_fd, 3) == -1 {
                    return Err(io::Error::last_os_error());
                }
                if input_fd != 3 && input_fd != audio_fd {
                    libc::close(input_fd);
                }
                if libc::dup2(audio_fd, 4) == -1
                    || libc::fcntl(3, libc::F_SETFD, 0) == -1
                    || libc::fcntl(4, libc::F_SETFD, 0) == -1
                {
                    return Err(io::Error::last_os_error());
                }
                if audio_fd != 4 {
                    libc::close(audio_fd);
                }
                Ok(())
            });
        }
        let child = command.spawn()?;
        if let Some(cgroup_dir) = &self.config.cgroup_dir {
            write_cgroup_pid(cgroup_dir, child.id())?;
        }
        let checkpoint_root = wait_for_namespace_init(child.id())?;
        write_atomic_pid(&self.session_state_dir.join("session.pid"), checkpoint_root)?;
        adapters.activate()?;
        Ok(child)
    }

    pub fn run(&self) -> io::Result<ExitStatus> {
        install_signal_handlers()?;
        let mut child = self.spawn()?;
        loop {
            if let Some(status) = child.try_wait()? {
                return Ok(status);
            }
            let signal = PENDING_SIGNAL.swap(0, Ordering::SeqCst);
            if signal != 0 {
                // Negative PID addresses the compositor's process group.
                // SAFETY: kill has no memory-safety preconditions.
                let result = unsafe { libc::kill(-(child.id() as i32), signal) };
                if result == -1 {
                    let error = io::Error::last_os_error();
                    if error.raw_os_error() != Some(libc::ESRCH) {
                        return Err(error);
                    }
                }
            }
            thread::sleep(Duration::from_millis(20));
        }
    }

    pub fn runtime_dir(&self) -> &Path {
        &self.session_runtime_dir
    }

    pub fn state_dir(&self) -> &Path {
        &self.session_state_dir
    }
}

struct ResourceAdapters {
    input_parent: UnixDatagram,
    input_child: UnixDatagram,
    audio_parent: UnixDatagram,
    audio_child: UnixDatagram,
    control_socket: UnixDatagram,
    audio_log: PathBuf,
}

impl ResourceAdapters {
    fn create(runtime_dir: &Path, state_dir: &Path) -> io::Result<Self> {
        let control_path = runtime_dir.join("control.sock");
        match fs::remove_file(&control_path) {
            Ok(()) => {}
            Err(error) if error.kind() == io::ErrorKind::NotFound => {}
            Err(error) => return Err(error),
        }
        let (input_parent, input_child) = UnixDatagram::pair()?;
        let (audio_parent, audio_child) = UnixDatagram::pair()?;
        let control_socket = UnixDatagram::bind(&control_path)?;
        fs::set_permissions(&control_path, fs::Permissions::from_mode(0o600))?;
        Ok(Self {
            input_parent,
            input_child,
            audio_parent,
            audio_child,
            control_socket,
            audio_log: state_dir.join("audio-observations.log"),
        })
    }

    fn activate(self) -> io::Result<()> {
        let Self {
            input_parent,
            input_child,
            audio_parent,
            audio_child,
            control_socket,
            audio_log,
        } = self;
        drop(input_child);
        drop(audio_child);

        thread::Builder::new()
            .name(String::from("wss-input-adapter"))
            .spawn(move || {
                let mut message = [0_u8; 4096];
                while let Ok(size) = control_socket.recv(&mut message) {
                    if input_parent.send(&message[..size]).is_err() {
                        break;
                    }
                }
            })?;
        thread::Builder::new()
            .name(String::from("wss-audio-adapter"))
            .spawn(move || {
                let mut message = [0_u8; 65536];
                while let Ok(size) = audio_parent.recv(&mut message) {
                    let write_result = OpenOptions::new()
                        .create(true)
                        .append(true)
                        .mode(0o600)
                        .open(&audio_log)
                        .and_then(|mut output| {
                            output.write_all(&message[..size])?;
                            output.write_all(b"\n")
                        });
                    if write_result.is_err() {
                        break;
                    }
                }
            })?;
        Ok(())
    }
}

fn validate_session_name(name: &str) -> Result<(), String> {
    if name.is_empty()
        || name == "."
        || name == ".."
        || !name
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.'))
    {
        return Err(String::from(
            "session name must contain only ASCII letters, digits, '.', '-', or '_'",
        ));
    }
    Ok(())
}

fn ensure_private_directory(path: &Path, mode: u32) -> io::Result<()> {
    match fs::symlink_metadata(path) {
        Ok(metadata) => {
            if !metadata.is_dir() || metadata.file_type().is_symlink() {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidInput,
                    format!("{} is not a real directory", path.display()),
                ));
            }
            if metadata.uid() != unsafe { libc::geteuid() } {
                return Err(io::Error::new(
                    io::ErrorKind::PermissionDenied,
                    format!("{} is owned by another user", path.display()),
                ));
            }
            fs::set_permissions(path, fs::Permissions::from_mode(mode))?;
        }
        Err(error) if error.kind() == io::ErrorKind::NotFound => {
            fs::create_dir_all(path)?;
            fs::set_permissions(path, fs::Permissions::from_mode(mode))?;
        }
        Err(error) => return Err(error),
    }
    Ok(())
}

fn wait_for_namespace_init(unshare_pid: u32) -> io::Result<u32> {
    let children = PathBuf::from(format!("/proc/{unshare_pid}/task/{unshare_pid}/children"));
    for _ in 0..500 {
        let contents = fs::read_to_string(&children)?;
        if let Some(pid) = contents.split_whitespace().next() {
            return pid.parse().map_err(|error| {
                io::Error::new(
                    io::ErrorKind::InvalidData,
                    format!("invalid namespace-init PID: {error}"),
                )
            });
        }
        thread::sleep(Duration::from_millis(10));
    }
    Err(io::Error::new(
        io::ErrorKind::TimedOut,
        "unshare did not create the PID-namespace init process",
    ))
}

fn write_atomic_pid(path: &Path, pid: u32) -> io::Result<()> {
    let temporary = path.with_extension("tmp");
    let mut output = OpenOptions::new()
        .create(true)
        .truncate(true)
        .write(true)
        .mode(0o600)
        .open(&temporary)?;
    writeln!(output, "{pid}")?;
    output.sync_all()?;
    fs::rename(temporary, path)
}

fn write_resource_manifest(state_dir: &Path) -> io::Result<()> {
    let temporary = state_dir.join("resources.manifest.tmp");
    let final_path = state_dir.join("resources.manifest");
    let mut output = OpenOptions::new()
        .create(true)
        .truncate(true)
        .write(true)
        .mode(0o600)
        .open(&temporary)?;
    output.write_all(
        b"schema=1\ndisplay=headless\ngpu=encapsulated-none\ninput=supervisor-socketpair-fd3\naudio=supervisor-observer-fd4\nruntime=private-directory\nwayland-socket=session-internal\nnative-drm=unsupported\nnative-libinput=unsupported\nnative-audio=unsupported\n",
    )?;
    output.sync_all()?;
    fs::rename(temporary, final_path)
}

fn ensure_cgroup_directory(path: &Path) -> io::Result<()> {
    fs::create_dir_all(path)?;
    if !path.join("cgroup.procs").exists() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("{} is not a cgroup v2 directory", path.display()),
        ));
    }
    Ok(())
}

fn write_cgroup_pid(path: &Path, pid: u32) -> io::Result<()> {
    let mut processes = OpenOptions::new()
        .write(true)
        .custom_flags(libc::O_CLOEXEC)
        .open(path.join("cgroup.procs"))?;
    writeln!(processes, "{pid}")
}

pub fn close_uncontrolled_descriptors() -> io::Result<()> {
    let descriptors = fs::read_dir("/proc/self/fd")?
        .filter_map(Result::ok)
        .filter_map(|entry| entry.file_name().to_string_lossy().parse::<i32>().ok())
        .filter(|descriptor| *descriptor > 2)
        .collect::<Vec<_>>();
    for descriptor in descriptors {
        // The read_dir descriptor may already be closed when its iterator was dropped.
        // SAFETY: closing an integer descriptor is memory-safe.
        if unsafe { libc::close(descriptor) } == -1 {
            let error = io::Error::last_os_error();
            if error.raw_os_error() != Some(libc::EBADF) {
                return Err(error);
            }
        }
    }
    Ok(())
}

extern "C" fn record_signal(signal: i32) {
    PENDING_SIGNAL.store(signal, Ordering::SeqCst);
}

fn install_signal_handlers() -> io::Result<()> {
    // SAFETY: record_signal has C ABI and only performs an atomic store.
    unsafe {
        let mut action: libc::sigaction = std::mem::zeroed();
        action.sa_sigaction = record_signal as *const () as usize;
        libc::sigemptyset(&mut action.sa_mask);
        for signal in [libc::SIGTERM, libc::SIGINT, libc::SIGHUP] {
            if libc::sigaction(signal, &action, std::ptr::null_mut()) == -1 {
                return Err(io::Error::last_os_error());
            }
        }
    }
    Ok(())
}

pub fn command_display(argv: &[OsString]) -> String {
    argv.iter()
        .map(|value| shell_escape_for_log(value))
        .collect::<Vec<_>>()
        .join(" ")
}

fn shell_escape_for_log(value: &OsStr) -> String {
    let text = value.to_string_lossy();
    format!("'{}'", text.replace('\'', "'\\''"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn temporary_directory(name: &str) -> PathBuf {
        std::env::temp_dir().join(format!(
            "wss-{name}-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ))
    }

    #[test]
    fn parses_compositor_as_structured_argv() {
        let config = SessionConfig::parse(
            [
                "--session",
                "alpha",
                "--state-dir",
                "/state path",
                "--runtime-dir",
                "/runtime",
                "--",
                "/nix/store/compositor/bin/niri",
                "--config",
                "literal;not-shell",
            ]
            .map(OsString::from),
        )
        .unwrap();
        assert_eq!(config.session_name, "alpha");
        assert_eq!(config.state_dir, Path::new("/state path"));
        assert_eq!(config.compositor_argv[2], "literal;not-shell");
    }

    #[test]
    fn rejects_path_traversal_session_name() {
        let error =
            SessionConfig::parse(["--session", "../escape", "--", "niri"].map(OsString::from))
                .unwrap_err();
        assert!(error.contains("session name"));
    }

    #[test]
    fn prepares_private_runtime_and_state_boundaries() {
        let root = temporary_directory("boundaries");
        let config = SessionConfig {
            session_name: String::from("test"),
            state_dir: root.join("state"),
            runtime_dir: root.join("runtime"),
            cgroup_dir: None,
            compositor_argv: vec![OsString::from("true")],
        };
        let domain = SessionDomain::prepare(config).unwrap();
        assert_eq!(
            fs::metadata(domain.runtime_dir())
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o700
        );
        assert_eq!(
            fs::metadata(domain.state_dir())
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o700
        );
        let resources = fs::read_to_string(domain.state_dir().join("resources.manifest")).unwrap();
        assert!(resources.contains("input=supervisor-socketpair-fd3"));
        assert!(resources.contains("native-drm=unsupported"));
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn keeps_shell_metacharacters_literal() {
        let argv = vec![OsString::from("printf"), OsString::from("$(touch nope)")];
        assert_eq!(command_display(&argv), "'printf' '$(touch nope)'");
    }
}
