{
  description = "NixOS deployment example using Nixploy";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixploy = {
      url = "github:nixployhq/nixploy";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { nixpkgs, nixploy, ... }: {
    nixosConfigurations.demo = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        nixploy.nixosModules.default
        ./configuration.nix
        ./vm.nix
      ];
    };
  };
}
