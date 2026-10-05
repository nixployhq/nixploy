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
  tests = {
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
      && defaults.environment == { };
    example = valid (import ../examples/configuration.nix).services.nixploy.apps;
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
