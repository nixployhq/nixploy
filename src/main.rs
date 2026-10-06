use anyhow::{Context, Result, bail};
use nixploy::{Config, SystemBackend, deploy, request_retry};
use std::{env, fs, path::PathBuf};

fn main() {
    if let Err(error) = run() {
        eprintln!("nixploy: {error:#}");
        std::process::exit(1);
    }
}

fn run() -> Result<()> {
    let args: Vec<_> = env::args_os().skip(1).collect();
    let (retry, path) = match args.as_slice() {
        [path] => (false, PathBuf::from(path)),
        [command, path] if command == "retry" => (true, PathBuf::from(path)),
        _ => bail!("usage: nixploy [retry] /etc/nixploy/<app>.json"),
    };
    let config: Config =
        serde_json::from_slice(&fs::read(&path).context("reading configuration")?)?;
    config.validate()?;
    if retry {
        request_retry(&config, &path)?;
        eprintln!(
            "Retry scheduled. Wait for the next poll or run: systemctl start nixploy-update-{}.service",
            config.app
        );
        return Ok(());
    }
    let mut backend = SystemBackend::new(config.clone());
    deploy(&config, &path, &mut backend)
}
