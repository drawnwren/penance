{
  assertCrossHelloElf,
  backpackSrc,
  benchGhcPackageFlags,
  benchHpkgs,
  benchSrc,
  crossHaskellCompilerAttr,
  crossHaskellCompilerName,
  crossHaskellGhcFor,
  crossHaskellTarget,
  crossHelloSrc,
  hackageStateVarVersion,
  haskellNixCrossAarch64,
  hpkgs,
  lockExternalSrc,
  localThDependencySrc,
  multiInstanceExternalSrc,
  penanceLib,
  penanceStateVarHackageGhc,
  penanceStateVarStackageGhc,
  pkgs,
  plannerBin,
  simpleLibSrc,
  stackageResolver,
  stackageStateVarSnapshot,
  stackageStateVarSnapshotHash,
  stackageStateVarSnapshotUrl,
  stackageStateVarVersion,
  stripBin,
  writeMetadataJson,
  ...
}:
let
  penanceProject = args: penanceLib.penanceProject ({ contentAddressed = true; } // args);
  penanceBenchShellGhc = penanceBenchDevShell.passthru.penanceGhc;
  simpleLibComponent =
    (penanceProject {
      src = ../../../../tests/fixtures/simple-lib;
      compiler = "ghc-9.10.2";
      index-state = "2026-04-01T00:00:00Z";
      mode = "component";
    }).drvGraph;
  backpackSignaturesModule =
    (penanceProject {
      src = ../../../../tests/fixtures/backpack-signatures;
      compiler = "ghc-9.10.2";
      index-state = "2026-04-01T00:00:00Z";
      mode = "module";
    }).drvGraph;
  backpackMultiInstanceModule =
    (penanceProject {
      src = ../../../../tests/fixtures/backpack-multi-instance;
      compiler = "ghc-9.10.2";
      index-state = "2026-04-01T00:00:00Z";
      mode = "module";
    }).drvGraph;
  penanceBenchComponent =
    (penanceProject {
      src = benchSrc;
      compiler = "ghc-9.10.3";
      index-state = "2026-02-01T00:00:00Z";
      mode = "component";
    }).drvGraph;
  penanceBenchModule =
    (penanceProject {
      src = benchSrc;
      compiler = "ghc-9.10.3";
      index-state = "2026-02-01T00:00:00Z";
      mode = "module";
    }).drvGraph;
  penanceBenchLockProject = penanceProject {
    src = benchSrc;
    compiler = "ghc-9.10.2";
    index-state = "2026-02-01T00:00:00Z";
    mode = "component";
  };
  penanceBenchSurface = penanceBenchLockProject.surface;
  penanceBenchLibViaLock = penanceBenchLockProject.packages."penance-bench".components.lib;
  penanceBenchViaLock =
    penanceBenchLockProject.packages."penance-bench".components."exe:penance-bench";
  penanceBenchTestViaLock =
    penanceBenchLockProject.packages."penance-bench".components."test:penance-bench-test";
  penanceBenchBenchmarkViaLock =
    penanceBenchLockProject.packages."penance-bench".components."bench:penance-bench-benchmark";
  penanceBenchDevShell = penanceBenchLockProject.devShells.default;
  penanceBenchO0LockProject = penanceProject {
    src = benchSrc;
    compiler = "ghc-9.10.2";
    index-state = "2026-02-01T00:00:00Z";
    mode = "component";
    ghcOptions = [ "-O0" ];
  };
  penanceBenchO0ViaLock =
    penanceBenchO0LockProject.packages."penance-bench".components."exe:penance-bench";
  penanceSimpleLibLockProject = penanceProject {
    src = simpleLibSrc;
    compiler = "ghc-9.10.2";
    index-state = "2026-04-01T00:00:00Z";
    mode = "component";
  };
  penanceSimpleLibViaLock = penanceSimpleLibLockProject.packages."simple-lib".components.lib;
  penanceLockExternalProject = penanceProject {
    src = lockExternalSrc;
    hackageNix = ../../../penance-hackage;
    compiler = "ghc-9.10.3";
    index-state = "2026-02-01T00:00:00Z";
    mode = "component";
  };
  penanceLockExternalViaLock =
    penanceLockExternalProject.packages."lock-external".components."exe:lock-external";
  localThDependencyProject = penanceProject {
    src = localThDependencySrc;
    compiler = "ghc-9.10.2";
    index-state = "2026-04-01T00:00:00Z";
    mode = "component";
  };
  localThConsumer =
    localThDependencyProject.packages."local-th-consumer".components."exe:local-th-consumer";
  localThLock = builtins.fromJSON (builtins.readFile (localThDependencySrc + "/penance.lock"));
  localThInterfaceLock = localThLock // {
    packages = map (
      package:
      if package.name == "local-th-consumer" then
        package
        // {
          components = map (
            component:
            if component.name == "exe:local-th-consumer" then
              component // { needsFullDb = false; }
            else
              component
          ) package.components;
        }
      else
        package
    ) localThLock.packages;
  };
  localThInterfaceProject = penanceProject {
    src = localThDependencySrc;
    compiler = "ghc-9.10.2";
    index-state = "2026-04-01T00:00:00Z";
    mode = "component";
    lockOverride = localThInterfaceLock;
  };
  localThInterfaceConsumer =
    localThInterfaceProject.packages."local-th-consumer".components."exe:local-th-consumer";
  penanceLocalThDependency =
    assert localThConsumer.compile.localDependencyDb == "dbFull";
    assert localThInterfaceConsumer.compile.localDependencyDb == "dbIface";
    assert localThConsumer.compile.drvPath != localThInterfaceConsumer.compile.drvPath;
    pkgs.runCommand "penance-local-th-dependency-proof"
      {
        nativeBuildInputs = [ pkgs.jq ];
      }
      ''
        mkdir -p "$out"
        ${localThConsumer}/bin/local-th-consumer > "$out/output.txt"
        grep -qx local-th-producer "$out/output.txt"
        jq -e '.localDependencyDb == "dbFull"' ${localThConsumer.compile}/metadata.json >/dev/null
        cp ${localThConsumer.compile}/metadata.json "$out/compile-metadata.json"
      '';
  multiInstanceExternalProject = penanceProject {
    src = multiInstanceExternalSrc;
    hackageNix = multiInstanceExternalSrc + "/nix/penance-hackage";
    mode = "component";
  };
  multiInstanceEnabled =
    multiInstanceExternalProject.packages."multi-instance-external".components."exe:consumer-enabled";
  multiInstanceDisabled =
    multiInstanceExternalProject.packages."multi-instance-external".components."exe:consumer-disabled";
  multiInstanceRawLock = builtins.fromJSON (
    builtins.readFile (multiInstanceExternalSrc + "/penance.lock")
  );
  multiInstanceCorruptLock = multiInstanceRawLock // {
    packages = map (
      package:
      package
      // {
        components = map (
          component:
          if component.name == "exe:consumer-enabled" then
            component // { externalDepends = [ "missing-hashable-unit" ]; }
          else
            component
        ) package.components;
      }
    ) multiInstanceRawLock.packages;
  };
  multiInstanceCorruptResult = builtins.tryEval (
    builtins.deepSeq (penanceLib.lowerLock multiInstanceCorruptLock) true
  );
  penanceMultiInstanceExternal =
    assert !multiInstanceCorruptResult.success;
    pkgs.runCommand "penance-multi-instance-external-proof"
      {
        nativeBuildInputs = [ pkgs.jq ];
      }
      ''
        mkdir -p "$out"

        ${multiInstanceEnabled}/bin/consumer-enabled > "$out/enabled.txt"
        ${multiInstanceDisabled}/bin/consumer-disabled > "$out/disabled.txt"

        jq -e '
          .directHackageUnitIds == ["hashable-1.5.0.0-random-enabled"]
        ' ${multiInstanceEnabled.compile}/metadata.json >/dev/null
        jq -e '
          .directHackageUnitIds == ["hashable-1.5.0.0-random-disabled"]
        ' ${multiInstanceDisabled.compile}/metadata.json >/dev/null

        cp ${multiInstanceEnabled.compile}/metadata.json "$out/enabled-metadata.json"
        cp ${multiInstanceDisabled.compile}/metadata.json "$out/disabled-metadata.json"
        printf '%s\n' rejected > "$out/corrupted-edge.txt"
      '';
  mkPenanceModuleGranularBench =
    name:
    let
      core =
        pkgs.runCommand "${name}-core"
          {
            nativeBuildInputs = [
              benchHpkgs.ghc
              pkgs.findutils
              pkgs.gnugrep
              plannerBin
            ];
          }
          ''
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
              --lock penance.lock \
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
    pkgs.runCommand name { } ''
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
  penanceBenchChecks = pkgs.runCommand "penance-bench-checks" { } ''
    mkdir -p "$out"
    ${runBenchChecks "${penanceBenchTestViaLock}/bin/penance-bench-test" "${penanceBenchBenchmarkViaLock}/bin/penance-bench-benchmark"}
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
  mkStateVarCompileProof =
    name: ghc: metadata:
    pkgs.runCommand name
      {
        nativeBuildInputs = [
          ghc
        ];
      }
      ''
        mkdir -p "$out/bin"
        ${stateVarProofScript "statevar-proof"}
        ${writeMetadataJson metadata}
      '';
  mkStackageStateVarCompileProof =
    name: ghc: metadata:
    pkgs.runCommand name
      {
        nativeBuildInputs = [
          ghc
          pkgs.coreutils
          pkgs.gawk
          pkgs.gnugrep
        ];
      }
      ''
        mkdir -p "$out/bin"
        cp ${stackageStateVarSnapshot} "$out/snapshot.yaml"
        snapshot_hash="$(sha256sum "$out/snapshot.yaml" | awk '{print $1}')"
        test "$snapshot_hash" = "${stackageStateVarSnapshotHash}"
        awk -v package=StateVar '
          match($0, "^- hackage: " package "-([0-9][^@[:space:]]*)@", fields) {
            print package, fields[1], $0
            found = 1
            exit
          }
          END { if (!found) exit 1 }
        ' "$out/snapshot.yaml" > "$out/snapshot-resolution.txt"
        resolved_version="$(awk '{print $2}' "$out/snapshot-resolution.txt")"
        test "$resolved_version" = "${stackageStateVarVersion}"
        ${stateVarProofScript "stackage-statevar-proof"}
        built_version="$(ghc-pkg field StateVar version --simple-output)"
        test "$built_version" = "$resolved_version"
        ${writeMetadataJson metadata}
      '';
  mkCrossHaskellCompileProof =
    name: ghc: metadata:
    pkgs.runCommand name
      {
        nativeBuildInputs = [
          ghc
          pkgs.file
          pkgs.gnugrep
        ];
      }
      ''
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
  mkLibraryManifest =
    name: root: metadata:
    pkgs.runCommand name
      {
        nativeBuildInputs = [
          pkgs.findutils
        ];
      }
      ''
        mkdir -p "$out"
        test -e ${root}
        find ${root} -type f | sort > "$out/files.txt"
        test -s "$out/files.txt"
        ${writeMetadataJson metadata}
      '';
  mkPenanceShellProof =
    name: shell:
    pkgs.runCommand name
      {
        nativeBuildInputs = [
          shell.passthru.penanceGhc
          pkgs.cabal-install
          pkgs.coreutils
          pkgs.findutils
          pkgs.gnugrep
        ];
      }
      ''
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
        test ${pkgs.lib.escapeShellArg shell.PENANCE_LOCK_PACKAGES} = ${pkgs.lib.escapeShellArg (pkgs.lib.concatStringsSep " " shell.passthru.penanceProjection.externalPackages)}
        test ${pkgs.lib.escapeShellArg shell.PENANCE_LOCAL_PACKAGES} = ${pkgs.lib.escapeShellArg (pkgs.lib.concatStringsSep " " shell.passthru.penanceProjection.localPackages)}
        exe="$(find dist-newstyle -type f -perm -0100 -name penance-bench | head -n 1)"
        test -n "$exe"
        cp "$exe" "$out/bin/shell-proof"
        "$out/bin/shell-proof" > "$out/output.txt"
        grep -q "generated:penance-bench" "$out/output.txt"
        ghc-pkg list ${pkgs.lib.concatStringsSep " " shell.passthru.penanceProjection.externalPackages} > "$out/package-db.txt"
        cabal --numeric-version > "$out/cabal-version.txt"
        cat > "$out/nix-support/penance-shell.json" <<'JSON'
        {"schema":"penance/dev-shell-proof/1","compiler":"ghc","packages":${builtins.toJSON shell.passthru.penanceProjection.externalPackages},"localPackages":${builtins.toJSON shell.passthru.penanceProjection.localPackages},"cabal":true,"externalBuilds":0}
        JSON
      '';
  mkVariantBundle =
    name: entries:
    pkgs.runCommand name { } (
      ''
        mkdir -p "$out/variants"
      ''
      + pkgs.lib.concatStringsSep "\n" (
        map (entry: ''
          ln -s ${entry.path} "$out/variants/${entry.name}"
          test -e "$out/variants/${entry.name}"
        '') entries
      )
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
    mkStateVarCompileProof "penance-hackage-StateVar-${hackageStateVarVersion}"
      penanceStateVarHackageGhc
      {
        schema = "penance/hackage-package-set/1";
        package = "StateVar";
        version = hackageStateVarVersion;
        source = "hackage";
      };
  penanceStackageStateVar =
    mkStackageStateVarCompileProof "penance-stackage-${stackageResolver}-StateVar"
      penanceStateVarStackageGhc
      {
        schema = "penance/stackage-snapshot/1";
        resolver = stackageResolver;
        package = "StateVar";
        version = stackageStateVarVersion;
        resolvedFrom = "tests/fixtures/stackage/${stackageResolver}-StateVar.yaml";
        snapshotUrl = stackageStateVarSnapshotUrl;
        source = "stackage-snapshots";
      };
  penanceBenchShell = mkPenanceShellProof "penance-bench-shell" penanceBenchDevShell;
  penanceBackpackReal =
    let
      backpackCabal = pkgs.haskell.lib.dontHaddock (
        pkgs.haskell.lib.disableLibraryProfiling (
          pkgs.haskell.lib.disableExecutableProfiling (
            pkgs.haskell.lib.disableSharedLibraries (
              hpkgs.callCabal2nix "backpack-multi-instance" backpackSrc { }
            )
          )
        )
      );
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
    pkgs.runCommand "penance-backpack-real" { } ''
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
    mkCrossHaskellCompileProof "penance-haskell-aarch64-linux-real" penanceCrossHaskellGhc
      {
        schema = "penance/haskell-cross/1";
        target = crossHaskellTarget;
        compiler = crossHaskellCompilerName;
        source = "raw-cross-ghc";
      };
in
{
  inherit
    penanceBenchShellGhc
    simpleLibComponent
    backpackSignaturesModule
    backpackMultiInstanceModule
    penanceBenchComponent
    penanceBenchModule
    penanceBenchLockProject
    penanceBenchSurface
    penanceBenchLibViaLock
    penanceBenchViaLock
    penanceBenchTestViaLock
    penanceBenchBenchmarkViaLock
    penanceBenchDevShell
    penanceBenchO0LockProject
    penanceBenchO0ViaLock
    penanceSimpleLibLockProject
    penanceSimpleLibViaLock
    penanceLockExternalProject
    penanceLockExternalViaLock
    localThDependencyProject
    localThConsumer
    penanceLocalThDependency
    multiInstanceExternalProject
    multiInstanceEnabled
    multiInstanceDisabled
    penanceMultiInstanceExternal
    mkPenanceModuleGranularBench
    runBenchChecks
    penanceBenchChecks
    stateVarProofScript
    mkStateVarCompileProof
    mkStackageStateVarCompileProof
    mkCrossHaskellCompileProof
    mkLibraryManifest
    mkPenanceShellProof
    mkVariantBundle
    penanceHackageStateVar
    penanceStackageStateVar
    penanceBenchShell
    penanceBackpackReal
    penanceCrossHaskellGhc
    penanceHaskellAarch64LinuxReal
    ;
}
