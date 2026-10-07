{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.nixploy.webhook;
  apps = lib.filterAttrs (_: app: app.enable && app.webhook.enable) config.services.nixploy.apps;
  worker = pkgs.callPackage ../package.nix { };
  directory = "/var/lib/nixploy-webhooks";
  configFile = "/etc/nixploy-webhooks.json";
  tokenPath =
    name: app:
    if app.webhook.tokenFile == null then
      "${directory}/tokens/${name}.token"
    else
      app.webhook.tokenFile;
in
{
  options.services.nixploy.webhook = {
    listenAddress = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = "IP address for the shared HTTP webhook receiver. Put an HTTPS reverse proxy or tunnel in front of it. No firewall ports are opened automatically.";
    };
    port = lib.mkOption {
      type = lib.types.ints.between 1 65535;
      default = 9070;
      description = "Port for the shared webhook receiver, started when at least one enabled app enables webhooks.";
    };
  };

  config = lib.mkIf (apps != { }) {
    users.groups._nixploy-webhooks = { };
    users.users._nixploy-webhooks = {
      isSystemUser = true;
      group = "_nixploy-webhooks";
    };
    systemd.tmpfiles.rules = [
      "d ${directory} 0755 root root -"
      "d ${directory}/tokens 0700 root root -"
      "d ${directory}/queue 0700 _nixploy-webhooks _nixploy-webhooks -"
    ];
    environment.etc."nixploy-webhooks.json".text = builtins.toJSON {
      inherit (cfg) listenAddress port;
      tokenDirectory = "${directory}/tokens";
      queueDirectory = "${directory}/queue";
      apps = lib.mapAttrs (_: app: { inherit (app.webhook) tokenFile; }) apps;
    };
    systemd.services.nixploy-webhook-tokens = {
      description = "Initialize persistent Nixploy webhook tokens";
      after = [ "systemd-tmpfiles-setup.service" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${worker}/bin/nixploy-worker init-tokens ${configFile}";
        UMask = "0077";
        ProtectSystem = "strict";
        ReadWritePaths = [ "${directory}/tokens" ];
        ProtectHome = true;
        PrivateTmp = true;
      };
    };
    systemd.services.nixploy-webhooks = {
      description = "Nixploy authenticated deployment triggers";
      wantedBy = [ "multi-user.target" ];
      requires = [ "nixploy-webhook-tokens.service" ];
      after = [
        "nixploy-webhook-tokens.service"
        "network.target"
      ];
      restartTriggers = [ config.environment.etc."nixploy-webhooks.json".source ];
      serviceConfig = {
        Type = "exec";
        User = "_nixploy-webhooks";
        Group = "_nixploy-webhooks";
        ExecStart = "${worker}/bin/nixploy-worker serve-hooks ${configFile}";
        LoadCredential = lib.mapAttrsToList (name: app: "${name}:${tokenPath name app}") apps;
        Restart = "on-failure";
        RestartSec = "5s";
        TimeoutStopSec = "15s";
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ReadWritePaths = [ "${directory}/queue" ];
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        CapabilityBoundingSet = "";
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_UNIX"
        ];
        UMask = "0077";
      };
    };
    systemd.paths = lib.mapAttrs' (
      name: _:
      lib.nameValuePair "nixploy-webhook-${name}" {
        description = "Dispatch queued Nixploy update for ${name}";
        wantedBy = [ "multi-user.target" ];
        after = [ "systemd-tmpfiles-setup.service" ];
        pathConfig = {
          PathExists = "${directory}/queue/${name}";
          Unit = "nixploy-update-${name}.service";
        };
      }
    ) apps;
  };
}
