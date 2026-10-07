//! A provider-independent trigger. It can only create per-app request markers;
//! systemd starts the existing privileged updater with its usual credentials.
use anyhow::{Context, Result, ensure};
use axum::{
    Router,
    body::Bytes,
    extract::{DefaultBodyLimit, Path as RoutePath, State},
    http::{HeaderMap, StatusCode},
    routing::post,
};
use serde::Deserialize;
use sha2::{Digest, Sha256};
use std::{
    collections::BTreeMap,
    fs::{self, File},
    io::{Read, Write},
    net::IpAddr,
    os::unix::fs::PermissionsExt,
    path::{Path, PathBuf},
    sync::Arc,
    time::Duration,
};
use subtle::ConstantTimeEq;

const CONFIG: &str = "/etc/nixploy-webhooks.json";
const MAX_TOKEN: usize = 256;

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Settings {
    pub listen_address: IpAddr,
    pub port: u16,
    pub token_directory: PathBuf,
    pub queue_directory: PathBuf,
    pub apps: BTreeMap<String, App>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct App {
    pub token_file: Option<PathBuf>,
}

impl Settings {
    fn load(path: &Path) -> Result<Self> {
        let settings: Self = serde_json::from_slice(&fs::read(path)?)?;
        settings.validate()?;
        Ok(settings)
    }

    fn validate(&self) -> Result<()> {
        ensure!(self.port > 0, "invalid webhook port");
        ensure!(
            self.token_directory.is_absolute() && self.queue_directory.is_absolute(),
            "webhook directories must be absolute"
        );
        for (name, app) in &self.apps {
            ensure!(
                !name.is_empty()
                    && name.as_bytes()[0].is_ascii_alphanumeric()
                    && name
                        .bytes()
                        .all(|c| c.is_ascii_alphanumeric() || b"_-".contains(&c)),
                "invalid webhook app name"
            );
            ensure!(
                app.token_file.as_ref().is_none_or(|p| p.is_absolute()),
                "tokenFile must be absolute"
            );
        }
        Ok(())
    }

    fn generated_path(&self, app: &str) -> Result<PathBuf> {
        let entry = self
            .apps
            .get(app)
            .context("webhook is not enabled for this app")?;
        ensure!(
            entry.token_file.is_none(),
            "this app uses tokenFile; manage its token through your secret provider"
        );
        Ok(self.token_directory.join(format!("{app}.token")))
    }
}

fn read_token(path: &Path) -> Result<Vec<u8>> {
    let mut bytes = Vec::new();
    File::open(path)?
        .take((MAX_TOKEN + 3) as u64)
        .read_to_end(&mut bytes)?;
    if bytes.ends_with(b"\n") {
        bytes.pop();
        if bytes.ends_with(b"\r") {
            bytes.pop();
        }
    }
    ensure!(
        (32..=MAX_TOKEN).contains(&bytes.len()) && bytes.iter().all(|c| (33..=126).contains(c)),
        "webhook token must contain 32 to 256 printable non-whitespace ASCII characters on one line"
    );
    Ok(bytes)
}

fn write_token(path: &Path) -> Result<()> {
    let mut random = [0u8; 32];
    File::open("/dev/urandom")?.read_exact(&mut random)?;
    let token: String = random.iter().map(|byte| format!("{byte:02x}")).collect();
    let directory = path.parent().context("missing token directory")?;
    let mut file = tempfile::NamedTempFile::new_in(directory)?;
    file.as_file()
        .set_permissions(fs::Permissions::from_mode(0o600))?;
    writeln!(file, "{token}")?;
    file.as_file().sync_all()?;
    file.persist(path)?;
    File::open(directory)?.sync_all()?;
    Ok(())
}

fn initialize(settings: &Settings) -> Result<()> {
    fs::create_dir_all(&settings.token_directory)?;
    fs::set_permissions(&settings.token_directory, fs::Permissions::from_mode(0o700))?;
    let _lock = crate::lock(&settings.token_directory)?;
    for (app, entry) in &settings.apps {
        if entry.token_file.is_none() {
            let path = settings.generated_path(app)?;
            match fs::symlink_metadata(&path) {
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => write_token(&path)?,
                Err(error) => return Err(error.into()),
                Ok(meta) => {
                    ensure!(
                        meta.is_file() && meta.permissions().mode() & 0o077 == 0,
                        "generated webhook token must be a private regular file"
                    );
                    read_token(&path)?;
                }
            }
        }
    }
    Ok(())
}

struct Receiver {
    tokens: BTreeMap<String, [u8; 32]>,
    queue_directory: PathBuf,
}

// Fixed-size digests keep comparisons constant-time regardless of token length.
fn token_digest(token: &[u8]) -> [u8; 32] {
    Sha256::digest(token).into()
}

fn enqueue(directory: &Path, app: &str) -> Result<()> {
    let file = tempfile::NamedTempFile::new_in(directory)?;
    file.as_file().sync_all()?;
    file.persist(directory.join(app))?;
    File::open(directory)?.sync_all()?;
    Ok(())
}

async fn trigger(
    State(receiver): State<Arc<Receiver>>,
    RoutePath(app): RoutePath<String>,
    headers: HeaderMap,
    _body: Bytes,
) -> StatusCode {
    let Some(expected) = receiver.tokens.get(&app) else {
        return StatusCode::NOT_FOUND;
    };
    let mut authorization = headers.get_all(axum::http::header::AUTHORIZATION).iter();
    let token = authorization
        .next()
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.split_once(' '))
        .filter(|(scheme, _)| scheme.eq_ignore_ascii_case("Bearer"))
        .map(|(_, token)| token);
    let Some(token) = token.filter(|value| value.len() <= MAX_TOKEN) else {
        return StatusCode::UNAUTHORIZED;
    };
    if authorization.next().is_some()
        || !bool::from(expected.ct_eq(&token_digest(token.as_bytes())))
    {
        return StatusCode::UNAUTHORIZED;
    }
    // Paths come only from the validated configuration map, never the payload.
    let result =
        tokio::task::spawn_blocking(move || enqueue(&receiver.queue_directory, &app)).await;
    match result {
        Ok(Ok(())) => StatusCode::ACCEPTED,
        _ => {
            eprintln!("unable to persist webhook trigger");
            StatusCode::SERVICE_UNAVAILABLE
        }
    }
}

