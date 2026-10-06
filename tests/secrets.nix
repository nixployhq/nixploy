{
  pkgs,
  sopsSource,
  ageSource,
}:
let
  prepare = pkgs.writeShellScript "prepare-secret-fixtures" ''
    set -eu
    umask 077
    state=/var/lib/secret-fixture
    mkdir -p "$state"
    if [ ! -f "$state/identity" ]; then
      ${pkgs.age}/bin/age-keygen -o "$state/identity" 2>/dev/null
    fi
    recipient=$(${pkgs.age}/bin/age-keygen -y "$state/identity")
    ${pkgs.openssl}/bin/openssl rand -hex 32 > /run/server-token
    printf 'APP_MESSAGE=%s\n' "$1" > "$state/app.env"
    ${pkgs.python3}/bin/python -c 'import json,pathlib; p=pathlib.Path("/var/lib/secret-fixture"); (p/"plain.json").write_text(json.dumps({"git-token":pathlib.Path("/run/server-token").read_text().strip(),"app-env":(p/"app.env").read_text()}))'
    ${pkgs.sops}/bin/sops --encrypt --age "$recipient" --input-type json --output-type json "$state/plain.json" > "$state/secrets.json"
    ${pkgs.age}/bin/age -r "$recipient" < /run/server-token > "$state/token.age"
    ${pkgs.age}/bin/age -r "$recipient" < "$state/app.env" > "$state/app-env.age"
    rm "$state/plain.json" "$state/app.env"
  '';
  fixtureFlake = pkgs.writeText "secret-fixture-flake.nix" ''
    {
      outputs = { self }: {
        packages.${pkgs.stdenv.hostPlatform.system}.default = builtins.derivation {
          name = "secret-fixture";
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
  fixtureApp = pkgs.writeText "secret-fixture-app" ''
    #!${pkgs.runtimeShell}
    echo "one:$APP_MESSAGE" > "$VERSION_FILE"
    while true; do ${pkgs.coreutils}/bin/sleep 1; done
  '';
in
pkgs.testers.runNixOSTest {
  name = "nixploy-secret-providers";
  nodes.machine = { config, lib, ... }: {
    imports = [
      ../nix/modules/nixploy.nix
      "${sopsSource}/modules/sops"
      "${ageSource}/modules/age.nix"
    ];
    virtualisation.memorySize = 2048;
    systemd.sysusers.enable = true;
    environment.systemPackages = [
      pkgs.git
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

    # Generate dummy credentials inside the guest. Neither plaintext secrets nor
    # the age identity are part of the VM's Nix store or committed fixtures.
    systemd.services.secret-fixture = {
      wantedBy = [ "sysinit.target" ];
      after = [ "local-fs.target" ];
      before = [
        "agenix-install-secrets.service"
        "sops-install-secrets.service"
      ];
      unitConfig.DefaultDependencies = false;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${prepare} one";
      };
    };
    systemd.services.sops-install-secrets = {
      requires = [ "secret-fixture.service" ];
      after = [ "secret-fixture.service" ];
    };
    systemd.services.agenix-install-secrets = {
      requires = [ "secret-fixture.service" ];
      after = [ "secret-fixture.service" ];
    };
    sops = {
      # Test-only: encrypted files are generated at runtime, so build-time
      # validation cannot read them. Production examples use committed ciphertext.
      validateSopsFiles = false;
      defaultSopsFile = "/var/lib/secret-fixture/secrets.json";
      defaultSopsFormat = "json";
      age.keyFile = "/var/lib/secret-fixture/identity";
      age.sshKeyPaths = [ ];
      gnupg.sshKeyPaths = [ ];
      secrets = {
        git-token.mode = "0400";
        app-env = {
          mode = "0400";
          restartUnits = [ "nixploy-app-sops.service" ];
        };
      };
    };
    age = {
      identityPaths = [ "/var/lib/secret-fixture/identity" ];
      secrets = {
        git-token.file = "/var/lib/secret-fixture/token.age";
        app-env.file = "/var/lib/secret-fixture/app-env.age";
      };
    };
    services.nixploy.apps = lib.genAttrs [ "sops" "age" ] (name: {
      repository = "https://localhost/app.git";
      executable = "server";
      pollInterval = "2s";
      git.https = {
        username = "test-user";
        tokenFile =
          if name == "sops" then config.sops.secrets.git-token.path else config.age.secrets.git-token.path;
      };
      environment.VERSION_FILE = "/var/lib/${name}/version";
    });
    systemd.services.nixploy-app-sops.serviceConfig = {
      StateDirectory = "sops";
      EnvironmentFile = config.sops.secrets.app-env.path;
    };
    systemd.services.nixploy-app-age.serviceConfig = {
      StateDirectory = "age";
      EnvironmentFile = config.age.secrets.app-env.path;
    };
    systemd.services.nixploy-update-sops.environment.GIT_SSL_CAINFO = "/run/test-cert.pem";
    systemd.services.nixploy-update-age.environment.GIT_SSL_CAINFO = "/run/test-cert.pem";
    systemd.services.git-https-fixture = {
      serviceConfig.ExecStart = "${pkgs.python3}/bin/python ${./https-server.py} ${pkgs.git}/libexec/git-core/git-http-backend";
    };
  };
  testScript = ''
    start_all()
    machine.wait_for_unit("multi-user.target")
    for provider in ["sops", "age"]:
        machine.succeed(f"systemctl stop nixploy-update-{provider}.timer nixploy-update-{provider}.service")
    machine.wait_for_unit("sops-install-secrets.service")
    machine.wait_for_unit("agenix-install-secrets.service")
    machine.succeed("cmp /run/secrets/git-token /run/server-token || test $(cat /run/secrets/git-token) = $(cat /run/server-token)")
    machine.succeed("cmp /run/agenix/git-token /run/server-token")
    machine.succeed("${pkgs.openssl}/bin/openssl req -x509 -newkey rsa:2048 -noenc -keyout /run/test-cert-key.pem -out /run/test-cert.pem -days 1 -subj /CN=localhost -addext subjectAltName=DNS:localhost")
    machine.succeed("git init -b main /srv/git/app.git; git -C /srv/git/app.git config user.name fixture; git -C /srv/git/app.git config user.email fixture@example.invalid")
    machine.succeed("cp ${fixtureFlake} /srv/git/app.git/flake.nix; cp ${fixtureApp} /srv/git/app.git/server; chmod u+w /srv/git/app.git/server")
    machine.succeed("echo '{\"nodes\":{\"root\":{}},\"root\":\"root\",\"version\":7}' > /srv/git/app.git/flake.lock")
    machine.succeed("git -C /srv/git/app.git add .; git -C /srv/git/app.git commit -m initial; systemctl start git-https-fixture")
    machine.wait_for_open_port(443)
    for provider in ["sops", "age"]:
        machine.succeed(f"systemctl start nixploy-update-{provider}.service")
        machine.wait_until_succeeds(f"grep -qx one:one /var/lib/{provider}/version")
        secret_dir = "/run/secrets" if provider == "sops" else "/run/agenix"
        machine.fail(f"su -s /bin/sh nixploy-{provider} -c 'cat {secret_dir}/git-token'")
        machine.fail(f"su -s /bin/sh nixploy-{provider} -c 'cat {secret_dir}/app-env'")
    # Rotate encrypted files and let the actual providers replace their generations.
    machine.succeed("${prepare} two")
    machine.succeed("systemctl restart sops-install-secrets.service agenix-install-secrets.service agenix-chown.service")
    machine.wait_until_succeeds("grep -qx one:two /var/lib/sops/version")
    machine.succeed("systemctl restart nixploy-app-age.service")
    machine.wait_until_succeeds("grep -qx one:two /var/lib/age/version")
    machine.succeed("sed -i 's/one:/two:/' /srv/git/app.git/server; git -C /srv/git/app.git commit -am second")
    for provider in ["sops", "age"]:
        machine.succeed(f"systemctl start nixploy-update-{provider}.timer")
        machine.wait_until_succeeds(f"grep -qx two:two /var/lib/{provider}/version")
        machine.wait_until_succeeds(f"jq -e '.pending == null' /var/lib/nixploy/{provider}/state.json")
  '';
}
