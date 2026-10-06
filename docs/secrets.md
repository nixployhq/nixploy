# Secret providers

[Back to Nixploy](../README.md)

Nixploy consumes runtime files. Your secret provider decrypts or fetches them;
Nixploy loads Git credentials using systemd `LoadCredential`. No provider-specific
Nixploy options or plugins are required.

| Secret | Where to reference its runtime path |
| --- | --- |
| Git SSH private key | `services.nixploy.apps.<app>.git.privateKeyFile` |
| Git HTTPS token | `services.nixploy.apps.<app>.git.https.tokenFile` |
| App environment variables | `systemd.services.nixploy-app-<app>.serviceConfig.EnvironmentFile` |
| An app credential file | `systemd.services.nixploy-app-<app>.serviceConfig.LoadCredential` |

Use the provider's `.path` value directly. Do not use `builtins.readFile` on a
secret or put plaintext in `environment`, `writeText`, or a Nix path literal.
Encrypted files may be committed; decryption identities and plaintext stay on
the host. Keep Git credentials root-owned and readable only by root: the updater
loads them, so the application user does not need access.

## sops-nix

Add the [sops-nix input and NixOS module](https://github.com/Mic92/sops-nix#usage-example)
to your infrastructure flake:

```nix
inputs.sops-nix.url = "github:Mic92/sops-nix";
inputs.sops-nix.inputs.nixpkgs.follows = "nixpkgs";
# Include sops-nix in outputs arguments and add to the host's modules list:
# sops-nix.nixosModules.sops
```

With your host's age identity provisioned and an encrypted `secrets.yaml` containing
`git-token` and `app-env` entries, add this host module:

```nix
{ config, ... }:
{
  sops.defaultSopsFile = ./secrets.yaml;
  sops.age.keyFile = "/var/lib/sops-nix/key.txt";
  sops.secrets.git-token.mode = "0400";
  sops.secrets.app-env = {
    mode = "0400";
    restartUnits = [ "nixploy-app-my-app.service" ];
  };

  services.nixploy.apps.my-app = {
    repository = "https://github.com/your-org/your-app.git";
    executable = "your-app";
    git.https = {
      username = "your-git-username";
      tokenFile = config.sops.secrets.git-token.path;
    };
  };

  systemd.services.nixploy-app-my-app.serviceConfig.EnvironmentFile =
    config.sops.secrets.app-env.path;
}
```

The decrypted `git-token` is one token line. The `app-env` value is a multiline
string of systemd environment assignments, such as `DATABASE_URL=...`.
For SSH, declare a private-key secret and use its `.path` for `git.privateKeyFile`,
alongside a verified `git.knownHostsFile`, instead of `git.https`.

## agenix

Add [agenix](https://github.com/ryantm/agenix) to your infrastructure flake:

```nix
inputs.agenix.url = "github:ryantm/agenix";
inputs.agenix.inputs.nixpkgs.follows = "nixpkgs";
# Include agenix in outputs arguments and add to the host's modules list:
# agenix.nixosModules.default
```

Encrypt `git-token.age` and `app-env.age` for the host's identity using your
agenix recipient configuration. Reference their decrypted paths:

```nix
{ config, ... }:
{
  age.identityPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
  age.secrets.git-token = {
    file = ./git-token.age;
    mode = "0400";
  };
  age.secrets.app-env = {
    file = ./app-env.age;
    mode = "0400";
  };

  services.nixploy.apps.my-app = {
    repository = "https://github.com/your-org/your-app.git";
    executable = "your-app";
    git.https = {
      username = "your-git-username";
      tokenFile = config.age.secrets.git-token.path;
    };
  };

  systemd.services.nixploy-app-my-app = {
    serviceConfig.EnvironmentFile = config.age.secrets.app-env.path;
    restartTriggers = [ config.age.secrets.app-env.file ];
  };
}
```

Provision the host identity separately. For SSH Git authentication, use a secret
containing the private key and pass its `.path` to `git.privateKeyFile` instead.

## Startup and rotation

Use the providers' **NixOS modules** for host services; Home Manager user-session
secrets may not exist when a system service starts. The NixOS providers install
secrets during system activation or early boot. Nixploy consumes their stable
paths, including symlinks to secret generations.

A Git credential is copied into the update service's private credentials directory
on each invocation. After the provider installs a replacement, the next poll
loads it. Rotation does not require an application restart or an immediate update
service restart. An in-progress update keeps its existing credential snapshot.

Application secrets are loaded at app startup. A secret change alone does not
change the deployed Git revision, so arrange an app restart. The examples use
sops-nix `restartUnits` or an agenix encrypted-file `restartTriggers` entry for
NixOS configuration switches. For an out-of-band secret replacement, restart the
app after provisioning finishes:

```sh
sudo systemctl restart nixploy-app-my-app.service
```

Missing Git credentials fail that update attempt; the currently running app
remains untouched. A required missing application environment file prevents app
startup. Provision secrets before activation rather than making required files
optional.

## Other mechanisms

Vault agents, other secret-fetching services, or manually provisioned files can
use the same paths. Have the provider write files atomically with restrictive
permissions. If it runs as a systemd service, declare dependencies on the service
that finishes provisioning:

```nix
systemd.services.nixploy-update-my-app = {
  requires = [ "provision-git-secrets.service" ];
  after = [ "provision-git-secrets.service" ];
};
systemd.services.nixploy-app-my-app = {
  requires = [ "provision-app-secrets.service" ];
  after = [ "provision-app-secrets.service" ];
};
```

These are example unit names: define or substitute your provider's units. A
long-running agent must signal readiness only after its files are available.
`After` alone orders startup but does not start a provider or wait for arbitrary
background file creation.

For apps that accept a credential file, systemd credentials avoid exposing the
secret in environment variables:

```nix
systemd.services.nixploy-app-my-app.serviceConfig.LoadCredential = [
  "api-key:/run/secrets/my-app-api-key"
];
```

The application reads `$CREDENTIALS_DIRECTORY/api-key`. Its source file can
remain root-only; systemd grants the app access to the service's private copy.
