{
  description = "penance: Wasm-assisted dynamic Haskell/Nix build graph prototype";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    crane.url = "github:ipetkov/crane";
    haskellNix.url = "github:input-output-hk/haskell.nix";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, crane, haskellNix, rust-overlay }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      forAllSystems = f:
        builtins.listToAttrs (map
          (system: {
            name = system;
            value = f system;
          })
          systems);

      rustTargets = [
        "wasm32-unknown-unknown"
        "wasm32-wasip1"
      ];

      rustToolchainFor = p:
        p.rust-bin.stable."1.94.1".default.override {
          targets = rustTargets;
        };
    in
    {
      lib = forAllSystems (system:
        let
          pkgs = import nixpkgs { inherit system; };
        in
          import ./nix/lib.nix {
            inherit pkgs;
            inherit (pkgs) lib;
          });

      packages = forAllSystems (system:
        let
          pkgs = import nixpkgs {
            inherit system;
            overlays = [ (import rust-overlay) ];
          };
          haskellNixPkgs = import haskellNix.inputs.nixpkgs-unstable {
            inherit system;
            overlays = [ haskellNix.overlay ];
            inherit (haskellNix) config;
          };
          craneLib = (crane.mkLib pkgs).overrideToolchain rustToolchainFor;
          hpkgs = pkgs.haskell.packages.ghc9102 or pkgs.haskellPackages;
          simpleLibSrc = ./tests/fixtures/simple-lib;
          benchSrc = ./tests/bench/vs-haskell-nix/project;
          rustSrc = pkgs.lib.cleanSourceWith {
            src = ./wasm-planner;
            name = "penance-wasm-planner-source";
            filter = path: type:
              craneLib.filterCargoSources path type;
          };
          commonRustArgs = {
            pname = "penance-wasm-planner-native";
            version = "0.1.0";
            src = rustSrc;
            strictDeps = true;
          };

          wasmPlannerCargoArtifacts = craneLib.buildDepsOnly commonRustArgs;

          wasmPlannerNative = craneLib.buildPackage (commonRustArgs // {
            cargoArtifacts = wasmPlannerCargoArtifacts;
          });

          builtinRustArgs = commonRustArgs // {
            pname = "penance-wasm-planner-builtin";
            doCheck = false;
            CARGO_BUILD_TARGET = "wasm32-unknown-unknown";
            cargoExtraArgs = "--lib";
            nativeBuildInputs = [
              pkgs.rustc.llvmPackages.lld
            ];
          };

          wasmPlannerBuiltinArtifacts = craneLib.buildDepsOnly builtinRustArgs;

          wasmPlannerBuiltin = craneLib.buildPackage (builtinRustArgs // {
            cargoArtifacts = wasmPlannerBuiltinArtifacts;
            installPhase = ''
              runHook preInstall
              mkdir -p "$out"
              cp "target/wasm32-unknown-unknown/release/penance_wasm_planner.wasm" "$out/planner.wasm"
              runHook postInstall
            '';
          });

          wasiRustArgs = commonRustArgs // {
            pname = "penance-wasm-planner-wasi";
            doCheck = false;
            CARGO_BUILD_TARGET = "wasm32-wasip1";
          };

          wasmPlannerWasiArtifacts = craneLib.buildDepsOnly wasiRustArgs;

          wasmPlannerWasi = craneLib.buildPackage (wasiRustArgs // {
            cargoArtifacts = wasmPlannerWasiArtifacts;
            installPhase = ''
              runHook preInstall
              mkdir -p "$out"
              cp "target/wasm32-wasip1/release/normalize-project.wasm" "$out/planner.wasm"
              runHook postInstall
            '';
          });
          plannerBin = hpkgs.mkDerivation {
            pname = "penance-planner";
            version = "0.1.0.0";
            src = ./planner-bin;
            isLibrary = false;
            isExecutable = true;
            executableHaskellDepends = with hpkgs; [
              base
              directory
              filepath
            ];
            mainProgram = "penance-planner";
            license = pkgs.lib.licenses.mit;
          };
          penanceLib = import ./nix/lib.nix {
            inherit pkgs;
            inherit (pkgs) lib;
            plannerWasm = ./nix/planner.wasm;
            penancePlanner = plannerBin;
          };
          simpleLibComponent = (penanceLib.penanceProject {
            src = ./tests/fixtures/simple-lib;
            compiler = "ghc-9.10.2";
            index-state = "2026-04-01T00:00:00Z";
            mode = "component";
          }).drvGraph;
          backpackSignaturesModule = (penanceLib.penanceProject {
            src = ./tests/fixtures/backpack-signatures;
            compiler = "ghc-9.10.2";
            index-state = "2026-04-01T00:00:00Z";
            mode = "module";
          }).drvGraph;
          backpackMultiInstanceModule = (penanceLib.penanceProject {
            src = ./tests/fixtures/backpack-multi-instance;
            compiler = "ghc-9.10.2";
            index-state = "2026-04-01T00:00:00Z";
            mode = "module";
          }).drvGraph;
          penanceBenchComponent = (penanceLib.penanceProject {
            src = benchSrc;
            compiler = "ghc-9.10.3";
            index-state = "2026-02-01T00:00:00Z";
            mode = "component";
          }).drvGraph;
          penanceBenchModule = (penanceLib.penanceProject {
            src = benchSrc;
            compiler = "ghc-9.10.3";
            index-state = "2026-02-01T00:00:00Z";
            mode = "module";
          }).drvGraph;
          haskellNixSimpleProject = haskellNixPkgs.haskell-nix.cabalProject' {
            name = "simple-lib";
            src = haskellNixPkgs.haskell-nix.cleanSourceHaskell {
              name = "simple-lib-src";
              src = simpleLibSrc;
            };
            compiler-nix-name = "ghc910";
            index-state = "2026-04-01T00:00:00Z";
            cabalProject = builtins.readFile (simpleLibSrc + "/cabal.project");
            cabalProjectLocal = "";
            cabalProjectFreeze = "";
            configureArgs = "--disable-tests --disable-benchmarks";
          };
          haskellNixSimpleLib =
            haskellNixSimpleProject.hsPkgs."simple-lib".components.library;
          haskellNixBenchProject = haskellNixPkgs.haskell-nix.cabalProject' {
            name = "penance-bench";
            src = haskellNixPkgs.haskell-nix.cleanSourceHaskell {
              name = "penance-bench-src";
              src = benchSrc;
            };
            compiler-nix-name = "ghc910";
            index-state = "2026-02-01T00:00:00Z";
            cabalProject = builtins.readFile (benchSrc + "/cabal.project");
            cabalProjectLocal = "";
            cabalProjectFreeze = "";
            configureArgs = "--disable-tests --disable-benchmarks";
          };
          haskellNixBenchPackage = haskellNixBenchProject.hsPkgs."penance-bench";
          haskellNixBenchExe =
            haskellNixBenchPackage.components.exes."penance-bench";
          haskellNixBenchSurface =
            let
              packageName = haskellNixBenchPackage.identifier.name;
              packageVersion = haskellNixBenchPackage.identifier.version;
              libraryComponents =
                pkgs.lib.optional (haskellNixBenchPackage.components ? library) {
                  package = packageName;
                  component = "lib";
                  kind = "library";
                  unitId = haskellNixBenchPackage.components.library.identifier.unit-id;
                };
              sublibraryComponents =
                map
                  (name: {
                    package = packageName;
                    component = "lib:${name}";
                    kind = "library";
                    unitId = haskellNixBenchPackage.components.sublibs.${name}.identifier.unit-id;
                  })
                  (builtins.attrNames (haskellNixBenchPackage.components.sublibs or {}));
              executableComponents =
                map
                  (name: {
                    package = packageName;
                    component = "exe:${name}";
                    kind = "executable";
                    unitId = haskellNixBenchPackage.components.exes.${name}.identifier.unit-id;
                  })
                  (builtins.attrNames (haskellNixBenchPackage.components.exes or {}));
              testComponents =
                map
                  (name: {
                    package = packageName;
                    component = "test:${name}";
                    kind = "test-suite";
                    unitId = haskellNixBenchPackage.components.tests.${name}.identifier.unit-id;
                  })
                  (builtins.attrNames (haskellNixBenchPackage.components.tests or {}));
              benchmarkComponents =
                map
                  (name: {
                    package = packageName;
                    component = "bench:${name}";
                    kind = "benchmark";
                    unitId = haskellNixBenchPackage.components.benchmarks.${name}.identifier.unit-id;
                  })
                  (builtins.attrNames (haskellNixBenchPackage.components.benchmarks or {}));
            in
              pkgs.writeText "haskell-nix-bench-surface.json" (builtins.toJSON {
                source = "haskell.nix";
                packages = [{
                  name = packageName;
                  version = packageVersion;
                }];
                components =
                  libraryComponents
                  ++ sublibraryComponents
                  ++ executableComponents
                  ++ testComponents
                  ++ benchmarkComponents;
              });
        in
        {
          inherit
            backpackMultiInstanceModule
            backpackSignaturesModule
            haskellNixBenchExe
            haskellNixBenchSurface
            haskellNixSimpleLib
            plannerBin
            penanceBenchComponent
            penanceBenchModule
            simpleLibComponent
            wasmPlannerBuiltin
            wasmPlannerBuiltinArtifacts
            wasmPlannerCargoArtifacts
            wasmPlannerNative
            wasmPlannerWasi
            wasmPlannerWasiArtifacts
            ;
          default = wasmPlannerNative;
        });

      checks = forAllSystems (system:
        let
          pkgs = import nixpkgs { inherit system; };
        in
        {
          wasm-planner = self.packages.${system}.wasmPlannerNative;
          simple-lib-component = self.packages.${system}.simpleLibComponent;
          backpack-signatures-module = self.packages.${system}.backpackSignaturesModule;
          backpack-multi-instance-module = self.packages.${system}.backpackMultiInstanceModule;
          graph-plan-prototype = pkgs.runCommand "penance-graph-plan-prototype-check" {
            nativeBuildInputs = [ pkgs.jq ];
          } ''
            fixture=${self.packages.${system}.backpackMultiInstanceModule}

            test -f "$fixture/graph-plan.json"
            for root in $(${pkgs.jq}/bin/jq -r '.rootFiles[]' "$fixture/graph-plan.json"); do
              test -f "$fixture/$root"
            done

            ${pkgs.jq}/bin/jq -e '
              .kind == "graphPlan"
              and .status == "planned"
              and .rootFiles.packageGraph == "packages/package-graph.json"
              and (.packages | length) == 1
              and (.components | length) == 3
              and (.modules | length) == 3
              and (.backpack | length) == 4
            ' "$fixture/graph-plan.json" >/dev/null

            ${pkgs.jq}/bin/jq -e '
              .packages[0].package == "backpack-multi-instance"
              and (.packages[0].components | length) == 3
              and .packages[0].signatures == ["Data.MyAbstractMap"]
              and .packages[0].requiredSignatures == ["Data.MyAbstractMap"]
            ' "$fixture/packages/package-graph.json" >/dev/null

            ${pkgs.jq}/bin/jq -e '
              [.plannedDrvs[].kind] | sort == [
                "instantiationDrv",
                "instantiationDrv",
                "signatureDrv",
                "signatureTypecheckDrv"
              ]
            ' "$fixture/signatures/backpack-graph.json" >/dev/null

            for drv in $(${pkgs.jq}/bin/jq -r '.packages[].drvPlan, .components[].drvPlan, .modules[].drvPlan, .backpack[].drvPlan' "$fixture/graph-plan.json"); do
              test -f "$fixture/$drv"
            done

            touch "$out"
          '';
          bench-surface-parity = pkgs.runCommand "penance-bench-surface-parity" {
            nativeBuildInputs = [
              pkgs.diffutils
              pkgs.jq
              pkgs.perl
            ];
          } ''
            mkdir -p "$out"
            ${./scripts/validate-surface-parity.sh} \
              ${self.packages.${system}.penanceBenchModule} \
              ${self.packages.${system}.haskellNixBenchSurface} \
              ${./tests/bench/vs-haskell-nix/project/penance-bench.cabal} \
              "$out"
          '';
          architecture-suite-static = pkgs.runCommand "penance-architecture-suite-static" {
            nativeBuildInputs = [
              pkgs.bash
              pkgs.jq
            ];
          } ''
            bash -n ${./scripts/bench-architecture-phases.sh}
            jq -e '
              .schema == "penance/architecture-phase-matrix/1"
              and (.phases | length) >= 8
              and all(.phases[]; has("id") and has("milestone") and has("status") and has("required"))
              and all(.phases[]; .status as $status | ["comparison", "failing"] | index($status) != null)
              and all(.phases[] | select(.status == "comparison"); (.penanceAttr != null and .haskellNixAttr != null))
              and all(.phases[] | select(.status == "failing"); (.required == true and (.failure | type == "string")))
              and ([.phases[] | select(.status == "failing")] | length) >= 8
            ' ${./tests/architecture/phase-matrix.json} >/dev/null
            touch "$out"
          '';
          nix-format = pkgs.runCommand "penance-nix-parse-check" {} ''
            ${pkgs.nix}/bin/nix-instantiate --parse ${./flake.nix} >/dev/null
            ${pkgs.nix}/bin/nix-instantiate --parse ${./nix/lib.nix} >/dev/null
            ${pkgs.nix}/bin/nix-instantiate --parse ${./nix/shim.nix} >/dev/null
            ${pkgs.nix}/bin/nix-instantiate --parse ${./nix/planner-drv.nix} >/dev/null
            touch "$out"
          '';
        });

      apps = forAllSystems (system:
        let
          pkgs = import nixpkgs { inherit system; };
          benchVsHaskellNix = pkgs.writeShellApplication {
            name = "bench-vs-haskell-nix";
            runtimeInputs = [
              pkgs.coreutils
              pkgs.time
            ];
            text = ''
              if [ -x /nix/var/nix/profiles/default/bin/nix ]; then
                export PENANCE_NIX_BIN=''${PENANCE_NIX_BIN:-/nix/var/nix/profiles/default/bin/nix}
              fi
              exec ${./scripts/bench-vs-haskell-nix.sh} ${system} "$@"
            '';
          };
          benchArchitecturePhases = pkgs.writeShellApplication {
            name = "bench-architecture-phases";
            runtimeInputs = [
              pkgs.coreutils
              pkgs.jq
              pkgs.perl
            ];
            text = ''
              if [ -x /nix/var/nix/profiles/default/bin/nix ]; then
                export PENANCE_NIX_BIN=''${PENANCE_NIX_BIN:-/nix/var/nix/profiles/default/bin/nix}
              fi
              export PENANCE_PHASE_BENCH_OUT=''${PENANCE_PHASE_BENCH_OUT:-$(pwd -P)/docs/bench-results/architecture}
              exec ${./scripts/bench-architecture-phases.sh} \
                --flake ${self} \
                --matrix ${./tests/architecture/phase-matrix.json} \
                --system ${system} \
                "$@"
            '';
          };
          validateHackagePackage = pkgs.writeShellApplication {
            name = "validate-hackage-package";
            runtimeInputs = [
              pkgs.cabal-install
              pkgs.coreutils
              pkgs.findutils
              pkgs.gawk
              pkgs.jq
              pkgs.perl
            ];
            text = ''
              if [ -x /nix/var/nix/profiles/default/bin/nix ]; then
                export PENANCE_NIX_BIN=''${PENANCE_NIX_BIN:-/nix/var/nix/profiles/default/bin/nix}
              fi
              export PENANCE_REPO=''${PENANCE_REPO:-${self}}
              exec ${./scripts/validate-hackage-package.sh} "$@"
            '';
          };
          benchStackagePackage = pkgs.writeShellApplication {
            name = "bench-stackage-package";
            runtimeInputs = [
              pkgs.cabal-install
              pkgs.coreutils
              pkgs.curl
              pkgs.findutils
              pkgs.jq
              pkgs.perl
            ];
            text = ''
              if [ -x /nix/var/nix/profiles/default/bin/nix ]; then
                export PENANCE_NIX_BIN=''${PENANCE_NIX_BIN:-/nix/var/nix/profiles/default/bin/nix}
              fi
              export PENANCE_REPO=''${PENANCE_REPO:-${self}}
              exec ${./scripts/bench-stackage-package.sh} "$@"
            '';
          };
        in
        {
          bench-architecture-phases = {
            type = "app";
            program = "${benchArchitecturePhases}/bin/bench-architecture-phases";
          };
          bench-vs-haskell-nix = {
            type = "app";
            program = "${benchVsHaskellNix}/bin/bench-vs-haskell-nix";
          };
          bench-stackage-package = {
            type = "app";
            program = "${benchStackagePackage}/bin/bench-stackage-package";
          };
          validate-hackage-package = {
            type = "app";
            program = "${validateHackagePackage}/bin/validate-hackage-package";
          };
        });

      devShells = forAllSystems (system:
        let
          pkgs = import nixpkgs {
            inherit system;
            overlays = [ (import rust-overlay) ];
          };
          hpkgs = pkgs.haskell.packages.ghc9102 or pkgs.haskellPackages;
        in
        {
          default = pkgs.mkShell {
            packages = [
              pkgs.cabal-install
              (rustToolchainFor pkgs)
              hpkgs.ghc
              pkgs.nix
            ];
          };
        });
    };
}
