{
  description = "penance: GHC-Wasm-assisted dynamic Haskell/Nix build graph prototype";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    ghcWasm.url = "github:haskell-wasm/ghc-wasm-meta";
    haskellNix.url = "github:input-output-hk/haskell.nix";
  };

  outputs =
    {
      self,
      nixpkgs,
      ghcWasm,
      haskellNix,
    }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      forAllSystems = f: nixpkgs.lib.genAttrs systems f;

      pkgsFor = nixpkgs.lib.genAttrs systems (
        system:
        import nixpkgs {
          inherit system;
        }
      );

      # Single source for the benchmark package-set pins. The packages-section
      # proofs and the `nix run .#bench` env defaults both read these; the
      # committed snapshot fixture is named after the resolver.
      stackageResolver = "lts-24.41";
      hackageStateVarVersion = "1.2.2";
    in
    {
      lib = forAllSystems (
        system:
        let
          pkgs = pkgsFor.${system};
        in
        import ./nix/lib.nix {
          inherit pkgs;
          inherit (pkgs) lib;
          ifaceCanonicalizer = self.packages.${system}.ghcWasmIfaceCanonicalizer;
          penancePlanner = self.packages.${system}.plannerBin;
          repent = self.packages.${system}.repent;
        }
      );

      packages = import ./nix/harness/packages.nix {
        inherit
          self
          nixpkgs
          ghcWasm
          haskellNix
          forAllSystems
          pkgsFor
          stackageResolver
          hackageStateVarVersion
          ;
      };

      checks = import ./nix/harness/checks.nix {
        inherit
          self
          forAllSystems
          pkgsFor
          ;
      };

      apps = import ./nix/harness/apps.nix {
        inherit
          self
          forAllSystems
          pkgsFor
          stackageResolver
          hackageStateVarVersion
          ;
      };

      devShells = forAllSystems (
        system:
        let
          pkgs = pkgsFor.${system};
        in
        {
          default = pkgs.mkShell {
            inputsFrom = [
              self.packages.${system}.penanceBenchDevShell
            ];
            packages = [
              ghcWasm.packages.${system}.all_9_10
              pkgs.nix
            ];
          };
        }
      );
    };
}
