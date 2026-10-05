# Build with nix build --impure --expr 'import ./examples/demo-vm.nix {
#   repository = "https://github.com/OWNER/REPO.git";
#   hostAddress = "127.0.0.1";
# }'
{
  repository,
  hostAddress ? "127.0.0.1",
  hostPort ? 8080,
}:
let
  nixploy = builtins.getFlake (toString ../.);
  nixpkgs = nixploy.inputs.nixpkgs;
in
(nixpkgs.lib.nixosSystem {
  system = "x86_64-linux";
  modules = [
    "${nixpkgs}/nixos/modules/virtualisation/qemu-vm.nix"
    ../nix/modules/nixploy.nix
    ({ ... }: {
      networking.hostName = "nixploy-demo";
      system.stateVersion = "26.05";
      virtualisation = {
        graphics = false;
        memorySize = 2048;
        cores = 2;
        diskSize = 8192;
        writableStoreUseTmpfs = false;
        forwardPorts = [
          {
            from = "host";
            host.address = hostAddress;
            host.port = hostPort;
            guest.port = 3000;
          }
        ];
      };
      networking.firewall.allowedTCPPorts = [ 3000 ];
      services.nixploy.apps.demo = {
        inherit repository;
        executable = "nixploy-demo";
        pollInterval = "15s";
        environment = {
          HOST = "0.0.0.0";
          PORT = "3000";
        };
      };
      # Include worker and app logs in the VM console for remote inspection.
      systemd.services.nixploy-update-demo.serviceConfig.StandardOutput = "journal+console";
      systemd.services.nixploy-update-demo.serviceConfig.StandardError = "journal+console";
      systemd.services.nixploy-app-demo.serviceConfig.StandardOutput = "journal+console";
      systemd.services.nixploy-app-demo.serviceConfig.StandardError = "journal+console";
    })
  ];
}).config.system.build.vm
