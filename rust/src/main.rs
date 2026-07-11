use std::process::ExitCode;
use wayland_session_supervisor::checkpoint::{CheckpointOptions, capture, diagnose, restore};
use wayland_session_supervisor::{
    SessionConfig, SessionDomain, command_display, run_namespace_init,
    run_privileged_namespace_launcher,
};

fn main() -> ExitCode {
    let mut arguments = std::env::args_os().skip(1);
    match arguments.next().as_deref() {
        Some(command) if command == "run" => run(arguments),
        Some(command) if command == "capture" => checkpoint(arguments, true),
        Some(command) if command == "diagnose" => diagnostics(arguments),
        Some(command) if command == "restore" => checkpoint(arguments, false),
        Some(command) if command == "namespace-init" => namespace_init(arguments),
        Some(command) if command == "namespace-launch" => namespace_launch(arguments),
        _ => {
            eprintln!(
                "usage: wayland-session-supervisor <run|diagnose|capture|restore> [OPTIONS] -- COMPOSITOR [ARG ...]"
            );
            ExitCode::from(2)
        }
    }
}

fn namespace_launch(arguments: impl IntoIterator<Item = std::ffi::OsString>) -> ExitCode {
    match run_privileged_namespace_launcher(arguments) {
        Ok(status) => ExitCode::from(status.code().unwrap_or(1) as u8),
        Err(error) => {
            eprintln!("namespace launch failed: {error}");
            ExitCode::FAILURE
        }
    }
}

fn namespace_init(arguments: impl IntoIterator<Item = std::ffi::OsString>) -> ExitCode {
    let mut arguments = arguments.into_iter();
    if arguments.next().as_deref() != Some(std::ffi::OsStr::new("--")) {
        return ExitCode::from(2);
    }
    match run_namespace_init(arguments.collect()) {
        Ok(status) => ExitCode::from(status.code().unwrap_or(1) as u8),
        Err(error) => {
            eprintln!("namespace init failed: {error}");
            ExitCode::FAILURE
        }
    }
}

fn run(arguments: impl IntoIterator<Item = std::ffi::OsString>) -> ExitCode {
    let config = match SessionConfig::parse(arguments) {
        Ok(config) => config,
        Err(error) => {
            eprintln!("invalid session configuration: {error}");
            return ExitCode::from(2);
        }
    };
    eprintln!(
        "starting session '{}' with {}",
        config.session_name,
        command_display(&config.compositor_argv)
    );

    let domain = match SessionDomain::prepare(config) {
        Ok(domain) => domain,
        Err(error) => {
            eprintln!("failed to prepare session domain: {error}");
            return ExitCode::FAILURE;
        }
    };
    match domain.run() {
        Ok(status) => ExitCode::from(status.code().unwrap_or(1) as u8),
        Err(error) => {
            eprintln!("session failed: {error}");
            ExitCode::FAILURE
        }
    }
}

fn diagnostics(arguments: impl IntoIterator<Item = std::ffi::OsString>) -> ExitCode {
    let options = match CheckpointOptions::parse(arguments) {
        Ok(options) => options,
        Err(error) => {
            eprintln!("invalid diagnostic configuration: {error}");
            return ExitCode::from(2);
        }
    };
    match diagnose(&options) {
        Ok(path) => {
            println!("diagnostic report written to {}", path.display());
            ExitCode::SUCCESS
        }
        Err(error) => {
            eprintln!("diagnostics failed: {error}");
            ExitCode::FAILURE
        }
    }
}

fn checkpoint(
    arguments: impl IntoIterator<Item = std::ffi::OsString>,
    is_capture: bool,
) -> ExitCode {
    let options = match CheckpointOptions::parse(arguments) {
        Ok(options) => options,
        Err(error) => {
            eprintln!("invalid checkpoint configuration: {error}");
            return ExitCode::from(2);
        }
    };
    if is_capture {
        match capture(&options) {
            Ok(path) => {
                println!("checkpoint captured at {}", path.display());
                ExitCode::SUCCESS
            }
            Err(error) => {
                eprintln!("capture failed: {error}");
                ExitCode::FAILURE
            }
        }
    } else {
        match restore(&options) {
            Ok(status) => ExitCode::from(status.code().unwrap_or(1) as u8),
            Err(error) => {
                eprintln!("restore failed: {error}");
                ExitCode::FAILURE
            }
        }
    }
}
