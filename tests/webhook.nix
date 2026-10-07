{ pkgs }:
let
  fixtureFlake = pkgs.writeText "webhook-flake.nix" ''
    {
      outputs = { self }: {
        packages.${pkgs.stdenv.hostPlatform.system}.default = builtins.derivation {
          name = "webhook-fixture";
          system = "${pkgs.stdenv.hostPlatform.system}";
          builder = builtins.appendContext "${pkgs.runtimeShell}" {
            "${pkgs.bashNonInteractive}" = { path = true; };
            "${pkgs.coreutils}" = { path = true; };
          };
          args = [ "-ec" "${pkgs.coreutils}/bin/sleep 5; ${pkgs.coreutils}/bin/mkdir -p $out/bin; ${pkgs.coreutils}/bin/cp $src/server $out/bin/server; ${pkgs.coreutils}/bin/chmod +x $out/bin/server; exit 0" ];
          src = self.outPath;
        };
      };
    }
  '';
  fixtureServer = pkgs.writeText "webhook-server" ''
    #!${pkgs.runtimeShell}
    echo one > "$VERSION_FILE"
    while true; do ${pkgs.coreutils}/bin/sleep 1; done
  '';
  client = pkgs.writeText "webhook-client.py" ''
    from pathlib import Path
    import sys
    import urllib.request
    import urllib.error
    request = urllib.request.Request("http://127.0.0.1:9070/hooks/" + sys.argv[1], method="POST")
    if sys.argv[2] != "-":
        request.add_header("Authorization", "Bearer " + Path(sys.argv[2]).read_text().strip())
    try:
        with urllib.request.urlopen(request, timeout=5) as response:
            print(response.status)
    except urllib.error.HTTPError as error:
        print(error.code)
  '';
