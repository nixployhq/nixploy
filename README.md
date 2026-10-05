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

## App options

Options live under `services.nixploy.apps.<name>`.

| App option | Default | Contract |
| --- | --- | --- |
| `enable` | `true` | Enable deployment and runtime units. |
| `repository` | Required | Public HTTPS URL, SSH URL, or `user@host:path`. |
| `branch` | `"main"` | Branch name relative to `refs/heads/`. |
| `package` | `"default"` | Name under `packages.<host-system>`, not a full attribute path. |
| `executable` | Required | Binary name in the package's `bin/`, not a path or command. |
| `pollInterval` | `"1min"` | Delay after an attempt completes; positive integer with `s`, `min`, `h`, or `d`. |
| `git.privateKeyFile` | `null` | Existing SSH private key, as an absolute string path. |
| `git.knownHostsFile` | `null` | Existing known-hosts file, as an absolute string path; required for enabled SSH apps. |
| `environment` | `{}` | Non-secret environment variables with string values. |

An empty app set is the default. There is no global enable option. App names
start with a letter or digit and contain only letters, digits, `_`, or `-`.
Package names allow letters, digits, `_`, `+`, and `-`; executable names also
allow dots, except `.` and `..`.

## Private repositories

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

See [examples/configuration.nix](examples/configuration.nix) for a configuration
with explicit defaults.

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
- Successful activation means the process started. There are no application
  health checks or automatic rollback.
- Repository authentication supports public HTTPS and SSH. HTTPS tokens and
  credential helpers are outside the current interface.
- Git submodules and Git LFS are not fetched. Missing or inconsistent lockfiles
  fail deployment.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for development commands, tests, and the
local demo VM.

## License

[MIT](LICENSE).
