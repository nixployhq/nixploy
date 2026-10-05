{ lib, rustPlatform }:
rustPlatform.buildRustPackage {
  pname = "nixploy";
  version = "0.1.0";
  src = lib.cleanSourceWith {
    src = ../.;
    filter =
      path: type:
      let
        name = baseNameOf path;
      in
      name == "Cargo.toml"
      || name == "Cargo.lock"
      || name == "LICENSE"
      || name == "src"
      || lib.hasPrefix (toString ../src + "/") path;
  };
  cargoLock.lockFile = ../Cargo.lock;
  meta = {
    description = "Short-lived application deployment worker for NixOS";
    mainProgram = "nixploy";
    license = lib.licenses.mit;
    platforms = lib.platforms.unix;
  };
}
