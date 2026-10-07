mod command;
mod system;
pub mod webhook;

pub use system::SystemBackend;

use anyhow::{Context, Result, bail, ensure};
use serde::{Deserialize, Serialize};
use std::{
    fs::{self, File, OpenOptions},
    io::Write,
    os::unix::{
        fs::{OpenOptionsExt, PermissionsExt, symlink},
        io::AsRawFd,
    },
    path::{Path, PathBuf},
};

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Config {
    pub app: String,
    pub repository: String,
    pub branch: String,
    pub package: String,
    pub executable: String,
    pub system: String,
    pub state_directory: PathBuf,
    pub generation: String,
    #[serde(default)]
    pub rollback: bool,
}

impl Config {
    pub fn validate(&self) -> Result<()> {
        fn name(value: &str, dots: bool) -> bool {
            !value.is_empty()
                && value != "."
                && value != ".."
                && value.bytes().all(|c| {
                    c.is_ascii_alphanumeric() || b"_+-".contains(&c) || (dots && c == b'.')
                })
        }
        ensure!(
            name(&self.app, false) && !self.app.contains('+'),
            "invalid app name"
        );
        ensure!(name(&self.package, false), "invalid package name");
        ensure!(
            name(&self.executable, true),
            "executable must be a binary name"
        );
        ensure!(name(&self.system, false), "invalid host system");
        ensure!(
            !self.repository.is_empty()
                && !self.repository.starts_with('-')
                && !self.repository.contains(['\n', '\r']),
            "invalid repository"
        );
        ensure!(
            !self.branch.is_empty()
                && !self.branch.starts_with('-')
                && !self.branch.contains(['\n', '\r']),
            "invalid branch"
        );
        ensure!(
            self.state_directory.is_absolute(),
            "state directory must be absolute"
        );
        Ok(())
    }

    fn service(&self) -> String {
        format!("nixploy-app-{}.service", self.app)
    }
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct Release {
    pub revision: String,
    pub configuration: Config,
    pub output: PathBuf,
}

impl Release {
    fn matches(&self, cfg: &Config, revision: &str) -> bool {
        &self.configuration == cfg && self.revision == revision
    }
}

#[derive(Default, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct State {
    pub active: Option<Release>,
    pub pending: Option<Release>,
    #[serde(default)]
    pub failed: Option<Release>,
    #[serde(default)]
    pub recovery: Option<Recovery>,
}

/// Persist the recovery decision before changing the profile or stopping a service.
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Recovery {
    pub configuration: Config,
    pub target: Option<Release>,
}

/// Effects that need external programs. Durable state and profile transitions are
/// real filesystem operations even in orchestration tests.
pub trait Backend {
    fn resolve(&mut self) -> Result<String>;
    /// Return an output protected by a temporary build root.
    fn build(&mut self, revision: &str) -> Result<PathBuf>;
    fn root(&mut self, output: &Path, root: &Path) -> Result<()>;
    fn restart(&mut self, service: &str) -> Result<()>;
    fn stop(&mut self, service: &str) -> Result<()>;
}

pub fn deploy(cfg: &Config, config_path: &Path, backend: &mut impl Backend) -> Result<()> {
    cfg.validate()?;
    let dir = &cfg.state_directory;
    fs::create_dir_all(dir)?;
    let _lock = lock(dir)?;
    private_directory(&dir.join("work"))?;
    fs::create_dir_all(dir.join("roots"))?;
    let mut state = load_state(dir)?;

    // Finish interrupted rollback before consulting Git, including during outages.
    let recovery_error = if state.recovery.is_some() {
        recover(cfg, config_path, &mut state, backend).err()
    } else {
        None
    };

    let revision = match backend.resolve() {
        Ok(revision) => revision,
        Err(error) => {
            if let Some(error) = recovery_error {
                return Err(error);
            }
            // A network outage must not prevent retrying a locally built release.
            if let Some(pending) = state.pending.as_ref().filter(|p| &p.configuration == cfg) {
                eprintln!("revision lookup failed; retrying pending activation");
                return activate(cfg, config_path, pending.clone(), &mut state, backend);
            }
            return Err(error);
        }
    };
    ensure!(
        matches!(revision.len(), 40 | 64) && revision.bytes().all(|c| c.is_ascii_hexdigit()),
        "Git returned an invalid commit ID"
    );

    if state
        .failed
        .as_ref()
        .is_some_and(|release| release.matches(cfg, &revision))
    {
        if let Some(error) = recovery_error {
            return Err(error);
        }
        eprintln!(
            "{}: revision {} previously failed; skipping (explicit retry or configuration change required)",
            cfg.app, revision
        );
        return Ok(());
    }

    if let Some(pending) = state.pending.as_ref().filter(|p| p.matches(cfg, &revision)) {
        return activate(cfg, config_path, pending.clone(), &mut state, backend);
    }
    if let Some(active) = state.active.as_ref().filter(|a| a.matches(cfg, &revision)) {
        if state.pending.is_none()
            && state.recovery.is_none()
            && fs::read_link(dir.join("profile")).ok().as_ref() == Some(&active.output)
        {
            backend.root(&active.output, &release_root(dir, active)?)?;
            cleanup(dir, &state)?;
            eprintln!("{}: revision {} already active", cfg.app, revision);
            return Ok(());
        }
        return activate(cfg, config_path, active.clone(), &mut state, backend);
    }

    eprintln!("{}: building revision {}", cfg.app, revision);
    let output = backend.build(&revision)?;
    let release = Release {
        revision,
        configuration: cfg.clone(),
        output,
    };
    activate(cfg, config_path, release, &mut state, backend)
}

