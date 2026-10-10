use super::*;
use tempfile::TempDir;

struct Fake {
    revision: String,
    output: PathBuf,
    resolve_failure: bool,
    build_failure: bool,
    restart_failure: bool,
    restart_results: std::collections::VecDeque<bool>,
    stops: usize,
    stop_failure: bool,
    builds: Vec<String>,
    restarts: usize,
    change_during_build: Option<(PathBuf, Config)>,
    change_during_restart: Option<(PathBuf, Config)>,
}

impl Backend for Fake {
    fn resolve(&mut self) -> Result<String> {
        ensure!(!self.resolve_failure, "fetch failed");
        Ok(self.revision.clone())
    }
    fn build(&mut self, revision: &str) -> Result<PathBuf> {
        self.builds.push(revision.to_owned());
        ensure!(!self.build_failure, "build failed");
        if let Some((path, cfg)) = &self.change_during_build {
            fs::write(path, serde_json::to_vec(cfg)?)?;
        }
        // Simulate a second push while the first revision is being built.
        self.revision = "b".repeat(40);
        Ok(self.output.clone())
    }
    fn root(&mut self, output: &Path, root: &Path) -> Result<()> {
        if root.symlink_metadata().is_ok() {
            fs::remove_file(root)?;
        }
        symlink(output, root)?;
        Ok(())
    }
    fn restart(&mut self, _: &str) -> Result<()> {
        self.restarts += 1;
        if let Some((path, cfg)) = self.change_during_restart.take() {
            fs::write(path, serde_json::to_vec(&cfg)?)?;
        }
        ensure!(
            !self.restart_failure && self.restart_results.pop_front().unwrap_or(true),
            "restart failed"
        );
        Ok(())
    }
    fn stop(&mut self, _: &str) -> Result<()> {
        self.stops += 1;
        ensure!(!self.stop_failure, "stop failed");
        Ok(())
    }
}

struct Fixture {
    _temp: TempDir,
    config: Config,
    path: PathBuf,
    fake: Fake,
}

impl Fixture {
    fn new() -> Self {
        let temp = tempfile::tempdir().unwrap();
        let config = Config {
            app: "demo".into(),
            repository: "https://example.com/demo.git".into(),
            branch: "main".into(),
            package: "default".into(),
            executable: "server".into(),
            system: "x86_64-linux".into(),
            state_directory: temp.path().join("state"),
            generation: "1".into(),
            rollback: false,
        };
        let path = temp.path().join("config.json");
        fs::write(&path, serde_json::to_vec(&config).unwrap()).unwrap();
        let output = temp.path().join("package-one");
        package(&output);
        Self {
            _temp: temp,
            config,
            path,
            fake: Fake {
                revision: "a".repeat(40),
                output,
                resolve_failure: false,
                build_failure: false,
                restart_failure: false,
                restart_results: Default::default(),
                stops: 0,
                stop_failure: false,
                builds: vec![],
                restarts: 0,
                change_during_build: None,
                change_during_restart: None,
            },
        }
    }
    fn run(&mut self) -> Result<()> {
        deploy(&self.config, &self.path, &mut self.fake)
    }
    fn state(&self) -> State {
        load_state(&self.config.state_directory).unwrap()
    }
    fn profile(&self) -> PathBuf {
        fs::read_link(self.config.state_directory.join("profile")).unwrap()
    }
    fn next(&mut self) {
        self.fake.revision = "b".repeat(40);
        self.fake.output = self._temp.path().join("package-two");
        package(&self.fake.output);
    }
    fn enable_rollback(&mut self) {
        self.config.rollback = true;
        fs::write(&self.path, serde_json::to_vec(&self.config).unwrap()).unwrap();
    }
}

fn package(path: &Path) {
    fs::create_dir_all(path.join("bin")).unwrap();
    let executable = path.join("bin/server");
    fs::write(&executable, "fixture").unwrap();
    fs::set_permissions(executable, fs::Permissions::from_mode(0o755)).unwrap();
}

