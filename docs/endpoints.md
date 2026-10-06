# Endpoints and reverse proxies

[Back to Nixploy](../README.md)

Declare an endpoint once and reuse its URL in other NixOS modules:

```nix
{ config, ... }:
{
  services.nixploy.apps.my-app = {
    repository = "https://github.com/your-org/your-app.git";
    executable = "your-app";
    endpoint = {
      host = "127.0.0.1";
      port = 3000;
    };
  };

  # Add to an existing cloudflared tunnel configuration:
  services.cloudflared.tunnels."your-tunnel-id".ingress."foo.example.com" =
    config.services.nixploy.apps.my-app.endpoint.url;
}
```

The derived URL is `http://127.0.0.1:3000`. An IPv6 host such as `::1` produces
`http://[::1]:3000`. Configure the tunnel's credentials and other required settings
through the [NixOS cloudflared module](https://github.com/NixOS/nixpkgs/blob/nixos-unstable/nixos/modules/services/networking/cloudflared.nix).

Setting an endpoint supplies `HOST` and `PORT` to the application (in this example,
`127.0.0.1` and `3000`). The application must respect those environment variables;
configure apps that use different settings explicitly. Without an endpoint,
Nixploy adds neither variable.

Explicit `environment.HOST` and `environment.PORT` values override these defaults.
For example, set `environment.HOST = "0.0.0.0";` to listen on all interfaces while
keeping the endpoint host at `127.0.0.1` for a local proxy. Overrides do not change
the derived URL, so keep it consistent with where the application is reachable.

The endpoint does not configure TLS, open firewall ports, install a proxy, or enable
readiness checks. Endpoint changes that alter the application's environment trigger a
deployment on the next update. URL changes also trigger deployment when used by
a readiness probe; otherwise the URL is only an output for consumers.

See the [configuration reference](configuration.md) for all endpoint options and [readiness checks](readiness.md) for probing an endpoint.
