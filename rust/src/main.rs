use std::process::ExitCode;
use wayland_session_supervisor::{SessionConfig, SessionDomain, command_display};

fn main() -> ExitCode {
    let mut arguments = std::env::args_os().skip(1);
    if arguments.next().as_deref() != Some("run".as_ref()) {
        eprintln!("usage: wayland-session-supervisor run [OPTIONS] -- COMPOSITOR [ARG ...]");
        return ExitCode::from(2);
    }

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