#[test]
fn first_deploy_pins_resolved_commit_even_when_branch_advances() {
    let mut f = Fixture::new();
    f.run().unwrap();
    assert_eq!(f.state().active.unwrap().revision, "a".repeat(40));
    assert_eq!(f.fake.builds, ["a".repeat(40)]);
    assert_eq!(f.profile(), f.fake.output);
    assert_eq!(f.fake.restarts, 1);
}

#[test]
fn unchanged_revision_is_noop_and_second_commit_deploys() {
    let mut f = Fixture::new();
    f.run().unwrap();
    f.fake.revision = "a".repeat(40);
    f.run().unwrap();
    assert_eq!(f.fake.restarts, 1);
    assert_eq!(f.fake.builds.len(), 1);
    f.next();
    f.run().unwrap();
    assert_eq!(f.state().active.unwrap().revision, "b".repeat(40));
    assert_eq!(f.fake.restarts, 2);
    assert_eq!(
        fs::read_dir(f.config.state_directory.join("roots"))
            .unwrap()
            .count(),
        1
    );
}

#[test]
fn fetch_and_build_failure_preserve_running_release_and_explicit_retry() {
    let mut f = Fixture::new();
    f.run().unwrap();
    let previous = f.profile();
    f.next();
    f.fake.resolve_failure = true;
    assert!(f.run().is_err());
    f.fake.resolve_failure = false;
    f.fake.build_failure = true;
    assert!(f.run().is_err());
    assert_eq!(f.profile(), previous);
    assert_eq!(f.fake.restarts, 1);
    assert_eq!(f.state().active.unwrap().revision, "a".repeat(40));
    f.fake.build_failure = false;
    // Each invocation reloads durable state, just like a fresh polling worker.
    f.run().unwrap();
    assert_eq!(f.fake.builds.len(), 2);
    assert_eq!(f.fake.restarts, 1);
    request_retry(&f.config, &f.path).unwrap();
    f.run().unwrap();
    assert_eq!(f.fake.restarts, 2);
}

#[test]
fn failed_build_is_suppressed_until_revision_configuration_or_explicit_retry_changes() {
    for trigger in ["revision", "configuration", "retry"] {
        let mut f = Fixture::new();
        f.fake.build_failure = true;
        assert!(f.run().is_err());
        let failure = f.state().failed_build.unwrap();
        assert_eq!(failure.revision, "a".repeat(40));
        assert_eq!(failure.configuration, f.config);
        assert_eq!(failure.error, "build failed");
        for _ in 0..3 {
            f.run().unwrap();
        }
        assert_eq!(f.fake.builds.len(), 1, "{trigger}");
        assert_eq!(f.fake.restarts, 0);
        match trigger {
            "revision" => f.next(),
            "configuration" => {
                f.config.generation = "2".into();
                fs::write(&f.path, serde_json::to_vec(&f.config).unwrap()).unwrap();
            }
            "retry" => request_retry(&f.config, &f.path).unwrap(),
            _ => unreachable!(),
        }
        // A second failed attempt must also be suppressed.
        assert!(f.run().is_err());
        f.run().unwrap();
        assert_eq!(f.fake.builds.len(), 2, "{trigger}");
        request_retry(&f.config, &f.path).unwrap();
        f.fake.build_failure = false;
        f.run().unwrap();
        assert_eq!(f.fake.builds.len(), 3, "{trigger}");
        assert_eq!(f.fake.restarts, 1);
        assert!(f.state().failed_build.is_none());
    }
}

