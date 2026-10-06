{
  description = "Automatic application deployment for NixOS";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    # Source-only inputs used by integration checks, not imported by the module.
    sops-nix-tests = {
      url = "github:Mic92/sops-nix";
      flake = false;
    };
    agenix-tests = {
      url = "github:ryantm/agenix";
      flake = false;
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      sops-nix-tests,
      agenix-tests,
    }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
      moduleTests = import ./tests/module.nix { inherit nixpkgs; };
    in
    {
      nixosModules.default = import ./nix/modules/nixploy.nix;

      packages = forAllSystems (system: {
        default = nixpkgs.legacyPackages.${system}.callPackage ./nix/package.nix { };
      });

      devShells = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = pkgs.mkShell {
            packages = [
              pkgs.cargo
              pkgs.rustc
              pkgs.rustfmt
              pkgs.clippy
              pkgs.git
            ];
          };
        }
      );

      checks = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          worker = self.packages.${system}.default;
          module-interface =
            assert moduleTests;
            pkgs.runCommand "nixploy-module-interface" { } "touch $out";
        }
        // nixpkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
          lifecycle = import ./tests/vm.nix { inherit pkgs; };
          readiness = import ./tests/readiness.nix { inherit pkgs; };
          rollback = import ./tests/readiness.nix {
            inherit pkgs;
            rollback = true;
          };
          https-auth = import ./tests/https.nix { inherit pkgs; };
          secret-providers = import ./tests/secrets.nix {
            inherit pkgs;
            sopsSource = sops-nix-tests;
            ageSource = agenix-tests;
          };
        }
      );

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixfmt);
    };
}
