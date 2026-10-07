//! Operations on configured applications.
use anyhow::{Context, Result, ensure};
use clap::Subcommand;
use nixploy::{Config, request_retry};
use std::{
    fs,
    io::ErrorKind,
    path::{Path, PathBuf},
    process,
};

use super::app_name;

#[derive(Subcommand)]
pub enum Command {
    /// List enabled apps in the applied NixOS configuration, one name per line
    List,
    /// Allow a failed release to retry and schedule its updater immediately
    Retry {
        #[arg(value_parser = app_name)]
        app: String,
    },
}

impl Command {
    pub fn run(self) -> Result<()> {
        match self {
            Self::List => list(),
            Self::Retry { app } => retry(&app),
        }
    }
}

fn list() -> Result<()> {
    for app in configured_apps(Path::new("/etc/nixploy"))? {
        println!("{app}");
    }
    Ok(())
}

fn configured_apps(directory: &Path) -> Result<Vec<String>> {
    let entries = match fs::read_dir(directory) {
        Ok(entries) => entries,
        Err(error) if error.kind() == ErrorKind::NotFound => return Ok(Vec::new()),
        Err(error) => return Err(error).context("listing configured apps"),
    };
    let mut apps = Vec::new();
    for entry in entries {
        let entry = entry.context("reading configured app entry")?;
        let filename = entry.file_name();
        let Some(name) = filename
            .to_str()
            .and_then(|name| name.strip_suffix(".json"))
        else {
            continue;
        };
        if app_name(name).is_err() {
            continue;
        }
        // Follow NixOS /etc links, but never read the root-only configuration contents.
        if fs::metadata(entry.path())
            .context("checking configured app file")?
            .is_file()
        {
            apps.push(name.to_owned());
        }
    }
    apps.sort();
    Ok(apps)
}

fn retry(app: &str) -> Result<()> {
    // SAFETY: geteuid takes no arguments and has no memory preconditions.
    ensure!(
        unsafe { libc::geteuid() } == 0,
        "retry requires root; run with sudo"
    );
    let (config, path) = load_config(app)?;
    request_retry(&config, &path)?;
    schedule_update(app)?;
    eprintln!(
        "Retry scheduled for {app}. Follow progress with: journalctl -fu nixploy-update-{app}.service"
    );
    Ok(())
}

fn load_config(app: &str) -> Result<(Config, PathBuf)> {
    let path = PathBuf::from("/etc/nixploy").join(format!("{app}.json"));
    let config: Config = serde_json::from_slice(
        &fs::read(&path).with_context(|| format!("reading configuration for app {app}"))?,
    )?;
    config.validate()?;
    ensure!(
        config.app == app,
        "configuration app name does not match requested app"
    );
    Ok((config, path))
}

fn schedule_update(app: &str) -> Result<()> {
    let status = process::Command::new("systemctl")
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
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::{PermissionsExt, symlink};

    #[test]
    fn lists_sorted_app_names_without_reading_private_configuration() {
        let root = tempfile::tempdir().unwrap();
        let directory = root.path().join("apps");
        fs::create_dir(&directory).unwrap();
        let config = root.path().join("private-config");
        fs::write(&config, "contents are not needed for listing").unwrap();
        fs::set_permissions(&config, fs::Permissions::from_mode(0o000)).unwrap();
        symlink(&config, directory.join("web.json")).unwrap();
        fs::write(directory.join("api.json"), "").unwrap();
        fs::write(directory.join("api.json.bak"), "").unwrap();
        fs::write(directory.join(".hidden.json"), "").unwrap();
        fs::create_dir(directory.join("directory.json")).unwrap();
        assert_eq!(configured_apps(&directory).unwrap(), ["api", "web"]);
    }

    #[test]
    fn empty_or_missing_configuration_lists_no_apps_but_other_errors_surface() {
        let root = tempfile::tempdir().unwrap();
        assert!(configured_apps(root.path()).unwrap().is_empty());
        assert!(
            configured_apps(&root.path().join("missing"))
                .unwrap()
                .is_empty()
        );
        let file = root.path().join("not-a-directory");
        fs::write(&file, "").unwrap();
        assert!(configured_apps(&file).is_err());
    }
}