fn activate(
    cfg: &Config,
    config_path: &Path,
    release: Release,
    state: &mut State,
    backend: &mut impl Backend,
) -> Result<()> {
    let dir = &cfg.state_directory;
    let executable = release.output.join("bin").join(&cfg.executable);
    let metadata =
        fs::metadata(&executable).context("package does not contain the configured executable")?;
    ensure!(
        metadata.is_file() && metadata.permissions().mode() & 0o111 != 0,
        "configured executable is not an executable file"
    );
    let root = release_root(dir, &release)?;
    backend.root(&release.output, &root)?;
    sync_directory(&dir.join("roots"))?;

    // /etc is updated on a NixOS switch. A superseded or removed app must not
    // activate using configuration loaded before a long build.
    ensure_current(cfg, config_path)?;
    state.pending = Some(release.clone());
    state.recovery = None;
    save_state(dir, state)?;
    cleanup(dir, state)?;
    switch_profile(dir, &release.output)?;
    if let Err(error) = backend.restart(&cfg.service()) {
        if !cfg.rollback {
            return Err(error);
        }
        ensure_current(cfg, config_path)?;
        state.failed = Some(release.clone());
        state.pending = None;
        state.recovery = Some(Recovery {
            configuration: cfg.clone(),
            // Restoring the same package cannot repair a failed startup.
            target: state
                .active
                .clone()
                .filter(|active| active.output != release.output),
        });
        save_state(dir, state)?;
        recover(cfg, config_path, state, backend)
            .context("deployment failed and recovery remains pending")?;
        return Err(
            error.context("deployment failed; recovery completed and failed revision suppressed")
        );
    }
    ensure_current(cfg, config_path)?;
    state.active = Some(release);
    state.pending = None;
    save_state(dir, state)?;
    cleanup(dir, state)?;
    eprintln!("{}: activation complete", cfg.app);
    Ok(())
}

fn ensure_current(cfg: &Config, config_path: &Path) -> Result<()> {
    let current: Config = serde_json::from_slice(
        &fs::read(config_path).context("configuration was removed during update")?,
    )?;
    ensure!(
        &current == cfg,
        "configuration changed during update; retry with the current configuration"
    );
    Ok(())
}

fn recover(
    cfg: &Config,
    config_path: &Path,
    state: &mut State,
    backend: &mut impl Backend,
) -> Result<()> {
    let recovery = state.recovery.clone().context("missing recovery state")?;
    ensure_current(cfg, config_path)?;
    // The NixOS configuration may have changed while a worker was stopped. Do not
    // restore a package using a superseded runtime configuration.
    if recovery.configuration != *cfg {
        state.recovery = None;
        save_state(&cfg.state_directory, state)?;
        return Ok(());
    }
    let dir = &cfg.state_directory;
    backend
        .stop(&cfg.service())
        .context("stopping failed application")?;
    ensure_current(cfg, config_path)?;
    if let Some(target) = &recovery.target {
        let executable = target.output.join("bin").join(&cfg.executable);
        let metadata =
            fs::metadata(executable).context("rollback package lacks configured executable")?;
        ensure!(
            metadata.is_file() && metadata.permissions().mode() & 0o111 != 0,
            "rollback executable is not executable"
        );
        backend.root(&target.output, &release_root(dir, target)?)?;
        ensure_current(cfg, config_path)?;
        switch_profile(dir, &target.output)?;
        backend
            .restart(&cfg.service())
            .context("rollback application did not become ready")?;
        ensure_current(cfg, config_path)?;
        eprintln!("{}: restored previous release {}", cfg.app, target.revision);
    } else {
        // Do not leave the failed first release selected for a later boot.
        match fs::remove_file(dir.join("profile")) {
            Ok(()) => sync_directory(dir)?,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => (),
            Err(error) => return Err(error.into()),
        }
        eprintln!(
            "{}: no previous package to restore; application stopped",
            cfg.app
        );
    }
    state.recovery = None;
    save_state(dir, state)?;
    cleanup(dir, state)
}

