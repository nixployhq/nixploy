# Nixploy

Deploy applications on NixOS directly from Git. Nixploy polls a branch, builds
its Nix flake package, and restarts the application when a new commit is ready.
Each application runs as a separate systemd service with its own user.

Your application repository defines how to build the app. Your NixOS
configuration defines where and how it runs.

## Quick start

Add Nixploy to your NixOS flake inputs:

```nix
inputs.nixploy.url = "github:nixployhq/nixploy";
```

Include `nixploy` in your flake's `outputs` arguments, then add its module and
an application to your host's `modules` list:

```nix
nixpkgs.lib.nixosSystem {
  system = "x86_64-linux";
  modules = [
    ./configuration.nix
    nixploy.nixosModules.default
    {
      services.nixploy.apps.demo = {
        repository = "https://github.com/nixployhq/demo.git";
        executable = "nixploy-demo";
        environment = {
          HOST = "0.0.0.0";
          PORT = "3000";
        };
      };
    }
  ];
}
```

Rebuild and switch your NixOS configuration. Nixploy will build and start the
[demo application](https://github.com/nixployhq/demo), then check for updates
every minute. Configure your host's firewall or reverse proxy to make the
application reachable.

For your own app, set `repository` and `executable`. The repository must commit
a `flake.lock` and expose `packages.<system>.<package>` with an `out` output
containing `bin/<executable>`. The package defaults to `default`.

For a complete infrastructure flake with a runnable NixOS VM, see
[examples/nixos](examples/nixos). It imports Nixploy from GitHub and includes
a lockfile.

## App options

Options live under `services.nixploy.apps.<name>`.

| App option | Default | Contract |
| --- | --- | --- |
| `enable` | `true` | Enable deployment and runtime units. |
| `repository` | Required | HTTPS URL, SSH URL, or `user@host:path`. |
| `branch` | `"main"` | Branch name relative to `refs/heads/`. |
| `package` | `"default"` | Name under `packages.<host-system>`, not a full attribute path. |
| `executable` | Required | Binary name in the package's `bin/`, not a path or command. |
| `pollInterval` | `"1min"` | Delay after an attempt completes; positive integer with `s`, `min`, `h`, or `d`. |
| `git.https.username` | `null` | HTTPS username expected by your Git provider; required with `tokenFile`. |
| `git.https.tokenFile` | `null` | Absolute string path to a file containing an HTTPS access token. |
| `git.privateKeyFile` | `null` | Existing SSH private key, as an absolute string path. |
| `git.knownHostsFile` | `null` | Existing known-hosts file, as an absolute string path; required for enabled SSH apps. |
| `endpoint` | `null` | Optional HTTP(S) endpoint; requires a port and supplies default `HOST` and `PORT` environment variables. |
| `endpoint.scheme` | `"http"` | `"http"` or `"https"`. |
| `endpoint.host` | `"127.0.0.1"` | Connectable hostname or IP; IPv6 without brackets. |
| `endpoint.port` | Required when set | Integer from 1 to 65535. |
| `endpoint.url` | Derived, read-only | URL built from the endpoint scheme, host, and port. |
| `environment` | `{}` without an endpoint | Non-secret environment variables with string values; explicit values override endpoint defaults. |
| `readiness` | `null` | Optional HTTP(S) startup probe. |
| `readiness.path` | `"/"` | Path appended to the endpoint URL. |
| `readiness.url` | Endpoint URL + path | Explicit probe URL; required without an endpoint. Overrides `path`. |
| `readiness.expectedStatus` | `200` | Exact HTTP status required, from 100 to 599. |
| `readiness.timeoutSeconds` | `30` | Total readiness deadline, from 1 to 120 seconds. |
| `readiness.intervalSeconds` | `1` | Delay between failed attempts, from 1 to 60 seconds. |
| `readiness.requestTimeoutSeconds` | `5` | Per-request timeout, from 1 to 30 seconds, bounded by the total deadline. |

An empty app set is the default. There is no global enable option. App names
start with a letter or digit and contain only letters, digits, `_`, or `-`.
Package names allow letters, digits, `_`, `+`, and `-`; executable names also
allow dots, except `.` and `..`.

## Endpoint references

Declare an endpoint once and reuse its URL in other NixOS modules:

```nix
{ config, ... }:
{
  services.nixploy.apps.my-app = {
    repository = "https://github.com/your-org/your-app.git";
    executable = "your-app";
    endpoint = {
      host = "127.0.0.1";
      port = 3000;
    };
  };

  # Add to an existing cloudflared tunnel configuration:
  services.cloudflared.tunnels."your-tunnel-id".ingress."foo.example.com" =
    config.services.nixploy.apps.my-app.endpoint.url;
}
```

The derived URL is `http://127.0.0.1:3000`. An IPv6 host such as `::1` produces
`http://[::1]:3000`. Configure the tunnel's credentials and other required settings
through the [NixOS cloudflared module](https://github.com/NixOS/nixpkgs/blob/nixos-unstable/nixos/modules/services/networking/cloudflared.nix).

Setting an endpoint supplies `HOST` and `PORT` to the application (in this example,
`127.0.0.1` and `3000`). The application must respect those environment variables;
configure apps that use different settings explicitly. Without an endpoint,
Nixploy adds neither variable.

Explicit `environment.HOST` and `environment.PORT` values override these defaults.
For example, set `environment.HOST = "0.0.0.0";` to listen on all interfaces while
keeping the endpoint host at `127.0.0.1` for a local proxy. Overrides do not change
the derived URL, so keep it consistent with where the application is reachable.

The endpoint does not configure TLS, open firewall ports, install a proxy, or enable
readiness checks. Endpoint changes that alter the application's environment trigger a
deployment on the next update. URL changes also trigger deployment when used by
a readiness probe; otherwise the URL is only an output for consumers.

## Readiness checks

Opt into an HTTP(S) startup probe for an app that exposes a readiness route:

```nix
services.nixploy.apps.my-app = {
  repository = "https://github.com/your-org/your-app.git";
  executable = "your-app";
  endpoint.port = 3000;
  readiness = {
    path = "/health";
    expectedStatus = 200;
    timeoutSeconds = 30;
    intervalSeconds = 1;
    requestTimeoutSeconds = 5;
  };
};
```

Nixploy sends GET requests to `http://127.0.0.1:3000/health` until one completes
with the expected status or the deadline expires. To use a separate management
port or an app without an endpoint, set `readiness.url` to its full HTTP(S) URL.
Choose an address that reaches this app directly; a shared proxy could answer
for another instance. Probe URLs are non-secret configuration stored in the Nix store.

The probe runs as the app's service user through systemd's `ExecStartPost`, on
every start, including boot and automatic restarts. Deployment becomes active
only after the probe succeeds. HTTPS uses the system CA bundle and verifies
certificates; redirects are not followed and proxy environment variables are ignored.

A timeout fails service startup and systemd stops the new process. The deployment
stays pending, with the previous successful release retained in state and as a GC
root. **The previous release is not restarted automatically:** the profile still
selects the new release. Systemd may retry the service under its restart policy;
the next deployment update retries pending activation and records success once
ready. This does not provide rollback or zero-downtime deployment.

These are startup checks, not continuous health monitoring. Without `readiness`,
activation still requires only a successful process start. Changing readiness
settings changes the deployment configuration and causes activation to be retried.

## Private repositories

### HTTPS tokens

Use an access token with permission to read the repository:

```nix
services.nixploy.apps.my-app = {
  repository = "https://github.com/your-org/your-app.git";
  executable = "your-app";
  git.https = {
    username = "your-git-username";
    tokenFile = "/run/secrets/my-app-git-token";
  };
};
```

These options are provider-independent. Set the username required by your Git
provider and provision the token file separately, for example with sops-nix or
agenix. The file must contain only the token on a single line; a trailing newline
is allowed. Use a quoted absolute path string so its contents stay out of the
Nix store. Both `username` and `tokenFile` are required.

Nixploy loads the file through systemd credentials for each update and supplies
the token as the HTTPS password through a repository-scoped Git credential
helper. Tokens are not put in repository URLs, command arguments, environment
variables, or deployment state. Replacing the file rotates the token on the next
update; automatic token issuance and renewal are not provided.

Authenticated HTTPS URLs must not contain embedded credentials, a query, or a
fragment. Redirects are disabled: use the repository’s canonical clone URL. HTTPS
token settings cannot be combined with SSH credential settings. These credentials
authenticate the app repository, not its private flake inputs.

### SSH keys

For an SSH repository, provide a known-hosts file and, when needed, a private key:

```nix
services.nixploy.apps.my-app = {
  repository = "git@github.com:your-org/your-app.git";
  executable = "your-app";
  git = {
    privateKeyFile = "/run/secrets/app-deploy-key";
    knownHostsFile = "/etc/ssh/ssh_known_hosts";
  };
};
```

Provision these files separately. Use absolute path **strings**, as above, to
keep secret contents out of the Nix store. Nixploy loads SSH credentials through
systemd and enforces host verification. If `privateKeyFile` is null, SSH
credentials must already be available to the worker. These settings authenticate
the application repository; private flake inputs need separate authentication.

See [examples/nixos/configuration.nix](examples/nixos/configuration.nix) for a configuration
with explicit defaults.

## Secret providers

Nixploy works with sops-nix, agenix, and other tools that provision runtime files.
Pass the provider’s decrypted path to the credential option, for example:

```nix
git.https.tokenFile = config.sops.secrets.git-token.path;
# Or: config.age.secrets.git-token.path
```

See [Secret providers](docs/secrets.md) for complete configuration snippets,
application secrets, startup ordering, and rotation.

## Application data and secrets

Use standard NixOS systemd options to provide writable storage and runtime secrets:

```nix
systemd.services.nixploy-app-my-app.serviceConfig = {
  StateDirectory = "my-app";
  WorkingDirectory = "/var/lib/my-app";
  EnvironmentFile = "/run/secrets/my-app-env";
};
```

Applications run with `ProtectSystem=strict`; use a separate `StateDirectory`
for writable data. Keep secrets out of the `environment` option, whose values
are stored in the Nix store. The host configuration manages secret provisioning,
network access, and reverse proxies.

## Deployment behavior

- The timer first runs 30 seconds after boot, then waits `pollInterval` after
  each completed attempt. Each build uses an exact Git commit.
- Unchanged commits do not restart the app. Changes to its Nixploy configuration
  can trigger deployment of the same commit with the new settings.
- Fetch and build failures leave the running release untouched. Failed
  activation remains pending for retry; a newer commit can supersede it.
- The selected release starts again after reboot. Package roots protect active
  and pending releases from Nix garbage collection.

The update worker runs as root and uses the Nix daemon; applications run as
restricted users named `nixploy-<name>`. Only configure repositories you trust
to supply your application.

For remote builds, configure `nix.distributedBuilds` and `nix.buildMachines` on
the host, including persistent credentials for the Nix daemon. Nixploy uses
Nix's standard build mechanism. Remote-builder integration is not yet covered
by the integration test suite.

## Operations

For an app named `my-app`:

```sh
systemctl status nixploy-app-my-app.service
systemctl status nixploy-update-my-app.timer
journalctl -u nixploy-update-my-app.service
sudo systemctl start nixploy-update-my-app.service
```

Deployment state and package roots live in `/var/lib/nixploy/<name>`. Disabling
or removing an app retains this directory. Once its units are stopped, remove
the directory to release its package roots; Nix garbage collection can then
reclaim unreferenced outputs. Keep application data in its own directory.

## Current limitations

Nixploy is an initial MVP:

- Deployment targets must run NixOS. Updates use polling; there are no webhooks.
- Optional HTTP(S) readiness probes gate startup. There is no continuous health
  monitoring, automatic rollback, or zero-downtime rollout.
- Repository authentication supports HTTPS tokens and SSH keys. Provider-specific
  token generation (such as GitHub Apps) and arbitrary credential helpers are
  not configured by this interface.
- Git submodules and Git LFS are not fetched. Missing or inconsistent lockfiles
  fail deployment.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for development commands, tests, and the
local demo VM.

## License

[MIT](LICENSE).
