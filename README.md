# Nixploy

Deploy applications on NixOS directly from Git. Nixploy polls a branch, builds
its Nix flake package, and restarts the application when a new commit is ready.
Each application runs as a separate systemd service with its own user.

Your application repository defines how to build the app. Your NixOS
configuration defines where and how it runs.

## Quick start

Start with your existing NixOS flake and `configuration.nix`.

1. Add Nixploy to your flake's `inputs`:

   ```nix
   nixploy = {
     url = "github:nixployhq/nixploy";
     inputs.nixpkgs.follows = "nixpkgs";
   };
   ```

2. Include `nixploy` in your `outputs` arguments:
   ```nix
   outputs = { nixpkgs, nixploy, ... }: { ... };
   ```

3. Add `nixploy.nixosModules.default` to your host's `modules` list.

   ```nix
   nixosConfigurations.my-host = nixpkgs.lib.nixosSystem {
     system = "x86_64-linux";
     modules = [
       ./configuration.nix
       nixploy.nixosModules.default
     ];
   };
   ```

   Use your existing host name and platform, and keep any other modules you
   already import.

4. Define an application in `configuration.nix` or as an inline module:

   ```nix
   services.nixploy.apps.demo = {
     repository = "https://github.com/nixployhq/demo.git";
     executable = "nixploy-demo";
     environment = {
       HOST = "0.0.0.0";
       PORT = "3000";
     };
   };
   ```

5. Rebuild and switch, replacing `my-host` with your configuration name:

   ```sh
   sudo nixos-rebuild switch --flake .#my-host
   ```

Nixploy will build and start the
[demo application](https://github.com/nixployhq/demo), then check for updates
every minute. Configure your host's firewall or reverse proxy to make the
application reachable.

### Example flake.nix

Here is a complete flake putting those steps together with an inline app module.
Keep your existing `configuration.nix`, and replace `my-host` and `x86_64-linux`
with your host's configuration name and platform:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixploy = {
      url = "github:nixployhq/nixploy";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { nixpkgs, nixploy, ... }: {
    nixosConfigurations.my-host = nixpkgs.lib.nixosSystem {
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
    };
  };
}
```

For your own app, set `repository` and `executable`. The repository must commit
a `flake.lock` and expose `packages.<system>.<package>` with an `out` output
containing `bin/<executable>`. The package defaults to `default`.

For a complete infrastructure flake with a runnable NixOS VM, see
[examples/nixos](examples/nixos). It imports Nixploy from GitHub and includes
a lockfile.

## How it works

Nixploy polls the configured branch, builds the exact commit through Nix, and
restarts the app's systemd service when the package is ready. Fetch or build
failures leave the running app untouched. An unchanged commit and configuration
do not restart it.

Each app has its own service user. You can use standard NixOS configuration for
persistent data, secrets, reverse proxies, and remote builders.

For apps with an HTTP readiness route, enable startup checks and automatic
package rollback:

```nix
services.nixploy.apps.my-app = {
  repository = "https://github.com/your-org/your-app.git";
  executable = "your-app";
  endpoint.port = 3000;
  readiness.path = "/health";
};
```

The endpoint defaults `HOST` to `127.0.0.1` and `PORT` to `3000`; your app must
respect those variables. Readiness requires HTTP 200. Failed activation restores
the previous successful package when available. Rollback does not undo application
data or database migrations. See [readiness and rollback](docs/readiness.md) for
timeouts, failure handling, and retrying a rejected revision.

## Usage

For an app named `my-app`:

```sh
# Inspect the app and update schedule.
systemctl status nixploy-app-my-app.service
systemctl status nixploy-update-my-app.timer

# Read application and deployment logs.
journalctl -u nixploy-app-my-app.service
journalctl -u nixploy-update-my-app.service

# Check for an update now.
sudo systemctl start nixploy-update-my-app.service
```

The default branch is `main`, package is `default`, and poll interval is `1min`.
Set `branch`, `package`, or `pollInterval` on the app to change them. There is no
global enable switch; defining an app enables it.

## Documentation

| Guide | Covers |
| --- | --- |
| [Configuration reference](docs/configuration.md) | App options, defaults, and accepted values. |
| [Endpoints and reverse proxies](docs/endpoints.md) | Reusing endpoint URLs, Cloudflared, and environment overrides. |
| [Private repositories](docs/authentication.md) | HTTPS tokens, SSH keys, and host verification. |
| [Secret providers](docs/secrets.md) | sops-nix, agenix, runtime secrets, and rotation. |
| [Readiness and rollback](docs/readiness.md) | Startup probes, automatic rollback, and explicit retries. |
| [Operations and application state](docs/operations.md) | Service management, persistent data, and deployment state. |
| [Remote builders](docs/remote-builders.md) | Build-box configuration using `nix.buildMachines`. |

## Current limitations

Nixploy is an initial MVP:

- Deployment targets must run NixOS. Updates use polling; there are no webhooks.
- Optional HTTP(S) readiness probes gate startup and enable package rollback.
  There is no continuous health monitoring or zero-downtime rollout.
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
