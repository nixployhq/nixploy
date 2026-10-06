{...}: {
  networking.hostName = "nixploy-demo";
  system.stateVersion = "26.05";

  services.nixploy.apps.demo = {
    repository = "https://github.com/nixployhq/demo.git";
    branch = "main";
    package = "default";
    executable = "nixploy-demo";
    pollInterval = "1min";
    environment = {
      HOST = "0.0.0.0";
      PORT = "3000";
    };
  };

  networking.firewall.allowedTCPPorts = [3000];
}
