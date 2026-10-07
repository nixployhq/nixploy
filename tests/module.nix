{ nixpkgs }:
let
  inherit (nixpkgs) lib;
  evaluate =
    apps:
    (lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ../nix/modules/nixploy.nix
        {
          services.nixploy.apps = apps;
          system.stateVersion = "26.05";
          boot.loader.grub.enable = false;
          fileSystems."/" = {
            device = "/dev/vda1";
            fsType = "ext4";
          };
        }
      ];
    }).config;
  valid =
    apps:
    let
      cfg = evaluate apps;
    in
    builtins.deepSeq cfg.services.nixploy.apps (lib.all (entry: entry.assertion) cfg.assertions);
  rejects =
    apps:
    let
      result = builtins.tryEval (valid apps);
    in
    !result.success || !result.value;
  publicApp = {
    repository = "https://example.com/app.git";
    executable = "web-server";
  };
  sshApp = publicApp // {
    repository = "git@example.com:team/app.git";
    git.knownHostsFile = "/etc/ssh/ssh_known_hosts";
  };
  defaults = (evaluate { demo = publicApp; }).services.nixploy.apps.demo;
  runtime = evaluate { demo = publicApp; };
  privateRuntime = evaluate {
    demo = sshApp // {
      git = {
        privateKeyFile = "/run/secrets/deploy";
        knownHostsFile = "/run/secrets/known-hosts";
      };
    };
  };
  httpsApp = publicApp // {
    git.https = {
      username = "test-user";
      tokenFile = "/run/secrets/git-token";
    };
  };
  httpsRuntime = evaluate { demo = httpsApp; };
  webhookRuntime = evaluate {
    demo = publicApp // {
      webhook.enable = true;
    };
    managed = publicApp // {
      webhook = {
        enable = true;
        tokenFile = "/run/secrets/hook";
      };
    };
    disabled = publicApp // {
      enable = false;
      webhook.enable = true;
    };
  };
  readinessRuntime = evaluate {
    demo = publicApp // {
      endpoint.port = 3000;
      readiness.path = "/health";
    };
  };
  endpointRuntime = evaluate {
    demo = publicApp // {
      endpoint.port = 3000;
    };
  };
  endpointOverrideRuntime = evaluate {
    demo = publicApp // {
      endpoint.port = 3000;
      environment = {
        HOST = "0.0.0.0";
        PORT = "8080";
        APP_MODE = "production";
      };
    };
  };
  endpointSchemeRuntime = evaluate {
    demo = publicApp // {
      endpoint = {
        port = 3000;
        scheme = "https";
      };
    };
  };
  endpointIpv6Runtime = evaluate {
    demo = publicApp // {
      endpoint = {
        host = "::1";
        port = 4000;
      };
      environment.APP_MODE = "production";
    };
  };
  endpoint =
    settings:
    (evaluate {
      demo = publicApp // {
        endpoint = settings;
      };
    }).services.nixploy.apps.demo.endpoint;
  proxyConfig =
    (lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ../nix/modules/nixploy.nix
        ({ config, ... }: {
          services.nixploy.apps.demo = publicApp // {
            endpoint.port = 3000;
          };
          services.cloudflared.tunnels.demo = {
            credentialsFile = "/run/secrets/tunnel.json";
            default = "http_status:404";
            ingress."foo.example.com" = config.services.nixploy.apps.demo.endpoint.url;
          };
        })
      ];
    }).config;
  tests = {
    webhookOptional =
      !defaults.webhook.enable
      && defaults.webhook.tokenFile == null
      && !(runtime.systemd.services ? nixploy-webhooks);
    webhookCredentials =
      webhookRuntime.systemd.services.nixploy-webhooks.serviceConfig.LoadCredential == [
        "demo:/var/lib/nixploy-webhooks/tokens/demo.token"
        "managed:/run/secrets/hook"
      ];
    webhookUnprivileged =
      webhookRuntime.systemd.services.nixploy-webhooks.serviceConfig.User == "_nixploy-webhooks";
    webhookQueue =
      webhookRuntime.systemd.paths.nixploy-webhook-demo.pathConfig.Unit == "nixploy-update-demo.service"
      &&
        webhookRuntime.systemd.paths.nixploy-webhook-demo.pathConfig.PathExists
        == "/var/lib/nixploy-webhooks/queue/demo"
      && !(webhookRuntime.systemd.paths ? nixploy-webhook-disabled);
    webhookDoesNotRedeploy =
      webhookRuntime.environment.etc."nixploy/demo.json".text
      == runtime.environment.etc."nixploy/demo.json".text;
    webhookRelativeToken = rejects {
      demo = publicApp // {
        webhook.tokenFile = "relative";
      };
    };
    readinessOptional =
      defaults.readiness == null
      && !(runtime.systemd.services.nixploy-app-demo.serviceConfig ? ExecStartPost);
    readinessDefaults =
      readinessRuntime.services.nixploy.apps.demo.readiness == {
        path = "/health";
        url = "http://127.0.0.1:3000/health";
        expectedStatus = 200;
        timeoutSeconds = 30;
        intervalSeconds = 2;
        startPeriodSeconds = 10;
        failureThreshold = 3;
        requestTimeoutSeconds = 5;
      };
    readinessUnit =
      builtins.length readinessRuntime.systemd.services.nixploy-app-demo.serviceConfig.ExecStartPost == 1
      && readinessRuntime.systemd.services.nixploy-app-demo.serviceConfig.User == "nixploy-demo"
      && readinessRuntime.systemd.services.nixploy-app-demo.serviceConfig.TimeoutStartSec == "35s";
    readinessExplicitUrl = valid {
      demo = publicApp // {
        readiness.url = "https://[::1]:8443/ready?check=1";
      };
    };
    readinessUrlRequired = rejects {
      demo = publicApp // {
        readiness = { };
      };
    };
    readinessBadUrl =
      lib.all
        (
          url:
          rejects {
            demo = publicApp // {
              readiness = { inherit url; };
            };
          }
        )
        [
          "ftp://localhost/"
          "http://user:password@localhost/"
          "http://localhost/a b"
          "http://localhost/#fragment"
        ];
    readinessBadPath = rejects {
      demo = publicApp // {
        endpoint.port = 3000;
        readiness.path = "health";
      };
    };
    readinessBadLimits =
      lib.all
        (
          settings:
          rejects {
            demo = publicApp // {
              readiness = {
                url = "http://localhost/";
              }
              // settings;
            };
          }
        )
        [
          { timeoutSeconds = 0; }
          { timeoutSeconds = 121; }
          { intervalSeconds = 0; }
          { requestTimeoutSeconds = 0; }
          { expectedStatus = 600; }
          { startPeriodSeconds = -1; }
          { startPeriodSeconds = 30; }
          { failureThreshold = 0; }
        ];
    readinessChangesGeneration =
      (builtins.fromJSON readinessRuntime.environment.etc."nixploy/demo.json".text).generation
      != (builtins.fromJSON endpointRuntime.environment.etc."nixploy/demo.json".text).generation;
    rollbackDefaults =
      !defaults.rollback.enable
      && readinessRuntime.services.nixploy.apps.demo.rollback.enable
      && (builtins.fromJSON readinessRuntime.environment.etc."nixploy/demo.json".text).rollback;
    rollbackCanBeDisabled =
      !(evaluate {
        demo = publicApp // {
          endpoint.port = 3000;
          readiness.path = "/health";
          rollback.enable = false;
        };
      }).services.nixploy.apps.demo.rollback.enable;
    endpointConsumer =
      proxyConfig.services.cloudflared.tunnels.demo.ingress."foo.example.com" == "http://127.0.0.1:3000"
      && proxyConfig.services.nixploy.apps.demo.environment.PORT == "3000";
    endpointOptional = defaults.endpoint == null;
    endpointUrl = (endpoint { port = 3000; }).url == "http://127.0.0.1:3000";
    endpointHttps =
      (endpoint {
        scheme = "https";
        host = "app.internal";
        port = 8443;
      }).url == "https://app.internal:8443";
    endpointIpv6 =
      (endpoint {
        host = "::1";
        port = 3000;
      }).url == "http://[::1]:3000";
    endpointReadOnly = rejects {
      demo = publicApp // {
        endpoint = {
          port = 3000;
          url = "http://override";
        };
      };
    };
    endpointPortRequired = rejects {
      demo = publicApp // {
        endpoint = { };
      };
    };
    endpointPortRange =
      lib.all
        (
          port:
          rejects {
            demo = publicApp // {
              endpoint = { inherit port; };
            };
          }
        )
        [
          0
          65536
        ];
    endpointBadScheme = rejects {
      demo = publicApp // {
        endpoint = {
          scheme = "ftp";
          port = 3000;
        };
      };
    };
    endpointBadHost =
      lib.all
        (
          host:
          rejects {
            demo = publicApp // {
              endpoint = {
                inherit host;
                port = 3000;
              };
            };
          }
        )
        [
          ""
          "https://localhost"
          "user@host"
          "host/path"
          "host:3000"
          "a b"
          "[::1]"
        ];
    endpointEnvironment =
      endpointRuntime.services.nixploy.apps.demo.environment == {
        HOST = "127.0.0.1";
        PORT = "3000";
      }
      && endpointRuntime.systemd.services.nixploy-app-demo.environment.HOST == "127.0.0.1"
      && endpointRuntime.systemd.services.nixploy-app-demo.environment.PORT == "3000";
    endpointEnvironmentOverrides =
      endpointOverrideRuntime.services.nixploy.apps.demo.environment == {
        HOST = "0.0.0.0";
        PORT = "8080";
        APP_MODE = "production";
      }
      && endpointOverrideRuntime.systemd.services.nixploy-app-demo.environment.HOST == "0.0.0.0"
      && endpointOverrideRuntime.systemd.services.nixploy-app-demo.environment.PORT == "8080"
      && endpointOverrideRuntime.services.nixploy.apps.demo.endpoint.url == "http://127.0.0.1:3000";
    endpointIpv6Environment =
      endpointIpv6Runtime.services.nixploy.apps.demo.environment == {
        HOST = "::1";
        PORT = "4000";
        APP_MODE = "production";
      };
    endpointEnvironmentChangesGeneration =
      (builtins.fromJSON endpointRuntime.environment.etc."nixploy/demo.json".text).generation
      != (builtins.fromJSON runtime.environment.etc."nixploy/demo.json".text).generation;
    endpointSchemeDoesNotChangeGeneration =
      endpointSchemeRuntime.environment.etc."nixploy/demo.json".text
      == endpointRuntime.environment.etc."nixploy/demo.json".text;
    endpointDoesNotConfigureListener =
      endpointRuntime.systemd.services.nixploy-app-demo.serviceConfig
      == runtime.systemd.services.nixploy-app-demo.serviceConfig
      &&
        endpointRuntime.networking.firewall.allowedTCPPorts == runtime.networking.firewall.allowedTCPPorts;
    httpsCredentials =
      httpsRuntime.systemd.services.nixploy-update-demo.serviceConfig.LoadCredential
      == [ "git-token:/run/secrets/git-token" ];
    httpsHelperScope =
      httpsRuntime.systemd.services.nixploy-update-demo.environment.GIT_CONFIG_VALUE_2 == "true"
      && httpsRuntime.systemd.services.nixploy-update-demo.environment.GIT_CONFIG_VALUE_3 == "false";
    httpsValid = valid { demo = httpsApp; };
    httpsUsernameRequired = rejects {
      demo = publicApp // {
        git.https.tokenFile = "/run/token";
      };
    };
    httpsTokenRequired = rejects {
      demo = publicApp // {
        git.https.username = "user";
      };
    };
    httpsRelativeToken = rejects {
      demo = publicApp // {
        git.https = {
          username = "user";
          tokenFile = "token";
        };
      };
    };
    httpsNixPathToken = rejects {
      demo = publicApp // {
        git.https = {
          username = "user";
          tokenFile = ./module.nix;
        };
      };
    };
    httpsSshMix = rejects {
      demo = httpsApp // {
        git = httpsApp.git // {
          privateKeyFile = "/run/key";
        };
      };
    };
    httpsSshRepository = rejects {
      demo = httpsApp // {
        repository = sshApp.repository;
        git = httpsApp.git // {
          knownHostsFile = "/run/hosts";
        };
      };
    };
    httpsQuery = rejects {
      demo = httpsApp // {
        repository = "https://example.com/app.git?token=value";
      };
    };
    httpsUserinfo = rejects {
      demo = httpsApp // {
        repository = "https://user:password@example.com/app.git";
      };
    };
    httpsUsernameInjection = rejects {
      demo = publicApp // {
        git.https = {
          username = "user\npassword=secret";
          tokenFile = "/run/token";
        };
      };
    };
    workerUsesDaemon =
      (runtime.systemd.services.nixploy-update-demo.environment.NIX_REMOTE or null) == "daemon";
    updateRetriesNotRateLimited =
      (runtime.systemd.services.nixploy-update-demo.unitConfig.StartLimitIntervalSec or null) == 0;
    emptyHasNoUnits = !(builtins.hasAttr "nixploy-update-demo" (evaluate { }).systemd.services);
    disabledHasNoUnits =
      !(builtins.hasAttr "nixploy-update-demo"
        (evaluate {
          demo = publicApp // {
            enable = false;
          };
        }).systemd.services
      );
    runtimePermissions =
      runtime.systemd.services.nixploy-app-demo.serviceConfig.User == "nixploy-demo"
      && runtime.systemd.services.nixploy-update-demo.serviceConfig.User == "root"
      && runtime.environment.etc."nixploy/demo.json".mode == "0600";
    initialBootGuard =
      runtime.systemd.services.nixploy-app-demo.unitConfig.ConditionFileIsExecutable
      == "/var/lib/nixploy/demo/profile/bin/web-server";
    timer = runtime.systemd.timers.nixploy-update-demo.timerConfig.OnUnitInactiveSec == "1min";
    credentials =
      privateRuntime.systemd.services.nixploy-update-demo.serviceConfig.LoadCredential == [
        "private-key:/run/secrets/deploy"
        "known-hosts:/run/secrets/known-hosts"
      ];
    workerConfiguration =
      (builtins.fromJSON runtime.environment.etc."nixploy/demo.json".text).system == "x86_64-linux";
    empty = valid { };
    multipleApps = valid {
      one = publicApp;
      two = sshApp;
    };
    defaultValues =
      defaults.enable
      && defaults.branch == "main"
      && defaults.package == "default"
      && defaults.pollInterval == "1min"
      && defaults.git.privateKeyFile == null
      && defaults.git.knownHostsFile == null
      && defaults.git.https.username == null
      && defaults.git.https.tokenFile == null
      && defaults.environment == { };
    example = valid (import ../examples/nixos/configuration.nix { }).services.nixploy.apps;
    sshUrl = valid {
      demo = sshApp // {
        repository = "ssh://git@example.com/team/app.git";
      };
    };
    disabled = valid {
      demo = sshApp // {
        enable = false;
        git = { };
      };
    };
    missingRepository = rejects {
      demo = {
        executable = "server";
      };
    };
    missingExecutable = rejects {
      demo = {
        repository = publicApp.repository;
      };
    };
    missingKnownHosts = rejects {
      demo = sshApp // {
        git = { };
      };
    };
    invalidAppName = rejects { "../escape" = publicApp; };
    invalidRepository = rejects {
      demo = publicApp // {
        repository = "file:///tmp/app";
      };
    };
    invalidBranch =
      lib.all
        (
          branch:
          rejects {
            demo = publicApp // {
              inherit branch;
            };
          }
        )
        [
          ""
          "-main"
          "a..b"
          "main.lock"
          "a//b"
          "a/.b"
          "a@{b"
          "a b"
          "a\\b"
          "a[b"
        ];
    branchWithSlash = valid {
      demo = publicApp // {
        branch = "release/v1";
      };
    };
    attributePath = rejects {
      demo = publicApp // {
        package = "packages.x86_64-linux.default";
      };
    };
    executablePath = rejects {
      demo = publicApp // {
        executable = "../bin/server";
      };
    };
    executableCommand = rejects {
      demo = publicApp // {
        executable = "server --port 3000";
      };
    };
    zeroInterval = rejects {
      demo = publicApp // {
        pollInterval = "0s";
      };
    };
    invalidInterval = rejects {
      demo = publicApp // {
        pollInterval = "tomorrow";
      };
    };
    validInterval = valid {
      demo = publicApp // {
        pollInterval = "30s";
      };
    };
    relativeCredential = rejects {
      demo = sshApp // {
        git.privateKeyFile = "secrets/key";
      };
    };
    nixPathCredential = rejects {
      demo = sshApp // {
        git.privateKeyFile = ./module.nix;
      };
    };
    invalidEnvironment = rejects {
      demo = publicApp // {
        environment."BAD=NAME" = "value";
      };
    };
    nonStringEnvironment = rejects {
      demo = publicApp // {
        environment.PORT = 3000;
      };
    };
  };
  failed = builtins.attrNames (lib.filterAttrs (_: passed: !passed) tests);
in
if failed == [ ] then
  true
else
  throw "Nixploy module tests failed: ${lib.concatStringsSep ", " failed}"
