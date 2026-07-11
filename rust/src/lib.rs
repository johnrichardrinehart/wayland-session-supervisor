pub mod checkpoint;

use checkpoint::write_session_manifest;
use std::ffi::{OsStr, OsString};
use std::fs::{self, File, OpenOptions};
use std::io::{self, Write};
use std::os::fd::AsRawFd;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};
use std::os::unix::net::UnixDatagram;
use std::os::unix::process::{CommandExt, ExitStatusExt};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, ExitStatus, Stdio};
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
    pub namespace_launcher: Option<PathBuf>,
    pub compositor_argv: Vec<OsString>,
}

impl SessionConfig {
    pub fn parse(arguments: impl IntoIterator<Item = OsString>) -> Result<Self, String> {
        let mut arguments = arguments.into_iter();
        let mut session_name = String::from("default");
        let mut state_dir = PathBuf::from("/var/lib/wayland-session-supervisor");
        let mut runtime_dir = PathBuf::from("/run/wayland-session-supervisor");
        let mut cgroup_dir = None;
        let mut namespace_launcher = None;

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
                Some("--namespace-launcher") => namespace_launcher = Some(value.into()),
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
            namespace_launcher,
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

    fn spawn(&self) -> io::Result<ManagedChild> {
        close_uncontrolled_descriptors()?;
        let adapters =
            ResourceAdapters::create(&self.session_runtime_dir, &self.session_state_dir)?;
        let cgroup_processes = self
            .config
            .cgroup_dir
            .as_ref()
            .map(|path| {
                if path.starts_with("/sys/fs/cgroup") {
                    File::open(path)
                } else {
                    OpenOptions::new()
                        .write(true)
                        .open(path.join("cgroup.procs"))
                }
            })
            .transpose()?;
        let cgroup_fd = cgroup_processes.as_ref().map(AsRawFd::as_raw_fd);
        let kernel_cgroup = self
            .config
            .cgroup_dir
            .as_ref()
            .is_some_and(|path| path.starts_with("/sys/fs/cgroup"));
        let needs_privileged_launcher = kernel_cgroup && unsafe { libc::geteuid() } != 0;
        let mut command = if needs_privileged_launcher {
            let launcher = self.config.namespace_launcher.as_ref().ok_or_else(|| {
                io::Error::new(
                    io::ErrorKind::PermissionDenied,
                    "unprivileged kernel-cgroup sessions require --namespace-launcher",
                )
            })?;
            let cgroup_fd = cgroup_fd.ok_or_else(|| {
                io::Error::new(io::ErrorKind::InvalidInput, "missing managed cgroup")
            })?;
            let mut command = Command::new(launcher);
            command
                .arg("namespace-launch")
                .arg("--cgroup-fd")
                .arg(cgroup_fd.to_string())
                .arg("--")
                .arg(std::env::current_exe()?)
                .arg("namespace-init")
                .arg("--")
                .args(&self.config.compositor_argv);
            command
        } else if kernel_cgroup {
            let mut command = Command::new(std::env::current_exe()?);
            command
                .arg("namespace-init")
                .arg("--")
                .args(&self.config.compositor_argv);
            command
        } else {
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
        };
        let session_log = OpenOptions::new()
            .create(true)
            .append(true)
            .mode(0o600)
            .open(self.session_state_dir.join("session.log"))?;
        command
            .stdin(Stdio::null())
            .stdout(Stdio::from(session_log.try_clone()?))
            .stderr(Stdio::from(session_log))
            .env("XDG_RUNTIME_DIR", &self.session_runtime_dir)
            .env("TMPDIR", self.session_runtime_dir.join("tmp"))
            .env("WSS_SESSION_NAME", &self.config.session_name)
            .env("WSS_SESSION_STATE_DIR", &self.session_state_dir)
            .env("WSS_DISPLAY_BACKEND", "headless")
            .env(
                "WSS_EGRESS_SPOOL",
                self.session_runtime_dir.join("adapter-egress.stream"),
            )
            .env(
                "WSS_CONTROL_SOCKET",
                self.session_runtime_dir.join("control.sock"),
            );

        // SAFETY: this closure calls only async-signal-safe descriptor and
        // process-group operations before exec.
        unsafe {
            command.pre_exec(move || {
                let session_result = if kernel_cgroup {
                    libc::setsid()
                } else {
                    libc::setpgid(0, 0)
                };
                if session_result == -1 {
                    return Err(io::Error::last_os_error());
                }
                if needs_privileged_launcher {
                    let cgroup_fd = cgroup_fd.expect("launcher requires a cgroup descriptor");
                    if libc::fcntl(cgroup_fd, libc::F_SETFD, 0) == -1 {
                        return Err(io::Error::last_os_error());
                    }
                }
                if let Some(cgroup_fd) = cgroup_fd.filter(|_| !kernel_cgroup) {
                    // Place this soon-to-exec unshare process in the managed
                    // cgroup before it can fork the namespace init. Build the
                    // decimal PID on the stack to remain async-signal-safe.
                    let mut digits = [0_u8; 10];
                    let mut pid = libc::getpid() as u32;
                    let mut start = digits.len();
                    loop {
                        start -= 1;
                        digits[start] = b'0' + (pid % 10) as u8;
                        pid /= 10;
                        if pid == 0 {
                            break;
                        }
                    }
                    let bytes = &digits[start..];
                    if libc::write(cgroup_fd, bytes.as_ptr().cast(), bytes.len())
                        != bytes.len() as isize
                    {
                        return Err(io::Error::last_os_error());
                    }
                    libc::close(cgroup_fd);
                }
                Ok(())
            });
        }
        let child = if needs_privileged_launcher {
            ManagedChild::Unshare(command.spawn()?)
        } else if kernel_cgroup {
            let cgroup_fd = cgroup_fd.ok_or_else(|| {
                io::Error::new(io::ErrorKind::InvalidInput, "missing managed cgroup")
            })?;
            ManagedChild::Direct(clone3_into_cgroup(&mut command, cgroup_fd)?)
        } else {
            ManagedChild::Unshare(command.spawn()?)
        };
        drop(cgroup_processes);
        let checkpoint_root = match &child {
            ManagedChild::Direct(pid) => *pid,
            ManagedChild::Unshare(process) => wait_for_namespace_init(process.id())?,
        };
        if let Some(cgroup_dir) = &self.config.cgroup_dir {
            fs::write(
                self.session_state_dir.join("cgroup.path"),
                cgroup_dir.as_os_str().as_encoded_bytes(),
            )?;
        }
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
                // SAFETY: kill has no memory-safety preconditions.
                let result = unsafe { libc::kill(child.signal_target(), signal) };
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

enum ManagedChild {
    Direct(u32),
    Unshare(Child),
}

impl ManagedChild {
    fn signal_target(&self) -> i32 {
        match self {
            Self::Direct(pid) => *pid as i32,
            Self::Unshare(child) => -(child.id() as i32),
        }
    }

    fn try_wait(&mut self) -> io::Result<Option<ExitStatus>> {
        match self {
            Self::Unshare(child) => child.try_wait(),
            Self::Direct(pid) => {
                let mut status = 0;
                // SAFETY: status points to writable storage and pid is our child.
                let result = unsafe { libc::waitpid(*pid as i32, &mut status, libc::WNOHANG) };
                if result == 0 {
                    Ok(None)
                } else if result == *pid as i32 {
                    Ok(Some(ExitStatus::from_raw(status)))
                } else {
                    Err(io::Error::last_os_error())
                }
            }
        }
    }
}

#[repr(C)]
#[derive(Default)]
struct CloneArgs {
    flags: u64,
    pidfd: u64,
    child_tid: u64,
    parent_tid: u64,
    exit_signal: u64,
    stack: u64,
    stack_size: u64,
    tls: u64,
    set_tid: u64,
    set_tid_size: u64,
    cgroup: u64,
}

pub fn run_privileged_namespace_launcher(
    arguments: impl IntoIterator<Item = OsString>,
) -> io::Result<ExitStatus> {
    let real_uid = unsafe { libc::getuid() };
    let real_gid = unsafe { libc::getgid() };
    if unsafe { libc::geteuid() } != 0 || real_uid == 0 {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "namespace launcher must be invoked through its setuid-root wrapper by a non-root user",
        ));
    }

    let mut arguments = arguments.into_iter();
    if arguments.next().as_deref() != Some(OsStr::new("--cgroup-fd")) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "missing --cgroup-fd",
        ));
    }
    let cgroup_fd: i32 = arguments
        .next()
        .and_then(|value| value.into_string().ok())
        .and_then(|value| value.parse().ok())
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "invalid cgroup descriptor"))?;
    if unsafe { libc::fcntl(cgroup_fd, libc::F_GETFD) } == -1 {
        return Err(io::Error::last_os_error());
    }
    if arguments.next().as_deref() != Some(OsStr::new("--")) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "missing -- before namespace command",
        ));
    }
    let argv: Vec<_> = arguments.collect();
    let executable = argv
        .first()
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "missing namespace command"))?;
    // The helper is a dedicated short-lived process. Remove supplementary
    // groups before cloning so the child cannot retain groups from the
    // setuid-root transition after Command drops its UID and primary GID.
    if unsafe { libc::setgroups(0, std::ptr::null()) } == -1 {
        return Err(io::Error::last_os_error());
    }
    let mut command = Command::new(executable);
    command.args(&argv[1..]).uid(real_uid).gid(real_gid);

    let child = clone3_into_cgroup(&mut command, cgroup_fd)?;
    let mut status = 0;
    loop {
        let result = unsafe { libc::waitpid(child as i32, &mut status, 0) };
        if result == child as i32 {
            return Ok(ExitStatus::from_raw(status));
        }
        let error = io::Error::last_os_error();
        if error.kind() != io::ErrorKind::Interrupted {
            return Err(error);
        }
    }
}

