//! Public command parsing and dispatch.
mod app;
mod deploy_hook;

use anyhow::Result;
use clap::{Parser, Subcommand};

#[derive(Parser)]
#[command(
    name = "nixploy",
    version,
    about = "Operate applications configured with Nixploy"
)]
pub struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    /// Operate configured applications
    App {
        #[command(subcommand)]
        command: app::Command,
    },
    /// Manage authenticated deployment hooks
    DeployHook {
        #[command(subcommand)]
        command: deploy_hook::Command,
    },
}

impl Cli {
    pub fn run(self) -> Result<()> {
        match self.command {
            Commands::App { command } => command.run(),
            Commands::DeployHook { command } => command.run(),
        }
    }
}

fn app_name(value: &str) -> Result<String, String> {
    if !value.is_empty()
        && value.as_bytes()[0].is_ascii_alphanumeric()
        && value
            .bytes()
            .all(|c| c.is_ascii_alphanumeric() || b"_-".contains(&c))
    {
        Ok(value.to_owned())
    } else {
        Err("expected an app name starting with a letter or digit, containing only letters, digits, underscores, and hyphens".into())
    }
}

#[cfg(test)]
mod tests;
