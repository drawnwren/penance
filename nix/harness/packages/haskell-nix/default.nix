{
  assertCrossHelloElf,
  backpackSrc,
  benchSrc,
  crossHaskellCompilerAttr,
  crossHaskellCompilerName,
  crossHaskellTarget,
  crossHelloSrc,
  hackageStateVarVersion,
  haskellNixCompilerShapeFor,
  haskellNixPkgs,
  hsBootThSrc,
  mkLibraryManifest,
  moduleCutoff30Src,
  penanceCrossHaskellGhc,
  pkgs,
  runBenchChecks,
  simpleLibSrc,
  stackageResolver,
  stackageStateVarVersion,
  writeMetadataJson,
  ...
}:
let
  mkBaselineProject =
    {
      name,
      src,
      indexState ? "2026-04-01T00:00:00Z",
      compilerNixName ? "ghc910",
      configureArgs ? "--disable-tests --disable-benchmarks",
      extra ? { },
    }:
    haskellNixPkgs.haskell-nix.cabalProject' (
      {
        inherit name configureArgs;
        src = haskellNixPkgs.haskell-nix.cleanSourceHaskell {
          name = "${name}-src";
          inherit src;
        };
        compiler-nix-name = compilerNixName;
        index-state = indexState;
        cabalProject = builtins.readFile (src + "/cabal.project");
        cabalProjectLocal = "";
        cabalProjectFreeze = "";
      }
      // extra
    );
  haskellNixBackpackProject = mkBaselineProject {
    name = "backpack-multi-instance";
    src = backpackSrc;
  };
  haskellNixBackpackExe =
    haskellNixBackpackProject.hsPkgs."backpack-multi-instance".components.exes."list-user";
  haskellNixSimpleProject = mkBaselineProject {
    name = "simple-lib";
    src = simpleLibSrc;
  };
  haskellNixSimpleLib = haskellNixSimpleProject.hsPkgs."simple-lib".components.library;
  haskellNixModuleCutoff30Project = mkBaselineProject {
    name = "module-cutoff-thirty";
    src = moduleCutoff30Src;
  };
  haskellNixModuleCutoff30Exe =
    haskellNixModuleCutoff30Project.hsPkgs."module-cutoff-thirty".components.exes."module-cutoff-30";
  haskellNixHsBootThProject = mkBaselineProject {
    name = "hs-boot-th";
    src = hsBootThSrc;
  };
  haskellNixHsBootThExe = haskellNixHsBootThProject.hsPkgs."hs-boot-th".components.exes."hs-boot-th";
  haskellNixHsBootThSmoke = pkgs.runCommand "haskell-nix-hs-boot-th-smoke" { } ''
    mkdir -p "$out/bin" "$out/nix-support"
    ln -s ${haskellNixHsBootThExe}/bin/hs-boot-th "$out/bin/hs-boot-th"
    "$out/bin/hs-boot-th" > "$out/output.txt"
    grep -qx "hs-boot-th:42:base:dep-v1:splice:base:dep-v1:sibling" "$out/output.txt"
    cat > "$out/nix-support/hs-boot-th-smoke.json" <<'JSON'
    {"schema":"penance/hs-boot-th-smoke/1","source":"haskell.nix","executable":"hs-boot-th"}
    JSON
  '';
  haskellNixBenchProject = mkBaselineProject {
    name = "penance-bench";
    src = benchSrc;
    indexState = "2026-02-01T00:00:00Z";
    configureArgs = "--enable-tests --enable-benchmarks";
  };
  haskellNixBenchMaterializedProject = haskellNixBenchProject.appendModule {
    materialized = haskellNixBenchProject.plan-nix;
  };
  haskellNixBenchPlan = haskellNixBenchProject.plan-nix;
  haskellNixBenchPlanMaterialized = haskellNixBenchMaterializedProject.plan-nix.outPath;
  haskellNixBenchPackage = haskellNixBenchProject.hsPkgs."penance-bench";
  haskellNixBenchExe = haskellNixBenchPackage.components.exes."penance-bench";
  haskellNixBenchTest = haskellNixBenchPackage.components.tests."penance-bench-test";
  haskellNixBenchBenchmark = haskellNixBenchPackage.components.benchmarks."penance-bench-benchmark";
  haskellNixBenchChecks = pkgs.runCommand "haskell-nix-bench-checks" { } ''
    mkdir -p "$out"

    test_bin="$(find ${haskellNixBenchTest}/bin -maxdepth 1 -type f -perm -0100 | head -n 1)"
    benchmark_bin="$(find ${haskellNixBenchBenchmark}/bin -maxdepth 1 -type f -perm -0100 | head -n 1)"
    test -n "$test_bin"
    test -n "$benchmark_bin"

    ${runBenchChecks "$test_bin" "$benchmark_bin"}
  '';
  haskellNixHackageStateVarPackage = haskellNixPkgs.haskell-nix.hackage-package {
    name = "StateVar";
    version = hackageStateVarVersion;
    compiler-nix-name = "ghc910";
    index-state = "2026-02-01T00:00:00Z";
  };
  haskellNixHackageStateVar =
    mkLibraryManifest "haskell-nix-hackage-StateVar-${hackageStateVarVersion}"
      haskellNixHackageStateVarPackage.components.library
      {
        schema = "penance/hackage-package-set/1";
        package = "StateVar";
        version = hackageStateVarVersion;
        source = "haskell.nix-hackage";
      };
  haskellNixStackageStateVar =
    mkLibraryManifest "haskell-nix-stackage-${stackageResolver}-StateVar"
      haskellNixPkgs.haskell-nix.snapshots.${stackageResolver}.StateVar.components.library
      {
        schema = "penance/stackage-snapshot/1";
        resolver = stackageResolver;
        package = "StateVar";
        version = stackageStateVarVersion;
        source = "haskell.nix-stackage";
      };
  haskellNixBenchShell = haskellNixBenchProject.shellFor {
    packages = ps: [ ps."penance-bench" ];
    withHoogle = false;
  };
  haskellNixBenchO0Project = haskellNixBenchProject.appendModule {
    modules = [
      {
        packages.penance-bench.components.exes.penance-bench.ghcOptions = [ "-O0" ];
      }
    ];
  };
  haskellNixBenchO0Exe =
    haskellNixBenchO0Project.hsPkgs."penance-bench".components.exes."penance-bench";
  haskellNixCrossHelloProject = mkBaselineProject {
    name = "cross-hello";
    src = crossHelloSrc;
    compilerNixName = crossHaskellCompilerName;
    indexState = "2026-02-01T00:00:00Z";
    extra = {
      modules = [
        {
          packages.cross-hello.components.exes.cross-hello = {
            ghcOptions = [ "-fllvm" ];
            setupBuildFlags = pkgs.lib.mkForce [
              "--ghc-option=-fllvm"
              "--gcc-option=-fPIC"
            ];
          };
        }
      ];
      compilerSelection =
        p:
        let
          baseCrossCompiler = p.haskell-nix.compiler.${crossHaskellCompilerAttr}.override {
            ghcEvalPackages = haskellNixPkgs.pkgsBuildBuild;
          };
        in
        (builtins.mapAttrs (
          _: x:
          x.override {
            ghcEvalPackages = haskellNixPkgs.pkgsBuildBuild;
          }
        ) p.haskell-nix.compiler)
        // {
          ${crossHaskellCompilerAttr} = haskellNixCompilerShapeFor baseCrossCompiler penanceCrossHaskellGhc;
        };
    };
  };
  haskellNixCrossHelloExe =
    haskellNixCrossHelloProject.projectCross.aarch64-multiplatform.hsPkgs."cross-hello".components.exes."cross-hello";
  mkCrossExecutableManifest =
    name: root: metadata:
    pkgs.runCommand name
      {
        nativeBuildInputs = [
          pkgs.file
          pkgs.findutils
          pkgs.gnugrep
        ];
      }
      ''
        mkdir -p "$out/bin"
        exe="$(find ${root}/bin -maxdepth 1 -type f -perm -0100 | head -n 1)"
        test -n "$exe"
        cp "$exe" "$out/bin/cross-hello"
        ${assertCrossHelloElf}
        ${writeMetadataJson metadata}
      '';
  haskellNixProjectCrossAarch64 =
    mkCrossExecutableManifest "haskell-nix-project-cross-aarch64" haskellNixCrossHelloExe
      {
        schema = "penance/haskell-cross/1";
        target = crossHaskellTarget;
        compiler = crossHaskellCompilerName;
        source = "haskell.nix-projectCross";
      };
  haskellNixBenchSurface =
    let
      packageName = haskellNixBenchPackage.identifier.name;
      packageVersion = haskellNixBenchPackage.identifier.version;
      libraryComponents = pkgs.lib.optional (haskellNixBenchPackage.components ? library) {
        package = packageName;
        component = "lib";
        kind = "library";
        unitId = haskellNixBenchPackage.components.library.identifier.unit-id;
      };
      sublibraryComponents = map (name: {
        package = packageName;
        component = "lib:${name}";
        kind = "library";
        unitId = haskellNixBenchPackage.components.sublibs.${name}.identifier.unit-id;
      }) (builtins.attrNames (haskellNixBenchPackage.components.sublibs or { }));
      executableComponents = map (name: {
        package = packageName;
        component = "exe:${name}";
        kind = "executable";
        unitId = haskellNixBenchPackage.components.exes.${name}.identifier.unit-id;
      }) (builtins.attrNames (haskellNixBenchPackage.components.exes or { }));
      testComponents = map (name: {
        package = packageName;
        component = "test:${name}";
        kind = "test-suite";
        unitId = haskellNixBenchPackage.components.tests.${name}.identifier.unit-id;
      }) (builtins.attrNames (haskellNixBenchPackage.components.tests or { }));
      benchmarkComponents = map (name: {
        package = packageName;
        component = "bench:${name}";
        kind = "benchmark";
        unitId = haskellNixBenchPackage.components.benchmarks.${name}.identifier.unit-id;
      }) (builtins.attrNames (haskellNixBenchPackage.components.benchmarks or { }));
    in
    pkgs.writeText "haskell-nix-bench-surface.json" (
      builtins.toJSON {
        source = "haskell.nix";
        packages = [
          {
            name = packageName;
            version = packageVersion;
          }
        ];
        components =
          libraryComponents
          ++ sublibraryComponents
          ++ executableComponents
          ++ testComponents
          ++ benchmarkComponents;
      }
    );
in
{
  inherit
    haskellNixBackpackProject
    haskellNixBackpackExe
    haskellNixSimpleProject
    haskellNixSimpleLib
    haskellNixModuleCutoff30Project
    haskellNixModuleCutoff30Exe
    haskellNixHsBootThProject
    haskellNixHsBootThExe
    haskellNixHsBootThSmoke
    haskellNixBenchProject
    haskellNixBenchMaterializedProject
    haskellNixBenchPlan
    haskellNixBenchPlanMaterialized
    haskellNixBenchPackage
    haskellNixBenchExe
    haskellNixBenchTest
    haskellNixBenchBenchmark
    haskellNixBenchChecks
    haskellNixHackageStateVarPackage
    haskellNixHackageStateVar
    haskellNixStackageStateVar
    haskellNixBenchShell
    haskellNixBenchO0Project
    haskellNixBenchO0Exe
    haskellNixCrossHelloProject
    haskellNixCrossHelloExe
    mkCrossExecutableManifest
    haskellNixProjectCrossAarch64
    haskellNixBenchSurface
    ;
}