fn clone3_into_cgroup(command: &mut Command, cgroup_fd: i32) -> io::Result<u32> {
    let arguments = CloneArgs {
        // libc exposes CLONE_INTO_CGROUP as a truncated c_int on GNU Linux.
        flags: libc::CLONE_NEWPID as u64 | 0x200000000_u64,
        exit_signal: libc::SIGCHLD as u64,
        cgroup: cgroup_fd as u64,
        ..CloneArgs::default()
    };
    // SAFETY: clone3 receives a valid fixed-size argument block. Without
    // CLONE_VM, the child has a private address space and immediately execs.
    let result = unsafe {
        libc::syscall(
            libc::SYS_clone3,
            &arguments as *const CloneArgs,
            std::mem::size_of::<CloneArgs>(),
        )
    };
    if result == -1 {
        return Err(io::Error::last_os_error());
    }
    if result == 0 {
        let error = command.exec();
        eprintln!("namespace init exec failed: {error}");
        // SAFETY: terminate the failed clone child without running destructors.
        unsafe { libc::_exit(127) }
    }
    Ok(result as u32)
}

struct ResourceAdapters {
    control_socket: UnixDatagram,
    input_socket: UnixDatagram,
    ingress_log: PathBuf,
    runtime_dir: PathBuf,
}

