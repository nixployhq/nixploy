# Configuration reference

[Back to Nixploy](../README.md)

Options live under `services.nixploy.apps.<name>`.

| App option | Default | Contract |
| --- | --- | --- |
| `enable` | `true` | Enable deployment and runtime units. |
| `repository` | Required | HTTPS URL, SSH URL, or `user@host:path`. |
| `branch` | `"main"` | Branch name relative to `refs/heads/`. |
| `package` | `"default"` | Name under `packages.<host-system>`, not a full attribute path. |
| `executable` | Required | Binary name in the package's `bin/`, not a path or command. |
| `pollInterval` | `"1min"` | Delay after an attempt completes; positive integer with `s`, `min`, `h`, or `d`. |
| `webhook.enable` | `false` | Enable authenticated `POST /hooks/<name>` triggers. Polling remains enabled. |
| `webhook.tokenFile` | `null` | Runtime token file; null generates a persistent token on the host. |
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
| `readiness.startPeriodSeconds` | `10` | Startup grace period, from 0 to 119 seconds; must be shorter than the total deadline. |
| `readiness.failureThreshold` | `3` | Failed probes after the grace period that fail startup, from 1 to 100. |
| `readiness.intervalSeconds` | `2` | Delay between failed attempts, from 1 to 60 seconds. |
| `readiness.requestTimeoutSeconds` | `5` | Per-request timeout, from 1 to 30 seconds, bounded by the total deadline. |
| `rollback.enable` | Enabled with readiness | Restore the last successful package after failed activation and suppress repeated attempts of the failed revision/configuration. |

An empty app set is the default. There is no global enable option. App names
start with a letter or digit and contain only letters, digits, `_`, or `-`.
Package names allow letters, digits, `_`, `+`, and `-`; executable names also
allow dots, except `.` and `..`.

See [endpoints](endpoints.md), [repository authentication](authentication.md), and [readiness and rollback](readiness.md) for usage examples.

Shared receiver options live under `services.nixploy.webhook`: `listenAddress`
defaults to `"127.0.0.1"` and `port` to `9070`. The receiver starts when at least
one enabled app enables its webhook. See [Webhook triggers](webhooks.md) for
token management, HTTPS exposure, and CI examples.
