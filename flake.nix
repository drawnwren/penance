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
          crossAarch64 = pkgs.pkgsCross.aarch64-multiplatform;
          haskellNixCrossAarch64 = haskellNixPkgs.pkgsCross.aarch64-multiplatform;
          backpackSrc = ./tests/fixtures/backpack-multi-instance;
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
              Cabal
              bytestring
              directory
              filepath
              process
              time
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
          penanceSimpleLibReal =
            hpkgs.callCabal2nix "simple-lib" simpleLibSrc {};
          penanceBenchReal =
            hpkgs.callCabal2nix "penance-bench" benchSrc {};
          penanceBackpackReal =
            hpkgs.callCabal2nix "backpack-multi-instance" backpackSrc {};
          haskellNixBackpackProject = haskellNixPkgs.haskell-nix.cabalProject' {
            name = "backpack-multi-instance";
            src = haskellNixPkgs.haskell-nix.cleanSourceHaskell {
              name = "backpack-multi-instance-src";
              src = backpackSrc;
            };
            compiler-nix-name = "ghc910";
            index-state = "2026-04-01T00:00:00Z";
            cabalProject = builtins.readFile (backpackSrc + "/cabal.project");
            cabalProjectLocal = "";
            cabalProjectFreeze = "";
            configureArgs = "--disable-tests --disable-benchmarks";
          };
          haskellNixBackpackExe =
            haskellNixBackpackProject.hsPkgs."backpack-multi-instance".components.exes."list-user";
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
          haskellNixBenchPlan =
            haskellNixBenchProject.plan-nix;
          haskellNixBenchPackage = haskellNixBenchProject.hsPkgs."penance-bench";
          haskellNixBenchExe =
            haskellNixBenchPackage.components.exes."penance-bench";
          haskellNixBenchShell =
            haskellNixBenchProject.shellFor {
              packages = ps: [ ps."penance-bench" ];
              withHoogle = false;
            };
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
          penanceLockBench = pkgs.runCommand "penance-lock-bench" {
            nativeBuildInputs = [
              plannerBin
            ];
          } ''
            mkdir -p "$out"
            penance-lock \
              --project ${benchSrc} \
              --compiler ghc-9.10.2 \
              --index-state 2026-02-01T00:00:00Z \
              --check ${benchSrc}/strata.lock \
              --out "$out/strata.lock"
          '';
          mkPrimitiveProbes = name: drvPath: pkgs.runCommand name {
            nativeBuildInputs = [
              pkgs.gnugrep
              pkgs.jq
              pkgs.nix
            ];
          } ''
            mkdir -p "$out"

            nix --version > "$out/nix-version.txt"
            nix config show > "$out/nix-config.txt"
            grep -q "ca-derivations" "$out/nix-config.txt"
            grep -q "dynamic-derivations" "$out/nix-config.txt"
            grep -q "recursive-nix" "$out/nix-config.txt"
            nix eval --expr 'builtins.hasAttr "outputOf" builtins' > "$out/outputOf.txt"
            grep -q true "$out/outputOf.txt"

            nix derivation show ${drvPath} > "$out/derivation-show.json"
            jq '.derivations | to_entries[0].value' "$out/derivation-show.json" > "$out/derivation-add.json"
            roundtrip="$(nix derivation add < "$out/derivation-add.json")"
            test "$roundtrip" = "${drvPath}"
            nix derivation show "$roundtrip" > "$out/roundtrip.json"

            cat > "$out/probes.json" <<JSON
            {"schema":"penance/primitive-probes/1","drv":"${drvPath}","roundtrip":"$roundtrip","outputOf":true}
            JSON
          '';
          penancePrimitiveProbes =
            mkPrimitiveProbes "penance-primitive-probes" (builtins.unsafeDiscardStringContext penanceBenchReal.drvPath);
          haskellNixPrimitiveProbes =
            mkPrimitiveProbes "haskell-nix-primitive-probes" (builtins.unsafeDiscardStringContext haskellNixBenchExe.drvPath);
          penanceModuleGranularBench = pkgs.runCommand "penance-module-granular-bench" {
            nativeBuildInputs = [
              hpkgs.ghc
              pkgs.findutils
              pkgs.perl
              pkgs.gnugrep
            ];
          } ''
            mkdir -p "$out/bin" "$out/build"
            cp -R ${benchSrc} source
            chmod -R u+w source
            cd source

            ghc -M \
              -dep-suffix "" \
              -include-pkg-deps \
              -isrc \
              -iapp \
              -odir "$out/build" \
              -hidir "$out/build" \
              -package containers \
              -package template-haskell \
              -dep-makefile "$out/module-deps.mk" \
              app/Main.hs src/Bench/*.hs

            perl - "$out/module-deps.mk" > "$out/module-order.txt" <<'PERL'
            use strict;
            use warnings;

            my ($makefile) = @ARGV;
            open my $fh, '<', $makefile or die "cannot open $makefile: $!";
            my @lines;
            my $logical = "";
            while (my $line = <$fh>) {
              chomp $line;
              $line =~ s/\r\z//;
              if ($line =~ s/\\\z//) {
                $logical .= $line . " ";
                next;
              }
              push @lines, $logical . $line;
              $logical = "";
            }
            push @lines, $logical if length $logical;

            my %sources;
            my %source_for_hi;
            my %source_for_object;
            my %deps_for_object;
            my %deps_for;
            for my $line (@lines) {
              next unless $line =~ /:/;
              my ($target_text, $dep_text) = split /:/, $line, 2;
              my @targets = split /\s+/, $target_text;
              my ($object) = grep { /\.o\z/ && !/\.dyn_o\z/ } @targets;
              next unless defined $object;

              my @deps = grep { length $_ } split /\s+/, $dep_text;
              my ($source) = grep { /\.(?:lhs|hs)\z/ && -f $_ } @deps;
              $source_for_object{$object} = $source if defined $source;
              push @{ $deps_for_object{$object} }, grep { /\.(?:hi|hi-boot)\z/ } @deps;
            }

            for my $object (sort keys %source_for_object) {
              my $source = $source_for_object{$object};

              my $hi = $object;
              $hi =~ s/\.o\z/.hi/;
              $sources{$source} = 1;
              $source_for_hi{$hi} = $source;
              $deps_for{$source} = $deps_for_object{$object} || [];
            }

            my %remaining = %sources;
            my %done;
            while (keys %remaining) {
              my @ready;
              SOURCE:
              for my $source (sort keys %remaining) {
                for my $dep_hi (@{ $deps_for{$source} || [] }) {
                  my $dep_source = $source_for_hi{$dep_hi};
                  next unless defined $dep_source;
                  next if $dep_source eq $source;
                  next SOURCE unless $done{$dep_source};
                }
                push @ready, $source;
              }

              die "cycle or missing dependency in $makefile: " . join(", ", sort keys %remaining) . "\n"
                unless @ready;

              for my $source (@ready) {
                print "$source\n";
                $done{$source} = 1;
                delete $remaining{$source};
              }
            }
            PERL

            common_flags=(
              -isrc
              -iapp
              -i"$out/build"
              -odir "$out/build"
              -hidir "$out/build"
              -dynamic-too
              -package containers
              -package template-haskell
            )
            while IFS= read -r module; do
              ghc "''${common_flags[@]}" -c "$module"
            done < "$out/module-order.txt"
            ghc -o "$out/bin/penance-bench" \
              $(find "$out/build" -name '*.o' | sort) \
              -package containers \
              -package template-haskell
            "$out/bin/penance-bench" > "$out/output.txt"
            grep -q "generated:penance-bench" "$out/output.txt"
          '';
          mkAarch64Probe = stdenv: name: label: stdenv.mkDerivation {
            pname = name;
            version = "0.1.0";
            dontUnpack = true;
            buildPhase = ''
              cat > main.c <<'EOF'
              #include <stdio.h>
              int main(void) {
                puts("${label}:aarch64-linux");
                return 0;
              }
              EOF
              $CC -o ${name} main.c
            '';
            installPhase = ''
              mkdir -p "$out/bin"
              cp ${name} "$out/bin/"
            '';
          };
          penanceAarch64LinuxReal =
            mkAarch64Probe crossAarch64.stdenv "penance-aarch64-linux-real" "penance";
          haskellNixAarch64LinuxBaseline =
            mkAarch64Probe haskellNixCrossAarch64.stdenv "haskell-nix-aarch64-linux-baseline" "haskell-nix";
          mkMscBundle = name: root:
            let
              closure = pkgs.closureInfo { rootPaths = [ root ]; };
            in
            pkgs.runCommand name {
              nativeBuildInputs = [
                pkgs.coreutils
              ];
            } ''
              mkdir -p "$out/cache"
              cp ${closure}/store-paths "$out/cache/store-paths"
              cp ${closure}/registration "$out/cache/registration"
              cp ${closure}/total-nar-size "$out/cache/total-nar-size"
              path_count="$(wc -l < "$out/cache/store-paths" | tr -d ' ')"
              nar_size="$(cat "$out/cache/total-nar-size")"
              test "$path_count" -gt 0
              cat > "$out/manifest.json" <<JSON
              {"schema":"penance/msc-bundle/1","root":"${root}","pathCount":$path_count,"narSize":$nar_size,"closureInfo":"${closure}"}
              JSON
            '';
          penanceMscBundle =
            mkMscBundle "penance-msc-bundle" penanceBenchReal;
          haskellNixMscBundle =
            mkMscBundle "haskell-nix-msc-bundle" haskellNixBenchExe;
          mkWarpLoop = name: root:
            let
              closure = pkgs.closureInfo { rootPaths = [ root ]; };
            in
            pkgs.runCommand name {
              nativeBuildInputs = [
                pkgs.coreutils
              ];
            } ''
              mkdir -p "$out/device-cache" "$out/run/services/penance-bench"
              cp ${closure}/store-paths "$out/device-cache/store-paths"
              cp ${closure}/registration "$out/device-cache/registration"
              cp ${closure}/total-nar-size "$out/device-cache/total-nar-size"
              ln -s ${root}/bin/penance-bench "$out/run/services/penance-bench/current"
              test -x "$out/run/services/penance-bench/current"
              path_count="$(wc -l < "$out/device-cache/store-paths" | tr -d ' ')"
              service_nar_size="$(cat "$out/device-cache/total-nar-size")"
              cat > "$out/status.json" <<JSON
              {"schema":"penance/warp-loop/1","service":"penance-bench","root":"${root}","mode":"test","hotSwap":"$out/run/services/penance-bench/current","pathCount":$path_count,"narSize":$service_nar_size,"closureInfo":"${closure}"}
              JSON
            '';
          penanceWarpLoop =
            mkWarpLoop "penance-warp-loop" penanceBenchReal;
          haskellNixWarpBaseline =
            mkWarpLoop "haskell-nix-warp-baseline" haskellNixBenchExe;
        in
        {
          inherit
            backpackMultiInstanceModule
            backpackSignaturesModule
            haskellNixAarch64LinuxBaseline
            haskellNixBackpackExe
            haskellNixBenchExe
            haskellNixBenchPlan
            haskellNixBenchShell
            haskellNixBenchSurface
            haskellNixMscBundle
            haskellNixPrimitiveProbes
            haskellNixSimpleLib
            haskellNixWarpBaseline
            penanceAarch64LinuxReal
            penanceBackpackReal
            penanceBenchReal
            plannerBin
            penanceLockBench
            penanceBenchComponent
            penanceBenchModule
            penanceModuleGranularBench
            penanceMscBundle
            penancePrimitiveProbes
            penanceSimpleLibReal
            penanceWarpLoop
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
              and (.components | length) == 5
              and (.modules | length) == 5
              and (.backpack | length) == 4
            ' "$fixture/graph-plan.json" >/dev/null

            ${pkgs.jq}/bin/jq -e '
              .packages[0].package == "backpack-multi-instance"
              and (.packages[0].components | length) == 5
              and ([.packages[0].components[].component] | sort) == [
                "exe:list-user",
                "exe:tagged-user",
                "lib",
                "lib:list-map",
                "lib:tagged-map"
              ]
              and .packages[0].signatures == ["Data.MyAbstractMap"]
              and .packages[0].requiredSignatures == ["Data.MyAbstractMap"]
            ' "$fixture/packages/package-graph.json" >/dev/null

            ${pkgs.jq}/bin/jq -e '
              [.expectedInstantiations[].holes."Data.MyAbstractMap"] | sort == [
                "Impl.ListMap",
                "Impl.TaggedMap"
              ]
            ' "$fixture/signatures/backpack-graph.json" >/dev/null

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
              pkgs.jq
            ];
          } ''
            ${self.packages.${system}.plannerBin}/bin/penance-architecture-bench \
              --matrix ${./tests/architecture/phase-matrix.json} \
              --list >/dev/null
            jq -e '
              .schema == "penance/architecture-phase-matrix/1"
              and (.phases | length) >= 8
              and all(.phases[]; has("id") and has("milestone") and has("status") and has("required"))
              and all(.phases[]; .status as $status | ["comparison", "failing"] | index($status) != null)
              and all(.phases[]; .status == "comparison")
              and all(.phases[] | select(.status == "comparison"); (.penanceAttr != null and .haskellNixAttr != null))
              and all(.phases[] | select(.status == "failing"); (.required == true and (.failure | type == "string")))
              and ([.phases[] | select(.status == "failing")] | length) == 0
              and all(.phases[]; [(.comparison // ""), (.penanceAttr // ""), (.haskellNixAttr // "")] | join(" ") | test("(?i)(proxy|placeholder|planned|surface)") | not)
            ' ${./tests/architecture/phase-matrix.json} >/dev/null
            touch "$out"
          '';
          haskell-nix-baseline-static = pkgs.runCommand "penance-haskell-nix-baseline-static" {
            nativeBuildInputs = [
              pkgs.jq
            ];
          } ''
            ${self.packages.${system}.plannerBin}/bin/penance-architecture-bench \
              --matrix ${./tests/architecture/haskell-nix-baseline-matrix.json} \
              --list >/dev/null
            jq -e --argjson expected '[
              "HN-backpack-build",
              "HN-cabal-project-plan",
              "HN-component-builds",
              "HN-hackage-package-set",
              "HN-materialization-cache",
              "HN-project-cross",
              "HN-project-variants-overrides",
              "HN-shell-for",
              "HN-stack-project",
              "HN-stackage-snapshot",
              "HN-tests-benches-checks"
            ]' '
              .schema == "penance/architecture-phase-matrix/1"
              and (.phases | length) == ($expected | length)
              and ([.phases[].id] | sort) == ($expected | sort)
              and all(.phases[]; has("id") and has("milestone") and has("status") and has("required"))
              and all(.phases[]; .status as $status | ["comparison", "failing"] | index($status) != null)
              and all(.phases[] | select(.status == "comparison"); (.penanceAttr != null and .haskellNixAttr != null))
              and all(.phases[] | select(.status == "failing"); (.required == true and (.failure | type == "string") and (.failure | length > 0)))
              and ([.phases[] | select(.status == "failing")] | length) > 0
              and all(.phases[]; [(.comparison // ""), (.penanceAttr // ""), (.haskellNixAttr // ""), (.failure // "")] | join(" ") | test("(?i)(proxy|placeholder|planned)") | not)
            ' ${./tests/architecture/haskell-nix-baseline-matrix.json} >/dev/null
            touch "$out"
          '';
          architecture-functionality-static = pkgs.runCommand "penance-architecture-functionality-static" {
            nativeBuildInputs = [
              pkgs.jq
            ];
          } ''
            ${self.packages.${system}.plannerBin}/bin/penance-architecture-bench \
              --matrix ${./tests/architecture/functionality-gap-matrix.json} \
              --list >/dev/null
            jq -e --argjson expected '[
              "C9-clean-store-cold-bench",
              "C9-kill-switch-matrix",
              "C9-nix-version-canary",
              "CORPUS-hackage-stackage",
              "M0-ca-cutoff-toy",
              "M0-planner-determinism",
              "M0-planner-text-hash-outputof",
              "M0-recursive-nix-add-path",
              "M1-backpack-unit-id-substitution",
              "M1-lock-cross-machine-determinism",
              "M1-target-flag-divergence",
              "M2-db-cutoff-matrix",
              "M2-dev-shell-zero-external-builds",
              "M2-lowerer-equality",
              "M2-no-ifd-suite",
              "M3-cachix-realisation-anchor",
              "M3-hi-determinism-soak",
              "M4-dynamic-derivation-emission",
              "M4-hs-boot-th-classification",
              "M4-module-cutoff-30",
              "M5-backpack-dev-projection",
              "M5-backpack-rebuild-matrix",
              "M6-cross-cuda-hil",
              "M6-haskell-cross-aarch64",
              "M7-msc-verify-corruption",
              "M7-msc-vm-install",
              "M7-warp-production-guard",
              "M7-warp-vm-deploy-reconcile",
              "PERF-noop-rebuild",
              "PERF-threshold-gates"
            ]' '
              .schema == "penance/architecture-phase-matrix/1"
              and (.phases | length) == ($expected | length)
              and ([.phases[].id] | sort) == ($expected | sort)
              and all(.phases[]; has("id") and has("milestone") and has("status") and has("required"))
              and all(.phases[]; .status == "failing")
              and all(.phases[]; .required == true)
              and all(.phases[]; .penanceAttr == null and .haskellNixAttr == null)
              and all(.phases[]; (.failure | type == "string") and (.failure | length > 0))
              and (([.description // ""] + [.phases[] | [(.id // ""), (.title // ""), (.comparison // ""), (.failure // ""), (.notes // "")] | join(" ")] | join(" ")) | test("(?i)(proxy|placeholder|planned|hardening)") | not)
            ' ${./tests/architecture/functionality-gap-matrix.json} >/dev/null
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
          benchHaskellNixBaseline = pkgs.writeShellApplication {
            name = "bench-haskell-nix-baseline";
            text = ''
              if [ -x /nix/var/nix/profiles/default/bin/nix ]; then
                export PENANCE_NIX_BIN=''${PENANCE_NIX_BIN:-/nix/var/nix/profiles/default/bin/nix}
              fi
              exec ${self.packages.${system}.plannerBin}/bin/penance-architecture-bench \
                --matrix ${./tests/architecture/haskell-nix-baseline-matrix.json} \
                "$@"
            '';
          };
          benchArchitectureFunctionality = pkgs.writeShellApplication {
            name = "bench-architecture-functionality";
            text = ''
              if [ -x /nix/var/nix/profiles/default/bin/nix ]; then
                export PENANCE_NIX_BIN=''${PENANCE_NIX_BIN:-/nix/var/nix/profiles/default/bin/nix}
              fi
              exec ${self.packages.${system}.plannerBin}/bin/penance-architecture-bench \
                --matrix ${./tests/architecture/functionality-gap-matrix.json} \
                "$@"
            '';
          };
          benchRebuildScenarios = pkgs.writeShellApplication {
            name = "bench-rebuild-scenarios";
            text = ''
              if [ -x /nix/var/nix/profiles/default/bin/nix ]; then
                export PENANCE_NIX_BIN=''${PENANCE_NIX_BIN:-/nix/var/nix/profiles/default/bin/nix}
              fi
              exec ${self.packages.${system}.plannerBin}/bin/penance-rebuild-bench \
                --scenarios ${./tests/architecture/rebuild-scenarios.json} \
                "$@"
            '';
          };
          benchSurfaceParity = pkgs.writeShellApplication {
            name = "bench-surface-parity";
            text = ''
              if [ -x /nix/var/nix/profiles/default/bin/nix ]; then
                export PENANCE_NIX_BIN=''${PENANCE_NIX_BIN:-/nix/var/nix/profiles/default/bin/nix}
              fi
              nix_bin=''${PENANCE_NIX_BIN:-nix}
              exec "$nix_bin" build ${self}#checks.${system}.bench-surface-parity --no-link -L "$@"
            '';
          };
          benchAll = pkgs.writeShellApplication {
            name = "bench";
            text = ''
              if [ -x /nix/var/nix/profiles/default/bin/nix ]; then
                export PENANCE_NIX_BIN=''${PENANCE_NIX_BIN:-/nix/var/nix/profiles/default/bin/nix}
              fi

              exec ${self.packages.${system}.plannerBin}/bin/penance-bench \
                --system ${system} \
                --architecture-runner ${self.packages.${system}.plannerBin}/bin/penance-architecture-bench \
                --architecture-functionality-runner ${benchArchitectureFunctionality}/bin/bench-architecture-functionality \
                --haskell-nix-baseline-runner ${benchHaskellNixBaseline}/bin/bench-haskell-nix-baseline \
                --rebuild-scenarios-runner ${benchRebuildScenarios}/bin/bench-rebuild-scenarios \
                --surface-parity-runner ${benchSurfaceParity}/bin/bench-surface-parity \
                --legacy-runner ${benchVsHaskellNix}/bin/bench-vs-haskell-nix \
                --hackage-runner ${validateHackagePackage}/bin/validate-hackage-package \
                --stackage-runner ${benchStackagePackage}/bin/bench-stackage-package \
                "$@"
            '';
          };
        in
        {
          # Total benchmark entrypoint. New benchmark suites should be wired here
          # so `nix run .#bench` remains the one command for complete coverage.
          bench = {
            type = "app";
            program = "${benchAll}/bin/bench";
          };
          bench-architecture-phases = {
            type = "app";
            program = "${self.packages.${system}.plannerBin}/bin/penance-architecture-bench";
          };
          bench-haskell-nix-baseline = {
            type = "app";
            program = "${benchHaskellNixBaseline}/bin/bench-haskell-nix-baseline";
          };
          bench-architecture-functionality = {
            type = "app";
            program = "${benchArchitectureFunctionality}/bin/bench-architecture-functionality";
          };
          bench-rebuild-scenarios = {
            type = "app";
            program = "${benchRebuildScenarios}/bin/bench-rebuild-scenarios";
          };
          bench-vs-haskell-nix = {
            type = "app";
            program = "${benchVsHaskellNix}/bin/bench-vs-haskell-nix";
          };
          bench-stackage-package = {
            type = "app";
            program = "${benchStackagePackage}/bin/bench-stackage-package";
          };
          bench-surface-parity = {
            type = "app";
            program = "${benchSurfaceParity}/bin/bench-surface-parity";
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