in
pkgs.testers.runNixOSTest {
  name = "nixploy-webhook";
  nodes.machine = { lib, ... }: {
    imports = [ ../nix/modules/nixploy.nix ];
    virtualisation.memorySize = 2048;
    virtualisation.writableStoreUseTmpfs = false;
    environment.systemPackages = [
      pkgs.git
      pkgs.python3
      pkgs.jq
    ];
    system.extraDependencies = [
      pkgs.bashNonInteractive
      pkgs.coreutils
      fixtureFlake
      fixtureServer
    ];
    nix.settings.substituters = lib.mkForce [ ];
    services.nixploy.apps = {
      demo = {
        repository = "https://fixture.invalid/app.git";
        executable = "server";
        webhook.enable = true;
        pollInterval = "1h";
        environment.VERSION_FILE = "/var/lib/demo/version";
      };
      managed = {
        repository = "https://fixture.invalid/app.git";
        executable = "server";
        webhook = {
          enable = true;
          tokenFile = "/run/managed-token";
        };
        pollInterval = "1h";
        environment.VERSION_FILE = "/var/lib/managed/version";
      };
    };
    systemd.services = {
      nixploy-app-demo.serviceConfig.StateDirectory = "demo";
      nixploy-app-managed.serviceConfig.StateDirectory = "managed";
      webhook-test-token = {
        before = [ "nixploy-webhooks.service" ];
        requiredBy = [ "nixploy-webhooks.service" ];
        script = ''
          umask 077
          ${pkgs.coreutils}/bin/head -c 32 /dev/urandom | ${pkgs.coreutils}/bin/base64 > /run/managed-token
        '';
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
      };
    }
    // lib.genAttrs [ "nixploy-update-demo" "nixploy-update-managed" ] (_: {
      environment = {
        GIT_CONFIG_COUNT = "1";
        GIT_CONFIG_KEY_0 = "url.file:///srv/app.insteadOf";
        GIT_CONFIG_VALUE_0 = "https://fixture.invalid/app.git";
      };
    });
    # Do not let polling mask missing or dropped webhook deliveries in this test.
    systemd.timers = lib.genAttrs [ "nixploy-update-demo" "nixploy-update-managed" ] (_: {
      timerConfig.OnBootSec = lib.mkForce "1h";
    });
  };
  testScript = ''
    start_all()
    machine.wait_for_unit("nixploy-webhooks.service")
    machine.wait_for_open_port(9070)
    machine.succeed("git init -b main /srv/app; git -C /srv/app config user.name fixture; git -C /srv/app config user.email fixture@example.invalid")
    machine.succeed("cp ${fixtureFlake} /srv/app/flake.nix; cp ${fixtureServer} /srv/app/server; chmod u+w /srv/app/server")
    machine.succeed("echo '{\"nodes\":{\"root\":{}},\"root\":\"root\",\"version\":7}' > /srv/app/flake.lock")
    machine.succeed("git -C /srv/app add .; git -C /srv/app commit -m initial")
    machine.succeed("umask 077; nixploy deploy-hook token show demo > /run/demo-token; echo incorrect > /run/wrong-token")

    def post(app="demo", token="/run/demo-token"):
        return int(machine.succeed(f"python ${client} {app} {token}").strip())

    assert post(token="-") == 401
    assert post(token="/run/wrong-token") == 401
    assert post(app="managed") == 401
    assert post(app="missing") == 404
    machine.fail("test -e /var/lib/nixploy/demo/profile")
    machine.fail("su -s /bin/sh nixploy-demo -c 'cat /var/lib/nixploy-webhooks/tokens/demo.token'")
    machine.fail("su -s /bin/sh _nixploy-webhooks -c 'cat /var/lib/nixploy-webhooks/tokens/demo.token'")
    machine.succeed("test $(stat -c %a /var/lib/nixploy-webhooks/tokens/demo.token) = 600")
    assert post() == 202
    machine.wait_until_succeeds("grep -qx one /var/lib/demo/version")
    machine.wait_until_succeeds("jq -e '.active != null and .pending == null' /var/lib/nixploy/demo/state.json")

    # A second push and burst of requests during a build must queue one follow-up.
    machine.succeed("sed -i 's/echo one/echo two/' /srv/app/server; git -C /srv/app commit -am second")
    second = machine.succeed("git -C /srv/app rev-parse HEAD").strip()
    assert post() == 202
    machine.wait_until_succeeds(f"journalctl -u nixploy-update-demo.service | grep 'building revision {second}'")
    machine.succeed("sed -i 's/echo two/echo three/' /srv/app/server; git -C /srv/app commit -am third")
    for _ in range(4):
        assert post() == 202
    machine.succeed("test -f /var/lib/nixploy-webhooks/queue/demo")
    machine.wait_until_succeeds("grep -qx three /var/lib/demo/version")
    third = machine.succeed("git -C /srv/app rev-parse HEAD").strip()
    machine.wait_until_succeeds(f"jq -e '.active.revision == \"{third}\" and .pending == null' /var/lib/nixploy/demo/state.json")
    machine.wait_until_succeeds("test ! -e /var/lib/nixploy-webhooks/queue/demo")

    # Generated token survives receiver restart. Rotation invalidates its old value.
    machine.succeed("systemctl restart nixploy-webhooks.service; nixploy deploy-hook token show demo > /run/same-token; cmp /run/demo-token /run/same-token")
    machine.succeed("nixploy deploy-hook token rotate demo; nixploy deploy-hook token show demo > /run/new-token")
    machine.wait_for_open_port(9070)
    assert post() == 401
    assert post(token="/run/new-token") == 202
    assert post(app="managed", token="/run/managed-token") == 202
    machine.wait_until_succeeds("grep -qx three /var/lib/managed/version")
    machine.fail("nixploy deploy-hook token rotate managed")
    machine.fail("nixploy deploy-hook token show managed")
    machine.succeed("cp /run/managed-token /run/old-managed-token; head -c 32 /dev/urandom | base64 > /run/managed-token; systemctl restart nixploy-webhooks.service")
    machine.wait_for_open_port(9070)
    assert post(app="managed", token="/run/old-managed-token") == 401
    assert post(app="managed", token="/run/managed-token") == 202

    # Tokens must not appear in configuration, deployment state, or the journal.
    machine.succeed("journalctl -u nixploy-webhooks -u nixploy-webhook-tokens -u nixploy-update-demo > /run/hook-journal")
    machine.succeed("python - <<'PY'\nfrom pathlib import Path\ntokens = [Path(p).read_bytes().strip() for p in ['/run/demo-token', '/run/new-token', '/run/managed-token']]\nfor p in ['/etc/nixploy-webhooks.json', '/etc/nixploy/demo.json', '/var/lib/nixploy/demo/state.json', '/run/hook-journal']:\n    assert all(token not in Path(p).read_bytes() for token in tokens), p\nPY")

    # Accepted requests and generated tokens survive reboot before dispatch.
    machine.wait_until_succeeds("test $(systemctl show -p ActiveState --value nixploy-update-demo.service) = inactive")
    machine.succeed("systemctl stop nixploy-webhook-demo.path")
    machine.succeed("sed -i 's/echo three/echo four/' /srv/app/server; git -C /srv/app commit -am fourth")
    assert post(token="/run/new-token") == 202
    token_hash = machine.succeed("sha256sum /var/lib/nixploy-webhooks/tokens/demo.token")
    machine.shutdown()
    machine.start()
    machine.wait_for_unit("nixploy-webhooks.service")
    assert token_hash == machine.succeed("sha256sum /var/lib/nixploy-webhooks/tokens/demo.token")
    machine.wait_until_succeeds("grep -qx four /var/lib/demo/version")
    machine.wait_until_succeeds("jq -e '.pending == null' /var/lib/nixploy/demo/state.json")
  '';
}
