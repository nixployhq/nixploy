# NixOS flake example

A standalone infrastructure flake that imports Nixploy from GitHub and deploys
its public [demo app](https://github.com/nixployhq/demo). The app and infrastructure
have separate repositories and lockfiles. App updates do not require a NixOS
rebuild.

## Run the VM

On an x86_64 Linux host with Nix, flakes enabled, and access to KVM, run from
this directory:

```sh
nix build path:.#nixosConfigurations.demo.config.system.build.vm
./result/bin/run-nixploy-demo-vm
```

Open http://127.0.0.1:8080 once the first deployment finishes. Initial startup
requires internet access to fetch and build the app. Deployment logs appear in
the VM console. The app polls `main` every minute after each attempt.

The VM keeps its disk in `nixploy-demo.qcow2` in the working directory. Run the
launcher under a service manager if you want it to remain running after logout.
The forwarded HTTP port binds to localhost; edit `vm.nix` to change it.

## Use your own app

Change `repository` and `executable` in `configuration.nix`, then rebuild and
restart the VM. To test automatic updates, push a change to your app's configured
branch and wait for its build to finish. No infrastructure rebuild is needed for
application commits.

## Use on a NixOS host

The flake exports `nixosConfigurations.demo`. For a real host, replace `./vm.nix`
in its module list with your host's hardware, boot, and filesystem configuration.
Set `system.stateVersion` to the value appropriate for that host; preserve the
existing value when adding Nixploy to an existing configuration. Configure SSH
access, secrets, and your firewall or reverse proxy as needed before activation.

Deploy through your normal NixOS workflow, for example on the target host:

```sh
sudo nixos-rebuild switch --flake path:.#demo
```

Do this only after replacing the VM module with the host configuration.

## Update dependencies

```sh
nix flake update --flake path:.
```

Review and commit the resulting `flake.lock`. This updates infrastructure
inputs; Nixploy independently follows the app's configured Git branch.