/// Authorize one retry. The regular updater performs it with its normal credentials.
pub fn request_retry(cfg: &Config, config_path: &Path) -> Result<()> {
    cfg.validate()?;
    let dir = &cfg.state_directory;
    let _lock = lock(dir)?;
    ensure_current(cfg, config_path)?;
    let mut state = load_state(dir)?;
    ensure!(
        state.recovery.is_none(),
        "recovery is still pending; run the updater to finish recovery first"
    );
    let failed = state
        .failed
        .as_ref()
        .context("no failed release to retry")?;
    ensure!(
        failed.configuration == *cfg,
        "failed release used a different configuration; run the updater normally"
    );
    state.pending = state.failed.take();
    save_state(dir, &state)
}

fn release_root(dir: &Path, release: &Release) -> Result<PathBuf> {
    Ok(dir.join("roots").join(
        release
            .output
            .file_name()
            .context("invalid package output path")?,
    ))
}

fn cleanup(dir: &Path, state: &State) -> Result<()> {
    let mut keep: Vec<_> = state
        .active
        .iter()
        .chain(state.pending.iter())
        .chain(state.failed.iter())
        .chain(
            state
                .recovery
                .iter()
                .filter_map(|recovery| recovery.target.as_ref()),
        )
        .map(|release| release_root(dir, release))
        .collect::<Result<_>>()?;
    // Keep the currently selected output until the restart completes as well.
    // It can differ from both active and pending while superseding a failed attempt.
    if let Some(name) = fs::read_link(dir.join("profile"))
        .ok()
        .and_then(|path| path.file_name().map(|name| name.to_owned()))
    {
        keep.push(dir.join("roots").join(name));
    }
    for entry in fs::read_dir(dir.join("roots"))? {
        let path = entry?.path();
        if !keep.contains(&path) {
            fs::remove_file(path)?;
        }
    }
    // Nix can create additional output links for multi-output derivations.
    for entry in fs::read_dir(dir.join("work"))? {
        let entry = entry?;
        if entry
            .file_name()
            .to_string_lossy()
            .starts_with("build-result")
            && entry.file_type()?.is_symlink()
        {
            fs::remove_file(entry.path())?;
        }
    }
    sync_directory(&dir.join("roots"))?;
    Ok(())
}

fn lock(dir: &Path) -> Result<File> {
    let file = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .mode(0o600)
        .open(dir.join("lock"))?;
    // SAFETY: file owns a live descriptor for the lifetime of this lock guard.
    if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
        bail!(
            "another update holds this app's lock: {}",
            std::io::Error::last_os_error()
        );
    }
    Ok(file)
}

fn private_directory(path: &Path) -> Result<()> {
    fs::create_dir_all(path)?;
    fs::set_permissions(path, fs::Permissions::from_mode(0o700))?;
    Ok(())
}

pub fn load_state(dir: &Path) -> Result<State> {
    match fs::read(dir.join("state.json")) {
        Ok(bytes) => serde_json::from_slice(&bytes)
            .context("invalid deployment state; refusing to overwrite it"),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(State::default()),
        Err(error) => Err(error.into()),
    }
}

fn save_state(dir: &Path, state: &State) -> Result<()> {
    let mut file = tempfile::NamedTempFile::new_in(dir)?;
    serde_json::to_writer_pretty(&mut file, state)?;
    file.write_all(b"\n")?;
    file.as_file().sync_all()?;
    file.persist(dir.join("state.json"))?;
    sync_directory(dir)
}

fn switch_profile(dir: &Path, output: &Path) -> Result<()> {
    let temporary = dir.join("profile.next");
    match fs::remove_file(&temporary) {
        Ok(()) => (),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => (),
        Err(error) => return Err(error.into()),
    }
    symlink(output, &temporary)?;
    fs::rename(temporary, dir.join("profile"))?;
    sync_directory(dir)
}

fn sync_directory(dir: &Path) -> Result<()> {
    File::open(dir)?.sync_all()?;
    Ok(())
}

#[cfg(test)]
mod tests;
