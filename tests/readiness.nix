{ pkgs }:
let
  fixtureFlake = pkgs.writeText "readiness-flake.nix" ''
    {
      outputs = { self }: {
        packages.${pkgs.stdenv.hostPlatform.system}.default = builtins.derivation {
          name = "readiness-fixture";
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
  fixtureServer = pkgs.writeText "readiness-server" ''
    #!${pkgs.python3}/bin/python3
    import http.server
    import os
    from pathlib import Path
    import time

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            with open("/var/lib/readiness/requests", "a") as log:
                log.write(self.path + "\n")
            mode = Path("/var/lib/readiness/mode").read_text().strip()
            if mode == "hang":
                time.sleep(30)
            status = 204 if mode == "ready" or self.path == "/ok" else 503
            if self.path not in ("/health", "/ok"):
                status = 404
            if mode == "redirect" and self.path == "/health":
                status = 302
            self.send_response(status)
            if status == 302:
                self.send_header("Location", "/ok")
            self.end_headers()

        def log_message(self, *args):
            pass

    http.server.ThreadingHTTPServer((os.environ["HOST"], int(os.environ["PORT"])), Handler).serve_forever()
  '';
in
pkgs.testers.runNixOSTest {
  name = "nixploy-readiness";
  nodes.machine = { lib, ... }: {
    imports = [ ../nix/modules/nixploy.nix ];
    virtualisation.memorySize = 2048;
    environment.systemPackages = [
      pkgs.git
      pkgs.jq
    ];
    system.extraDependencies = [
      pkgs.bashNonInteractive
      pkgs.coreutils
      pkgs.python3
      fixtureFlake
      fixtureServer
    ];
    nix.settings.substituters = lib.mkForce [ ];
    services.nixploy.apps.demo = {
      repository = "https://fixture.invalid/app.git";
      executable = "server";
      pollInterval = "1h";
      endpoint.port = 3000;
      readiness = {
        path = "/health";
        expectedStatus = 204;
        timeoutSeconds = 8;
        intervalSeconds = 1;
        requestTimeoutSeconds = 2;
      };
      # The probe must contact the app directly despite inherited proxy settings.
      environment.http_proxy = "http://127.0.0.1:9";
    };
    systemd.services.nixploy-app-demo.serviceConfig.StateDirectory = "readiness";
    systemd.services.nixploy-update-demo.environment = {
      GIT_CONFIG_COUNT = "1";
      GIT_CONFIG_KEY_0 = "url.file:///srv/app.insteadOf";
      GIT_CONFIG_VALUE_0 = "https://fixture.invalid/app.git";
    };
  };
  testScript = ''
    import json
    import time

    start_all()
    machine.wait_for_unit("multi-user.target")
    machine.succeed("systemctl stop nixploy-update-demo.timer nixploy-update-demo.service")
    machine.succeed("git init -b main /srv/app")
    machine.succeed("git -C /srv/app config user.name fixture")
    machine.succeed("git -C /srv/app config user.email fixture@example.invalid")
    machine.succeed("cp ${fixtureFlake} /srv/app/flake.nix; cp ${fixtureServer} /srv/app/server")
    machine.succeed("chmod u+w /srv/app/server")
    machine.succeed("echo '{\"nodes\":{\"root\":{}},\"root\":\"root\",\"version\":7}' > /srv/app/flake.lock")
    machine.succeed("git -C /srv/app add . && git -C /srv/app commit -m initial")
    machine.succeed("mkdir -p /var/lib/readiness; echo unhealthy > /var/lib/readiness/mode")

    def state():
        return json.loads(machine.succeed("cat /var/lib/nixploy/demo/state.json"))

    # A live process and open port are insufficient: the updater waits for HTTP readiness.
    machine.succeed("systemctl start --no-block nixploy-update-demo.service")
    machine.wait_until_succeeds("test $(systemctl show -p SubState --value nixploy-app-demo) = start-post")
    machine.wait_until_succeeds("test -s /var/lib/readiness/requests")
    assert state()["active"] is None
    assert state()["pending"] is not None
    machine.succeed("echo ready > /var/lib/readiness/mode")
    machine.wait_until_succeeds("jq -e '.active != null and .pending == null' /var/lib/nixploy/demo/state.json")
    machine.wait_for_unit("nixploy-app-demo.service")
    first = state()["active"]

    # No continuous probes once startup has completed.
    machine.succeed("echo unhealthy > /var/lib/readiness/mode")
    requests = machine.succeed("cat /var/lib/readiness/requests")
    time.sleep(2)
    assert requests == machine.succeed("cat /var/lib/readiness/requests")
    machine.succeed("systemctl is-active nixploy-app-demo")

    # A new revision that never becomes ready remains pending; the old release stays rooted.
    machine.succeed("echo '# second revision' >> /srv/app/server; git -C /srv/app commit -am second")
    started = time.monotonic()
    machine.fail("systemctl start nixploy-update-demo.service")
    assert time.monotonic() - started < 30
    machine.succeed("systemctl stop nixploy-app-demo.service")
    failed = state()
    assert failed["active"] == first
    assert failed["pending"] is not None
    assert failed["pending"]["output"] != first["output"]
    selected = machine.succeed("readlink /var/lib/nixploy/demo/profile").strip()
    assert selected == failed["pending"]["output"]
    machine.succeed("test $(find /var/lib/nixploy/demo/roots -type l | wc -l) -eq 2")
    machine.succeed("journalctl -u nixploy-app-demo | grep 'readiness probe failed'")

    # Retry the existing output with Git unavailable, without a new build or commit.
    machine.succeed("mv /srv/app /srv/offline; echo ready > /var/lib/readiness/mode")
    machine.succeed("systemctl start nixploy-update-demo.service")
    assert state()["pending"] is None
    assert state()["active"]["output"] == selected
    machine.succeed("test $(find /var/lib/nixploy/demo/roots -type l | wc -l) -eq 1")

    # Manual restarts are gated too, and redirects cannot hide an unready endpoint.
    machine.succeed("echo redirect > /var/lib/readiness/mode; truncate -s 0 /var/lib/readiness/requests")
    machine.fail("systemctl restart nixploy-app-demo.service")
    machine.succeed("systemctl stop nixploy-app-demo.service")
    assert "/ok" not in machine.succeed("cat /var/lib/readiness/requests")

    # Each hanging request is bounded, as is the entire startup window.
    machine.succeed("echo hang > /var/lib/readiness/mode; truncate -s 0 /var/lib/readiness/requests")
    started = time.monotonic()
    machine.fail("systemctl restart nixploy-app-demo.service")
    assert time.monotonic() - started < 15
    machine.succeed("systemctl stop nixploy-app-demo.service")
    assert len(machine.succeed("cat /var/lib/readiness/requests").splitlines()) >= 2
    machine.succeed("echo ready > /var/lib/readiness/mode; systemctl start nixploy-app-demo.service")
    machine.wait_for_unit("nixploy-app-demo.service")
  '';
}
