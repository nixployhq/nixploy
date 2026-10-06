# Private repositories

[Back to Nixploy](../README.md)

### HTTPS tokens

Use an access token with permission to read the repository:

```nix
services.nixploy.apps.my-app = {
  repository = "https://github.com/your-org/your-app.git";
  executable = "your-app";
  git.https = {
    username = "your-git-username";
    tokenFile = "/run/secrets/my-app-git-token";
  };
};
```

These options are provider-independent. Set the username required by your Git
provider and provision the token file separately, for example with sops-nix or
agenix. The file must contain only the token on a single line; a trailing newline
is allowed. Use a quoted absolute path string so its contents stay out of the
Nix store. Both `username` and `tokenFile` are required.

Nixploy loads the file through systemd credentials for each update and supplies
the token as the HTTPS password through a repository-scoped Git credential
helper. Tokens are not put in repository URLs, command arguments, environment
variables, or deployment state. Replacing the file rotates the token on the next
update; automatic token issuance and renewal are not provided.

Authenticated HTTPS URLs must not contain embedded credentials, a query, or a
fragment. Redirects are disabled: use the repository’s canonical clone URL. HTTPS
token settings cannot be combined with SSH credential settings. These credentials
authenticate the app repository, not its private flake inputs.

### SSH keys

For an SSH repository, provide a known-hosts file and, when needed, a private key:

```nix
services.nixploy.apps.my-app = {
  repository = "git@github.com:your-org/your-app.git";
  executable = "your-app";
  git = {
    privateKeyFile = "/run/secrets/app-deploy-key";
    knownHostsFile = "/etc/ssh/ssh_known_hosts";
  };
};
```

Provision these files separately. Use absolute path **strings**, as above, to
keep secret contents out of the Nix store. Nixploy loads SSH credentials through
systemd and enforces host verification. If `privateKeyFile` is null, SSH
credentials must already be available to the worker. These settings authenticate
the application repository; private flake inputs need separate authentication.

See [examples/nixos/configuration.nix](../examples/nixos/configuration.nix) for a configuration
with explicit defaults.

## Secret providers

Nixploy works with sops-nix, agenix, and other tools that provision runtime files.
Pass the provider’s decrypted path to the credential option, for example:

```nix
git.https.tokenFile = config.sops.secrets.git-token.path;
# Or: config.age.secrets.git-token.path
```

See [Secret providers](secrets.md) for complete configuration snippets,
application secrets, startup ordering, and rotation.

See the [configuration reference](configuration.md) for all Git authentication options.
