# Deploy hooks

[Back to Nixploy](../README.md)

Webhooks let CI or another trusted caller ask Nixploy to check for an update now.
They use a generic authenticated HTTP POST; no Git provider integration or payload
is required. Polling remains enabled as a fallback.

## Enable a trigger

```nix
services.nixploy.apps.my-app = {
  repository = "https://github.com/your-org/your-app.git";
  executable = "your-app";
  webhook.enable = true;
};
```

After switching your NixOS configuration, the shared receiver listens on
`127.0.0.1:9070`. The app's route is `POST /hooks/my-app`. To change the receiver's
address or port, configure `services.nixploy.webhook.listenAddress` or `.port`.
These settings are separate from the application's `endpoint`.

Nixploy generates a random 256-bit token for the app on the host. It persists at
`/var/lib/nixploy-webhooks/tokens/my-app.token`, readable only by root. It is reused
across receiver restarts, rebuilds, and host reboots and never enters the Nix store.
The receiver runs as a separate unprivileged user and receives a copy through
systemd credentials.

Retrieve the token as root and save it as a masked secret in your CI provider:

```sh
sudo nixploy deploy-hook token show my-app
```

This command intentionally prints the token. Do not put its output in logs, Git,
or a Nix expression. The webhook token authorizes a deployment trigger; it does
not replace your repository's deploy key or HTTPS access token.

## Expose the receiver

Use your own HTTPS reverse proxy or tunnel to expose the receiver to CI. For
example, add an ingress to an existing Cloudflared tunnel:

```nix
services.cloudflared.tunnels."your-tunnel-id".ingress."deploy.example.com" =
  "http://127.0.0.1:9070";
```

Configure the tunnel's credentials and other required settings separately.
Nixploy does not configure TLS, DNS, or firewall rules. Keep the receiver on
loopback when the proxy runs on the same host; bearer tokens must travel over
HTTPS when sent across the network.

## Call it from CI

Run this after your CI checks pass, with `NIXPLOY_TOKEN` supplied by the CI secret
store. Sending the header through standard input keeps the token out of curl's
command-line arguments:

```sh
printf 'Authorization: Bearer %s\n' "$NIXPLOY_TOKEN" |
  curl --fail-with-body --request POST \
    --header @- \
    https://deploy.example.com/hooks/my-app
```

Do not enable shell tracing for commands that handle the token. The endpoint takes
an empty body. The repository, branch, package, and executable remain defined in
Nix; callers cannot select a commit or supply deployment commands.

A GitHub Actions step can use the same generic endpoint without a GitHub webhook
or GitHub App:

```yaml
- name: Request deployment
  env:
    NIXPLOY_TOKEN: ${{ secrets.NIXPLOY_TOKEN }}
  run: |
    printf 'Authorization: Bearer %s\n' "$NIXPLOY_TOKEN" |
      curl --fail-with-body --request POST \
        --header @- \
        https://deploy.example.com/hooks/my-app
```

Run the step only in a trusted workflow for the deployment branch, after the
commit has been pushed and checks have succeeded. Nixploy resolves the configured
branch when processing the request, so it may deploy a newer commit than the one
that caused CI to send the request.

## Responses and delivery behavior

| Status | Meaning |
| --- | --- |
| `202 Accepted` | An update request was persisted; deployment has not necessarily started or succeeded. |
| `401 Unauthorized` | Missing or incorrect bearer token. |
| `404 Not Found` | No enabled webhook for this route/app. |
| `405 Method Not Allowed` | Use POST. |
| `413 Payload Too Large` | Send no request body. |
| `503 Service Unavailable` | The receiver could not persist the request. |

Requests coalesce into one pending marker per app. Systemd consumes the marker
before starting the existing updater. A request received during an update leaves
a marker for a follow-up, so a push during a build is not lost. Queued markers
survive receiver and host restarts. This is not a delivery history or a guarantee
that each request starts its own build: updates always check the latest configured
branch. Polling also covers interrupted updates and missed requests.

A webhook does not override failed-revision suppression. Use the
[explicit retry command](readiness.md#rollback-and-retry) to retry a rejected
revision with the same configuration.

## Rotate or provide a token

For a generated token:

```sh
sudo nixploy deploy-hook token rotate my-app
sudo nixploy deploy-hook token show my-app
```

Rotation atomically replaces the token and restarts the shared receiver to reload
credentials. Update the CI secret afterward; the old token no longer authenticates
new requests. There is no overlap period. Already accepted requests remain queued.
Application services are not restarted by token rotation.

To manage the token through sops-nix, agenix, or another secret provider:

```nix
services.nixploy.apps.my-app.webhook = {
  enable = true;
  tokenFile = config.sops.secrets.my-app-webhook-token.path;
};
```

The file must contain 32 to 256 printable non-whitespace ASCII characters on one
line; a trailing newline is allowed. Use a randomly generated secret. Nixploy
does not generate, display, or rotate externally managed tokens. Restart
`nixploy-webhooks.service` after replacing the file. For sops-nix, you can set the
secret's `restartUnits = [ "nixploy-webhooks.service" ];`.

Provision the file before the receiver starts. See [Secret providers](secrets.md)
for ordering and runtime file configuration. Disabling an app's webhook removes
its route but retains generated token and queue files on disk.

## Inspect delivery and deployment

```sh
systemctl status nixploy-webhooks.service
systemctl status nixploy-webhook-my-app.path
journalctl -u nixploy-webhooks.service
journalctl -u nixploy-update-my-app.service
```

If a path unit hits systemd's trigger rate limit after repeated startup errors,
fix the cause and restart `nixploy-webhook-my-app.path`. Polling remains active.
Tokens and authorization headers are not logged by the receiver.
