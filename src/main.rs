use anyhow::{Context, Result, ensure};
use clap::{Parser, Subcommand};
use nixploy::{Config, request_retry};
use std::{fs, path::PathBuf, process::Command};

#[derive(Parser)]
#[command(
    name = "nixploy",
    version,
    about = "Operate applications configured with Nixploy"
)]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    /// Operate configured applications
    App {
        #[command(subcommand)]
        command: AppCommand,
    },
    /// Manage authenticated deployment hooks
    DeployHook {
        #[command(subcommand)]
        command: HookCommand,
    },
}

#[derive(Subcommand)]
enum AppCommand {
    /// Allow a failed release to retry and schedule its updater immediately
    Retry {
        #[arg(value_parser = app_name)]
        app: String,
    },
}

#[derive(Subcommand)]
enum HookCommand {
    /// Retrieve or rotate a Nixploy-generated token (requires root)
    Token {
        #[command(subcommand)]
        command: TokenCommand,
    },
}

#[derive(Subcommand)]
enum TokenCommand {
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

fn main() {
    let cli = Cli::parse();
    if let Err(error) = run(cli) {
        eprintln!("nixploy: {error:#}");
        std::process::exit(1);
    }
}

fn run(cli: Cli) -> Result<()> {
    match cli.command {
        Commands::App {
            command: AppCommand::Retry { app },
        } => {
            // SAFETY: geteuid takes no arguments and has no memory preconditions.
            ensure!(
                unsafe { libc::geteuid() } == 0,
                "retry requires root; run with sudo"
            );
            let path = PathBuf::from("/etc/nixploy").join(format!("{app}.json"));
            let config: Config = serde_json::from_slice(
                &fs::read(&path).with_context(|| format!("reading configuration for app {app}"))?,
            )?;
            config.validate()?;
            ensure!(
                config.app == app,
                "configuration app name does not match requested app"
            );
            request_retry(&config, &path)?;
            let status = Command::new("systemctl")
                .args([
                    "start",
                    "--no-block",
                    "--",
                    &format!("nixploy-update-{app}.service"),
                ])
                .status()
                .context("retry saved, but updater could not be scheduled; polling will retry")?;
            ensure!(
                status.success(),
                "retry saved, but updater could not be scheduled; polling will retry"
            );
            eprintln!(
                "Retry scheduled for {app}. Follow progress with: journalctl -fu nixploy-update-{app}.service"
            );
            Ok(())
        }
        Commands::DeployHook {
            command: HookCommand::Token { command },
        } => match command {
            TokenCommand::Show { app } => nixploy::webhook::show_token(&app),
            TokenCommand::Rotate { app } => nixploy::webhook::rotate_token(&app),
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use clap::{CommandFactory, error::ErrorKind};

    #[test]
    fn command_tree_is_valid_and_help_needs_no_host_configuration() {
        Cli::command().debug_assert();
        for args in [
            vec!["nixploy", "--help"],
            vec!["nixploy", "app", "--help"],
            vec!["nixploy", "deploy-hook", "token", "--help"],
        ] {
            assert_eq!(
                Cli::try_parse_from(args).err().unwrap().kind(),
                ErrorKind::DisplayHelp
            );
        }
        assert_eq!(
            Cli::try_parse_from(["nixploy", "--version"])
                .err()
                .unwrap()
                .kind(),
            ErrorKind::DisplayVersion
        );
    }

    #[test]
    fn public_commands_require_app_names_and_reject_paths() {
        assert!(
            matches!(Cli::try_parse_from(["nixploy", "app", "retry", "my-app"]).unwrap().command,
            Commands::App { command: AppCommand::Retry { app } } if app == "my-app")
        );
        for verb in ["show", "rotate"] {
            assert!(
                Cli::try_parse_from(["nixploy", "deploy-hook", "token", verb, "my-app"]).is_ok()
            );
            for invalid in [
                "",
                "../other",
                "/etc/nixploy/app.json",
                "--other",
                "app.service",
                "a/b",
            ] {
                assert!(
                    Cli::try_parse_from(["nixploy", "deploy-hook", "token", verb, invalid])
                        .is_err()
                );
                assert!(Cli::try_parse_from(["nixploy", "app", "retry", invalid]).is_err());
            }
        }
        assert!(Cli::try_parse_from(["nixploy", "app", "retry"]).is_err());
        assert!(Cli::try_parse_from(["nixploy", "/etc/nixploy/app.json"]).is_err());
        assert!(Cli::try_parse_from(["nixploy", "webhook-init", "/tmp/config.json"]).is_err());
    }
}
