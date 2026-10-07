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
  readinessProbe =
    name: app:
    let
      probe = app.readiness;
      attempts = pkgs.writeShellScript "nixploy-readiness-attempts-${name}" ''
        SECONDS=0
        failures=0
        while true; do
          probe_started=$SECONDS
          if status=$(${pkgs.curl}/bin/curl --disable --silent --globoff \
            --noproxy '*' --proto '=http,https' --disallow-username-in-url \
            --cacert /etc/ssl/certs/ca-certificates.crt \
            --max-time ${toString probe.requestTimeoutSeconds} \
            --output /dev/null --write-out '%{http_code}' \
            --url ${lib.escapeShellArg probe.url}) \
            && [ "$status" = ${lib.escapeShellArg (toString probe.expectedStatus)} ]; then
            exit 0
          fi
          if [ "$probe_started" -ge ${toString probe.startPeriodSeconds} ]; then
            failures=$((failures + 1))
            if [ "$failures" -ge ${toString probe.failureThreshold} ]; then
              echo "Readiness failure threshold reached ($failures probes)" >&2
              exit 1
            fi
          fi
          ${pkgs.coreutils}/bin/sleep ${toString probe.intervalSeconds}
        done
      '';
    in
    pkgs.writeShellScript "nixploy-readiness-${name}" ''
      echo "Waiting for application readiness"
      if ${pkgs.coreutils}/bin/timeout --kill-after=1s ${toString probe.timeoutSeconds}s ${attempts}; then
        echo "Application readiness probe passed"
      else
        echo "Application readiness probe failed (threshold reached or ${toString probe.timeoutSeconds}s deadline expired)" >&2
        exit 1
      fi
    '';
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
  httpsHelper =
    name: app:
    pkgs.writeShellScript "nixploy-https-${name}" ''
      exec ${worker}/bin/nixploy-git-credential ${lib.escapeShellArg app.repository} ${lib.escapeShellArg app.git.https.username} "$@"
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
    rollback = app.rollback.enable;
    # Include resolved runtime overrides so they invalidate in-flight workers.
    generation = builtins.hashString "sha256" (
      builtins.toJSON {
        # Endpoint metadata alone does not change the deployed application.
        app = lib.removeAttrs app [
          "endpoint"
          "webhook"
        ];
        inherit (config.systemd.services."nixploy-app-${name}") serviceConfig environment;
      }
    );
  };
in
{
  config = lib.mkIf (apps != { }) {
    environment.systemPackages = [ worker ];
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
            TimeoutStartSec =
              if app.readiness == null then "60s" else "${toString (app.readiness.timeoutSeconds + 5)}s";
            TimeoutStopSec = "30s";
            NoNewPrivileges = true;
            ProtectSystem = "strict";
            ProtectHome = true;
            PrivateTmp = true;
            RestrictSUIDSGID = lib.mkDefault true;
            CapabilityBoundingSet = lib.mkDefault "";
            RestrictAddressFamilies = lib.mkDefault [
              "AF_UNIX"
              "AF_INET"
              "AF_INET6"
            ];
            UMask = lib.mkDefault "0077";
          }
          // lib.optionalAttrs (app.readiness != null) {
            ExecStartPost = [ (toString (readinessProbe name app)) ];
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
          }
          // lib.optionalAttrs (app.git.https.tokenFile != null) {
            # Reset inherited helpers. Never store a token in config, argv, or env.
            GIT_CONFIG_COUNT = "4";
            GIT_CONFIG_KEY_0 = "credential.helper";
            GIT_CONFIG_VALUE_0 = "";
            GIT_CONFIG_KEY_1 = "credential.helper";
            GIT_CONFIG_VALUE_1 = toString (httpsHelper name app);
            GIT_CONFIG_KEY_2 = "credential.useHttpPath";
            GIT_CONFIG_VALUE_2 = "true";
            GIT_CONFIG_KEY_3 = "http.followRedirects";
            GIT_CONFIG_VALUE_3 = "false";
            GIT_ASKPASS = "${pkgs.coreutils}/bin/false";
            SSH_ASKPASS = "${pkgs.coreutils}/bin/false";
          };
          # Causes a running worker to be stopped when its configuration changes.
          restartTriggers = [ config.environment.etc."nixploy/${name}.json".source ];
          serviceConfig = {
            Type = "oneshot";
            User = "root";
            ExecStart = "${worker}/bin/nixploy-worker update ${configFile name}";
            TimeoutStartSec = "75min";
            TimeoutStopSec = "15s";
            KillMode = "control-group";
            UMask = "0022";
            # Consume before Git resolution. A request arriving while this update
            # runs remains present, so the path unit schedules a follow-up.
            ExecStartPre = lib.optionals app.webhook.enable [
              "${pkgs.coreutils}/bin/rm -f /var/lib/nixploy-webhooks/queue/${name}"
            ];
            PrivateTmp = true;
            LoadCredential =
              lib.optional (app.git.privateKeyFile != null) "private-key:${app.git.privateKeyFile}"
              ++ lib.optional (app.git.knownHostsFile != null) "known-hosts:${app.git.knownHostsFile}"
              ++ lib.optional (app.git.https.tokenFile != null) "git-token:${app.git.https.tokenFile}";
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