#[test]
fn successful_new_build_clears_old_build_failure_before_activation_retry() {
    let mut f = Fixture::new();
    f.enable_rollback();
    f.fake.build_failure = true;
    assert!(f.run().is_err());
    f.next();
    f.fake.build_failure = false;
    f.fake.restart_failure = true;
    assert!(f.run().is_err());
    assert!(f.state().failed_build.is_none());
    assert!(f.state().failed.is_some());
    request_retry(&f.config, &f.path).unwrap();
    f.fake.restart_failure = false;
    f.run().unwrap();
    assert!(f.state().failed.is_none());
    assert_eq!(f.fake.builds.len(), 2);
    assert_eq!(f.state().active.unwrap().revision, "b".repeat(40));
}

#[test]
fn branch_lookup_failures_remain_retryable_without_recording_a_build_failure() {
    let mut f = Fixture::new();
    f.fake.resolve_failure = true;
    for _ in 0..3 {
        assert!(f.run().is_err());
        assert!(f.state().failed_build.is_none());
    }
    assert!(f.fake.builds.is_empty());
    f.fake.resolve_failure = false;
    f.run().unwrap();
    assert_eq!(f.fake.builds.len(), 1);
}

#[test]
fn failed_restart_keeps_pending_and_retries_without_network_or_build() {
    let mut f = Fixture::new();
    f.run().unwrap();
    f.next();
    f.fake.restart_failure = true;
    assert!(f.run().is_err());
    assert_eq!(f.state().active.unwrap().revision, "a".repeat(40));
    assert!(f.state().pending.is_some());
    assert_eq!(f.profile(), f.fake.output);
    assert_eq!(
        fs::read_dir(f.config.state_directory.join("roots"))
            .unwrap()
            .count(),
        2
    );
    f.fake.restart_failure = false;
    f.fake.resolve_failure = true;
    f.run().unwrap();
    assert!(f.state().pending.is_none());
    assert_eq!(f.state().active.unwrap().revision, "b".repeat(40));
    assert_eq!(f.fake.builds.len(), 2);
}

#[test]
fn newer_revision_supersedes_failed_activation() {
    let mut f = Fixture::new();
    f.fake.restart_failure = true;
    assert!(f.run().is_err());
    f.next();
    f.fake.restart_failure = false;
    f.run().unwrap();
    assert_eq!(f.state().active.unwrap().revision, "b".repeat(40));
}

#[test]
fn pending_transition_before_profile_switch_is_recoverable() {
    let mut f = Fixture::new();
    f.fake.restart_failure = true;
    assert!(f.run().is_err());
    fs::remove_file(f.config.state_directory.join("profile")).unwrap();
    f.fake.revision = "a".repeat(40);
    f.fake.restart_failure = false;
    f.run().unwrap();
    assert_eq!(f.profile(), f.fake.output);
    assert_eq!(f.fake.builds.len(), 1);
    assert!(f.state().pending.is_none());
}

#[test]
fn changed_package_configuration_redeploys_same_sha() {
    let mut f = Fixture::new();
    f.run().unwrap();
    f.fake.revision = "a".repeat(40);
    f.config.package = "web".into();
    fs::write(&f.path, serde_json::to_vec(&f.config).unwrap()).unwrap();
    f.run().unwrap();
    assert_eq!(f.fake.builds.len(), 2);
}

#[test]
fn infrastructure_change_during_build_prevents_activation() {
    let mut f = Fixture::new();
    let mut changed = f.config.clone();
    changed.generation = "2".into();
    f.fake.change_during_build = Some((f.path.clone(), changed));
    assert!(f.run().is_err());
    assert_eq!(f.fake.restarts, 0);
    assert!(f.state().active.is_none());
    assert!(!f.config.state_directory.join("profile").exists());
}

#[test]
fn missing_binary_does_not_switch_profile() {
    let mut f = Fixture::new();
    fs::remove_file(f.fake.output.join("bin/server")).unwrap();
    assert!(f.run().is_err());
    assert_eq!(f.fake.restarts, 0);
    assert!(f.state().pending.is_none());
}

