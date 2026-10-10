# Readiness and rollback

[Back to Nixploy](../README.md)

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
    startPeriodSeconds = 10;
    failureThreshold = 3;
    intervalSeconds = 2;
    requestTimeoutSeconds = 5;
  };
};
```

Nixploy sends GET requests to `http://127.0.0.1:3000/health` until one completes
with the expected status. Failures from probes started during the first 10 seconds
do not count; success during this period completes readiness immediately. After
the grace period, three consecutive failed probes fail startup. The 30-second
deadline includes the grace period, requests, and retry delays and can expire
before the failure threshold is reached. These are probe attempts within one
startup, not three service restarts. To use a separate management
port or an app without an endpoint, set `readiness.url` to its full HTTP(S) URL.
Choose an address that reaches this app directly; a shared proxy could answer
for another instance. Probe URLs are non-secret configuration stored in the Nix store.

The probe runs as the app's service user through systemd's `ExecStartPost`, on
every start, including boot and automatic restarts. Deployment becomes active
only after the probe succeeds. HTTPS uses the system CA bundle and verifies
certificates; redirects are not followed and proxy environment variables are ignored.

## Rollback and retry

Build failures are tracked separately as `failed_build` in `state.json`, regardless
of the rollback setting. The same commit and configuration will not build again
until explicitly retried with `sudo nixploy app retry my-app`. A new commit or
changed configuration permits another build automatically. The error summary is
saved with the failure; full build output remains in the updater journal.

Failed readiness fails service startup. With readiness configured, automatic
rollback is enabled by default. Nixploy restores the previous successful package,
restarts it, and requires its startup checks to pass. The update command still
reports failure so the failed deployment remains visible in the journal.

The failed revision and configuration are recorded in `state.json` as `failed`.
Ordinary polls skip that combination; a newer commit or a configuration change
can deploy normally. The latest failed package remains rooted for an explicit
retry. To retry after fixing an external dependency, run:

```sh
sudo nixploy app retry my-app
```

The command queues a retry under the deployment lock and schedules the regular
updater immediately with its normal credentials. It returns after scheduling,
without waiting for deployment to finish. Follow progress with
`journalctl -fu nixploy-update-my-app.service`. It does not change which Git branch
or revision is desired.

If rollback also fails, `recovery` remains recorded and the next update attempts
recovery before fetching Git. A newer commit can supersede failed recovery. With
no previous distinct package, Nixploy stops the failed app and removes its profile
so it is not selected at the next boot. `active` records the last successful
deployment; systemd reports current service health.

Rollback restores only the package. It uses the **current** NixOS environment,
secrets, service settings, and readiness probe; it does not undo application data
or database migrations. Recovery decisions survive worker interruption and reboot.
This is restart-based recovery, not a zero-downtime rollout.

Set `rollback.enable = false;` to retain the earlier retry behavior: failed
activation stays `pending`, and subsequent updates retry it. Without readiness,
rollback defaults to disabled but can be enabled for process-start failures.

These are startup checks, not continuous health monitoring. Without `readiness`,
activation still requires only a successful process start. Changing readiness
settings changes the deployment configuration and causes activation to be retried.

See the [configuration reference](configuration.md) for all probe options and [operations](operations.md) for service logs and deployment state.
