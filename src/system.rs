use crate::{Backend, Config, command::run};
use anyhow::{Context, Result, ensure};
use serde::Deserialize;
use std::{
    collections::BTreeMap,
    path::{Path, PathBuf},
    process::Command,
    time::Duration,
};

const GIT_TIMEOUT: Duration = Duration::from_secs(120);
const BUILD_TIMEOUT: Duration = Duration::from_secs(3600);
// Allow stop/start cleanup around the module's maximum 120-second readiness probe.
const ACTIVATION_TIMEOUT: Duration = Duration::from_secs(300);

pub struct SystemBackend {
    config: Config,
}

impl SystemBackend {
    pub fn new(config: Config) -> Self {
        Self { config }
    }

    fn git(&self) -> Command {
        let mut cmd = Command::new("git");
        cmd.args(["-c", "core.hooksPath=/dev/null"])
            .env("GIT_TERMINAL_PROMPT", "0")
            .env("GIT_CONFIG_NOSYSTEM", "1")
            .env("GIT_CONFIG_GLOBAL", "/dev/null");
        cmd
    }
}

impl Backend for SystemBackend {
    fn resolve(&mut self) -> Result<String> {
        let reference = format!("refs/heads/{}", self.config.branch);
        run(
            self.git().args(["check-ref-format", &reference]),
            GIT_TIMEOUT,
        )
        .context("invalid Git branch")?;
        let output = run(
            self.git().args([
                "ls-remote",
                "--exit-code",
                "--refs",
                &self.config.repository,
                &reference,
            ]),
            GIT_TIMEOUT,
        )
        .context("resolving Git branch")?;
        let revisions: Vec<_> = output
            .lines()
            .filter_map(|line| {
                let (revision, name) = line.split_once('\t')?;
                (name == reference).then_some(revision)
            })
            .collect();
        ensure!(
            revisions.len() == 1,
            "configured branch was not uniquely resolved"
        );
        Ok(revisions[0].to_string())
    }

    fn build(&mut self, revision: &str) -> Result<PathBuf> {
        let work = self.config.state_directory.join("work");
        let repo = work.join("repository.git");
        if !repo.exists() {
            run(self.git().args(["init", "--bare"]).arg(&repo), GIT_TIMEOUT)?;
        }
        // Fetch the resolved object, never a moving branch. If the server no
        // longer serves it after a force push, fail and resolve again next poll.
        run(
            self.git().arg("--git-dir").arg(&repo).args([
                "fetch",
                "--force",
                "--no-tags",
                &self.config.repository,
                &format!("{revision}:refs/heads/nixploy"),
            ]),
            GIT_TIMEOUT,
        )
        .context("fetching the resolved commit")?;
        let lock = run(
            self.git()
                .arg("--git-dir")
                .arg(&repo)
                .args(["show", &format!("{revision}:flake.lock")]),
            GIT_TIMEOUT,
        )
        .context("application must commit flake.lock")?;
        let _: serde_json::Value =
            serde_json::from_str(&lock).context("invalid committed flake.lock")?;
        let installable = format!(
            "git+file://{}?ref=refs/heads/nixploy&rev={}#packages.{}.{}",
            repo.display(),
            revision,
            self.config.system,
            serde_json::to_string(&self.config.package)?
        );
        let output = run(
            Command::new("nix")
                .args([
                    "--extra-experimental-features",
                    "nix-command flakes",
                    "build",
                    "--no-update-lock-file",
                    "--no-write-lock-file",
                    "--print-build-logs",
                    "--json",
                    "--out-link",
                ])
                .arg(work.join("build-result"))
                .arg(installable),
            BUILD_TIMEOUT,
        )
        .context("building the locked application package")?;
        #[derive(Deserialize)]
        struct BuildResult {
            outputs: BTreeMap<String, PathBuf>,
        }
        let results: Vec<BuildResult> = serde_json::from_str(&output)?;
        ensure!(results.len() == 1, "expected one package from nix build");
        let path = results[0]
            .outputs
            .get("out")
            .context("package must have an 'out' output")?
            .clone();
        ensure!(
            path.parent() == Some(Path::new("/nix/store")),
            "build returned a non-store output"
        );
        Ok(path)
    }

    fn root(&mut self, output: &Path, root: &Path) -> Result<()> {
        // Re-register existing links too: the daemon's auto root may have been removed.
        run(
            Command::new("nix-store")
                .args(["--realise", "--add-root"])
                .arg(root)
                .arg("--indirect")
                .arg(output),
            BUILD_TIMEOUT,
        )
        .context("retaining package GC root")?;
        Ok(())
    }

    fn restart(&mut self, service: &str) -> Result<()> {
        run(
            Command::new("systemctl").args(["reset-failed", service]),
            ACTIVATION_TIMEOUT,
        )?;
        run(
            Command::new("systemctl").args(["restart", service]),
            ACTIVATION_TIMEOUT,
        )
        .context("restarting application")?;
        Ok(())
    }

    fn stop(&mut self, service: &str) -> Result<()> {
        run(
            Command::new("systemctl").args(["stop", service]),
            ACTIVATION_TIMEOUT,
        )?;
        Ok(())
    }
}