#[test]
fn concurrent_update_is_rejected() {
    let mut f = Fixture::new();
    fs::create_dir_all(&f.config.state_directory).unwrap();
    let _guard = lock(&f.config.state_directory).unwrap();
    assert!(f.run().unwrap_err().to_string().contains("lock"));
    assert_eq!(f.fake.builds.len(), 0);
}

#[test]
fn corrupt_state_is_not_overwritten() {
    let mut f = Fixture::new();
    fs::create_dir_all(&f.config.state_directory).unwrap();
    let path = f.config.state_directory.join("state.json");
    fs::write(&path, "broken").unwrap();
    assert!(f.run().is_err());
    assert_eq!(fs::read_to_string(path).unwrap(), "broken");
}

#[test]
fn invalid_executable_is_rejected_before_effects() {
    let mut f = Fixture::new();
    f.config.executable = "../escape".into();
    assert!(f.run().is_err());
    assert!(f.fake.builds.is_empty());
}

#[test]
fn failed_activation_rolls_back_and_suppresses_repeated_polls_until_explicit_retry() {
    let mut f = Fixture::new();
    f.enable_rollback();
    f.run().unwrap();
    let previous = f.profile();
    f.next();
    f.fake.restart_results.extend([false, true]);
    assert!(f.run().is_err());
    assert_eq!(f.profile(), previous);
    assert_eq!(f.state().active.unwrap().revision, "a".repeat(40));
    assert!(f.state().pending.is_none());
    assert!(f.state().recovery.is_none());
    assert_eq!(f.state().failed.unwrap().revision, "b".repeat(40));
    assert_eq!(f.fake.stops, 1);
    assert_eq!(
        fs::read_dir(f.config.state_directory.join("roots"))
            .unwrap()
            .count(),
        2
    );
    let restarts = f.fake.restarts;
    f.run().unwrap();
    f.run().unwrap();
    assert_eq!(f.fake.restarts, restarts);
    assert_eq!(f.fake.builds.len(), 2);
    request_retry(&f.config, &f.path).unwrap();
    f.run().unwrap();
    assert_eq!(f.profile(), f.fake.output);
    assert!(f.state().failed.is_none());
    assert_eq!(f.fake.builds.len(), 2);
}

#[test]
fn first_release_failure_stops_and_deselects_package_and_retry_works_offline() {
    let mut f = Fixture::new();
    f.enable_rollback();
    f.fake.restart_results.push_back(false);
    assert!(f.run().is_err());
    assert!(f.state().active.is_none());
    assert!(f.state().pending.is_none());
    assert!(f.state().failed.is_some());
    assert!(!f.config.state_directory.join("profile").exists());
    f.fake.revision = "a".repeat(40);
    f.run().unwrap();
    assert_eq!(f.fake.restarts, 1);
    request_retry(&f.config, &f.path).unwrap();
    f.fake.resolve_failure = true;
    f.run().unwrap();
    assert!(f.state().failed.is_none());
    assert!(f.state().active.is_some());
    assert_eq!(f.fake.builds.len(), 1);
}

#[test]
fn failed_rollback_is_durable_and_recovers_without_git() {
    let mut f = Fixture::new();
    f.enable_rollback();
    f.run().unwrap();
    let previous = f.profile();
    f.next();
    f.fake.restart_failure = true;
    assert!(f.run().is_err());
    assert!(f.state().recovery.is_some());
    assert_eq!(f.profile(), previous);
    assert!(request_retry(&f.config, &f.path).is_err());
    f.fake.restart_failure = false;
    f.fake.resolve_failure = true;
    // Git lookup still reports its outage, but recovery has already completed.
    assert!(f.run().is_err());
    assert!(f.state().recovery.is_none());
    assert_eq!(f.profile(), previous);
    assert_eq!(f.fake.restarts, 4);
    assert_eq!(f.fake.builds.len(), 2);
}

