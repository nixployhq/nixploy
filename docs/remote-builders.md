# Remote builders

[Back to Nixploy](../README.md)

Nixploy uses the host's Nix daemon and standard `nix.buildMachines` settings.
Configure the deployment host with a builder capable of building packages for
the app host's platform:

```nix
{
  nix.distributedBuilds = true;
  nix.settings.builders-use-substitutes = true;
  nix.buildMachines = [{
    hostName = "builder.example.com";
    system = "x86_64-linux";
    protocol = "ssh-ng";
    sshUser = "nixbuilder";
    sshKey = "/run/secrets/build-key";
    maxJobs = 4;
  }];

  programs.ssh.knownHosts.buildbox = {
    hostNames = [ "builder.example.com" ];
    publicKey = "ssh-ed25519 REPLACE_WITH_BUILDER_HOST_PUBLIC_KEY";
  };
}
```

Provision the private key outside the Nix store, readable by root before builds
start. It is the Nix daemon's builder credential, separate from the application's
Git credential. Replace the host key with the builder's verified public host key.

On a NixOS builder, enable SSH and authorize the deployment host's build key:

```nix
{
  services.openssh.enable = true;
  users.groups.nixbuilder = {};
  users.users.nixbuilder = {
    isSystemUser = true;
    group = "nixbuilder";
    useDefaultShell = true;
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 REPLACE_WITH_DEPLOYMENT_HOST_BUILD_PUBLIC_KEY"
    ];
  };
  nix.settings.trusted-users = [ "nixbuilder" ];
}
```

Nix trusted users have effectively root-level access; reserve this account for
trusted deployment hosts. The builder receives application source and build
inputs. Git checkout and flake evaluation stay on the deployment host, and Nix
copies the built output back before Nixploy activates it. Readiness and rollback
run on the deployment host.

Nix may still build locally when local jobs are enabled. To require remote builds
for testing, set `nix.settings.max-jobs = 0;` on the deployment host. This affects
all builds through its daemon, not just Nixploy. Declare `supportedFeatures` on a
build-machine entry only for features that the builder actually provides.

See the [Nix distributed-build guide](https://nix.dev/tutorials/nixos/distributed-builds-setup.html)
for the underlying setup. See [Testing](testing.md) for the
remote-builder integration check.

See [secret providers](secrets.md) for provisioning runtime key files.