fn router(receiver: Receiver) -> Router {
    Router::new()
        .route("/hooks/{app}", post(trigger))
        .layer(DefaultBodyLimit::max(0))
        .with_state(Arc::new(receiver))
}

async fn serve(settings: Settings) -> Result<()> {
    let credentials = PathBuf::from(
        std::env::var_os("CREDENTIALS_DIRECTORY").context("missing systemd credentials")?,
    );
    let mut tokens = BTreeMap::new();
    for app in settings.apps.keys() {
        tokens.insert(
            app.clone(),
            token_digest(&read_token(&credentials.join(app))?),
        );
    }
    let listener = tokio::net::TcpListener::bind((settings.listen_address, settings.port)).await?;
    let app = router(Receiver {
        tokens,
        queue_directory: settings.queue_directory,
    });
    let slots = Arc::new(tokio::sync::Semaphore::new(64));
    loop {
        let (stream, _) = listener.accept().await?;
        let Ok(permit) = slots.clone().try_acquire_owned() else {
            drop(stream);
            continue;
        };
        let service = hyper_util::service::TowerToHyperService::new(app.clone());
        tokio::spawn(async move {
            let _permit = permit;
            // Bound slow headers/bodies and disable keep-alive. A reverse proxy
            // supplies HTTPS; the receiver defaults to loopback only.
            let mut http = hyper::server::conn::http1::Builder::new();
            http.keep_alive(false).max_buf_size(16 * 1024);
            let connection = http.serve_connection(hyper_util::rt::TokioIo::new(stream), service);
            let _ = tokio::time::timeout(Duration::from_secs(10), connection).await;
        });
    }
}

/// Initialize generated tokens before systemd loads receiver credentials.
pub fn initialize_from_file(path: &Path) -> Result<()> {
    require_root()?;
    initialize(&Settings::load(path)?)
}

/// Run the unprivileged receiver with credentials supplied by systemd.
pub fn serve_from_file(path: &Path) -> Result<()> {
    let settings = Settings::load(path)?;
    tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .enable_all()
        .build()?
        .block_on(serve(settings))
}

fn require_root() -> Result<()> {
    // SAFETY: geteuid takes no arguments and has no memory preconditions.
    ensure!(
        unsafe { libc::geteuid() } == 0,
        "webhook token management requires root"
    );
    Ok(())
}

/// Print only the requested token to stdout for use with pipes and secret stores.
pub fn show_token(app: &str) -> Result<()> {
    require_root()?;
    let settings = Settings::load(Path::new(CONFIG))?;
    let path = settings.generated_path(app)?;
    let _lock = crate::lock(&settings.token_directory)?;
    println!("{}", String::from_utf8(read_token(&path)?)?);
    Ok(())
}