pub(crate) fn start_restored_adapters(runtime_dir: &Path, state_dir: &Path) -> io::Result<()> {
    ResourceAdapters::create(runtime_dir, state_dir)?.activate()
}

impl ResourceAdapters {
    fn create(runtime_dir: &Path, _state_dir: &Path) -> io::Result<Self> {
        let control_path = runtime_dir.join("control.sock");
        let input_path = runtime_dir.join("input.sock");
        for path in [&control_path, &input_path] {
            match fs::remove_file(path) {
                Ok(()) => {}
                Err(error) if error.kind() == io::ErrorKind::NotFound => {}
                Err(error) => return Err(error),
            }
        }
        OpenOptions::new()
            .create(true)
            .append(true)
            .mode(0o600)
            .open(runtime_dir.join("adapter-egress.stream"))?;
        let control_socket = UnixDatagram::bind(&control_path)?;
        let input_socket = UnixDatagram::bind(&input_path)?;
        fs::set_permissions(&control_path, fs::Permissions::from_mode(0o600))?;
        fs::set_permissions(&input_path, fs::Permissions::from_mode(0o600))?;
        Ok(Self {
            control_socket,
            input_socket,
            ingress_log: runtime_dir.join("adapter-ingress.log"),
            runtime_dir: runtime_dir.to_path_buf(),
        })
    }

