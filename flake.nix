{
  description = "penance: Wasm-assisted dynamic Haskell/Nix build graph prototype";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    ghcWasm.url = "github:haskell-wasm/ghc-wasm-meta";
    haskellNix.url = "github:input-output-hk/haskell.nix";
  };

  outputs = { self, nixpkgs, ghcWasm, haskellNix }:
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

      # Single source for the benchmark package-set pins. The packages-section
      # proofs and the `nix run .#bench` env defaults both read these; the
      # committed snapshot fixture is named after the resolver.
      stackageResolver = "lts-24.41";
      hackageStateVarVersion = "1.2.2";
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
          };
          haskellNixPkgs = import haskellNix.inputs.nixpkgs-unstable {
            inherit system;
            overlays = [ haskellNix.overlay ];
            inherit (haskellNix) config;
          };
          hpkgs = pkgs.haskell.packages.ghc9102 or pkgs.haskellPackages;
          benchHpkgs = pkgs.haskell.packages.ghc9103 or hpkgs;
          stripBin = "${pkgs.stdenv.cc.bintools.bintools}/bin/strip";
          writeMetadataJson = metadata: ''
            cat > "$out/metadata.json" <<'JSON'
            ${builtins.toJSON metadata}
            JSON
          '';
          assertCrossHelloElf = ''
            file "$out/bin/cross-hello" > "$out/file.txt"
            grep -E 'ELF.*(aarch64|ARM aarch64)' "$out/file.txt"
          '';
          crossAarch64 = pkgs.pkgsCross.aarch64-multiplatform;
          haskellNixCrossAarch64 = haskellNixPkgs.pkgsCross.aarch64-multiplatform;
          backpackSrc = ./tests/fixtures/backpack-multi-instance;
          crossHelloSrc = ./tests/fixtures/cross-hello;
          hsBootThSrc = ./tests/fixtures/hs-boot-th;
          lockExternalSrc = ./tests/fixtures/lock-external;
          moduleCutoff30Src = ./tests/fixtures/module-cutoff-30;
          simpleLibSrc = ./tests/fixtures/simple-lib;
          benchSrc = ./tests/bench/vs-haskell-nix/project;
          benchLock = builtins.fromJSON (builtins.readFile (benchSrc + "/strata.lock"));
          # Arc B seed: the module-granular prototype still invokes raw GHC,
          # but its external package flags come from the committed lock.
          benchGhcPackageNames =
            map (unit: unit.name)
              (builtins.filter
                (unit: unit.source == "ghc-boot" && unit.name != "base")
                benchLock.externalUnits);
          benchGhcPackageFlags =
            pkgs.lib.concatMapStringsSep " " (name: "-package ${name}") benchGhcPackageNames;
          benchDyndrvGhcFlags =
            [
              "-hide-all-packages"
              "-no-user-package-db"
              "-package"
              "base"
            ]
            ++ pkgs.lib.concatMap (name: [ "-package" name ]) benchGhcPackageNames
            ++ [
              "-O0"
              "-fomit-interface-pragmas"
              "-fignore-interface-pragmas"
              "-fhide-source-paths"
              "-fdiagnostics-color=never"
            ];
          benchDyndrvGhcFlagsText = pkgs.lib.concatStringsSep "\n" benchDyndrvGhcFlags;
          cutoff30DyndrvGhcFlags =
            [
              "-hide-all-packages"
              "-no-user-package-db"
              "-package"
              "base"
              "-O0"
              "-fomit-interface-pragmas"
              "-fignore-interface-pragmas"
              "-fhide-source-paths"
              "-fdiagnostics-color=never"
            ];
          cutoff30DyndrvGhcFlagsText = pkgs.lib.concatStringsSep "\n" cutoff30DyndrvGhcFlags;
          hsBootThDyndrvGhcFlags =
            [
              "-hide-all-packages"
              "-no-user-package-db"
              "-package"
              "base"
              "-package"
              "template-haskell"
              "-O0"
              "-fomit-interface-pragmas"
              "-fignore-interface-pragmas"
              "-fhide-source-paths"
              "-fdiagnostics-color=never"
            ];
          hsBootThDyndrvGhcFlagsText = pkgs.lib.concatStringsSep "\n" hsBootThDyndrvGhcFlags;
          crossHaskellCompilerName = "ghc910";
          crossHaskellCompilerAttr =
            haskellNixPkgs.haskell-nix.resolve-compiler-name crossHaskellCompilerName;
          crossHaskellTarget = "aarch64-unknown-linux-gnu";
          # The same Rts.hs fix must land in the hadrian input drv and in the
          # in-tree hadrian sources that GHC's own build uses.
          patchHadrianRtsRules = dir: ''
            substituteInPlace ${dir}/Rules/Rts.hs \
              --replace-fail 'when osxHost $ cmd' 'when (osxHost && libSuf == ".dylib") $ cmd'
          '';
          crossHaskellHadrianFor = ghc:
            ghc.hadrian.overrideAttrs (old: {
              postPatch = (old.postPatch or "") + patchHadrianRtsRules "src";
            });
          crossHaskellGhcFor = ghc:
            (ghc.override {
              useLLVM = true;
              libffi = null;
              ghcFlavour = "quickest+llvm";
              hadrian = crossHaskellHadrianFor ghc;
              enableProfiledLibs = false;
              enableDocs = false;
            }).overrideAttrs (old: {
              postPatch = (old.postPatch or "") + patchHadrianRtsRules "hadrian/src";
              hadrianFlags = (old.hadrianFlags or []) ++ [
                "*.*.ghc.*.opts += -I${haskellNixCrossAarch64.libffi.dev}/include"
              ];
            });
          haskellNixCompilerShapeFor = baseCompiler: ghc:
            haskellNixPkgs.haskell-nix.haskellLib.makeCompilerDeps
              (ghc.overrideAttrs (old: {
                passthru = (old.passthru or {}) // {
                  raw-src = baseCompiler.raw-src or baseCompiler.buildGHC.raw-src;
                  buildGHC = benchHpkgs.ghc;
                  targetPrefix = ghc.targetPrefix or "${crossHaskellTarget}-";
                  version = ghc.version or baseCompiler.version;
                };
              }));
          stackageStateVarSnapshot =
            ./tests/fixtures/stackage + "/${stackageResolver}-StateVar.yaml";
          stackageStateVarSnapshotUrl = "https://raw.githubusercontent.com/commercialhaskell/stackage-snapshots/master/lts/24/41.yaml";
          stackageStateVarSnapshotHash = "0309c4253d979705ab59973fd0c67e263e863ed7158bb4507f13165e46f20842";
          stackageStateVarSnapshotLine =
            let
              matches =
                builtins.filter
                  (line: pkgs.lib.hasPrefix "- hackage: StateVar-" line)
                  (pkgs.lib.splitString "\n" (builtins.readFile stackageStateVarSnapshot));
            in
              if matches == []
                then throw "StateVar is missing from ${stackageResolver} snapshot"
                else builtins.head matches;
          stackageStateVarVersion =
            builtins.head
              (pkgs.lib.splitString "@"
                (pkgs.lib.removePrefix "- hackage: StateVar-" stackageStateVarSnapshotLine));
          penanceStateVarHackageGhc =
            benchHpkgs.ghcWithPackages (ps: [
              (ps.callHackage "StateVar" hackageStateVarVersion {})
            ]);
          penanceStateVarStackageGhc =
            benchHpkgs.ghcWithPackages (ps: [
              (ps.callHackage "StateVar" stackageStateVarVersion {})
            ]);
          penanceBenchShellPackageNames =
            builtins.filter (name: name != "template-haskell") benchGhcPackageNames;
          penanceBenchShellGhc =
            benchHpkgs.ghcWithPackages
              (ps: map (name: ps.${name}) penanceBenchShellPackageNames);
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
          wasmPlannerNative = pkgs.runCommand "penance-wasm-planner-native-0.1.0" {
            meta = {
              mainProgram = "normalize-project";
              license = pkgs.lib.licenses.mit;
            };
          } ''
            mkdir -p "$out/bin"
            ln -s ${plannerBin}/bin/normalize-project "$out/bin/normalize-project"
            "$out/bin/normalize-project" --self-test
          '';
          wasmPlannerBuiltin = pkgs.runCommand "penance-wasm-planner-ghc-wasm-0.1.0" {
            nativeBuildInputs = [
              ghcWasm.packages.${system}.all_9_10
            ];
            meta.license = pkgs.lib.licenses.mit;
          } ''
            mkdir build "$out"
            wasm32-wasi-ghc \
              -O2 \
              -Wall \
              -i${./planner-bin/src} \
              -odir build \
              -hidir build \
              -optl-Wl,--allow-undefined \
              -o "$out/planner.wasm" \
              ${./planner-bin/src/WasmBuiltinMain.hs}
          '';
          # Determinate Nix consumes the GHC output through its WASI calling
          # convention, so the standalone and builtin artifacts are identical.
          wasmPlannerWasi = wasmPlannerBuiltin;
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
          penanceBenchLockProject = penanceLib.penanceProject {
            src = benchSrc;
            compiler = "ghc-9.10.2";
            index-state = "2026-02-01T00:00:00Z";
            mode = "component";
          };
          penanceBenchLibViaLock =
            penanceBenchLockProject.packages."penance-bench".components.lib;
          penanceBenchViaLock =
            penanceBenchLockProject.packages."penance-bench".components."exe:penance-bench";
          penanceBenchTestViaLock =
            penanceBenchLockProject.packages."penance-bench".components."test:penance-bench-test";
          penanceBenchBenchmarkViaLock =
            penanceBenchLockProject.packages."penance-bench".components."bench:penance-bench-benchmark";
          penanceBenchDevShell =
            penanceBenchLockProject.devShells.default;
          penanceBenchO0LockProject = penanceLib.penanceProject {
            src = benchSrc;
            compiler = "ghc-9.10.2";
            index-state = "2026-02-01T00:00:00Z";
            mode = "component";
            ghcOptions = [ "-O0" ];
          };
          penanceBenchO0ViaLock =
            penanceBenchO0LockProject.packages."penance-bench".components."exe:penance-bench";
          penanceSimpleLibLockProject = penanceLib.penanceProject {
            src = simpleLibSrc;
            compiler = "ghc-9.10.2";
            index-state = "2026-04-01T00:00:00Z";
            mode = "component";
          };
          penanceSimpleLibViaLock =
            penanceSimpleLibLockProject.packages."simple-lib".components.lib;
          penanceLockExternalProject = penanceLib.penanceProject {
            src = lockExternalSrc;
            compiler = "ghc-9.10.3";
            index-state = "2026-02-01T00:00:00Z";
            mode = "component";
          };
          penanceLockExternalViaLock =
            penanceLockExternalProject.packages."lock-external".components."exe:lock-external";
          mkPenanceModuleGranularBench = name:
            let
              core = pkgs.runCommand "${name}-core" {
                nativeBuildInputs = [
                  benchHpkgs.ghc
                  pkgs.findutils
                  pkgs.gnugrep
                  plannerBin
                ];
              } ''
              mkdir -p "$out/bin" build
              cp -R ${benchSrc} source
              chmod -R u+w source
              cd source

              dep_flags=(
                -dep-suffix ""
                -include-pkg-deps
                -isrc
                -iapp
                -odir ../build
                -hidir ../build
                ${benchGhcPackageFlags}
              )
              ghc -M "''${dep_flags[@]}" -dep-makefile "$out/module-deps.mk" app/Main.hs src/Bench/*.hs

              penance-plan module-order \
                --makefile "$out/module-deps.mk" \
                --out "$out/module-order.txt"
              penance-plan module-plan \
                --makefile "$out/module-deps.mk" \
                --lock strata.lock \
                --component exe:penance-bench \
                --out "$out/module-plan.json"

              common_flags=(
                -isrc
                -iapp
                -i../build
                -odir ../build
                -hidir ../build
                ${benchGhcPackageFlags}
              )
              : > "$out/compile-log.txt"
              while IFS= read -r module; do
                echo "$module" >> "$out/compile-log.txt"
                extra_flags=()
                if [ "$module" = "src/Bench/TH.hs" ]; then
                  extra_flags=(-dynamic-too)
                fi
                ghc "''${common_flags[@]}" "''${extra_flags[@]}" -c "$module"
              done < "$out/module-order.txt"
              ghc \
                -o "$out/bin/penance-bench" \
                $(find ../build -name '*.o' | sort) \
                ${benchGhcPackageFlags}
              ${stripBin} -x "$out/bin/penance-bench"

              "$out/bin/penance-bench" > "$out/output.txt"
              grep -q "generated:penance-bench" "$out/output.txt"
            '';
            in
              pkgs.runCommand name {} ''
                mkdir -p "$out/bin"
                ln -s ${core}/bin/penance-bench "$out/bin/penance-bench"
                cp ${core}/module-deps.mk "$out/module-deps.mk"
                cp ${core}/module-order.txt "$out/module-order.txt"
                cp ${core}/module-plan.json "$out/module-plan.json"
                cp ${core}/compile-log.txt "$out/compile-log.txt"
                cp ${core}/output.txt "$out/output.txt"
                "$out/bin/penance-bench" > "$out/output.txt.check"
                cmp ${core}/output.txt "$out/output.txt.check"
              '';
          # Shared verification tail for both sides of the
          # HN-tests-benches-checks comparison row: the row only measures
          # equivalent work if both sides run the same checks and emit the
          # same checks.json shape.
          runBenchChecks = testRef: benchmarkRef: ''
            "${testRef}" > "$out/test.out"
            "${benchmarkRef}" > "$out/benchmark.out"
            grep -q "rendered-bytes=" "$out/benchmark.out"

            cat > "$out/checks.json" <<JSON
            {"schema":"penance/tests-benches-checks/1","test":"${testRef}","benchmark":"${benchmarkRef}"}
            JSON
          '';
          penanceBenchChecks = pkgs.runCommand "penance-bench-checks" {} ''
            mkdir -p "$out"
            ${runBenchChecks
              "${penanceBenchTestViaLock}/bin/penance-bench-test"
              "${penanceBenchBenchmarkViaLock}/bin/penance-bench-benchmark"}
          '';
          # Shared proof program for the Hackage and Stackage StateVar lanes:
          # the comparison rows only measure equivalent work if both lanes
          # compile and run the same program.
          stateVarProofScript = proofName: ''
            cat > Main.hs <<'EOF'
            module Main where

            import Data.StateVar ()

            main :: IO ()
            main =
              putStrLn "${proofName}"
            EOF
            ghc Main.hs -o "$out/bin/${proofName}"
            "$out/bin/${proofName}" > "$out/output.txt"
          '';
          mkStateVarCompileProof = name: ghc: metadata: pkgs.runCommand name {
            nativeBuildInputs = [
              ghc
            ];
          } ''
            mkdir -p "$out/bin"
            ${stateVarProofScript "statevar-proof"}
            ${writeMetadataJson metadata}
          '';
          mkStackageStateVarCompileProof = name: ghc: metadata: pkgs.runCommand name {
            nativeBuildInputs = [
              ghc
              pkgs.coreutils
              pkgs.gawk
              pkgs.gnugrep
              pkgs.perl
            ];
          } ''
            mkdir -p "$out/bin"
            cp ${stackageStateVarSnapshot} "$out/snapshot.yaml"
            snapshot_hash="$(sha256sum "$out/snapshot.yaml" | awk '{print $1}')"
            test "$snapshot_hash" = "${stackageStateVarSnapshotHash}"
            perl -Mstrict -Mwarnings -e '
              my ($package, $snapshot) = @ARGV;
              open my $fh, "<", $snapshot or die "cannot open $snapshot: $!";
              while (my $line = <$fh>) {
                chomp $line;
                if ($line =~ /^- hackage: \Q$package\E-([0-9][^@\s]*)\@/) {
                  print "$package $1 $line\n";
                  exit 0;
                }
              }
              die "missing $package in $snapshot\n";
            ' StateVar "$out/snapshot.yaml" > "$out/snapshot-resolution.txt"
            resolved_version="$(awk '{print $2}' "$out/snapshot-resolution.txt")"
            test "$resolved_version" = "${stackageStateVarVersion}"
            ${stateVarProofScript "stackage-statevar-proof"}
            built_version="$(ghc-pkg field StateVar version --simple-output)"
            test "$built_version" = "$resolved_version"
            ${writeMetadataJson metadata}
          '';
          mkCrossHaskellCompileProof = name: ghc: metadata: pkgs.runCommand name {
            nativeBuildInputs = [
              ghc
              pkgs.file
              pkgs.gnugrep
            ];
          } ''
            mkdir -p "$out/bin" build
            cp -R ${crossHelloSrc} source
            chmod -R u+w source
            cd source

            if [ -x ${ghc}/bin/${crossHaskellTarget}-ghc ]; then
              cross_ghc=${ghc}/bin/${crossHaskellTarget}-ghc
            elif command -v ${crossHaskellTarget}-ghc >/dev/null 2>&1; then
              cross_ghc="$(command -v ${crossHaskellTarget}-ghc)"
            else
              echo "no ${crossHaskellTarget}-ghc on PATH" >&2
              exit 1
            fi

            "$cross_ghc" \
              -fllvm \
              -iapp \
              -outputdir ../build \
              -odir ../build \
              -hidir ../build \
              app/Main.hs \
              -o "$out/bin/cross-hello"

            ${assertCrossHelloElf}
            ${writeMetadataJson metadata}
          '';
          mkLibraryManifest = name: root: metadata: pkgs.runCommand name {
            nativeBuildInputs = [
              pkgs.findutils
            ];
          } ''
            mkdir -p "$out"
            test -e ${root}
            find ${root} -type f | sort > "$out/files.txt"
            test -s "$out/files.txt"
            ${writeMetadataJson metadata}
          '';
          mkPenanceShellProof = name: ghc: pkgs.runCommand name {
            nativeBuildInputs = [
              ghc
              pkgs.cabal-install
              pkgs.coreutils
              pkgs.findutils
              pkgs.gnugrep
            ];
          } ''
            mkdir -p "$out/bin" "$out/nix-support" build
            cp -R ${benchSrc} source
            chmod -R u+w source
            cd source
            export HOME="$TMPDIR/home"
            export CABAL_DIR="$TMPDIR/cabal"
            mkdir -p "$HOME" "$CABAL_DIR"
            cabal build all -v1 2>&1 | tee "$out/cabal-build.log"
            external_builds="$(grep -E 'Downloading|Building [a-z].*-[0-9]' "$out/cabal-build.log" | grep -vc 'penance-bench-0\.1\.0\.0' || true)"
            test "$external_builds" = 0
            exe="$(find dist-newstyle -type f -perm -0100 -name penance-bench | head -n 1)"
            test -n "$exe"
            cp "$exe" "$out/bin/shell-proof"
            "$out/bin/shell-proof" > "$out/output.txt"
            grep -q "generated:penance-bench" "$out/output.txt"
            ghc-pkg list ${pkgs.lib.concatStringsSep " " penanceBenchShellPackageNames} > "$out/package-db.txt"
            cabal --numeric-version > "$out/cabal-version.txt"
            cat > "$out/nix-support/penance-shell.json" <<'JSON'
            {"schema":"penance/dev-shell-proof/1","compiler":"ghc","packages":${builtins.toJSON penanceBenchShellPackageNames},"cabal":true,"externalBuilds":0}
            JSON
          '';
          mkVariantBundle = name: entries: pkgs.runCommand name {} (
            ''
              mkdir -p "$out/variants"
            ''
            + pkgs.lib.concatStringsSep "\n" (map
              (entry: ''
                ln -s ${entry.path} "$out/variants/${entry.name}"
                test -e "$out/variants/${entry.name}"
              '')
              entries)
            + ''
              cat > "$out/variants.json" <<'JSON'
              ${builtins.toJSON {
                schema = "penance/project-variants/1";
                variants = map (entry: entry.name) entries;
              }}
              JSON
            ''
          );
          penanceHackageStateVar =
            mkStateVarCompileProof "penance-hackage-StateVar-${hackageStateVarVersion}" penanceStateVarHackageGhc {
              schema = "penance/hackage-package-set/1";
              package = "StateVar";
              version = hackageStateVarVersion;
              source = "hackage";
            };
          penanceStackageStateVar =
            mkStackageStateVarCompileProof "penance-stackage-${stackageResolver}-StateVar" penanceStateVarStackageGhc {
              schema = "penance/stackage-snapshot/1";
              resolver = stackageResolver;
              package = "StateVar";
              version = stackageStateVarVersion;
              resolvedFrom = "tests/fixtures/stackage/${stackageResolver}-StateVar.yaml";
              snapshotUrl = stackageStateVarSnapshotUrl;
              source = "stackage-snapshots";
            };
          penanceBenchShell =
            mkPenanceShellProof "penance-bench-shell" penanceBenchShellGhc;
          penanceBackpackReal =
            let
              backpackCabal =
                pkgs.haskell.lib.dontHaddock
                (pkgs.haskell.lib.disableLibraryProfiling
                  (pkgs.haskell.lib.disableExecutableProfiling
                    (pkgs.haskell.lib.disableSharedLibraries
                      (hpkgs.callCabal2nix "backpack-multi-instance" backpackSrc {}))));
              backpackListUser = backpackCabal.overrideAttrs (_: {
                buildPhase = ''
                  runHook preBuild
                  ./Setup build exe:list-user
                  runHook postBuild
                '';
                installPhase = ''
                  runHook preInstall
                  mkdir -p "$out/bin" "$out/nix-support"
                  cp dist/build/list-user/list-user "$out/bin/list-user"
                  "$out/bin/list-user" > "$out/list-user.out"
                  grep -qx 0 "$out/list-user.out"
                  cat > "$out/nix-support/backpack.json" <<'JSON'
                  {"schema":"penance/backpack-real/1","package":"backpack-multi-instance","executable":"list-user","instantiation":"list-map"}
                  JSON
                  runHook postInstall
                '';
              });
            in
              pkgs.runCommand "penance-backpack-real" {} ''
                mkdir -p "$out/bin" "$out/nix-support"
                ln -s ${backpackListUser}/bin/list-user "$out/bin/list-user"
                "$out/bin/list-user" > "$out/list-user.out"
                grep -qx 0 "$out/list-user.out"
                cat > "$out/nix-support/backpack.json" <<'JSON'
                {"schema":"penance/backpack-real/1","package":"backpack-multi-instance","executable":"list-user","instantiation":"list-map","builder":"cabal-target-wrapper"}
                JSON
              '';
          penanceCrossHaskellGhc =
            crossHaskellGhcFor
              haskellNixCrossAarch64.buildPackages.haskell.compiler.${crossHaskellCompilerAttr};
          penanceHaskellAarch64LinuxReal =
            mkCrossHaskellCompileProof "penance-haskell-aarch64-linux-real" penanceCrossHaskellGhc {
              schema = "penance/haskell-cross/1";
              target = crossHaskellTarget;
              compiler = crossHaskellCompilerName;
              source = "raw-cross-ghc";
            };
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
          haskellNixModuleCutoff30Project = haskellNixPkgs.haskell-nix.cabalProject' {
            name = "module-cutoff-thirty";
            src = haskellNixPkgs.haskell-nix.cleanSourceHaskell {
              name = "module-cutoff-30-src";
              src = moduleCutoff30Src;
            };
            compiler-nix-name = "ghc910";
            index-state = "2026-04-01T00:00:00Z";
            cabalProject = builtins.readFile (moduleCutoff30Src + "/cabal.project");
            cabalProjectLocal = "";
            cabalProjectFreeze = "";
            configureArgs = "--disable-tests --disable-benchmarks";
          };
          haskellNixModuleCutoff30Exe =
            haskellNixModuleCutoff30Project.hsPkgs."module-cutoff-thirty".components.exes."module-cutoff-30";
          haskellNixHsBootThProject = haskellNixPkgs.haskell-nix.cabalProject' {
            name = "hs-boot-th";
            src = haskellNixPkgs.haskell-nix.cleanSourceHaskell {
              name = "hs-boot-th-src";
              src = hsBootThSrc;
            };
            compiler-nix-name = "ghc910";
            index-state = "2026-04-01T00:00:00Z";
            cabalProject = builtins.readFile (hsBootThSrc + "/cabal.project");
            cabalProjectLocal = "";
            cabalProjectFreeze = "";
            configureArgs = "--disable-tests --disable-benchmarks";
          };
          haskellNixHsBootThExe =
            haskellNixHsBootThProject.hsPkgs."hs-boot-th".components.exes."hs-boot-th";
          haskellNixHsBootThSmoke =
            pkgs.runCommand "haskell-nix-hs-boot-th-smoke" {} ''
              mkdir -p "$out/bin" "$out/nix-support"
              ln -s ${haskellNixHsBootThExe}/bin/hs-boot-th "$out/bin/hs-boot-th"
              "$out/bin/hs-boot-th" > "$out/output.txt"
              grep -q "hs-boot-th:42:dep-v1:splice:dep-v1:sibling" "$out/output.txt"
              cat > "$out/nix-support/hs-boot-th-smoke.json" <<'JSON'
              {"schema":"penance/hs-boot-th-smoke/1","source":"haskell.nix","executable":"hs-boot-th"}
              JSON
            '';
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
            configureArgs = "--enable-tests --enable-benchmarks";
          };
          haskellNixBenchMaterializedProject =
            haskellNixBenchProject.appendModule {
              materialized = haskellNixBenchProject.plan-nix;
            };
          haskellNixBenchPlan =
            haskellNixBenchProject.plan-nix;
          haskellNixBenchPlanMaterialized =
            haskellNixBenchMaterializedProject.plan-nix.outPath;
          haskellNixBenchPackage = haskellNixBenchProject.hsPkgs."penance-bench";
          haskellNixBenchExe =
            haskellNixBenchPackage.components.exes."penance-bench";
          haskellNixBenchTest =
            haskellNixBenchPackage.components.tests."penance-bench-test";
          haskellNixBenchBenchmark =
            haskellNixBenchPackage.components.benchmarks."penance-bench-benchmark";
          haskellNixBenchChecks = pkgs.runCommand "haskell-nix-bench-checks" {} ''
            mkdir -p "$out"

            test_bin="$(find ${haskellNixBenchTest}/bin -maxdepth 1 -type f -perm -0100 | head -n 1)"
            benchmark_bin="$(find ${haskellNixBenchBenchmark}/bin -maxdepth 1 -type f -perm -0100 | head -n 1)"
            test -n "$test_bin"
            test -n "$benchmark_bin"

            ${runBenchChecks "$test_bin" "$benchmark_bin"}
          '';
          haskellNixHackageStateVarPackage =
            haskellNixPkgs.haskell-nix.hackage-package {
              name = "StateVar";
              version = hackageStateVarVersion;
              compiler-nix-name = "ghc910";
              index-state = "2026-02-01T00:00:00Z";
            };
          haskellNixHackageStateVar =
            mkLibraryManifest "haskell-nix-hackage-StateVar-${hackageStateVarVersion}"
              haskellNixHackageStateVarPackage.components.library {
                schema = "penance/hackage-package-set/1";
                package = "StateVar";
                version = hackageStateVarVersion;
                source = "haskell.nix-hackage";
              };
          haskellNixStackageStateVar =
            mkLibraryManifest "haskell-nix-stackage-${stackageResolver}-StateVar"
              haskellNixPkgs.haskell-nix.snapshots.${stackageResolver}.StateVar.components.library {
                schema = "penance/stackage-snapshot/1";
                resolver = stackageResolver;
                package = "StateVar";
                version = stackageStateVarVersion;
                source = "haskell.nix-stackage";
              };
          haskellNixBenchShell =
            haskellNixBenchProject.shellFor {
              packages = ps: [ ps."penance-bench" ];
              withHoogle = false;
            };
          haskellNixBenchO0Project =
            haskellNixBenchProject.appendModule {
              modules = [{
                packages.penance-bench.components.exes.penance-bench.ghcOptions = [ "-O0" ];
              }];
            };
          haskellNixBenchO0Exe =
            haskellNixBenchO0Project.hsPkgs."penance-bench".components.exes."penance-bench";
          haskellNixCrossHelloProject = haskellNixPkgs.haskell-nix.cabalProject' {
            name = "cross-hello";
            src = haskellNixPkgs.haskell-nix.cleanSourceHaskell {
              name = "cross-hello-src";
              src = crossHelloSrc;
            };
            compiler-nix-name = crossHaskellCompilerName;
            index-state = "2026-02-01T00:00:00Z";
            cabalProject = builtins.readFile (crossHelloSrc + "/cabal.project");
            cabalProjectLocal = "";
            cabalProjectFreeze = "";
            configureArgs = "--disable-tests --disable-benchmarks";
            modules = [{
              packages.cross-hello.components.exes.cross-hello = {
                ghcOptions = [ "-fllvm" ];
                setupBuildFlags = pkgs.lib.mkForce [
                  "--ghc-option=-fllvm"
                  "--gcc-option=-fPIC"
                ];
              };
            }];
            compilerSelection = p:
              let
                baseCrossCompiler =
                  p.haskell-nix.compiler.${crossHaskellCompilerAttr}.override {
                    ghcEvalPackages = haskellNixPkgs.pkgsBuildBuild;
                  };
              in
              (builtins.mapAttrs (_: x: x.override {
                ghcEvalPackages = haskellNixPkgs.pkgsBuildBuild;
              }) p.haskell-nix.compiler) // {
                ${crossHaskellCompilerAttr} =
                  haskellNixCompilerShapeFor baseCrossCompiler penanceCrossHaskellGhc;
              };
          };
          haskellNixCrossHelloExe =
            haskellNixCrossHelloProject.projectCross.aarch64-multiplatform.hsPkgs."cross-hello".components.exes."cross-hello";
          mkCrossExecutableManifest = name: root: metadata: pkgs.runCommand name {
            nativeBuildInputs = [
              pkgs.file
              pkgs.findutils
              pkgs.gnugrep
            ];
          } ''
            mkdir -p "$out/bin"
            exe="$(find ${root}/bin -maxdepth 1 -type f -perm -0100 | head -n 1)"
            test -n "$exe"
            cp "$exe" "$out/bin/cross-hello"
            ${assertCrossHelloElf}
            ${writeMetadataJson metadata}
          '';
          haskellNixProjectCrossAarch64 =
            mkCrossExecutableManifest "haskell-nix-project-cross-aarch64" haskellNixCrossHelloExe {
              schema = "penance/haskell-cross/1";
              target = crossHaskellTarget;
              compiler = crossHaskellCompilerName;
              source = "haskell.nix-projectCross";
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
              pkgs.jq
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

            penance-lock \
              --project ${lockExternalSrc} \
              --compiler ghc-9.10.2 \
              --index-state 2026-02-01T00:00:00Z \
              --out "$out/lock-external-1.lock"
            penance-lock \
              --project ${lockExternalSrc} \
              --compiler ghc-9.10.2 \
              --index-state 2026-02-01T00:00:00Z \
              --out "$out/lock-external-2.lock"
            cmp "$out/lock-external-1.lock" "$out/lock-external-2.lock"
            cmp "$out/lock-external-1.lock" ${lockExternalSrc}/strata.lock
            cp "$out/lock-external-1.lock" "$out/lock-external.strata.lock"

            jq -e '
              .schema == "penance/strata-lock/1"
              and any(.externalUnits[]; .name == "StateVar" and .version == "1.2.2" and .source == "hackage" and (.sdist.sha256 | length > 0))
              and any(.externalUnits[]; .name == "base" and .source == "ghc-boot")
            ' "$out/lock-external.strata.lock" >/dev/null

            scratch="$(mktemp -d "$TMPDIR/lock-external-stale.XXXXXX")"
            trap 'rm -rf "$scratch"' EXIT
            cp -R ${lockExternalSrc}/. "$scratch/"
            chmod -R u+w "$scratch"
            sed -i 's/StateVar >=1\.2 && <1\.3/StateVar >=1.2 \&\& <1.3,\n    bytestring/' "$scratch/lock-external.cabal"
            if penance-lock \
              --project "$scratch" \
              --compiler ghc-9.10.2 \
              --index-state 2026-02-01T00:00:00Z \
              --check ${lockExternalSrc}/strata.lock \
              > "$out/stale-lock.log" 2>&1; then
              echo "penance-lock --check unexpectedly accepted a stale lock" >&2
              exit 1
            fi
          '';
          mkPrimitiveProbes = name: drvPath: pkgs.runCommand name {
            nativeBuildInputs = [
              pkgs.gnugrep
              pkgs.gnused
              pkgs.jq
              pkgs.nix
            ];
          } ''
            mkdir -p "$out"
            work="$(mktemp -d)"

            nix --version > "$out/nix-version.txt"
            nix config show > "$work/nix-config.txt"
            grep -q "ca-derivations" "$work/nix-config.txt"
            grep -q "dynamic-derivations" "$work/nix-config.txt"
            grep -q "recursive-nix" "$work/nix-config.txt"
            nix eval --expr 'builtins.hasAttr "outputOf" builtins' > "$out/outputOf.txt"
            grep -q true "$out/outputOf.txt"

            nix derivation show ${drvPath} > "$work/derivation-show.json"
            jq '.derivations | to_entries[0].value' "$work/derivation-show.json" > "$work/derivation-add.json"
            roundtrip="$(nix derivation add < "$work/derivation-add.json")"
            test "$roundtrip" = "${drvPath}"
            nix derivation show "$roundtrip" > "$work/roundtrip.json"

            for file in nix-config.txt derivation-show.json derivation-add.json roundtrip.json; do
              sed -E 's#/nix/store/[0-9a-z]{32}-[A-Za-z0-9._+?=-]+#<store-path>#g' "$work/$file" > "$out/$file"
            done
            drv_name="$(basename ${drvPath})"
            roundtrip_name="$(basename "$roundtrip")"

            cat > "$out/probes.json" <<JSON
            {"schema":"penance/primitive-probes/1","drv":"$drv_name","roundtrip":"$roundtrip_name","outputOf":true}
            JSON
          '';
          penancePrimitiveProbes =
            mkPrimitiveProbes "penance-primitive-probes" (builtins.unsafeDiscardStringContext penanceBenchViaLock.drvPath);
          haskellNixPrimitiveProbes =
            mkPrimitiveProbes "haskell-nix-primitive-probes" (builtins.unsafeDiscardStringContext haskellNixBenchExe.drvPath);
          probePlannerPayload = ./tests/probes/planner-payload.txt;
          probeAddPathPayload = ./tests/probes/add-path-payload.txt;
          probeDeterminismSalt =
            pkgs.lib.replaceStrings [ "\n" "\r" ] [ "" "" ]
              (builtins.readFile ./tests/probes/determinism-salt.txt);
          caCutoffToySrc = ./tests/probes/ca-cutoff-toy;
          mkPenanceProbePlanner = name:
            { corruptChildJson ? false
            , nondeterministic ? false
            , childName ? "penance-probe-planner"
            , plannerRunSalt ? ""
            , messageSuffix ? ""
            }:
            pkgs.runCommand name {
              __contentAddressed = true;
              outputHashMode = "text";
              outputHashAlgo = "sha256";
              requiredSystemFeatures = [ "recursive-nix" ];
              PENANCE_PROBE_PLANNER_SALT = plannerRunSalt;
            } ''
              set -euo pipefail
              export NIX_CONFIG="extra-experimental-features = nix-command flakes ca-derivations dynamic-derivations recursive-nix"
              nix_bin=/nix/var/nix/profiles/default/bin/nix
              message="$(cat ${probePlannerPayload})"
              ${if messageSuffix != "" then ''
                message="$message ${messageSuffix}"
              '' else ""}
              ${if nondeterministic then ''
                message="$message $RANDOM"
              '' else ""}
              child_json="$TMPDIR/penance-probe-child.json"
              case "$message" in
                *\"*|*\\*)
                  echo "probe payload contains characters not supported by the JSON emitter" >&2
                  exit 1
                  ;;
              esac

              ${if corruptChildJson then ''
                printf '{ "name": "${childName}", "outputs": ' > "$child_json"
              '' else ''
                draft_json="$TMPDIR/penance-probe-child-draft.json"
                child_err="$TMPDIR/penance-probe-child.err"
                cat > "$draft_json" <<JSON
              {
                "name": "${childName}",
                "system": "${system}",
                "builder": "${pkgs.bash}/bin/bash",
                "args": ["-euc", "printf \"%s\\\\n\" \"\$message\" > \"\$out\""],
                "env": {
                  "builder": "${pkgs.bash}/bin/bash",
                  "name": "${childName}",
                  "system": "${system}",
                  "message": "$message"
                },
                "inputs": {
                  "drvs": {
                    "${builtins.baseNameOf pkgs.bash.drvPath}": {
                      "dynamicOutputs": {},
                      "outputs": ["out"]
                    }
                  },
                  "srcs": []
                },
                "outputs": {"out": {}},
                "version": 4
              }
              JSON

                if "$nix_bin" derivation add < "$draft_json" > "$TMPDIR/unexpected-child-drv" 2> "$child_err"; then
                  echo "draft child JSON unexpectedly added without a canonical output path" >&2
                  exit 1
                fi
                child_out="$(sed -n "s/.*should be '\([^']*\)'.*/\1/p" "$child_err" | head -n 1)"
                test -n "$child_out"
                child_out_name="''${child_out#/nix/store/}"

              cat > "$child_json" <<JSON
              {
                "name": "${childName}",
                "system": "${system}",
                "builder": "${pkgs.bash}/bin/bash",
                "args": ["-euc", "printf \"%s\\\\n\" \"\$message\" > \"\$out\""],
                "env": {
                  "builder": "${pkgs.bash}/bin/bash",
                  "name": "${childName}",
                  "out": "$child_out",
                  "system": "${system}",
                  "message": "$message"
                },
                "inputs": {
                  "drvs": {
                    "${builtins.baseNameOf pkgs.bash.drvPath}": {
                      "dynamicOutputs": {},
                      "outputs": ["out"]
                    }
                  },
                  "srcs": []
                },
                "outputs": {"out": {"path": "$child_out_name"}},
                "version": 4
              }
              JSON
              ''}

              child_drv="$("$nix_bin" derivation add < "$child_json")"
              cp "$child_drv" "$out"
            '';
          mkPenanceAddPathPlanner = name:
            pkgs.runCommand name {
              __contentAddressed = true;
              outputHashMode = "text";
              outputHashAlgo = "sha256";
              requiredSystemFeatures = [ "recursive-nix" ];
            } ''
              set -euo pipefail
              export NIX_CONFIG="extra-experimental-features = nix-command flakes ca-derivations dynamic-derivations recursive-nix"
              nix_bin=/nix/var/nix/profiles/default/bin/nix
              payload="$(cat ${probeAddPathPayload})"
              case "$payload" in
                *\"*|*\\*)
                  echo "add-path probe payload contains characters not supported by the JSON emitter" >&2
                  exit 1
                  ;;
              esac

              added_source="$TMPDIR/penance-added-source.txt"
              printf "%s\n" "$payload" > "$added_source"
              added_path="$("$nix_bin" store add-path "$added_source")"
              added_name="''${added_path#/nix/store/}"
              draft_json="$TMPDIR/penance-add-path-child-draft.json"
              child_json="$TMPDIR/penance-add-path-child.json"
              child_err="$TMPDIR/penance-add-path-child.err"
              cat > "$draft_json" <<JSON
              {
                "name": "penance-add-path-planner",
                "system": "${system}",
                "builder": "${pkgs.bash}/bin/bash",
                "args": ["-euc", "IFS= read -r line < \"\$src\"; printf \"%s\\\\n\" \"\$line\" > \"\$out\""],
                "env": {
                  "builder": "${pkgs.bash}/bin/bash",
                  "name": "penance-add-path-planner",
                  "src": "$added_path",
                  "system": "${system}"
                },
                "inputs": {
                  "drvs": {
                    "${builtins.baseNameOf pkgs.bash.drvPath}": {
                      "dynamicOutputs": {},
                      "outputs": ["out"]
                    }
                  },
                  "srcs": ["$added_name"]
                },
                "outputs": {"out": {}},
                "version": 4
              }
              JSON

              if "$nix_bin" derivation add < "$draft_json" > "$TMPDIR/unexpected-add-path-child-drv" 2> "$child_err"; then
                echo "draft add-path child JSON unexpectedly added without a canonical output path" >&2
                exit 1
              fi
              child_out="$(sed -n "s/.*should be '\([^']*\)'.*/\1/p" "$child_err" | head -n 1)"
              test -n "$child_out"
              child_out_name="''${child_out#/nix/store/}"

              cat > "$child_json" <<JSON
              {
                "name": "penance-add-path-planner",
                "system": "${system}",
                "builder": "${pkgs.bash}/bin/bash",
                "args": ["-euc", "IFS= read -r line < \"\$src\"; printf \"%s\\\\n\" \"\$line\" > \"\$out\""],
                "env": {
                  "builder": "${pkgs.bash}/bin/bash",
                  "name": "penance-add-path-planner",
                  "out": "$child_out",
                  "src": "$added_path",
                  "system": "${system}"
                },
                "inputs": {
                  "drvs": {
                    "${builtins.baseNameOf pkgs.bash.drvPath}": {
                      "dynamicOutputs": {},
                      "outputs": ["out"]
                    }
                  },
                  "srcs": ["$added_name"]
                },
                "outputs": {"out": {"path": "$child_out_name"}},
                "version": 4
              }
              JSON

              child_drv="$("$nix_bin" derivation add < "$child_json")"
              cp "$child_drv" "$out"
            '';
          penanceProbePlanner =
            mkPenanceProbePlanner "penance-probe-planner.drv" {};
          penanceProbePlannerCorrupt =
            mkPenanceProbePlanner "penance-probe-planner-corrupt.drv" {
              corruptChildJson = true;
            };
          penanceProbePlannerNondeterministic =
            mkPenanceProbePlanner "penance-probe-planner-nondeterministic.drv" {
              childName = "penance-probe-planner-nondeterministic";
              nondeterministic = true;
            };
          penanceProbePlannerDeterminismA =
            mkPenanceProbePlanner "penance-probe-planner-determinism.drv" {
              childName = "penance-probe-planner-determinism";
              plannerRunSalt = "${probeDeterminismSalt}-a";
            };
          penanceProbePlannerDeterminismB =
            mkPenanceProbePlanner "penance-probe-planner-determinism.drv" {
              childName = "penance-probe-planner-determinism";
              plannerRunSalt = "${probeDeterminismSalt}-b";
            };
          penanceProbePlannerDeterminismBadA =
            mkPenanceProbePlanner "penance-probe-planner-determinism-bad.drv" {
              childName = "penance-probe-planner-determinism-bad";
              plannerRunSalt = "${probeDeterminismSalt}-bad-a";
              messageSuffix = "${probeDeterminismSalt}-bad-a";
            };
          penanceProbePlannerDeterminismBadB =
            mkPenanceProbePlanner "penance-probe-planner-determinism-bad.drv" {
              childName = "penance-probe-planner-determinism-bad";
              plannerRunSalt = "${probeDeterminismSalt}-bad-b";
              messageSuffix = "${probeDeterminismSalt}-bad-b";
            };
          penanceProbePlannerConsumer =
            let
              childOut =
                builtins.outputOf
                  (builtins.unsafeDiscardOutputDependency penanceProbePlanner.outPath)
                  "out";
            in
              pkgs.runCommand "penance-probe-planner-consumer" {} ''
                mkdir -p "$out"
                cp ${childOut} "$out/payload.txt"
                grep -q "hello dynamic child" "$out/payload.txt"
              '';
          penanceAddPathPlanner =
            mkPenanceAddPathPlanner "penance-add-path-planner.drv";
          penanceAddPathConsumer =
            let
              childOut =
                builtins.outputOf
                  (builtins.unsafeDiscardOutputDependency penanceAddPathPlanner.outPath)
                  "out";
            in
              pkgs.runCommand "penance-add-path-consumer" {} ''
                mkdir -p "$out"
                cp ${childOut} "$out/payload.txt"
                grep -q "hello recursive add-path" "$out/payload.txt"
              '';
          mkCaCutoffToy = srcRoot:
            let
              mkModule = moduleName: srcFile: depIfaces:
                pkgs.runCommand "penance-ca-toy-${moduleName}" {
                  __contentAddressed = true;
                  outputHashMode = "recursive";
                  outputHashAlgo = "sha256";
                  outputs = [ "out" "hi" "o" ];
                  nativeBuildInputs = [
                    pkgs.coreutils
                    pkgs.gnugrep
                    pkgs.gnused
                  ];
                } ''
                  set -euo pipefail
                  mkdir -p "$out" "$hi" "$o"
                  echo "penance-ca-toy-${moduleName}" > "$out/stamp"
                  cp ${srcFile} source.toy
                  grep '^decl:' source.toy | sed 's/[[:space:]]\+$//' > "$hi/interface.txt"
                  cat source.toy > "$o/object.txt"
                  ${pkgs.lib.concatMapStringsSep "\n" (depIface: ''
                    test -f ${depIface}/interface.txt
                    cat ${depIface}/interface.txt >> "$hi/interface.txt"
                    cat ${depIface}/interface.txt >> "$o/object.txt"
                  '') depIfaces}
                  echo "compiled penance-ca-toy-${moduleName}" >&2
                '';
            in
              rec {
                a = mkModule "A" (srcRoot + "/A.toy") [];
                b = mkModule "B" (srcRoot + "/B.toy") [ a.hi ];
                c = mkModule "C" (srcRoot + "/C.toy") [ b.hi ];
                link = pkgs.runCommand "penance-ca-toy-link" {
                  nativeBuildInputs = [
                    pkgs.coreutils
                  ];
                } ''
                  set -euo pipefail
                  mkdir -p "$out"
                  cat ${a.o}/object.txt ${b.o}/object.txt ${c.o}/object.txt > "$out/linked.txt"
                  echo "linked penance-ca-toy" >&2
                '';
              };
          penanceCaCutoffToyGraph =
            mkCaCutoffToy caCutoffToySrc;
          penanceCaCutoffToyA =
            penanceCaCutoffToyGraph.a;
          penanceCaCutoffToyB =
            penanceCaCutoffToyGraph.b;
          penanceCaCutoffToyC =
            penanceCaCutoffToyGraph.c;
          penanceCaCutoffToy =
            penanceCaCutoffToyGraph.link;
          penanceModuleGranularBench =
            mkPenanceModuleGranularBench "penance-module-granular-bench";
          mkPenanceBenchDyndrvPlanner = name:
            pkgs.runCommand name {
              __contentAddressed = true;
              outputHashMode = "text";
              outputHashAlgo = "sha256";
              requiredSystemFeatures = [ "recursive-nix" ];
              nativeBuildInputs = [
                benchHpkgs.ghc
                plannerBin
                pkgs.coreutils
                pkgs.findutils
                pkgs.nix
              ];
            } ''
              set -euo pipefail
              export NIX_CONFIG="extra-experimental-features = nix-command flakes ca-derivations dynamic-derivations recursive-nix"
              nix_bin=/nix/var/nix/profiles/default/bin/nix

              cp -R ${benchSrc} source
              chmod -R u+w source
              cd source

              dep_flags=(
                -dep-suffix ""
                -include-pkg-deps
                -isrc
                -iapp
                -odir ../make-build
                -hidir ../make-build
                ${benchGhcPackageFlags}
              )
              mkdir -p ../make-build
              ghc -M "''${dep_flags[@]}" -dep-makefile "$TMPDIR/module-deps.mk" app/Main.hs src/Bench/*.hs

              penance-plan module-plan \
                --makefile "$TMPDIR/module-deps.mk" \
                --lock strata.lock \
                --component exe:penance-bench \
                --out "$TMPDIR/module-plan.json"

              cat > "$TMPDIR/ghc-flags.txt" <<'FLAGS'
${benchDyndrvGhcFlagsText}
FLAGS

              penance-plan emit-bench-dyndrv \
                --module-plan "$TMPDIR/module-plan.json" \
                --src-root "$PWD" \
                --out "$TMPDIR/root.drv" \
                --system ${pkgs.lib.escapeShellArg system} \
                --nix-bin "$nix_bin" \
                --builder ${pkgs.lib.escapeShellArg "${pkgs.bash}/bin/bash"} \
                --path ${pkgs.lib.escapeShellArg (pkgs.lib.makeBinPath [
                  pkgs.bash
                  pkgs.coreutils
                  pkgs.findutils
                  pkgs.gnugrep
                  pkgs.perl
                  benchHpkgs.ghc
                ])} \
                --ghc-flags "$TMPDIR/ghc-flags.txt" \
                --bin-name penance-bench \
                --smoke generated:penance-bench \
                --tool-drv ${pkgs.lib.escapeShellArg (builtins.unsafeDiscardStringContext pkgs.bash.drvPath)} \
                --tool-drv ${pkgs.lib.escapeShellArg (builtins.unsafeDiscardStringContext benchHpkgs.ghc.drvPath)} \
                --tool-drv ${pkgs.lib.escapeShellArg (builtins.unsafeDiscardStringContext pkgs.coreutils.drvPath)} \
                --tool-drv ${pkgs.lib.escapeShellArg (builtins.unsafeDiscardStringContext pkgs.findutils.drvPath)} \
                --tool-drv ${pkgs.lib.escapeShellArg (builtins.unsafeDiscardStringContext pkgs.gnugrep.drvPath)} \
                --tool-drv ${pkgs.lib.escapeShellArg (builtins.unsafeDiscardStringContext pkgs.perl.drvPath)}
              cp "$TMPDIR/root.drv" "$out"
            '';
          penanceBenchDyndrvPlanner =
            mkPenanceBenchDyndrvPlanner "penance-bench-dyndrv-planner.drv";
          penanceBenchDyndrvPlannerRepeat =
            mkPenanceBenchDyndrvPlanner "penance-bench-dyndrv-planner-repeat.drv";
          penanceBenchDyndrv =
            let
              dyndrvOut =
                builtins.outputOf
                  (builtins.unsafeDiscardOutputDependency penanceBenchDyndrvPlanner.outPath)
                  "out";
            in
              pkgs.runCommand "penance-bench-dyndrv" {} ''
                mkdir -p "$out"
                cp -R ${dyndrvOut}/. "$out/"
                "$out/bin/penance-bench" > "$out/output.txt.check"
                cmp "$out/output.txt" "$out/output.txt.check"
                cmp ${penanceBenchViaLock}/output.txt "$out/output.txt"
              '';
          penanceDyndrvEmissionProof =
            pkgs.runCommand "penance-dyndrv-emission-proof" {
              requiredSystemFeatures = [ "recursive-nix" ];
              nativeBuildInputs = [
                benchHpkgs.ghc
                plannerBin
                pkgs.coreutils
                pkgs.diffutils
                pkgs.findutils
                pkgs.gnugrep
                pkgs.jq
                pkgs.nix
              ];
            } ''
              set -euo pipefail
              export NIX_CONFIG="extra-experimental-features = nix-command flakes ca-derivations dynamic-derivations recursive-nix"
              nix_bin=/nix/var/nix/profiles/default/bin/nix
              max_planner_ms=2000

              emit_root() {
                local label="$1"
                local root_out="$2"
                local work="$TMPDIR/$label"
                mkdir -p "$work"
                cp -R ${benchSrc} "$work/source"
                chmod -R u+w "$work/source"
                (
                  cd "$work/source"
                  dep_flags=(
                    -dep-suffix ""
                    -include-pkg-deps
                    -isrc
                    -iapp
                    -odir "$work/make-build"
                    -hidir "$work/make-build"
                    ${benchGhcPackageFlags}
                  )
                  mkdir -p "$work/make-build"
                  ghc -M "''${dep_flags[@]}" -dep-makefile "$work/module-deps.mk" app/Main.hs src/Bench/*.hs

                  penance-plan module-plan \
                    --makefile "$work/module-deps.mk" \
                    --lock strata.lock \
                    --component exe:penance-bench \
                    --out "$work/module-plan.json"

                  cat > "$work/ghc-flags.txt" <<'FLAGS'
${benchDyndrvGhcFlagsText}
FLAGS

                  penance-plan emit-bench-dyndrv \
                    --module-plan "$work/module-plan.json" \
                    --src-root "$PWD" \
                    --out "$root_out" \
                    --system ${pkgs.lib.escapeShellArg system} \
                    --nix-bin "$nix_bin" \
                    --builder ${pkgs.lib.escapeShellArg "${pkgs.bash}/bin/bash"} \
                    --path ${pkgs.lib.escapeShellArg (pkgs.lib.makeBinPath [
                      pkgs.bash
                      pkgs.coreutils
                      pkgs.findutils
                      pkgs.gnugrep
                      pkgs.perl
                      benchHpkgs.ghc
                    ])} \
                    --ghc-flags "$work/ghc-flags.txt" \
                    --bin-name penance-bench \
                    --smoke generated:penance-bench \
                    --tool-drv ${pkgs.lib.escapeShellArg (builtins.unsafeDiscardStringContext pkgs.bash.drvPath)} \
                    --tool-drv ${pkgs.lib.escapeShellArg (builtins.unsafeDiscardStringContext benchHpkgs.ghc.drvPath)} \
                    --tool-drv ${pkgs.lib.escapeShellArg (builtins.unsafeDiscardStringContext pkgs.coreutils.drvPath)} \
                    --tool-drv ${pkgs.lib.escapeShellArg (builtins.unsafeDiscardStringContext pkgs.findutils.drvPath)} \
                    --tool-drv ${pkgs.lib.escapeShellArg (builtins.unsafeDiscardStringContext pkgs.gnugrep.drvPath)} \
                    --tool-drv ${pkgs.lib.escapeShellArg (builtins.unsafeDiscardStringContext pkgs.perl.drvPath)}
                )
              }

              start_ns="$(date +%s%N)"
              emit_root timed "$TMPDIR/root-timed.drv"
              end_ns="$(date +%s%N)"
              planner_ms=$(((end_ns - start_ns) / 1000000))
              if [ "$planner_ms" -ge "$max_planner_ms" ]; then
                echo "dyndrv planner took ''${planner_ms}ms, expected < ''${max_planner_ms}ms" >&2
                exit 1
              fi

              emit_root repeat "$TMPDIR/root-repeat.drv"
              cmp "$TMPDIR/root-timed.drv" "$TMPDIR/root-repeat.drv"
              cmp "$TMPDIR/root-timed.drv" ${penanceBenchDyndrvPlanner}
              cmp ${penanceBenchDyndrvPlanner} ${penanceBenchDyndrvPlannerRepeat}

              mkdir -p "$out"
              cp "$TMPDIR/root-timed.drv" "$out/root.drv"
              cp ${penanceBenchDyndrv}/output.txt "$out/output.txt"
              cmp ${penanceBenchViaLock}/output.txt "$out/output.txt"

              module_count="$(grep -o 'penance-dyndrv-module-' "$out/root.drv" | wc -l | tr -d ' ')"
              test "$module_count" -eq 11
              jq -n \
                --argjson plannerMs "$planner_ms" \
                --argjson maxPlannerMs "$max_planner_ms" \
                --argjson modules "$module_count" \
                '{
                  schema: "penance/dyndrv-emission-proof/1",
                  plannerMs: $plannerMs,
                  maxPlannerMs: $maxPlannerMs,
                  moduleDrvs: $modules,
                  converged: true,
                  outputMatchesUnit: true
                }' > "$out/proof.json"
            '';
          penanceModuleCutoff30DyndrvPlanner =
            pkgs.runCommand "penance-module-cutoff-30-dyndrv-planner.drv" {
              __contentAddressed = true;
              outputHashMode = "text";
              outputHashAlgo = "sha256";
              requiredSystemFeatures = [ "recursive-nix" ];
              nativeBuildInputs = [
                benchHpkgs.ghc
                plannerBin
                pkgs.coreutils
                pkgs.findutils
                pkgs.nix
              ];
            } ''
              set -euo pipefail
              export NIX_CONFIG="extra-experimental-features = nix-command flakes ca-derivations dynamic-derivations recursive-nix"
              nix_bin=/nix/var/nix/profiles/default/bin/nix

              cp -R ${moduleCutoff30Src} source
              chmod -R u+w source
              cd source

              dep_flags=(
                -dep-suffix ""
                -include-pkg-deps
                -isrc
                -iapp
                -odir ../make-build
                -hidir ../make-build
              )
              mkdir -p ../make-build
              ghc -M "''${dep_flags[@]}" -dep-makefile "$TMPDIR/module-deps.mk" app/Main.hs src/Cutoff/*.hs

              penance-plan module-plan \
                --makefile "$TMPDIR/module-deps.mk" \
                --lock strata.lock \
                --component exe:module-cutoff-30 \
                --out "$TMPDIR/module-plan.json"

              module_count="$(${pkgs.jq}/bin/jq '.modules | length' "$TMPDIR/module-plan.json")"
              test "$module_count" -eq 31

              cat > "$TMPDIR/ghc-flags.txt" <<'FLAGS'
${cutoff30DyndrvGhcFlagsText}
FLAGS

              penance-plan emit-bench-dyndrv \
                --module-plan "$TMPDIR/module-plan.json" \
                --src-root "$PWD" \
                --out "$TMPDIR/root.drv" \
                --system ${pkgs.lib.escapeShellArg system} \
                --nix-bin "$nix_bin" \
                --builder ${pkgs.lib.escapeShellArg "${pkgs.bash}/bin/bash"} \
                --path ${pkgs.lib.escapeShellArg (pkgs.lib.makeBinPath [
                  pkgs.bash
                  pkgs.coreutils
                  pkgs.findutils
                  pkgs.gnugrep
                  pkgs.perl
                  benchHpkgs.ghc
                ])} \
                --ghc-flags "$TMPDIR/ghc-flags.txt" \
                --bin-name module-cutoff-30 \
                --smoke cutoff-30: \
                --tool-drv ${pkgs.lib.escapeShellArg (builtins.unsafeDiscardStringContext pkgs.bash.drvPath)} \
                --tool-drv ${pkgs.lib.escapeShellArg (builtins.unsafeDiscardStringContext benchHpkgs.ghc.drvPath)} \
                --tool-drv ${pkgs.lib.escapeShellArg (builtins.unsafeDiscardStringContext pkgs.coreutils.drvPath)} \
                --tool-drv ${pkgs.lib.escapeShellArg (builtins.unsafeDiscardStringContext pkgs.findutils.drvPath)} \
                --tool-drv ${pkgs.lib.escapeShellArg (builtins.unsafeDiscardStringContext pkgs.gnugrep.drvPath)} \
                --tool-drv ${pkgs.lib.escapeShellArg (builtins.unsafeDiscardStringContext pkgs.perl.drvPath)}
              cp "$TMPDIR/root.drv" "$out"
            '';
          penanceModuleCutoff30Dyndrv =
            let
              dyndrvOut =
                builtins.outputOf
                  (builtins.unsafeDiscardOutputDependency penanceModuleCutoff30DyndrvPlanner.outPath)
                  "out";
            in
              pkgs.runCommand "penance-module-cutoff-30-dyndrv" {} ''
                mkdir -p "$out"
                cp -R ${dyndrvOut}/. "$out/"
                "$out/bin/module-cutoff-30" > "$out/output.txt.check"
                cmp "$out/output.txt" "$out/output.txt.check"
                grep -q "cutoff-30:" "$out/output.txt"
              '';
          penanceHsBootThDyndrvPlanner =
            pkgs.runCommand "penance-hs-boot-th-dyndrv-planner.drv" {
              __contentAddressed = true;
              outputHashMode = "text";
              outputHashAlgo = "sha256";
              requiredSystemFeatures = [ "recursive-nix" ];
              nativeBuildInputs = [
                benchHpkgs.ghc
                plannerBin
                pkgs.coreutils
                pkgs.findutils
                pkgs.jq
                pkgs.nix
              ];
            } ''
              set -euo pipefail
              export NIX_CONFIG="extra-experimental-features = nix-command flakes ca-derivations dynamic-derivations recursive-nix"
              nix_bin=/nix/var/nix/profiles/default/bin/nix

              cp -R ${hsBootThSrc} source
              chmod -R u+w source
              cd source

              dep_flags=(
                -dep-suffix ""
                -include-pkg-deps
                -isrc
                -iapp
                -odir ../make-build
                -hidir ../make-build
                -package template-haskell
              )
              mkdir -p ../make-build
              ghc -M "''${dep_flags[@]}" -dep-makefile "$TMPDIR/module-deps.mk" app/Main.hs src/Cycle/*.hs src/TH/*.hs

              penance-plan module-plan \
                --makefile "$TMPDIR/module-deps.mk" \
                --lock strata.lock \
                --component exe:hs-boot-th \
                --out "$TMPDIR/module-plan.json"

              jq -e '
                (.modules | map(.source)) as $sources
                | ($sources | index("src/Cycle/A.hs-boot")) as $boot
                | ($sources | index("src/Cycle/B.hs")) as $cycleB
                | ($sources | index("src/Cycle/A.hs")) as $cycleA
                | ($boot != null and $cycleB != null and $cycleA != null and $boot < $cycleB and $cycleB < $cycleA)
                and any(.modules[]; .source == "src/TH/Splice.hs" and .db == "dbFull")
                and any(.modules[]; .source == "src/TH/Sibling.hs" and .db == "dbIface")
                and any(.modules[]; .source == "src/TH/Dep.hs" and .db == "dbIface")
              ' "$TMPDIR/module-plan.json" >/dev/null

              cat > "$TMPDIR/ghc-flags.txt" <<'FLAGS'
${hsBootThDyndrvGhcFlagsText}
FLAGS

              penance-plan emit-bench-dyndrv \
                --module-plan "$TMPDIR/module-plan.json" \
                --src-root "$PWD" \
                --out "$TMPDIR/root.drv" \
                --system ${pkgs.lib.escapeShellArg system} \
                --nix-bin "$nix_bin" \
                --builder ${pkgs.lib.escapeShellArg "${pkgs.bash}/bin/bash"} \
                --path ${pkgs.lib.escapeShellArg (pkgs.lib.makeBinPath [
                  pkgs.bash
                  pkgs.coreutils
                  pkgs.findutils
                  pkgs.gnugrep
                  pkgs.perl
                  benchHpkgs.ghc
                ])} \
                --ghc-flags "$TMPDIR/ghc-flags.txt" \
                --bin-name hs-boot-th \
                --smoke hs-boot-th: \
                --tool-drv ${pkgs.lib.escapeShellArg (builtins.unsafeDiscardStringContext pkgs.bash.drvPath)} \
                --tool-drv ${pkgs.lib.escapeShellArg (builtins.unsafeDiscardStringContext benchHpkgs.ghc.drvPath)} \
                --tool-drv ${pkgs.lib.escapeShellArg (builtins.unsafeDiscardStringContext pkgs.coreutils.drvPath)} \
                --tool-drv ${pkgs.lib.escapeShellArg (builtins.unsafeDiscardStringContext pkgs.findutils.drvPath)} \
                --tool-drv ${pkgs.lib.escapeShellArg (builtins.unsafeDiscardStringContext pkgs.gnugrep.drvPath)} \
                --tool-drv ${pkgs.lib.escapeShellArg (builtins.unsafeDiscardStringContext pkgs.perl.drvPath)}
              cp "$TMPDIR/root.drv" "$out"
            '';
          penanceHsBootThDyndrv =
            let
              dyndrvOut =
                builtins.outputOf
                  (builtins.unsafeDiscardOutputDependency penanceHsBootThDyndrvPlanner.outPath)
                  "out";
            in
              pkgs.runCommand "penance-hs-boot-th-dyndrv" {} ''
                mkdir -p "$out"
                cp -R ${dyndrvOut}/. "$out/"
                "$out/bin/hs-boot-th" > "$out/output.txt.check"
                cmp "$out/output.txt" "$out/output.txt.check"
                grep -q "hs-boot-th:42:dep-v1:splice:dep-v1:sibling" "$out/output.txt"
              '';
          penanceHsBootThClassificationProof =
            pkgs.runCommand "penance-hs-boot-th-classification-proof" {
              nativeBuildInputs = [
                benchHpkgs.ghc
                plannerBin
                pkgs.coreutils
                pkgs.findutils
                pkgs.jq
              ];
            } ''
              set -euo pipefail
              mkdir -p "$out/bin" "$out/nix-support" make-build
              cp -R ${hsBootThSrc} source
              chmod -R u+w source
              cd source

              dep_flags=(
                -dep-suffix ""
                -include-pkg-deps
                -isrc
                -iapp
                -odir ../make-build
                -hidir ../make-build
                -package template-haskell
              )
              ghc -M "''${dep_flags[@]}" -dep-makefile "$out/module-deps.mk" app/Main.hs src/Cycle/*.hs src/TH/*.hs
              penance-plan module-plan \
                --makefile "$out/module-deps.mk" \
                --lock strata.lock \
                --component exe:hs-boot-th \
                --out "$out/module-plan.json"

              jq -e '
                (.modules | map(.source)) as $sources
                | ($sources | index("src/Cycle/A.hs-boot")) as $boot
                | ($sources | index("src/Cycle/B.hs")) as $cycleB
                | ($sources | index("src/Cycle/A.hs")) as $cycleA
                | ($boot != null and $cycleB != null and $cycleA != null and $boot < $cycleB and $cycleB < $cycleA)
                and any(.modules[]; .source == "src/TH/Splice.hs" and .db == "dbFull")
                and any(.modules[]; .source == "src/TH/Sibling.hs" and .db == "dbIface")
                and any(.modules[]; .source == "src/TH/Dep.hs" and .db == "dbIface")
                and any(.modules[]; .source == "src/Cycle/A.hs-boot" and .deps == [])
              ' "$out/module-plan.json" >/dev/null

              cd ..
              ln -s ${penanceHsBootThDyndrv}/bin/hs-boot-th "$out/bin/hs-boot-th"
              "$out/bin/hs-boot-th" > "$out/output.txt"
              cmp ${penanceHsBootThDyndrv}/output.txt "$out/output.txt"
              cat > "$out/nix-support/hs-boot-th-classification.json" <<'JSON'
              {"schema":"penance/hs-boot-th-classification/1","hsBootOrder":"boot-before-source-cycle","thModule":"src/TH/Splice.hs","thDb":"dbFull","siblingDb":"dbIface","depBodyEditScenario":"M4-hs-boot-th-dep-body-edit"}
              JSON
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
          mkDirectAarch64Probe = name:
            let
              # Minimal aarch64-linux ELF generated from the C _start probe.
              aarch64ExitElfHex = ''
                7f454c460201010000000000000000000200b70001000000b0004000000000004000000000000000f002000000000000000000004000380002004000070006000100000005000000000000000000000004000000000000000400000000000f400000000000000f400000000000000000001000000000051e5746406000000000000000000000000000000000000000000000000000000000000000000000000000000000000001000000000000000fd7bbfa9fd030091a80b80d2000080d2010000d4000000001000000000000000017a520004781e011b0c1f001400000018000000ccffffff1400000000410e109d029e014743433a2028474e55292031
                352e322e300000000000000000000000000000000000000000000000000000000003000100b00040000000000000000000000000000000000003000200c8004000000000000000000000000000000000000300030000000000000000000000000000000010000000400f1ff000000000000000000000000000000000900000000000100b00040000000000000000000000000000c00000000000200dc0040000000000000000000000000001e00000010000200e8ff41000000000000000000000000000f00000010000200e8ff41000000000000000000000000001d00000010000200e8ff41000000000000000000000000002e00000012000100
                b00040000000000014000000000000002900000010000200e8ff41000000000000000000000000003500000010000200e8ff41000000000000000000000000003d00000010000200e8ff41000000000000000000000000004400000010000200e8ff4100000000000000000000000000003c737464696e3e002478002464005f5f6273735f73746172745f5f005f5f6273735f656e645f5f005f5f6273735f7374617274005f5f656e645f5f005f6564617461005f656e6400002e73796d746162002e737472746162002e7368737472746162002e74657874002e65685f6672616d65002e636f6d6d656e740000000000000000000000000000000000000000
                0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001b000000010000000600000000000000b000400000000000b000000000000000140000000000000000000000000000000400000000000000000000000000000021000000010000000200000000000000c800400000000000c8000000000000002c000000000000000000000000000000080000000000000000000000000000002b0000000100000030000000000000000000000000000000f400000000000000120000000000000000000000000000000100000000000000010000000000000001000000020000000000000000000000
                00000000000000000801000000000000680100000000000005000000070000000800000000000000180000000000000009000000030000000000000000000000000000000000000070020000000000004900000000000000000000000000000001000000000000000000000000000000110000000300000000000000000000000000000000000000b9020000000000003400000000000000000000000000000001000000000000000000000000000000
              '';
            in
            derivation {
              inherit name;
              system = pkgs.stdenv.hostPlatform.system;
              builder = "${pkgs.bash}/bin/bash";
              args = [
                "-euc"
                ''
                  ${pkgs.coreutils}/bin/mkdir -p "$out/bin"
                  ${pkgs.perl}/bin/perl -0777 -ne 's/\s+//g; print pack("H*", $_)' \
                    > "$out/bin/${name}" <<'HEX'
                  ${aarch64ExitElfHex}
                  HEX
                  ${pkgs.coreutils}/bin/chmod +x "$out/bin/${name}"
                ''
              ];
            };
          penanceAarch64LinuxReal =
            mkDirectAarch64Probe "penance-aarch64-linux-real";
          haskellNixAarch64LinuxBaseline =
            mkAarch64Probe haskellNixCrossAarch64.stdenv "haskell-nix-aarch64-linux-baseline" "haskell-nix";
          copyClosureCache = closure: dir: ''
            mkdir -p "${dir}"
            cp ${closure}/store-paths "${dir}/store-paths"
            cp ${closure}/registration "${dir}/registration"
            cp ${closure}/total-nar-size "${dir}/total-nar-size"
          '';
          mkMscBundle = name: root:
            let
              closure = pkgs.closureInfo { rootPaths = [ root ]; };
            in
            pkgs.runCommand name {
              nativeBuildInputs = [
                pkgs.coreutils
              ];
            } ''
              ${copyClosureCache closure "$out/cache"}
              path_count="$(wc -l < "$out/cache/store-paths" | tr -d ' ')"
              nar_size="$(cat "$out/cache/total-nar-size")"
              test "$path_count" -gt 0
              cat > "$out/manifest.json" <<JSON
              {"schema":"penance/msc-bundle/1","root":"${root}","pathCount":$path_count,"narSize":$nar_size,"closureInfo":"${closure}"}
              JSON
            '';
          mkLockCacheManifest = name: lockPath: root:
            let
              lockHash = builtins.hashFile "sha256" lockPath;
              manifest = builtins.toJSON {
                schema = "penance/lock-cache-manifest/1";
                inherit lockHash;
                rootDrv = builtins.unsafeDiscardStringContext root.drvPath;
              };
            in
              pkgs.runCommandLocal name {} ''
                printf '%s\n' '${manifest}' > "$out"
              '';
          penanceMscBundle =
            mkMscBundle "penance-msc-bundle" penanceBenchViaLock;
          haskellNixMscBundle =
            mkMscBundle "haskell-nix-msc-bundle" haskellNixBenchExe;
          penanceLockCacheManifest =
            mkLockCacheManifest "penance-lock-cache-manifest" (benchSrc + "/strata.lock") penanceBenchViaLock;
          penanceProjectVariants =
            pkgs.runCommand "penance-project-variants" {} ''
              mkdir -p "$out/variants" "$out/nix-support"
              ln -s ${penanceBenchViaLock} "$out/variants/granularity-unit"
              ln -s ${penanceBenchDyndrv} "$out/variants/granularity-module"
              ln -s ${penanceBenchO0ViaLock} "$out/variants/ghcOptions-O0"

              "$out/variants/granularity-unit/bin/penance-bench" > "$out/granularity-unit.out"
              "$out/variants/granularity-module/bin/penance-bench" > "$out/granularity-module.out"
              cmp "$out/granularity-unit.out" "$out/granularity-module.out"
              cmp ${penanceBenchViaLock}/output.txt "$out/granularity-unit.out"
              cmp ${penanceBenchDyndrv}/output.txt "$out/granularity-module.out"

              cat > "$out/variants.json" <<'JSON'
              {"schema":"penance/project-variants/1","variants":["granularity-unit","granularity-module","ghcOptions-O0"],"granularity":{"unit":"penanceBenchViaLock","module":"penanceBenchDyndrv","sameLock":"tests/bench/vs-haskell-nix/project/strata.lock","outputsEquivalent":true}}
              JSON
            '';
          haskellNixProjectVariants =
            mkVariantBundle "haskell-nix-project-variants" [
              { name = "baseline"; path = haskellNixBenchExe; }
              { name = "appendModule-ghcOptions-O0"; path = haskellNixBenchO0Exe; }
            ];
          mkWarpLoop = name: root:
            let
              closure = pkgs.closureInfo { rootPaths = [ root ]; };
            in
            pkgs.runCommand name {
              nativeBuildInputs = [
                pkgs.coreutils
              ];
            } ''
              ${copyClosureCache closure "$out/device-cache"}
              mkdir -p "$out/run/services/penance-bench"
              ln -s ${root}/bin/penance-bench "$out/run/services/penance-bench/current"
              test -x "$out/run/services/penance-bench/current"
              path_count="$(wc -l < "$out/device-cache/store-paths" | tr -d ' ')"
              service_nar_size="$(cat "$out/device-cache/total-nar-size")"
              cat > "$out/status.json" <<JSON
              {"schema":"penance/warp-loop/1","service":"penance-bench","root":"${root}","mode":"test","hotSwap":"$out/run/services/penance-bench/current","pathCount":$path_count,"narSize":$service_nar_size,"closureInfo":"${closure}"}
              JSON
            '';
          penanceWarpLoop =
            mkWarpLoop "penance-warp-loop" penanceBenchViaLock;
          haskellNixWarpBaseline =
            mkWarpLoop "haskell-nix-warp-baseline" haskellNixBenchExe;
        in
        {
          inherit
            backpackMultiInstanceModule
            backpackSignaturesModule
            haskellNixAarch64LinuxBaseline
            haskellNixBackpackExe
            haskellNixBenchChecks
            haskellNixBenchExe
            haskellNixBenchPlan
            haskellNixBenchPlanMaterialized
            haskellNixBenchShell
            haskellNixBenchSurface
            haskellNixHackageStateVar
            haskellNixHsBootThExe
            haskellNixHsBootThSmoke
            haskellNixMscBundle
            haskellNixModuleCutoff30Exe
            haskellNixPrimitiveProbes
            haskellNixProjectCrossAarch64
            haskellNixProjectVariants
            haskellNixSimpleLib
            haskellNixStackageStateVar
            haskellNixWarpBaseline
            penanceAarch64LinuxReal
            penanceAddPathConsumer
            penanceAddPathPlanner
            penanceBackpackReal
            penanceBenchChecks
            penanceBenchDevShell
            penanceBenchShellGhc
            penanceBenchBenchmarkViaLock
            penanceBenchLibViaLock
            penanceBenchO0ViaLock
            penanceBenchDyndrv
            penanceBenchDyndrvPlanner
            penanceBenchDyndrvPlannerRepeat
            penanceDyndrvEmissionProof
            penanceModuleCutoff30Dyndrv
            penanceModuleCutoff30DyndrvPlanner
            penanceBenchShell
            penanceBenchTestViaLock
            penanceBenchViaLock
            penanceCaCutoffToy
            penanceCaCutoffToyA
            penanceCaCutoffToyB
            penanceCaCutoffToyC
            penanceHackageStateVar
            penanceHaskellAarch64LinuxReal
            penanceHsBootThClassificationProof
            penanceHsBootThDyndrv
            penanceHsBootThDyndrvPlanner
            penanceLockExternalViaLock
            plannerBin
            penanceLockBench
            penanceLockCacheManifest
            penanceBenchComponent
            penanceBenchModule
            penanceModuleGranularBench
            penanceMscBundle
            penancePrimitiveProbes
            penanceProbePlanner
            penanceProbePlannerConsumer
            penanceProbePlannerCorrupt
            penanceProbePlannerDeterminismA
            penanceProbePlannerDeterminismB
            penanceProbePlannerDeterminismBadA
            penanceProbePlannerDeterminismBadB
            penanceProbePlannerNondeterministic
            penanceProjectVariants
            penanceSimpleLibViaLock
            penanceStackageStateVar
            penanceWarpLoop
            simpleLibComponent
            wasmPlannerBuiltin
            wasmPlannerNative
            wasmPlannerWasi
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
              and all(.phases[]; .status == "comparison")
              and all(.phases[]; (.penanceAttr != null and .haskellNixAttr != null))
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
              "HN-stackage-snapshot",
              "HN-tests-benches-checks"
            ]' '
              .schema == "penance/architecture-phase-matrix/1"
              and (.phases | length) == ($expected | length)
              and ([.phases[].id] | sort) == ($expected | sort)
              and all(.phases[]; has("id") and has("milestone") and has("status") and has("required"))
              and all(.phases[]; .status == "comparison")
              and all(.phases[]; (.penanceAttr != null and .haskellNixAttr != null))
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
              "M0-ca-cutoff-toy-remote",
              "M1-backpack-unit-id-substitution",
              "M1-lock-cross-machine-determinism",
              "M1-target-flag-divergence",
              "M2-dev-shell-zero-external-builds",
              "M2-lowerer-equality",
              "M3-cachix-realisation-anchor",
              "M4-dynamic-derivation-emission",
              "M4-hs-boot-th-classification",
              "M4-module-cutoff-30",
              "M5-backpack-dev-projection",
              "M5-backpack-rebuild-matrix",
              "M6-cross-cuda-hil",
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
              and all(.phases[]; .required == true)
              and ([.phases[] | select(.status == "comparison").id] | sort) == ["M4-dynamic-derivation-emission", "M4-hs-boot-th-classification", "M4-module-cutoff-30"]
              and all(.phases[]; .status == "failing" or .status == "comparison")
              and all(.phases[]; if .status == "failing" then (.penanceAttr == null and .haskellNixAttr == null and (.failure | type == "string") and (.failure | length > 0)) else (.penanceAttr != null and .haskellNixAttr != null and .failure == null) end)
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
          benchDynamicProbes = pkgs.writeShellApplication {
            name = "bench-dynamic-probes";
            runtimeInputs = [
              pkgs.coreutils
              pkgs.findutils
              pkgs.gnugrep
              pkgs.gnused
              pkgs.perl
              pkgs.rsync
            ];
            text = ''
              if [ -x /nix/var/nix/profiles/default/bin/nix ]; then
                export PENANCE_NIX_BIN=''${PENANCE_NIX_BIN:-/nix/var/nix/profiles/default/bin/nix}
              fi

              nix_bin=''${PENANCE_NIX_BIN:-nix}
              flake_ref=''${PENANCE_DYNAMIC_PROBES_FLAKE:-$PWD}
              case "$flake_ref" in
                /*) flake_dir="$flake_ref" ;;
                .|./*) flake_dir="$(cd "$flake_ref" && pwd)" ;;
                *)
                  echo "bench-dynamic-probes requires a local flake path, got: $flake_ref" >&2
                  exit 1
                  ;;
              esac

              stamp="$(date -u +%Y%m%dT%H%M%SZ)"
              out_root=''${PENANCE_DYNAMIC_PROBES_OUT:-$flake_dir/docs/bench-results/dynamic-probes/${system}-$stamp}
              tmp_root=''${TMPDIR:-/tmp}
              mkdir -p "$out_root/logs"

              nix_common=(
                --extra-experimental-features "nix-command flakes ca-derivations dynamic-derivations recursive-nix"
                --option system-features "recursive-nix apple-virt benchmark big-parallel nixos-test"
              )

              "$nix_bin" "''${nix_common[@]}" --version > "$out_root/nix-version.txt"
              "$nix_bin" "''${nix_common[@]}" config show experimental-features > "$out_root/experimental-features.txt"
              "$nix_bin" "''${nix_common[@]}" config show system-features > "$out_root/system-features.txt"
              grep -q "ca-derivations" "$out_root/experimental-features.txt"
              grep -q "dynamic-derivations" "$out_root/experimental-features.txt"
              grep -q "recursive-nix" "$out_root/experimental-features.txt"
              grep -q "recursive-nix" "$out_root/system-features.txt"
              "$nix_bin" "''${nix_common[@]}" eval --expr 'builtins.hasAttr "outputOf" builtins' > "$out_root/outputOf.txt"
              grep -q true "$out_root/outputOf.txt"
              "$nix_bin" "''${nix_common[@]}" eval --option allow-import-from-derivation false \
                --raw "$flake_dir#penanceBenchViaLock.drvPath" > "$out_root/no-ifd-penanceBenchViaLock.drvPath"
              "$nix_bin" "''${nix_common[@]}" eval --option allow-import-from-derivation false \
                --raw "$flake_dir#penanceSimpleLibViaLock.drvPath" > "$out_root/no-ifd-penanceSimpleLibViaLock.drvPath"
              "$nix_bin" "''${nix_common[@]}" eval --option allow-import-from-derivation false \
                --raw "$flake_dir#penanceLockExternalViaLock.drvPath" > "$out_root/no-ifd-penanceLockExternalViaLock.drvPath"

              write_hi_hashes() {
                local root="$1"
                local output="$2"
                find "$root" -name '*.hi' -type f | sort | while IFS= read -r hi; do
                  rel="''${hi#"$root"/}"
                  hash="$(sha256sum "$hi" | cut -d ' ' -f 1)"
                  printf "%s  %s\n" "$hash" "$rel"
                done > "$output"
              }

              built_count() {
                grep -E -c "building '/nix/store/[0-9a-z]{32}-$1\\.drv'" "$2" || true
              }

              assert_built_count() {
                local name="$1"
                local log="$2"
                local expected="$3"
                local actual
                actual="$(built_count "$name" "$log" | tail -n 1 | tr -d ' ')"
                if [ "$actual" != "$expected" ]; then
                  echo "expected $expected builds for $name in $log, saw $actual" >&2
                  exit 1
                fi
              }

              "$nix_bin" "''${nix_common[@]}" build "$flake_dir#penanceProbePlannerConsumer" \
                --no-link -L > "$out_root/logs/consumer-build.log" 2>&1

              plan_drv="$("$nix_bin" "''${nix_common[@]}" eval --raw "$flake_dir#penanceProbePlanner.drvPath")"
              printf "%s\n" "$plan_drv" > "$out_root/planner-drv.txt"
              "$nix_bin" "''${nix_common[@]}" build "$plan_drv^out^out" \
                --no-link -L > "$out_root/logs/cli-chain.log" 2>&1

              "$nix_bin" "''${nix_common[@]}" build "$flake_dir#penanceProbePlannerConsumer" \
                --no-link -L > "$out_root/logs/no-op-build.log" 2>&1
              if grep -q "building '" "$out_root/logs/no-op-build.log"; then
                echo "second planner-consumer build rebuilt derivations unexpectedly" >&2
                exit 1
              fi

              base_plan_out="$("$nix_bin" "''${nix_common[@]}" build "$flake_dir#penanceProbePlanner" \
                --print-out-paths --no-link -L 2> "$out_root/logs/planner-build.log" | tail -n 1)"
              test -n "$base_plan_out"
              printf "%s\n" "$base_plan_out" > "$out_root/planner-output.txt"
              det_scratch="$(mktemp -d "$tmp_root/penance-determinism.XXXXXX")"
              trap 'rm -rf "$det_scratch"' EXIT
              rsync -a \
                --exclude .git \
                --exclude 'result' \
                --exclude 'result-*' \
                --exclude 'docs/bench-results' \
                --exclude 'target' \
                --exclude 'dist-newstyle' \
                "$flake_dir/" "$det_scratch/"
              chmod -R u+w "$det_scratch"
              printf "determinism %s\n" "$stamp" > "$det_scratch/tests/probes/determinism-salt.txt"
              det_a="$("$nix_bin" "''${nix_common[@]}" build "$det_scratch#penanceProbePlannerDeterminismA" \
                --print-out-paths --no-link -L 2> "$out_root/logs/planner-determinism-a.log" | tail -n 1)"
              det_b="$("$nix_bin" "''${nix_common[@]}" build "$det_scratch#penanceProbePlannerDeterminismB" \
                --print-out-paths --no-link -L 2> "$out_root/logs/planner-determinism-b.log" | tail -n 1)"
              test -n "$det_a"
              test -n "$det_b"
              "$nix_bin" "''${nix_common[@]}" derivation show "$det_a" \
                | sed -E 's#/nix/store/[0-9a-z]{32}-[A-Za-z0-9._+?=-]+#<store-path>#g' \
                > "$out_root/planner-determinism-a.json"
              "$nix_bin" "''${nix_common[@]}" derivation show "$det_b" \
                | sed -E 's#/nix/store/[0-9a-z]{32}-[A-Za-z0-9._+?=-]+#<store-path>#g' \
                > "$out_root/planner-determinism-b.json"
              cmp "$out_root/planner-determinism-a.json" "$out_root/planner-determinism-b.json"
              bad_a="$("$nix_bin" "''${nix_common[@]}" build "$det_scratch#penanceProbePlannerDeterminismBadA" \
                --print-out-paths --no-link -L 2> "$out_root/logs/planner-determinism-bad-a.log" | tail -n 1)"
              bad_b="$("$nix_bin" "''${nix_common[@]}" build "$det_scratch#penanceProbePlannerDeterminismBadB" \
                --print-out-paths --no-link -L 2> "$out_root/logs/planner-determinism-bad-b.log" | tail -n 1)"
              test -n "$bad_a"
              test -n "$bad_b"
              "$nix_bin" "''${nix_common[@]}" derivation show "$bad_a" \
                | sed -E 's#/nix/store/[0-9a-z]{32}-[A-Za-z0-9._+?=-]+#<store-path>#g' \
                > "$out_root/planner-determinism-bad-a.json"
              "$nix_bin" "''${nix_common[@]}" derivation show "$bad_b" \
                | sed -E 's#/nix/store/[0-9a-z]{32}-[A-Za-z0-9._+?=-]+#<store-path>#g' \
                > "$out_root/planner-determinism-bad-b.json"
              if cmp "$out_root/planner-determinism-bad-a.json" "$out_root/planner-determinism-bad-b.json" >/dev/null; then
                echo "planner determinism negative control unexpectedly matched" >&2
                exit 1
              fi
              rm -rf "$det_scratch"

              add_consumer_out="$("$nix_bin" "''${nix_common[@]}" build "$flake_dir#penanceAddPathConsumer" \
                --print-out-paths --no-link -L > "$out_root/logs/add-path-consumer.stdout" 2> "$out_root/logs/add-path-consumer.log" && tail -n 1 "$out_root/logs/add-path-consumer.stdout")"
              test -n "$add_consumer_out"
              cmp "$add_consumer_out/payload.txt" "$flake_dir/tests/probes/add-path-payload.txt"
              add_plan_drv="$("$nix_bin" "''${nix_common[@]}" eval --raw "$flake_dir#penanceAddPathPlanner.drvPath")"
              printf "%s\n" "$add_plan_drv" > "$out_root/add-path-planner-drv.txt"
              "$nix_bin" "''${nix_common[@]}" build "$add_plan_drv^out^out" \
                --no-link -L > "$out_root/logs/add-path-cli-chain.log" 2>&1
              "$nix_bin" "''${nix_common[@]}" build "$flake_dir#penanceAddPathConsumer" \
                --no-link -L > "$out_root/logs/add-path-no-op-build.log" 2>&1
              if grep -q "building '" "$out_root/logs/add-path-no-op-build.log"; then
                echo "second add-path consumer build rebuilt derivations unexpectedly" >&2
                exit 1
              fi
              add_plan_out="$("$nix_bin" "''${nix_common[@]}" build "$flake_dir#penanceAddPathPlanner" \
                --print-out-paths --no-link -L 2> "$out_root/logs/add-path-planner-build.log" | tail -n 1)"
              test -n "$add_plan_out"
              printf "%s\n" "$add_plan_out" > "$out_root/add-path-planner-output.txt"
              "$nix_bin" "''${nix_common[@]}" derivation show "$add_plan_out" > "$out_root/add-path-child.json"
              grep -q 'penance-added-source.txt' "$out_root/add-path-child.json"
              child_count="$(grep -o '"[0-9a-z]\{32\}-penance-add-path-planner\.drv"' "$out_root/add-path-child.json" | wc -l | tr -d ' ')"
              test "$child_count" = 1

              "$nix_bin" "''${nix_common[@]}" build "$flake_dir#penanceCaCutoffToy" \
                --no-link -L > "$out_root/logs/ca-toy-baseline.log" 2>&1
              "$nix_bin" "''${nix_common[@]}" build "$flake_dir#penanceCaCutoffToy" \
                --no-link -L > "$out_root/logs/ca-toy-no-op.log" 2>&1
              if grep -q "building '" "$out_root/logs/ca-toy-no-op.log"; then
                echo "second CA cutoff toy build rebuilt derivations unexpectedly" >&2
                exit 1
              fi

              hi_soak_count=5
              hi_hash_count=0
              for run in $(seq 1 "$hi_soak_count"); do
                hi_out="$("$nix_bin" "''${nix_common[@]}" build "$flake_dir#penanceBenchLibViaLock.iface" \
                  --rebuild --print-out-paths --no-link -L \
                  > "$out_root/logs/hi-soak-$run.stdout" \
                  2> "$out_root/logs/hi-soak-$run.log" && tail -n 1 "$out_root/logs/hi-soak-$run.stdout")"
                test -n "$hi_out"
                printf "%s\n" "$hi_out" > "$out_root/hi-soak-$run.path"
                write_hi_hashes "$hi_out" "$out_root/hi-soak-$run.sha256"
                run_hash_count="$(wc -l < "$out_root/hi-soak-$run.sha256" | tr -d ' ')"
                test "$run_hash_count" -gt 0
                grep -q 'Bench/Model.hi' "$out_root/hi-soak-$run.sha256"
                if [ "$run" = 1 ]; then
                  hi_hash_count="$run_hash_count"
                  cp "$out_root/hi-soak-$run.sha256" "$out_root/hi-soak-baseline.sha256"
                else
                  cmp "$out_root/hi-soak-baseline.sha256" "$out_root/hi-soak-$run.sha256"
                fi
              done
              cp "$out_root/hi-soak-baseline.sha256" "$out_root/hi-soak-corrupt.sha256"
              perl -0pi -e 's/^([0-9a-f])/$1 eq "0" ? "1" : "0"/e' "$out_root/hi-soak-corrupt.sha256"
              if cmp "$out_root/hi-soak-baseline.sha256" "$out_root/hi-soak-corrupt.sha256" >/dev/null; then
                echo "hi determinism self-check failed to detect a corrupted hash" >&2
                exit 1
              fi

              scratch="$(mktemp -d "$tmp_root/penance-dynamic-probes.XXXXXX")"
              trap 'rm -rf "$scratch"' EXIT
              rsync -a \
                --exclude .git \
                --exclude 'result' \
                --exclude 'result-*' \
                --exclude 'docs/bench-results' \
                --exclude 'target' \
                --exclude 'dist-newstyle' \
                "$flake_dir/" "$scratch/"
              chmod -R u+w "$scratch"
              printf "hello dynamic child edited %s\n" "$stamp" > "$scratch/tests/probes/planner-payload.txt"
              printf "hello recursive add-path edited %s\n" "$stamp" > "$scratch/tests/probes/add-path-payload.txt"
              edited_plan_out="$("$nix_bin" "''${nix_common[@]}" build "$scratch#penanceProbePlanner" \
                --print-out-paths --no-link -L 2> "$out_root/logs/liveness-build.log" | tail -n 1)"
              test -n "$edited_plan_out"
              printf "%s\n" "$edited_plan_out" > "$out_root/planner-output-edited.txt"
              if [ "$base_plan_out" = "$edited_plan_out" ]; then
                echo "editing the probe payload did not change the emitted child drv path" >&2
                exit 1
              fi
              edited_add_plan_out="$("$nix_bin" "''${nix_common[@]}" build "$scratch#penanceAddPathPlanner" \
                --print-out-paths --no-link -L 2> "$out_root/logs/add-path-liveness-build.log" | tail -n 1)"
              test -n "$edited_add_plan_out"
              printf "%s\n" "$edited_add_plan_out" > "$out_root/add-path-planner-output-edited.txt"
              if [ "$add_plan_out" = "$edited_add_plan_out" ]; then
                echo "editing the add-path payload did not change the emitted child drv path" >&2
                exit 1
              fi
              printf "module A\ndecl: value :: Int\nbody: value = 1\ncomment: body edit %s\n" "$stamp" \
                > "$scratch/tests/probes/ca-cutoff-toy/A.toy"
              "$nix_bin" "''${nix_common[@]}" build "$scratch#penanceCaCutoffToy" \
                --no-link -L > "$out_root/logs/ca-toy-body-edit.log" 2>&1
              assert_built_count penance-ca-toy-A "$out_root/logs/ca-toy-body-edit.log" 1
              assert_built_count penance-ca-toy-B "$out_root/logs/ca-toy-body-edit.log" 0
              assert_built_count penance-ca-toy-C "$out_root/logs/ca-toy-body-edit.log" 0
              assert_built_count penance-ca-toy-link "$out_root/logs/ca-toy-body-edit.log" 1
              printf "module A\ndecl: value_%s :: Integer\nbody: value = 1\ncomment: declaration edit %s\n" "$stamp" "$stamp" \
                > "$scratch/tests/probes/ca-cutoff-toy/A.toy"
              "$nix_bin" "''${nix_common[@]}" build "$scratch#penanceCaCutoffToy" \
                --no-link -L > "$out_root/logs/ca-toy-declaration-edit.log" 2>&1
              assert_built_count penance-ca-toy-A "$out_root/logs/ca-toy-declaration-edit.log" 1
              assert_built_count penance-ca-toy-B "$out_root/logs/ca-toy-declaration-edit.log" 1
              assert_built_count penance-ca-toy-C "$out_root/logs/ca-toy-declaration-edit.log" 1
              assert_built_count penance-ca-toy-link "$out_root/logs/ca-toy-declaration-edit.log" 1

              cutoff_token="B5$(printf "%s" "$stamp" | tr -cd 'A-Za-z0-9')"
              "$nix_bin" "''${nix_common[@]}" build "$scratch#penanceBenchViaLock" \
                --no-link -L > "$out_root/logs/static-cutoff-baseline.log" 2>&1
              "$nix_bin" "''${nix_common[@]}" build "$scratch#penanceBenchViaLock" \
                --no-link -L > "$out_root/logs/static-cutoff-no-op.log" 2>&1
              if grep -q "building '" "$out_root/logs/static-cutoff-no-op.log"; then
                echo "second static-unit cutoff build rebuilt derivations unexpectedly" >&2
                exit 1
              fi
              perl -0pi -e "s#    Users -> \"/users\"#    Users -> \"/people-$cutoff_token\"#" \
                "$scratch/tests/bench/vs-haskell-nix/project/src/Bench/Route.hs"
              body_out="$("$nix_bin" "''${nix_common[@]}" build "$scratch#penanceBenchViaLock" \
                --print-out-paths --no-link -L > "$out_root/logs/static-cutoff-body.stdout" 2> "$out_root/logs/static-cutoff-body.log" && tail -n 1 "$out_root/logs/static-cutoff-body.stdout")"
              test -n "$body_out"
              grep -q "/people-$cutoff_token" "$body_out/output.txt"
              assert_built_count penance-penance-bench-lib "$out_root/logs/static-cutoff-body.log" 1
              assert_built_count penance-penance-bench-lib-dbIface "$out_root/logs/static-cutoff-body.log" 0
              assert_built_count penance-penance-bench-lib-dbFull "$out_root/logs/static-cutoff-body.log" 1
              assert_built_count penance-penance-bench-exe-penance-bench-compile "$out_root/logs/static-cutoff-body.log" 0
              assert_built_count penance-penance-bench-exe-penance-bench "$out_root/logs/static-cutoff-body.log" 1

              perl -0pi -e "s/module Bench\\.App \\(runApp\\) where/module Bench.App (runApp, runVersion$cutoff_token) where/" \
                "$scratch/tests/bench/vs-haskell-nix/project/src/Bench/App.hs"
              printf '\nrunVersion%s :: String\nrunVersion%s = "%s"\n' "$cutoff_token" "$cutoff_token" "$cutoff_token" \
                >> "$scratch/tests/bench/vs-haskell-nix/project/src/Bench/App.hs"
              "$nix_bin" "''${nix_common[@]}" build "$scratch#penanceBenchViaLock" \
                --no-link -L > "$out_root/logs/static-cutoff-export.log" 2>&1
              assert_built_count penance-penance-bench-lib "$out_root/logs/static-cutoff-export.log" 1
              assert_built_count penance-penance-bench-lib-dbIface "$out_root/logs/static-cutoff-export.log" 1
              assert_built_count penance-penance-bench-lib-dbFull "$out_root/logs/static-cutoff-export.log" 1
              assert_built_count penance-penance-bench-exe-penance-bench-compile "$out_root/logs/static-cutoff-export.log" 1
              assert_built_count penance-penance-bench-exe-penance-bench "$out_root/logs/static-cutoff-export.log" 1

              if "$nix_bin" "''${nix_common[@]}" build "$flake_dir#penanceProbePlannerCorrupt" \
                --no-link -L > "$out_root/logs/corrupt-child-json.log" 2>&1; then
                echo "corrupt child JSON unexpectedly succeeded" >&2
                exit 1
              fi

              cat > "$out_root/summary.json" <<JSON
              {
                "schema": "penance/dynamic-probes/1",
                "probes": ["P2-outputOf-chain", "P3-cli-chain", "P4-recursive-add-path", "P5-ca-cutoff-toy-local", "P7-planner-determinism", "M2-no-ifd-static-unit-suite", "M2-dbIface-dbFull-cutoff", "M3-hi-determinism-soak"],
                "plannerDrv": "$plan_drv",
                "plannerOut": "$base_plan_out",
                "editedPlannerOut": "$edited_plan_out",
                "plannerDeterminism": "nix-store --realise --check",
                "addPathPlannerDrv": "$add_plan_drv",
                "addPathPlannerOut": "$add_plan_out",
                "editedAddPathPlannerOut": "$edited_add_plan_out",
                "caToyBodyEditBuilds": ["penance-ca-toy-A", "penance-ca-toy-link"],
                "caToyDeclarationEditBuilds": ["penance-ca-toy-A", "penance-ca-toy-B", "penance-ca-toy-C", "penance-ca-toy-link"],
                "staticUnitBodyEditBuilds": ["penance-penance-bench-lib", "penance-penance-bench-lib-dbFull", "penance-penance-bench-exe-penance-bench"],
                "staticUnitExportEditBuilds": ["penance-penance-bench-lib", "penance-penance-bench-lib-dbIface", "penance-penance-bench-lib-dbFull", "penance-penance-bench-exe-penance-bench-compile", "penance-penance-bench-exe-penance-bench"],
                "hiSoakRuns": $hi_soak_count,
                "hiSoakHashCount": $hi_hash_count,
                "hiSoakSelfCheck": "failed-as-expected",
                "noOpBuilds": 0,
                "corruptChildJson": "failed"
              }
              JSON

              echo "wrote dynamic probe metrics:"
              echo "  $out_root/summary.json"
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

              # Keep the suite defaults on the same pins the flake proofs use.
              export PENANCE_BENCH_STACKAGE_RESOLVER=''${PENANCE_BENCH_STACKAGE_RESOLVER:-${stackageResolver}}
              export PENANCE_BENCH_HACKAGE_PACKAGE=''${PENANCE_BENCH_HACKAGE_PACKAGE:-StateVar-${hackageStateVarVersion}}

              exec ${self.packages.${system}.plannerBin}/bin/penance-bench \
                --system ${system} \
                --architecture-runner ${self.packages.${system}.plannerBin}/bin/penance-architecture-bench \
                --architecture-functionality-runner ${benchArchitectureFunctionality}/bin/bench-architecture-functionality \
                --dynamic-probes-runner ${benchDynamicProbes}/bin/bench-dynamic-probes \
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
          bench-dynamic-probes = {
            type = "app";
            program = "${benchDynamicProbes}/bin/bench-dynamic-probes";
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
          penance-lock = {
            type = "app";
            program = "${self.packages.${system}.plannerBin}/bin/penance-lock";
          };
        });

      devShells = forAllSystems (system:
        let
          pkgs = import nixpkgs {
            inherit system;
          };
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
        });
    };
}