/// Replace a generated token and reload the receiver's credential snapshot.
pub fn rotate_token(app: &str) -> Result<()> {
    require_root()?;
    let settings = Settings::load(Path::new(CONFIG))?;
    let path = settings.generated_path(app)?;
    let lock = crate::lock(&settings.token_directory)?;
    write_token(&path)?;
    // Initialization takes the same lock: release it before restart.
    drop(lock);
    crate::command::run(
        std::process::Command::new("systemctl").args(["restart", "nixploy-webhooks.service"]),
        Duration::from_secs(30),
    ).context("token rotated, but receiver restart failed; restart nixploy-webhooks.service before using it")?;
    eprintln!("Token rotated. Update your CI secret with: nixploy deploy-hook token show {app}");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::{body::Body, http::Request};
    use tower::ServiceExt;

    const TOKEN: &str = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

    #[tokio::test]
    async fn authentication_is_scoped_and_requests_coalesce() {
        let directory = tempfile::tempdir().unwrap();
        let receiver = router(Receiver {
            tokens: [
                ("demo".into(), token_digest(TOKEN.as_bytes())),
                ("other".into(), token_digest(b"a different token")),
            ]
            .into(),
            queue_directory: directory.path().into(),
        });
        for (path, method, auth, body, status) in [
            ("/hooks/demo", "POST", "", "", StatusCode::UNAUTHORIZED),
            (
                "/hooks/demo",
                "POST",
                "Bearer wrong",
                "",
                StatusCode::UNAUTHORIZED,
            ),
            (
                "/hooks/missing",
                "POST",
                &format!("Bearer {TOKEN}"),
                "",
                StatusCode::NOT_FOUND,
            ),
            (
                "/hooks/other",
                "POST",
                &format!("Bearer {TOKEN}"),
                "",
                StatusCode::UNAUTHORIZED,
            ),
            (
                "/hooks/demo",
                "GET",
                &format!("Bearer {TOKEN}"),
                "",
                StatusCode::METHOD_NOT_ALLOWED,
            ),
            (
                "/hooks/demo",
                "POST",
                &format!("Bearer {TOKEN}"),
                "payload",
                StatusCode::PAYLOAD_TOO_LARGE,
            ),
        ] {
            let request = Request::builder()
                .method(method)
                .uri(path)
                .header("Authorization", auth)
                .body(Body::from(body))
                .unwrap();
            assert_eq!(
                receiver.clone().oneshot(request).await.unwrap().status(),
                status
            );
            assert_eq!(fs::read_dir(directory.path()).unwrap().count(), 0);
        }
        for _ in 0..3 {
            let request = Request::post("/hooks/demo")
                .header("Authorization", format!("Bearer {TOKEN}"))
                .body(Body::empty())
                .unwrap();
            assert_eq!(
                receiver.clone().oneshot(request).await.unwrap().status(),
                StatusCode::ACCEPTED
            );
        }
        assert_eq!(fs::read_dir(directory.path()).unwrap().count(), 1);
        // Simulate updater consumption, then a trigger during its build.
        fs::remove_file(directory.path().join("demo")).unwrap();
        let request = Request::post("/hooks/demo")
            .header("Authorization", format!("Bearer {TOKEN}"))
            .body(Body::empty())
            .unwrap();
        assert_eq!(
            receiver.oneshot(request).await.unwrap().status(),
            StatusCode::ACCEPTED
        );
        assert!(directory.path().join("demo").exists());
    }

    #[test]
    fn tokens_persist_rotate_and_managed_files_are_untouched() {
        let directory = tempfile::tempdir().unwrap();
        let managed = directory.path().join("managed");
        fs::write(&managed, TOKEN).unwrap();
        let settings = Settings {
            listen_address: "127.0.0.1".parse().unwrap(),
            port: 9000,
            token_directory: directory.path().join("tokens"),
            queue_directory: directory.path().join("queue"),
            apps: [
                ("demo".into(), App { token_file: None }),
                (
                    "managed".into(),
                    App {
                        token_file: Some(managed.clone()),
                    },
                ),
            ]
            .into(),
        };
        settings.validate().unwrap();
        initialize(&settings).unwrap();
        let path = settings.generated_path("demo").unwrap();
        let token = read_token(&path).unwrap();
        assert_eq!(token.len(), 64);
        assert_eq!(
            fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o600
        );
        initialize(&settings).unwrap();
        assert_eq!(read_token(&path).unwrap(), token);
        write_token(&path).unwrap();
        assert_ne!(read_token(&path).unwrap(), token);
        assert!(settings.generated_path("managed").is_err());
        assert_eq!(fs::read_to_string(managed).unwrap(), TOKEN);
    }

    #[test]
    fn invalid_tokens_fail_closed() {
        let file = tempfile::NamedTempFile::new().unwrap();
        for bytes in [
            b"".as_slice(),
            b"short",
            b"two\nlines",
            &[b'a'; MAX_TOKEN + 1],
        ] {
            fs::write(file.path(), bytes).unwrap();
            assert!(read_token(file.path()).is_err());
        }
        fs::write(file.path(), format!("{TOKEN}\r\n")).unwrap();
        assert_eq!(read_token(file.path()).unwrap(), TOKEN.as_bytes());
    }

    #[tokio::test]
    async fn ambiguous_auth_and_unwritable_queue_are_not_accepted() {
        let directory = tempfile::tempdir().unwrap();
        let app = router(Receiver {
            tokens: [("demo".into(), token_digest(TOKEN.as_bytes()))].into(),
            queue_directory: directory.path().join("missing"),
        });
        let request = Request::post("/hooks/demo")
            .header("Authorization", format!("Bearer {TOKEN}"))
            .header("Authorization", format!("Bearer {TOKEN}"))
            .body(Body::empty())
            .unwrap();
        assert_eq!(
            app.clone().oneshot(request).await.unwrap().status(),
            StatusCode::UNAUTHORIZED
        );
        let request = Request::post("/hooks/demo")
            .header("Authorization", format!("Bearer {TOKEN}"))
            .body(Body::empty())
            .unwrap();
        assert_eq!(
            app.oneshot(request).await.unwrap().status(),
            StatusCode::SERVICE_UNAVAILABLE
        );
    }
}
