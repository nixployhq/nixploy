//! Internal Git credential helper. Secrets travel only over Git's helper pipe.
use anyhow::{Context, Result, bail, ensure};
use std::{
    env,
    fs::File,
    io::{self, Read, Write},
    path::Path,
};

const LIMIT: u64 = 16 * 1024;

fn bounded_read(reader: impl Read) -> Result<String> {
    let mut value = String::new();
    reader
        .take(LIMIT + 1)
        .read_to_string(&mut value)
        .context("reading credential data")?;
    ensure!(value.len() as u64 <= LIMIT, "credential data too large");
    Ok(value)
}

fn context(repository: &str) -> Result<(&str, &str)> {
    let (host, path) = repository
        .strip_prefix("https://")
        .and_then(|url| url.split_once('/'))
        .context("credential repository must be an HTTPS URL")?;
    ensure!(
        !host.is_empty()
            && !host.contains('@')
            && !path.is_empty()
            && !repository
                .chars()
                .any(|c| c.is_control() || c.is_whitespace())
            && !repository.contains(['?', '#']),
        "invalid credential repository URL"
    );
    Ok((host, path))
}

fn answer(
    repository: &str,
    username: &str,
    operation: &str,
    input: &str,
    token_file: &Path,
    output: &mut impl Write,
) -> Result<()> {
    // Git sends the password back on store/erase. Never persist or print it.
    if operation != "get" {
        return Ok(());
    }
    let (host, path) = context(repository)?;
    ensure!(
        !username.is_empty()
            && !username.contains(':')
            && !username
                .chars()
                .any(|c| c.is_control() || c.is_whitespace()),
        "invalid HTTPS username"
    );
    let mut fields = std::collections::BTreeMap::new();
    for line in input.lines().take_while(|line| !line.is_empty()) {
        ensure!(!line.contains(['\0', '\r']), "invalid credential request");
        let (key, value) = line.split_once('=').context("invalid credential request")?;
        if matches!(key, "protocol" | "host" | "path" | "username") {
            ensure!(
                fields.insert(key, value).is_none(),
                "duplicate credential field"
            );
        }
    }
    if fields.get("protocol") != Some(&"https")
        || fields.get("host") != Some(&host)
        || fields.get("path") != Some(&path)
        || fields
            .get("username")
            .is_some_and(|value| *value != username)
    {
        output.write_all(b"quit=true\n\n")?;
        return Ok(());
    }
    let value = bounded_read(File::open(token_file).context("opening HTTPS token credential")?)?;
    let token = value
        .strip_suffix("\r\n")
        .or_else(|| value.strip_suffix('\n'))
        .unwrap_or(&value);
    ensure!(
        !token.is_empty() && !token.chars().any(|c| c.is_control() || c.is_whitespace()),
        "HTTPS token must be one nonempty line"
    );
    writeln!(output, "username={username}\npassword={token}\n")?;
    Ok(())
}

fn run() -> Result<()> {
    let args: Vec<_> = env::args().skip(1).collect();
    let [repository, username, operation] = args.as_slice() else {
        bail!("internal Git credential helper: expected repository, username, operation");
    };
    if operation != "get" {
        return Ok(());
    }
    let directory =
        env::var_os("CREDENTIALS_DIRECTORY").context("missing systemd credentials directory")?;
    let input = bounded_read(io::stdin().lock())?;
    answer(
        repository,
        username,
        operation,
        &input,
        &Path::new(&directory).join("git-token"),
        &mut io::stdout().lock(),
    )
}

fn main() {
    if run().is_err() {
        // Never include input or filesystem error details in the journal.
        eprintln!("nixploy: HTTPS credential unavailable or invalid");
        std::process::exit(1);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    const REPO: &str = "https://example.com/team/app.git";
    const INPUT: &str = "protocol=https\nhost=example.com\npath=team/app.git\n\n";

    #[test]
    fn exact_scope_and_rotation() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("token");
        for value in ["first-token\n", "second-token\r\n"] {
            std::fs::write(&path, value).unwrap();
            let mut output = Vec::new();
            answer(REPO, "user", "get", INPUT, &path, &mut output).unwrap();
            assert_eq!(
                String::from_utf8(output).unwrap(),
                format!("username=user\npassword={}\n\n", value.trim())
            );
        }
    }

    #[test]
    fn denies_other_protocol_host_path_and_username_before_reading_secret() {
        for input in [
            INPUT.replace("https", "http"),
            INPUT.replace("example.com", "other.example"),
            INPUT.replace("app.git", "other.git"),
            INPUT.replace("app.git", "app.git/extra"),
            INPUT.replace("\n\n", "\nusername=other\n\n"),
            "protocol=https\nhost=example.com\n\n".into(),
        ] {
            let mut output = Vec::new();
            answer(
                REPO,
                "user",
                "get",
                &input,
                Path::new("/does-not-exist"),
                &mut output,
            )
            .unwrap();
            assert_eq!(output, b"quit=true\n\n");
        }
    }

    #[test]
    fn rejects_invalid_tokens_without_emitting_them() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("token");
        for value in [
            "",
            "\n",
            "secret\npassword=another",
            "secret\0",
            "secret with space",
        ] {
            std::fs::write(&path, value).unwrap();
            let mut output = Vec::new();
            assert!(answer(REPO, "user", "get", INPUT, &path, &mut output).is_err());
            assert!(output.is_empty());
        }
    }

    #[test]
    fn store_and_erase_do_not_read_or_write_credentials() {
        for operation in ["store", "erase"] {
            let mut output = Vec::new();
            answer(
                REPO,
                "user",
                operation,
                "password=secret\n",
                Path::new("/does-not-exist"),
                &mut output,
            )
            .unwrap();
            assert!(output.is_empty());
        }
    }

    #[test]
    fn bounds_input_and_rejects_ambiguous_fields() {
        assert!(bounded_read(vec![b'x'; LIMIT as usize + 1].as_slice()).is_err());
        let mut output = Vec::new();
        assert!(
            answer(
                REPO,
                "user",
                "get",
                "protocol=https\nhost=example.com\nhost=evil.example\n\n",
                Path::new("/does-not-exist"),
                &mut output
            )
            .is_err()
        );
        assert!(output.is_empty());
    }
}
