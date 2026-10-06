# Development

## Demo

See [examples/nixos](examples/nixos) for a standalone infrastructure flake
that deploys the public Topcoat demo in a persistent NixOS VM. It includes
build/run instructions and guidance for adapting it to a host.

## Checks

```sh
nix develop path:.
cargo test
cargo fmt --all -- --check
cargo clippy --all-targets -- -D warnings
nix flake check path:.
nix run path:.#formatter.aarch64-darwin -- flake.nix nix/*.nix nix/modules/*.nix tests/*.nix examples/nixos/*.nix
```

The `worker` check builds the Rust package and runs its unit tests.
`module-interface` evaluates defaults, generated units, credentials, the example,
and invalid configuration. Both work on macOS without a NixOS VM. The Linux-only
`lifecycle` check exercises real services, local Git fixtures (including SSH),
timer updates, failed builds, permissions, GC protection, and pending activation
recovery across reboot. Run it on an x86_64 Linux host with KVM available:

```sh
nix build path:.#checks.x86_64-linux.lifecycle path:.#checks.x86_64-linux.https-auth -L
```

The `https-auth` check uses a local TLS Git server and runtime-generated tokens.
It covers authenticated deployment, incorrect and missing credentials, token
rotation, redirect rejection, and checks for secret leakage. It does not require
a GitHub account or a real PAT.

The `readiness` check uses a local Git repository and HTTP application. It tests
delayed startup, pending state on failure, retry without Git access, redirect
rejection, request and overall timeouts, and readiness gating on manual restarts.

```sh
nix build path:.#checks.x86_64-linux.readiness -L
```

The `rollback` check verifies the startup grace period and failure threshold,
restoration and readiness of the previous package, failed revision suppression
across reboot, GC protection, explicit retry, and recovery without Git access.
Rust tests also cover interrupted and failed rollback, first deployment failures,
configuration changes, and superseding failed recovery with a new commit.

```sh
nix build path:.#checks.x86_64-linux.rollback -L
```

The `remote-builder` check runs the rollback scenario with a separate builder VM
configured through `nix.buildMachines` over `ssh-ng`. SSH credentials are generated
inside the VMs. Local builds and binary substitutes are disabled, and the fixture
requires a feature available only on the builder. It checks remote build logs and
the output in the builder's store, then exercises deployment, readiness, rollback,
reboot, and explicit retry on the app host.

```sh
nix build path:.#checks.x86_64-linux.remote-builder -L
```

The `secret-providers` check imports pinned sops-nix and agenix modules. It
creates test identities and encrypted data inside the VM, then verifies Git
credentials, application environment files, permissions, and rotation through
both providers. Their source-only flake inputs are used for tests; the Nixploy
module does not import or enable either provider.

```sh
nix build path:.#checks.x86_64-linux.secret-providers -L
```

For a local smoke test on macOS or Linux with Git, Nix, and Python 3 available:

```sh
cargo build
python3 tests/local-smoke.py target/debug/nixploy
```

This uses real local Git repositories, Nix builds, and GC-root registration, with
only `systemctl` substituted. It never runs garbage collection or deploys an app.

The `path:.` reference includes new files before they are tracked by Git. Replace
`aarch64-darwin` in the formatting command with `x86_64-linux` or `aarch64-linux`
as needed. Once files are tracked, `nix fmt` with the same file arguments works.
