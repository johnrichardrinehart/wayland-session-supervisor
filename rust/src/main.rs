use std::process::{Command, ExitCode};

fn main() -> ExitCode {
    let mut arguments = std::env::args_os().skip(1);
    if arguments.next().as_deref() != Some("run".as_ref())
        || arguments.next().as_deref() != Some("--".as_ref())
    {
        eprintln!("usage: wayland-session-supervisor run -- COMPOSITOR [ARG ...]");
        return ExitCode::from(2);
    }

    let Some(program) = arguments.next() else {
        eprintln!("a compositor command is required");
        return ExitCode::from(2);
    };

    match Command::new(program).args(arguments).status() {
        Ok(status) => ExitCode::from(status.code().unwrap_or(1) as u8),
        Err(error) => {
            eprintln!("failed to start compositor: {error}");
            ExitCode::FAILURE
        }
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn scaffold_is_testable() {
        assert_eq!(2 + 2, 4);
    }
}
