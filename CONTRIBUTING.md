# Contributing

This guide explains how to set up a development checkout, find the relevant code,
validate changes, submit a pull request, and try the demo with your local changes.
It also covers the human review and disclosure requirements for AI-assisted
contributions. For detailed test coverage and commands, see [Testing](docs/testing.md).

## Set up a checkout

Install Nix with flakes enabled, then clone the repository and enter its development
shell:

```sh
git clone https://github.com/nixployhq/nixploy.git
cd nixploy
nix develop path:.
```

The shell provides Rust, Cargo, rustfmt, Clippy, and Git. The flake supports
`x86_64-linux`, `aarch64-linux`, and `aarch64-darwin`. NixOS VM tests require a
Linux machine with access to KVM; Rust and module checks also run on supported macOS.

Run the commands below from the repository root. `path:.` includes new files
before Git tracks them, which is useful when adding modules or tests.

## Find the code

| Location | Purpose |
| --- | --- |
| `src/` | Deployment worker, durable state, command execution, and Git credential helper. |
| `nix/modules/` | Public NixOS options and generated systemd services. |
| `tests/` | Module checks, NixOS VM scenarios, and the local smoke test. |
| `examples/nixos/` | Standalone NixOS demo flake. |
| `docs/` | Configuration and usage guides. |

## Make and check changes

Keep changes focused and update documentation when public options or behavior
change. Add or adjust tests for changes to deployment, authentication, or service
behavior. Documentation-only edits need link, example, and formatting checks.

For Rust changes, run:

```sh
cargo test
cargo fmt --all -- --check
cargo clippy --all-targets -- -D warnings
```

For Nix changes, select your current platform and check the module interface:

```sh
nixploy_system=$(nix eval --impure --raw --expr builtins.currentSystem)
nix build "path:.#checks.${nixploy_system}.module-interface" --no-link
```

Format the Nix files you changed with the pinned formatter, for example:

```sh
nix run "path:.#formatter.${nixploy_system}" -- nix/modules/nixploy.nix
```

Run the VM checks relevant to the change on Linux with KVM. For example, changes
to activation and rollback should exercise both scenarios:

```sh
nix build "path:.#checks.${nixploy_system}.lifecycle" \
  "path:.#checks.${nixploy_system}.rollback" --no-link -L
```

See [Testing](docs/testing.md) for the check catalogue, the full suite, and a local
smoke test that does not need a VM.

## Submit a contribution

1. Fork the repository if you do not have write access, and create a branch for
   your change. For larger changes, use an issue to discuss the proposed behavior
   and scope before investing in the implementation.
2. Make the change, update relevant documentation, and run the checks appropriate
   to it. Review the complete diff yourself before submitting.
3. Push your branch and open a pull request against `main`.
4. Explain the problem, what changes for users, and any limitations or tradeoffs.
   Link related issues and list the checks you actually ran, including their
   results and any relevant checks you could not run.
5. Include the AI disclosure below if you used AI assistance, and respond to
   review feedback with any needed changes or clarification.

Bug reports and documentation improvements are welcome too. For a bug report,
include reproduction steps, expected and actual behavior, and relevant versions
and logs. Remove credentials and other secrets before sharing configuration or logs.

## AI-assisted contributions

AI-assisted contributions are welcome, provided the contributor has personally
reviewed and validated the changes before submitting them. You must understand
the submitted work, check its correctness, and run appropriate validation. You
remain responsible for the contribution; an AI review or passing generated tests
does not replace your own human review.

Fully disclose AI assistance in the pull request, including:

- **Models:** each model used, with its version or identifier when available.
  If the tool does not expose the model, say so.
- **Tools and harnesses:** the assistants, agents, editors, CLI tools, or other
  harnesses used to access or orchestrate those models.
- **Use:** what each model and tool was used for, such as planning, research,
  implementation, tests, documentation, debugging, or review. Include assistance
  used during revisions to the pull request.
- **Human validation:** what you personally reviewed and how you validated the
  result, including checks run and any remaining uncertainty.

For example, include this in the pull request description and keep it up to date:

```text
AI assistance
- Model(s): <model names and versions/identifiers, or state if unavailable>
- Tooling/harnesses: <tools used with each model>
- Used for: <tasks and parts of the contribution assisted by each>
- Human review and validation: <what I reviewed, checks run, and results>
- Limitations: <checks not run or unresolved concerns, if any>
```

## Try the demo

The [standalone demo](examples/nixos) normally uses its pinned GitHub version of
Nixploy. To try changes from this checkout, run from the repository root on an
x86_64 Linux host with KVM:

```sh
nix build path:./examples/nixos#nixosConfigurations.demo.config.system.build.vm \
  --override-input nixploy "path:$PWD" --no-write-lock-file \
  --out-link /tmp/nixploy-demo-vm
/tmp/nixploy-demo-vm/bin/run-nixploy-demo-vm
```

This overrides the module source for that build without changing the example's
lockfile. The VM creates a persistent disk in your working directory and serves
the demo at `http://127.0.0.1:8080`. See the [example instructions](examples/nixos/README.md)
for configuration and VM usage.
