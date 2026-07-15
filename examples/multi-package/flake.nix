{
  description = "Two-package Penance project with independent shells";

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
      packages = forAllSystems (
        system:
        let
          inherit (projectFor system) packages;
        in
        {
          model = packages.example-model.components.lib;
          server = packages.example-server.components."exe:example-server";
          default = packages.example-server.components."exe:example-server";
        }
      );
      devShells = forAllSystems (
        system:
        let
          shells = (projectFor system).devShells.packages;
        in
        {
          model = shells.example-model;
          server = shells.example-server;
          default = shells.example-server;
        }
      );
    };
}
