{ pkgs }:
let
  fixtureFlake = pkgs.writeText "fixture-flake.nix" ''
    {
      outputs = { self }: {
        packages.${pkgs.stdenv.hostPlatform.system}.default = builtins.derivation {
          name = "nixploy-fixture";
          system = "${pkgs.stdenv.hostPlatform.system}";
          # Generated store-path strings need context to become sandbox inputs.
          builder = builtins.appendContext "${pkgs.runtimeShell}" {
            "${pkgs.bashNonInteractive}" = { path = true; };
            "${pkgs.coreutils}" = { path = true; };
          };
          # Keep Bash as the builder until exit: tail-exec of a coreutils command
          # can close the log pipe before process exit, triggering Nix cleanup.
          args = [ "-ec" "${pkgs.coreutils}/bin/mkdir -p $out/bin; ${pkgs.coreutils}/bin/cp $src/server $out/bin/server; ${pkgs.coreutils}/bin/chmod +x $out/bin/server; exit 0" ];
          src = self.outPath;
        };
      };
    }
  '';
  fixtureServer = pkgs.writeText "fixture-server" ''
    #!${pkgs.runtimeShell}
    echo one > "$VERSION_FILE"
    while true; do ${pkgs.coreutils}/bin/sleep 1; done
  '';
in
pkgs.testers.runNixOSTest {
  name = "nixploy-lifecycle";
  nodes.machine = { lib, ... }: {
    imports = [ ../nix/modules/nixploy.nix ];
    virtualisation.memorySize = 2048;
    # Built outputs must survive the reboot, just as on a real deployment host.
    virtualisation.writableStoreUseTmpfs = false;
    environment.systemPackages = [
      pkgs.git
      pkgs.jq
      pkgs.openssh
    ];
    system.extraDependencies = [
      pkgs.bashNonInteractive
      pkgs.coreutils
      fixtureFlake
      fixtureServer
    ];
    nix.settings.substituters = lib.mkForce [ ];
    services.nixploy.apps.demo = {
      repository = "https://fixture.invalid/app.git";
      executable = "server";
      pollInterval = "2s";
      environment.VERSION_FILE = "/var/lib/demo/version";
    };
    services.openssh = {
      enable = true;
      settings.PasswordAuthentication = false;
      settings.PermitRootLogin = "prohibit-password";
    };
    services.nixploy.apps.ssh-demo = {
      repository = "ssh://root@localhost/srv/app";
      executable = "server";
      git.privateKeyFile = "/run/nixploy-test-key";
      git.knownHostsFile = "/run/nixploy-test-hosts";
      environment.VERSION_FILE = "/var/lib/ssh-demo/version";
    };
    systemd.services.nixploy-app-ssh-demo.serviceConfig.StateDirectory = "ssh-demo";
    systemd.services.nixploy-app-demo.serviceConfig = {
      StateDirectory = "demo";
      WorkingDirectory = "/var/lib/demo";
    };
    # Exercise real Git against a local fixture without an external network.
    systemd.services.nixploy-update-demo.environment = {
      GIT_CONFIG_COUNT = "1";
      GIT_CONFIG_KEY_0 = "url.file:///srv/app.insteadOf";
      GIT_CONFIG_VALUE_0 = "https://fixture.invalid/app.git";
    };
  };

  testScript = ''
    start_all()
    machine.wait_for_unit("multi-user.target")
    machine.succeed("systemctl stop nixploy-update-demo.timer")
    machine.succeed("systemctl stop nixploy-update-demo.service")
    machine.succeed("systemctl stop nixploy-update-ssh-demo.timer nixploy-update-ssh-demo.service")
    machine.fail("test -e /var/lib/nixploy/demo/profile")
    machine.fail("systemctl is-active nixploy-app-demo.service")

    machine.succeed("git init -b main /srv/app")
    machine.succeed("git -C /srv/app config user.name fixture")
    machine.succeed("git -C /srv/app config user.email fixture@example.invalid")
    machine.succeed("cp ${fixtureFlake} /srv/app/flake.nix")
    machine.succeed("cp ${fixtureServer} /srv/app/server")
    machine.succeed("chmod u+w /srv/app/flake.nix /srv/app/server")
    machine.succeed("echo '{\"nodes\":{\"root\":{}},\"root\":\"root\",\"version\":7}' > /srv/app/flake.lock")
    machine.succeed("git -C /srv/app add . && git -C /srv/app commit -m initial")

    machine.wait_for_unit("sshd.service")
    machine.succeed("ssh-keygen -t ed25519 -N \"\" -f /run/nixploy-test-key")
    machine.succeed("mkdir -p /root/.ssh && chmod 700 /root/.ssh")
    machine.succeed("cp /run/nixploy-test-key.pub /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys")
    machine.succeed("ssh-keyscan localhost > /run/nixploy-test-hosts")
    machine.succeed("systemctl start nixploy-update-ssh-demo.service")
    machine.wait_until_succeeds("grep -qx one /var/lib/ssh-demo/version")

    machine.succeed("systemctl start nixploy-update-demo.service")
    machine.wait_for_unit("nixploy-app-demo.service")
    machine.wait_until_succeeds("grep -qx one /var/lib/demo/version")
    first = machine.succeed("readlink /var/lib/nixploy/demo/profile").strip()
    pid = machine.succeed("systemctl show -p MainPID --value nixploy-app-demo").strip()
    machine.succeed("systemctl start nixploy-update-demo.service")
    assert pid == machine.succeed("systemctl show -p MainPID --value nixploy-app-demo").strip()
    machine.fail("su -s /bin/sh nixploy-demo -c 'touch /var/lib/nixploy/demo/forbidden'")
    machine.succeed("su -s /bin/sh nixploy-demo -c 'test -x /var/lib/nixploy/demo/profile/bin/server'")

    machine.succeed("sed -i 's/echo one/echo two/' /srv/app/server")
    machine.succeed("git -C /srv/app commit -am second")
    # Confirm that the timer, not just manual invocation, deploys a new commit.
    machine.succeed("systemctl start nixploy-update-demo.timer")
    machine.wait_until_succeeds("grep -qx two /var/lib/demo/version")
    machine.succeed("systemctl stop nixploy-update-demo.timer")
    machine.wait_until_succeeds("test $(systemctl show -p ActiveState --value nixploy-update-demo.service) = inactive")
    second = machine.succeed("readlink /var/lib/nixploy/demo/profile").strip()
    assert first != second
    machine.wait_until_succeeds("test $(find /var/lib/nixploy/demo/roots -type l | wc -l) -eq 1")
    machine.succeed(f"nix-store --query --roots {second} | grep /var/lib/nixploy/demo/roots/")

    machine.succeed("echo 'throw \"intentional failure\"' > /srv/app/flake.nix")
    machine.succeed("git -C /srv/app commit -am broken")
    pid = machine.succeed("systemctl show -p MainPID --value nixploy-app-demo").strip()
    machine.fail("systemctl start nixploy-update-demo.service")
    assert second == machine.succeed("readlink /var/lib/nixploy/demo/profile").strip()
    assert pid == machine.succeed("systemctl show -p MainPID --value nixploy-app-demo").strip()
    machine.succeed("nix-store --gc")
    machine.succeed(f"test -x {second}/bin/server")

    # A failed start stays pending and can be retried without a new Git commit.
    machine.succeed("cp ${fixtureFlake} /srv/app/flake.nix && chmod u+w /srv/app/flake.nix")
    machine.succeed("sed -i 's/echo two/echo three/' /srv/app/server")
    machine.succeed("git -C /srv/app commit -am third")
    machine.succeed("mkdir -p /run/systemd/system/nixploy-app-demo.service.d")
    machine.succeed("printf '[Service]\\nExecStartPre=/run/current-system/sw/bin/false\\n' > /run/systemd/system/nixploy-app-demo.service.d/fail.conf")
    machine.succeed("systemctl daemon-reload")
    machine.fail("systemctl start nixploy-update-demo.service")
    machine.succeed("jq -e '.pending != null' /var/lib/nixploy/demo/state.json")
    # Reboot removes the injected failure, and the timer recovers pending state.
    machine.shutdown()
    machine.start()
    machine.wait_for_unit("nixploy-app-demo.service")
    machine.wait_until_succeeds("grep -qx three /var/lib/demo/version")
    machine.wait_until_succeeds("jq -e '.pending == null' /var/lib/nixploy/demo/state.json")
    machine.wait_until_succeeds("test $(find /var/lib/nixploy/demo/roots -type l | wc -l) -eq 1")
  '';
}
