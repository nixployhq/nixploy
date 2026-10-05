{ modulesPath, ... }:
{
  imports = [ "${modulesPath}/virtualisation/qemu-vm.nix" ];

  virtualisation = {
    graphics = false;
    memorySize = 2048;
    cores = 2;
    diskSize = 8192;
    writableStoreUseTmpfs = false;
    forwardPorts = [
      {
        from = "host";
        host.address = "127.0.0.1";
        host.port = 8080;
        guest.port = 3000;
      }
    ];
  };

  # Show deployment progress in the VM console.
  systemd.services.nixploy-update-demo.serviceConfig = {
    StandardOutput = "journal+console";
    StandardError = "journal+console";
  };
}
