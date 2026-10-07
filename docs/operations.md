# Operations and application state

[Back to Nixploy](../README.md)

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

## Command-line interface

Use `nixploy --help` to discover commands and append `--help` at any level:

```sh
nixploy app retry --help
nixploy deploy-hook token --help
sudo nixploy app retry my-app
sudo nixploy deploy-hook token show my-app
sudo nixploy deploy-hook token rotate my-app
```

Commands take the app name from `services.nixploy.apps`, rather than a configuration
file path. Retry schedules the updater and returns without waiting for deployment.
Token retrieval prints only the secret to stdout. See [deploy hooks](webhooks.md)
for setup and CI integration.

Systemd invokes `nixploy-worker` internally. Apply the updated NixOS configuration
to install its service definitions alongside the new CLI. The previous
`nixploy retry <config-path>`, `webhook-token`, and `rotate-webhook-token` forms
have been replaced by the commands above.

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
- Fetch and build failures leave the running release untouched. Failed activation
  triggers rollback when enabled; otherwise it remains pending for retry.
- The selected release starts again after reboot. Package roots protect active
  and pending releases, rollback targets, and the latest failed release from Nix
  garbage collection.

The update worker runs as root and uses the Nix daemon; applications run as
restricted users named `nixploy-<name>`. Only configure repositories you trust
to supply your application.

See [readiness and rollback](readiness.md) for failed deployments and explicit retry, and [secret providers](secrets.md) for runtime secret provisioning.
