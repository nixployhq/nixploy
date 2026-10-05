# Development

## Demo

The public [Topcoat demo](https://github.com/nixployhq/demo) is a small app whose
home page displays its deployed Git revision. To run it in a long-lived NixOS VM
on an x86_64 Linux machine with KVM:

```sh
nix build --impure --out-link demo-vm --expr 'import ./examples/demo-vm.nix {
  repository = "https://github.com/nixployhq/demo.git";
}'
mkdir -p demo-state
cd demo-state
../demo-vm/bin/run-nixploy-demo-vm
```

Open http://127.0.0.1:8080 after the initial build. The VM polls `main` every
15 seconds after each completed attempt. Edit `src/main.rs` in the demo repo,
commit, and push to test an update. The VM disk persists in `demo-state`.
Run the launcher under a service manager to keep it running after logout.
The demo binds to localhost by default. Set `hostAddress` and `hostPort` to
choose a different listening address and port.

## Checks

```sh
nix develop path:.
cargo test
cargo fmt --all -- --check
cargo clippy --all-targets -- -D warnings
nix flake check path:.
nix run path:.#formatter.aarch64-darwin -- flake.nix nix/*.nix nix/modules/*.nix tests/*.nix examples/*.nix
```

The `worker` check builds the Rust package and runs its unit tests.
`module-interface` evaluates defaults, generated units, credentials, the example,
and invalid configuration. Both work on macOS without a NixOS VM. The Linux-only
`lifecycle` check exercises real services, local Git fixtures (including SSH),
timer updates, failed builds, permissions, GC protection, and pending activation
recovery across reboot. Run it on an x86_64 Linux host with KVM available:

```sh
nix build path:.#checks.x86_64-linux.lifecycle -L
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
