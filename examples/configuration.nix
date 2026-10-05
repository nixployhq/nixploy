# Import inputs.nixploy.nixosModules.default in your infrastructure flake.
{
  services.nixploy.apps.my-app = {
    repository = "git@github.com:your-org/your-app.git";
    branch = "main";
    package = "default";
    executable = "your-app";
    pollInterval = "1min";

    git = {
      privateKeyFile = "/run/secrets/app-deploy-key";
      knownHostsFile = "/etc/ssh/ssh_known_hosts";
    };

    environment = {
      HOST = "0.0.0.0";
      PORT = "3000";
    };
  };
}
