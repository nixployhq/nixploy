use anyhow::{Context, Result, bail};
use nixploy::{Config, SystemBackend, deploy};
use std::{env, fs, path::PathBuf};

fn main() {
    if let Err(error) = run() {
        eprintln!("nixploy: {error:#}");
        std::process::exit(1);
    }
}

fn run() -> Result<()> {
    let args: Vec<_> = env::args_os().skip(1).collect();
    if args.len() != 1 {
        bail!("usage: nixploy /etc/nixploy/<app>.json (normally invoked by systemd)");
    }
    let path = PathBuf::from(&args[0]);
    let config: Config =
        serde_json::from_slice(&fs::read(&path).context("reading configuration")?)?;
    config.validate()?;
    let mut backend = SystemBackend::new(config.clone());
    deploy(&config, &path, &mut backend)
}
