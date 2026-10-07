//! Deployment hook token commands.
use anyhow::Result;
use clap::Subcommand;

use super::app_name;

#[derive(Subcommand)]
pub enum Command {
    /// Retrieve or rotate a Nixploy-generated token (requires root)
    Token {
        #[command(subcommand)]
        command: TokenCommand,
    },
}

#[derive(Subcommand)]
pub enum TokenCommand {
    /// Print only the token to stdout; keep the output secret
    Show {
        #[arg(value_parser = app_name)]
        app: String,
    },
    /// Replace the token and restart the receiver; update your CI secret afterward
    Rotate {
        #[arg(value_parser = app_name)]
        app: String,
    },
}

impl Command {
    pub fn run(self) -> Result<()> {
        match self {
            Self::Token { command } => command.run(),
        }
    }
}

impl TokenCommand {
    fn run(self) -> Result<()> {
        match self {
            Self::Show { app } => nixploy::webhook::show_token(&app),
            Self::Rotate { app } => nixploy::webhook::rotate_token(&app),
        }
    }
}
