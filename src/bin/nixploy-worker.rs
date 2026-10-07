//! Internal systemd entry points. The public CLI operates on configured app names.
use anyhow::{Context, Result};
use clap::{Parser, Subcommand};
use nixploy::{Config, SystemBackend, deploy};
use std::{fs, path::PathBuf};

#[derive(Parser)]
#[command(version, about = "Internal Nixploy worker invoked by systemd")]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    Update { config: PathBuf },
    InitTokens { config: PathBuf },
    ServeHooks { config: PathBuf },
}

fn main() {
    if let Err(error) = run(Cli::parse()) {
        eprintln!("nixploy-worker: {error:#}");
        std::process::exit(1);
    }
}

fn run(cli: Cli) -> Result<()> {
    match cli.command {
        Command::Update { config: path } => {
            let config: Config =
                serde_json::from_slice(&fs::read(&path).context("reading configuration")?)?;
            config.validate()?;
            let mut backend = SystemBackend::new(config.clone());
            deploy(&config, &path, &mut backend)
        }
        Command::InitTokens { config } => nixploy::webhook::initialize_from_file(&config),
        Command::ServeHooks { config } => nixploy::webhook::serve_from_file(&config),
    }
}
