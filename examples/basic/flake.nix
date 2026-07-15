{
  description = "Basic lock-backed Penance library";

  nixConfig.allow-import-from-derivation = false;

  inputs = {
    penance.url = "path:../..";
    nixpkgs.follows = "penance/nixpkgs";
  };

  outputs =
    { nixpkgs, penance, ... }:
    let
      systems = [
        "aarch64-darwin"
        "aarch64-linux"
        "x86_64-darwin"
        "x86_64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
      projectFor = system: penance.lib.${system}.penanceProject { src = ./.; };
    in
    {
      packages = forAllSystems (system: {
        default = (projectFor system).packages.simple-lib;
      });
      devShells = forAllSystems (system: {
        default = (projectFor system).devShells.packages.simple-lib;
        simple-lib = (projectFor system).devShells.packages.simple-lib;
      });
    };
}
