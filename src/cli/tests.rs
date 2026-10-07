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
    assert!(matches!(
        Cli::try_parse_from(["nixploy", "app", "list"])
            .unwrap()
            .command,
        Commands::App {
            command: app::Command::List
        }
    ));
    assert!(Cli::try_parse_from(["nixploy", "app", "list", "my-app"]).is_err());
    assert!(
        matches!(Cli::try_parse_from(["nixploy", "app", "retry", "my-app"]).unwrap().command,
        Commands::App { command: app::Command::Retry { app } } if app == "my-app")
    );
    for verb in ["show", "rotate"] {
        assert!(Cli::try_parse_from(["nixploy", "deploy-hook", "token", verb, "my-app"]).is_ok());
        for invalid in [
            "",
            "../other",
            "/etc/nixploy/app.json",
            "--other",
            "app.service",
            "a/b",
        ] {
            assert!(
                Cli::try_parse_from(["nixploy", "deploy-hook", "token", verb, invalid]).is_err()
            );
            assert!(Cli::try_parse_from(["nixploy", "app", "retry", invalid]).is_err());
        }
    }
    assert!(Cli::try_parse_from(["nixploy", "app", "retry"]).is_err());
    assert!(Cli::try_parse_from(["nixploy", "/etc/nixploy/app.json"]).is_err());
    assert!(Cli::try_parse_from(["nixploy", "webhook-init", "/tmp/config.json"]).is_err());
}