#[test]
fn stopped_worker_before_rollback_switch_recovers_on_next_run() {
    let mut f = Fixture::new();
    f.enable_rollback();
    f.run().unwrap();
    let previous = f.profile();
    f.next();
    f.fake.restart_results.push_back(false);
    f.fake.stop_failure = true;
    assert!(f.run().is_err());
    assert!(f.state().recovery.is_some());
    assert_eq!(f.profile(), f.fake.output);
    f.fake.stop_failure = false;
    f.run().unwrap();
    assert_eq!(f.profile(), previous);
    assert!(f.state().recovery.is_none());
    assert_eq!(f.fake.builds.len(), 2);
}

#[test]
fn newer_commit_can_supersede_even_a_failed_rollback() {
    let mut f = Fixture::new();
    f.enable_rollback();
    f.run().unwrap();
    f.next();
    f.fake.restart_failure = true;
    assert!(f.run().is_err());
    f.fake.restart_failure = false;
    f.fake.restart_results.extend([false, true]);
    f.fake.revision = "c".repeat(40);
    f.fake.output = f._temp.path().join("package-three");
    package(&f.fake.output);
    f.run().unwrap();
    assert!(f.state().recovery.is_none());
    assert_eq!(f.state().active.unwrap().revision, "c".repeat(40));
    assert_eq!(f.profile(), f.fake.output);
}

#[test]
fn configuration_change_allows_failed_revision_again() {
    let mut f = Fixture::new();
    f.enable_rollback();
    f.fake.restart_results.push_back(false);
    assert!(f.run().is_err());
    f.config.generation = "new-config".into();
    fs::write(&f.path, serde_json::to_vec(&f.config).unwrap()).unwrap();
    f.fake.revision = "a".repeat(40);
    f.run().unwrap();
    assert_eq!(f.state().active.unwrap().configuration, f.config);
    assert_eq!(f.fake.builds.len(), 2);
}

#[test]
fn old_state_without_rollback_fields_remains_readable() {
    let mut f = Fixture::new();
    f.run().unwrap();
    let mut state = serde_json::to_value(f.state()).unwrap();
    state.as_object_mut().unwrap().remove("failed");
    state.as_object_mut().unwrap().remove("recovery");
    state.as_object_mut().unwrap().remove("failed_build");
    state["active"]["configuration"]
        .as_object_mut()
        .unwrap()
        .remove("rollback");
    fs::write(
        f.config.state_directory.join("state.json"),
        serde_json::to_vec(&state).unwrap(),
    )
    .unwrap();
    assert!(!f.state().active.unwrap().configuration.rollback);
    assert!(f.state().recovery.is_none());
    assert!(f.state().failed.is_none());
    assert!(f.state().failed_build.is_none());
}

#[test]
fn configuration_changed_during_failed_start_prevents_stale_rollback() {
    let mut f = Fixture::new();
    f.enable_rollback();
    f.run().unwrap();
    f.next();
    let mut changed = f.config.clone();
    changed.generation = "new-generation".into();
    f.fake.change_during_restart = Some((f.path.clone(), changed));
    f.fake.restart_results.push_back(false);
    assert!(f.run().is_err());
    assert_eq!(f.fake.stops, 0);
    assert!(f.state().failed.is_none());
    assert!(f.state().recovery.is_none());
    assert!(f.state().pending.is_some());
}

#[test]
fn configuration_change_supersedes_old_recovery_before_starting_any_old_service() {
    let mut f = Fixture::new();
    f.enable_rollback();
    f.run().unwrap();
    f.next();
    f.fake.restart_failure = true;
    assert!(f.run().is_err());
    assert!(f.state().recovery.is_some());
    let stops = f.fake.stops;
    f.config.generation = "new-generation".into();
    fs::write(&f.path, serde_json::to_vec(&f.config).unwrap()).unwrap();
    f.fake.restart_failure = false;
    f.run().unwrap();
    assert_eq!(f.fake.stops, stops);
    assert!(f.state().recovery.is_none());
    assert_eq!(f.state().active.unwrap().configuration, f.config);
}
