# Testing

[Back to contributing](../CONTRIBUTING.md)

Run these commands from the repository root with Nix flakes enabled. Enter
`nix develop path:.` for the Rust tools, then select your host platform:

```sh
nixploy_system=$(nix eval --impure --raw --expr builtins.currentSystem)
```

## Check catalogue

Checks are exposed as `checks.<system>.<name>` in the root flake.

| Check | Environment | Coverage |
| --- | --- | --- |
| `worker` | Supported Linux or macOS | Builds the Rust package through Nix and runs its unit tests. |
| `module-interface` | Supported Linux or macOS | Evaluates options, defaults, generated units, credentials, examples, and invalid configuration. |
| `webhook` | Linux with KVM | HTTP authentication, generated and managed tokens, rotation, trigger bursts during builds, and queued requests across reboot. |
| `lifecycle` | Linux with KVM | Real services, local Git and SSH fixtures, polling, failed builds, permissions, GC roots, and recovery across reboot. |
| `https-auth` | Linux with KVM | TLS Git authentication, missing or incorrect credentials, rotation, redirect rejection, and secret leakage checks. |
| `readiness` | Linux with KVM | Delayed readiness, pending activation with rollback disabled, offline retry, redirects, timeouts, and manual restarts. |
| `rollback` | Linux with KVM | Startup grace and failure thresholds, fallback readiness, failed revision suppression across reboot, GC protection, explicit retry, and recovery without Git. |
| `remote-builder` | Linux with KVM; two VMs | Remote builds over `ssh-ng`, output transfer, deployment, readiness, rollback, reboot, and retry. |
| `secret-providers` | Linux with KVM | Actual sops-nix and agenix modules, runtime decryption, Git credentials, app environment files, permissions, and rotation. |

For a selected check:

```sh
nix build "path:.#checks.${nixploy_system}.module-interface" --no-link -L
```

The VM scenarios use local repositories and generated test credentials; they do
not require a GitHub account, real PAT, or production secrets. Building the test
VMs can require network access to fetch flake inputs and dependencies.

The remote-builder scenario disables local builds and binary substitutes. Its
fixture requires a feature available only on the builder and verifies the output
in the builder's store. The secret-provider scenario uses source-only flake inputs
for its providers; the public Nixploy module does not import or enable them.

## Full suite

```sh
nix flake check path:. -L
```

This runs the checks for the current system. On macOS it does **not** run the
Linux-only VM tests. Run those on a supported Linux host with KVM to validate
service behavior. Rust formatting and linting are separate from the flake checks:

```sh
cargo fmt --all -- --check
cargo clippy --all-targets -- -D warnings
```

## Local smoke test

On supported macOS or Linux with Nix, Git, and Python 3 available:

```sh
cargo build
python3 tests/local-smoke.py target/debug/nixploy-worker
```

Python 3 is an additional prerequisite for this script; it is not included in the
development shell. The script uses real local Git repositories, Nix builds, and
GC-root registration, with only `systemctl` substituted. It creates temporary
repositories and state directories and small outputs in the Nix store. It does
not run garbage collection, start application services, or replace VM coverage of
systemd behavior.
