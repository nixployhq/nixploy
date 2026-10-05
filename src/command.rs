use anyhow::{Context, Result, bail, ensure};
use std::{
    io::{Read, Seek, SeekFrom},
    os::unix::process::CommandExt,
    process::{Command, Stdio},
    thread,
    time::{Duration, Instant},
};

/// Capture stdout in a file so large output cannot deadlock a child. Stderr goes
/// directly to the journal. Never print command arguments (they may be sensitive).
pub fn run(command: &mut Command, timeout: Duration) -> Result<String> {
    let mut output = tempfile::tempfile()?;
    command
        .stdin(Stdio::null())
        .stdout(output.try_clone()?)
        .stderr(Stdio::inherit())
        .process_group(0);
    let mut child = command.spawn().context("starting subprocess")?;
    let start = Instant::now();
    let status = loop {
        if let Some(status) = child.try_wait()? {
            break status;
        }
        if start.elapsed() >= timeout {
            // SAFETY: the child was assigned its own process group above. Kill
            // its descendants too, then reap the direct child.
            unsafe {
                libc::kill(-(child.id() as i32), libc::SIGKILL);
            }
            let _ = child.wait();
            bail!("subprocess timed out after {} seconds", timeout.as_secs());
        }
        thread::sleep(Duration::from_millis(25));
    };
    ensure!(status.success(), "subprocess failed with {status}");
    ensure!(
        output.metadata()?.len() <= 8 * 1024 * 1024,
        "subprocess stdout exceeded 8 MiB"
    );
    output.seek(SeekFrom::Start(0))?;
    let mut text = String::new();
    output.read_to_string(&mut text)?;
    Ok(text)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn arguments_remain_literal() {
        let value = "$(touch /tmp/nixploy-must-not-exist); ' spaced";
        let output = run(
            Command::new("printf").args(["%s", value]),
            Duration::from_secs(2),
        )
        .unwrap();
        assert_eq!(output, value);
    }

    #[test]
    fn failed_commands_are_errors() {
        assert!(run(&mut Command::new("false"), Duration::from_secs(2)).is_err());
    }

    #[test]
    fn timeouts_terminate_commands() {
        let start = Instant::now();
        assert!(run(Command::new("sleep").arg("10"), Duration::from_millis(50)).is_err());
        assert!(start.elapsed() < Duration::from_secs(2));
    }
}