    fn activate(self) -> io::Result<()> {
        let Self {
            control_socket,
            input_socket,
            ingress_log,
            runtime_dir,
        } = self;

        thread::Builder::new()
            .name(String::from("wss-ingress-adapter"))
            .spawn(move || {
                let mut message = [0_u8; 4096];
                while let Ok(size) = control_socket.recv(&mut message) {
                    if OpenOptions::new()
                        .create(true)
                        .append(true)
                        .mode(0o600)
                        .open(&ingress_log)
                        .and_then(|mut output| {
                            output.write_all(&message[..size])?;
                            output.write_all(b"\n")
                        })
                        .is_err()
                    {
                        break;
                    }
                }
            })?;
        thread::Builder::new()
            .name(String::from("wss-input-adapter"))
            .spawn(move || {
                let mut message = [0_u8; 4096];
                while let Ok(size) = input_socket.recv(&mut message) {
                    let Ok(text) = std::str::from_utf8(&message[..size]) else {
                        continue;
                    };
                    let display = fs::read_dir(&runtime_dir).ok().and_then(|entries| {
                        entries.filter_map(Result::ok).find_map(|entry| {
                            let name = entry.file_name();
                            let value = name.to_string_lossy();
                            (value.starts_with("wayland-") && !value.ends_with(".lock"))
                                .then(|| name.into_string().ok())
                                .flatten()
                        })
                    });
                    let Some(display) = display else { continue };
                    let status = Command::new("wtype")
                        .arg(text)
                        .arg("-k")
                        .arg("Return")
                        .env("XDG_RUNTIME_DIR", &runtime_dir)
                        .env("WAYLAND_DISPLAY", display)
                        .status();
                    if let Err(error) = status {
                        eprintln!("input adapter failed to start wtype: {error}");
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
        b"schema=1\ndisplay=headless\ngpu=encapsulated-none\nadapter-ingress=private-control-log\ninput=private-wayland-virtual-keyboard\nadapter-egress=private-append-spool\nruntime=private-directory\nwayland-socket=session-internal\nnative-drm=unsupported\nnative-device-adapters=unsupported\n",
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

pub fn run_namespace_init(compositor_argv: Vec<OsString>) -> io::Result<ExitStatus> {
    if compositor_argv.is_empty() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "missing compositor argv",
        ));
    }
    install_signal_handlers()?;
    let mut command = Command::new(&compositor_argv[0]);
    command.args(&compositor_argv[1..]);
    // SAFETY: setpgid is async-signal-safe before exec.
    unsafe {
        command.pre_exec(|| {
            if libc::setpgid(0, 0) == -1 {
                return Err(io::Error::last_os_error());
            }
            Ok(())
        });
    }
    let child = command.spawn()?;
    let primary = child.id() as i32;
    std::mem::forget(child);
    let mut primary_status = None;
    loop {
        let signal = PENDING_SIGNAL.swap(0, Ordering::SeqCst);
        if signal != 0 {
            // SAFETY: negative PID targets the managed compositor group.
            unsafe { libc::kill(-primary, signal) };
        }
        loop {
            let mut status = 0;
            // SAFETY: reap any namespace descendant into writable status.
            let reaped = unsafe { libc::waitpid(-1, &mut status, libc::WNOHANG) };
            if reaped > 0 {
                if reaped == primary {
                    primary_status = Some(status);
                    // Stop remaining orphaned services after the compositor.
                    unsafe { libc::kill(-1, libc::SIGTERM) };
                }
                continue;
            }
            if reaped == -1 && io::Error::last_os_error().raw_os_error() == Some(libc::ECHILD) {
                return Ok(ExitStatus::from_raw(primary_status.unwrap_or_default()));
            }
            break;
        }
        thread::sleep(Duration::from_millis(20));
    }
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
            namespace_launcher: None,
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
        assert!(resources.contains("adapter-ingress=private-control-log"));
        assert!(resources.contains("native-drm=unsupported"));
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn keeps_shell_metacharacters_literal() {
        let argv = vec![OsString::from("printf"), OsString::from("$(touch nope)")];
        assert_eq!(command_display(&argv), "'printf' '$(touch nope)'");
    }
}
