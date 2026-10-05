{
  config,
  lib,
  pkgs,
  ...
}:
let
  apps = lib.filterAttrs (_: app: app.enable) config.services.nixploy.apps;
  worker = pkgs.callPackage ../package.nix { };
  appUser = name: "nixploy-${name}";
  stateDir = name: "/var/lib/nixploy/${name}";
  configFile = name: "/etc/nixploy/${name}.json";
  sshWrapper =
    name: app:
    pkgs.writeShellScript "nixploy-ssh-${name}" ''
      exec ${pkgs.openssh}/bin/ssh -F /dev/null \
        -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=30 \
        -o GlobalKnownHostsFile=/dev/null \
        -o "UserKnownHostsFile=$CREDENTIALS_DIRECTORY/known-hosts" \
        ${
          lib.optionalString (
            app.git.privateKeyFile != null
          ) ''-o IdentitiesOnly=yes -i "$CREDENTIALS_DIRECTORY/private-key"''
        } "$@"
    '';
  workerConfig = name: app: {
    app = name;
    inherit (app)
      repository
      branch
      package
      executable
      ;
    system = pkgs.stdenv.hostPlatform.system;
    stateDirectory = stateDir name;
    # Include resolved runtime overrides so they invalidate in-flight workers.
    generation = builtins.hashString "sha256" (
      builtins.toJSON {
        inherit app;
        inherit (config.systemd.services."nixploy-app-${name}") serviceConfig environment;
      }
    );
  };
in
{
  config = lib.mkIf (apps != { }) {
    nix.settings.experimental-features = [
      "nix-command"
      "flakes"
    ];

    users.groups = lib.mapAttrs' (name: _: lib.nameValuePair (appUser name) { }) apps;
    users.users = lib.mapAttrs' (
      name: _:
      lib.nameValuePair (appUser name) {
        isSystemUser = true;
        group = appUser name;
      }
    ) apps;

    # Only controller-owned paths live here. App-writable StateDirectory values
    # must be separate from this tree.
    systemd.tmpfiles.rules = [
      "d /var/lib/nixploy 0755 root root -"
    ]
    ++ lib.concatLists (
      lib.mapAttrsToList (name: _: [
        "d ${stateDir name} 0755 root root -"
        "d ${stateDir name}/work 0700 root root -"
        "d ${stateDir name}/roots 0755 root root -"
      ]) apps
    );

    environment.etc = lib.mapAttrs' (
      name: app:
      lib.nameValuePair "nixploy/${name}.json" {
        text = builtins.toJSON (workerConfig name app);
        mode = "0600";
      }
    ) apps;

    systemd.services = lib.mkMerge [
      (lib.mapAttrs' (
        name: app:
        lib.nameValuePair "nixploy-app-${name}" {
          description = "Nixploy application ${name}";
          wantedBy = [ "multi-user.target" ];
          after = [
            "network.target"
            "systemd-tmpfiles-setup.service"
          ];
          unitConfig.ConditionFileIsExecutable = "${stateDir name}/profile/bin/${app.executable}";
          environment = app.environment;
          serviceConfig = {
            Type = "exec";
            User = appUser name;
            Group = appUser name;
            ExecStart = "${stateDir name}/profile/bin/${app.executable}";
            Restart = "on-failure";
            RestartSec = "5s";
            TimeoutStartSec = "60s";
            TimeoutStopSec = "30s";
            NoNewPrivileges = true;
            ProtectSystem = "strict";
            ProtectHome = true;
            PrivateTmp = true;
          };
        }
      ) apps)
      (lib.mapAttrs' (
        name: app:
        lib.nameValuePair "nixploy-update-${name}" {
          description = "Update Nixploy application ${name}";
          # The timer supplies retry pacing; short intervals and manual updates
          # must not exhaust systemd's start limit and prevent later attempts.
          unitConfig.StartLimitIntervalSec = 0;
          wants = [ "network-online.target" ];
          after = [
            "network-online.target"
            "systemd-tmpfiles-setup.service"
          ];
          path = [
            pkgs.git
            pkgs.nix
            pkgs.systemd
          ];
          environment = {
            HOME = "${stateDir name}/work";
            GIT_TERMINAL_PROMPT = "0";
            # Root would otherwise select the local store and bypass the daemon.
            NIX_REMOTE = "daemon";
          }
          // lib.optionalAttrs (app.git.knownHostsFile != null) {
            GIT_SSH = toString (sshWrapper name app);
            GIT_SSH_VARIANT = "ssh";
          };
          # Causes a running worker to be stopped when its configuration changes.
          restartTriggers = [ config.environment.etc."nixploy/${name}.json".source ];
          serviceConfig = {
            Type = "oneshot";
            User = "root";
            ExecStart = "${worker}/bin/nixploy ${configFile name}";
            TimeoutStartSec = "75min";
            TimeoutStopSec = "15s";
            KillMode = "control-group";
            UMask = "0022";
            PrivateTmp = true;
            LoadCredential =
              lib.optional (app.git.privateKeyFile != null) "private-key:${app.git.privateKeyFile}"
              ++ lib.optional (app.git.knownHostsFile != null) "known-hosts:${app.git.knownHostsFile}";
          };
        }
      ) apps)
    ];

    systemd.timers = lib.mapAttrs' (
      name: app:
      lib.nameValuePair "nixploy-update-${name}" {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "30s";
          OnUnitInactiveSec = app.pollInterval;
          AccuracySec = "1s";
          Unit = "nixploy-update-${name}.service";
        };
      }
    ) apps;
  };
}
