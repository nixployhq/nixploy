{ pkgs }:
let
  fixtureFlake = pkgs.writeText "https-fixture-flake.nix" ''
    {
      outputs = { self }: {
        packages.${pkgs.stdenv.hostPlatform.system}.default = builtins.derivation {
          name = "https-fixture";
          system = "${pkgs.stdenv.hostPlatform.system}";
          builder = builtins.appendContext "${pkgs.runtimeShell}" {
            "${pkgs.bashNonInteractive}" = { path = true; };
            "${pkgs.coreutils}" = { path = true; };
          };
          args = [ "-ec" "${pkgs.coreutils}/bin/mkdir -p $out/bin; ${pkgs.coreutils}/bin/cp $src/server $out/bin/server; ${pkgs.coreutils}/bin/chmod +x $out/bin/server; exit 0" ];
          src = self.outPath;
        };
      };
    }
  '';
  fixtureApp = pkgs.writeText "https-fixture-app" ''
    #!${pkgs.runtimeShell}
    echo one > "$VERSION_FILE"
    while true; do ${pkgs.coreutils}/bin/sleep 1; done
  '';
in
pkgs.testers.runNixOSTest {
  name = "nixploy-https";
  nodes.machine = { lib, ... }: {
    imports = [ ../nix/modules/nixploy.nix ];
    virtualisation.memorySize = 2048;
    environment.systemPackages = [
      pkgs.git
      pkgs.openssl
      pkgs.python3
      pkgs.jq
    ];
    system.extraDependencies = [
      pkgs.bashNonInteractive
      pkgs.coreutils
      fixtureFlake
      fixtureApp
    ];
    nix.settings.substituters = lib.mkForce [ ];
    services.nixploy.apps.demo = {
      repository = "https://localhost/app.git";
      executable = "server";
      git.https = {
        username = "test-user";
        tokenFile = "/run/client-token";
      };
      environment.VERSION_FILE = "/var/lib/demo/version";
    };
    systemd.services.nixploy-app-demo.serviceConfig.StateDirectory = "demo";
    systemd.services.nixploy-update-demo.environment.GIT_SSL_CAINFO = "/run/test-cert.pem";
    systemd.services.git-https-fixture = {
      serviceConfig.StandardError = "journal+console";
      serviceConfig.ExecStart = "${pkgs.python3}/bin/python ${./https-server.py} ${pkgs.git}/libexec/git-core/git-http-backend";
    };
  };
  testScript = ''
    start_all()
    machine.wait_for_unit("multi-user.target")
    machine.succeed("systemctl stop nixploy-update-demo.timer nixploy-update-demo.service")
    machine.succeed("openssl req -x509 -newkey rsa:2048 -noenc -keyout /run/test-cert-key.pem -out /run/test-cert.pem -days 1 -subj /CN=localhost -addext subjectAltName=DNS:localhost")
    machine.succeed("git init -b main /srv/git/app.git")
    machine.succeed("git -C /srv/git/app.git config user.name fixture; git -C /srv/git/app.git config user.email fixture@example.invalid")
    machine.succeed("cp ${fixtureFlake} /srv/git/app.git/flake.nix; cp ${fixtureApp} /srv/git/app.git/server; chmod u+w /srv/git/app.git/server")
    machine.succeed("echo '{\"nodes\":{\"root\":{}},\"root\":\"root\",\"version\":7}' > /srv/git/app.git/flake.lock")
    machine.succeed("git -C /srv/git/app.git add .; git -C /srv/git/app.git commit -m initial")
    machine.succeed("umask 077; openssl rand -hex 32 > /run/server-token; echo wrong-token > /run/client-token")
    machine.succeed("systemctl start git-https-fixture.service")
    machine.wait_for_open_port(443)
    # Wrong credentials fail without activating any package.
    machine.fail("systemctl start nixploy-update-demo.service")
    machine.fail("test -e /var/lib/nixploy/demo/profile")
    machine.succeed("cp /run/server-token /run/client-token")
    machine.succeed("systemctl start nixploy-update-demo.service")
    machine.wait_until_succeeds("grep -qx one /var/lib/demo/version")
    first = machine.succeed("readlink /var/lib/nixploy/demo/profile").strip()
    pid = machine.succeed("systemctl show -p MainPID --value nixploy-app-demo").strip()
    # Missing credentials cannot stop a running app.
    machine.succeed("mv /run/client-token /run/client-token.saved")
    machine.fail("systemctl start nixploy-update-demo.service")
    assert pid == machine.succeed("systemctl show -p MainPID --value nixploy-app-demo").strip()
    machine.succeed("mv /run/client-token.saved /run/client-token")
    # Refuse redirects, including redirects to another repo on the same host.
    machine.succeed("touch /run/redirect-enabled")
    machine.fail("systemctl start nixploy-update-demo.service")
    machine.fail("test -e /run/redirect-followed")
    machine.succeed("rm /run/redirect-enabled")
    # An invalid token preserves the old release even with a new commit available.
    machine.succeed("sed -i 's/echo one/echo two/' /srv/git/app.git/server; git -C /srv/git/app.git commit -am second")
    machine.succeed("echo expired-token > /run/client-token")
    machine.fail("systemctl start nixploy-update-demo.service")
    assert first == machine.succeed("readlink /var/lib/nixploy/demo/profile").strip()
    assert pid == machine.succeed("systemctl show -p MainPID --value nixploy-app-demo").strip()
    # A new token is loaded on the next invocation without rebuilding NixOS.
    machine.succeed("cp /run/server-token /run/old-token; openssl rand -hex 32 > /run/server-token; cp /run/server-token /run/client-token")
    machine.succeed("systemctl start nixploy-update-demo.service")
    machine.wait_until_succeeds("grep -qx two /var/lib/demo/version")
    second = machine.succeed("readlink /var/lib/nixploy/demo/profile").strip()
    assert first != second
    machine.succeed("jq -e '.pending == null' /var/lib/nixploy/demo/state.json")
    machine.fail("su -s /bin/sh nixploy-demo -c 'cat /run/client-token'")
    # Token values must not enter config, repository state, or journal output.
    machine.succeed("journalctl -u nixploy-update-demo.service > /run/update-journal")
    machine.succeed("python - <<'PY'\nfrom pathlib import Path\nsecrets = [Path(p).read_bytes().strip() for p in ['/run/old-token', '/run/server-token']]\npaths = [Path('/etc/nixploy/demo.json'), Path('/run/update-journal')] + list(Path('/var/lib/nixploy/demo').rglob('config')) + [Path('/var/lib/nixploy/demo/state.json')]\nfor path in paths:\n    data = path.read_bytes()\n    assert all(secret not in data for secret in secrets), str(path)\nPY")
  '';
}
