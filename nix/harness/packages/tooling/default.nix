{
  benchHpkgs,
  benchSrc,
  cSourcesSrc,
  ghcWasm,
  hpkgs,
  lockExternalSrc,
  localThDependencySrc,
  multiInstanceExternalSrc,
  pkgs,
  repentCabalDir,
  repentCabalIndexState,
  simpleLibSrc,
  system,
  ...
}:
let
  plannerBin = hpkgs.mkDerivation {
    pname = "penance-planner";
    version = "0.1.0.0";
    src = ../../../../planner-bin;
    isLibrary = true;
    isExecutable = true;
    libraryHaskellDepends = with hpkgs; [
      base
      Cabal
      bytestring
      containers
      directory
      filepath
      process
    ];
    executableHaskellDepends = with hpkgs; [
      async
      base
      Cabal
      bytestring
      containers
      directory
      filepath
      process
      time
    ];
    testHaskellDepends = with hpkgs; [
      base
      Cabal
      containers
      directory
      filepath
      tasty
      tasty-hunit
      tasty-quickcheck
    ];
    postInstall = ''
      mkdir -p "$out/share/penance-tests"
      cp dist/test/*.log "$out/share/penance-tests/"
    '';
    mainProgram = "penance-planner";
  };
  repentTool = pkgs.writeShellApplication {
    name = "repent";
    runtimeInputs = [
      pkgs.cabal-install
      pkgs.cabal2nix
      hpkgs.ghc
      pkgs.nix
    ];
    text = ''
      export CABAL_DIR=${repentCabalDir}
      export PENANCE_INDEX_STATE=''${PENANCE_INDEX_STATE:-${repentCabalIndexState}}
      exec ${plannerBin}/bin/repent "$@"
    '';
  };
  penanceDocs =
    pkgs.runCommand "penance-docs"
      {
        nativeBuildInputs = [
          pkgs.mdbook
          pkgs.mdbook-mermaid
        ];
      }
      ''
        book_root="$TMPDIR/penance-book"
        cp -R ${../../../..}/. "$book_root"
        chmod -R u+w "$book_root"
        mdbook-mermaid install "$book_root"
        mdbook build "$book_root" --dest-dir "$out"
      '';
  plannerNormalizerNative =
    pkgs.runCommand "penance-planner-normalizer-native-0.1.0"
      {
        meta = {
          mainProgram = "normalize-project";
        };
      }
      ''
        mkdir -p "$out/bin"
        ln -s ${plannerBin}/bin/normalize-project "$out/bin/normalize-project"
        "$out/bin/normalize-project" --self-test
      '';
  ghcWasmPlanner =
    pkgs.runCommand "penance-planner-ghc-wasm-0.1.0"
      {
        nativeBuildInputs = [
          ghcWasm.packages.${system}.all_9_10
        ];
      }
      ''
        mkdir build "$out"
        wasm32-wasi-ghc \
          -O2 \
          -Wall \
          -i${../../../../planner-bin/src} \
          -odir build \
          -hidir build \
          -optl-Wl,--allow-undefined \
          -o build/planner.wasm \
          ${../../../../planner-bin/src/WasmBuiltinMain.hs}
        wasm-opt -Oz build/planner.wasm -o "$out/planner.wasm"
      '';
  ghcWasmIfaceCanonicalizerBuilt =
    pkgs.runCommand "penance-iface-canonicalizer-ghc-wasm-built-0.1.0"
      {
        nativeBuildInputs = [
          ghcWasm.packages.${system}.all_9_10
        ];
        meta = {
          mainProgram = "penance-iface-canon";
        };
      }
      ''
                    mkdir -p build "$out/bin" "$out/libexec"
                    wasm32-wasi-ghc \
                      -O2 \
                      -Wall \
                      -package ghc \
                      -odir build \
                      -hidir build \
                      -o build/penance-iface-canon.wasm \
                      ${../../../../planner-bin/src/IfaceCanonMain.hs}
                    wasm-opt -Oz build/penance-iface-canon.wasm -o "$out/libexec/penance-iface-canon.wasm"
                    cat > "$out/bin/penance-iface-canon" <<EOF
        #!${pkgs.runtimeShell}
        if [ -n "''${TMPDIR:-}" ]; then
          export HOME="\$TMPDIR"
          export XDG_CACHE_HOME="\$TMPDIR/.cache"
        fi
        exec ${pkgs.wasmtime}/bin/wasmtime run --dir / "$out/libexec/penance-iface-canon.wasm" "\$@"
        EOF
                    chmod 0555 "$out/bin/penance-iface-canon"
      '';
  ghcWasmIfaceCanonicalizer =
    pkgs.runCommand "penance-iface-canonicalizer-ghc-wasm-0.1.0"
      {
        meta = {
          mainProgram = "penance-iface-canon";
        };
      }
      ''
                    mkdir -p "$out/bin" "$out/libexec"
                    cp ${../../../iface-canonicalizer.wasm} "$out/libexec/penance-iface-canon.wasm"
                    cat > "$out/bin/penance-iface-canon" <<EOF
        #!${pkgs.runtimeShell}
        if [ -n "''${TMPDIR:-}" ]; then
          export HOME="\$TMPDIR"
          export XDG_CACHE_HOME="\$TMPDIR/.cache"
        fi
        exec ${pkgs.wasmtime}/bin/wasmtime run --dir / "$out/libexec/penance-iface-canon.wasm" "\$@"
        EOF
                    chmod 0555 "$out/bin/penance-iface-canon"
      '';
  penanceIfaceCanonicalizerProof =
    pkgs.runCommand "penance-iface-canonicalizer-proof"
      {
        nativeBuildInputs = [
          ghcWasmIfaceCanonicalizer
          pkgs.gawk
          pkgs.gnugrep
        ];
      }
      ''
        fixture=${../../../../tests/fixtures/iface-canonicalizer}

        compile_case() {
          ghc="$1"
          source="$2"
          case_dir="$3"
          mkdir -p "$case_dir"
          cp "$source" "$case_dir/IfaceSubject.hs"
          "$ghc" \
            -O0 \
            -fomit-interface-pragmas \
            -fignore-interface-pragmas \
            -fhide-source-paths \
            -fforce-recomp \
            -c "$case_dir/IfaceSubject.hs" \
            -odir "$case_dir" \
            -hidir "$case_dir"
        }

        prove_version() {
          ghc="$1"
          compiler_version="$("$ghc" --numeric-version)"
          label="ghc-$compiler_version"
          iface_version="$(printf '%s' "$compiler_version" | tr -d .)"
          case "$iface_version" in
            ""|*[!0-9]*)
              echo "$label: cannot derive interface version from GHC $compiler_version" >&2
              exit 1
              ;;
          esac
          root="$TMPDIR/$label"
          canon="$root/canonical"

          compile_case "$ghc" "$fixture/Baseline.hs" "$root/baseline"
          compile_case "$ghc" "$fixture/BodyEdit.hs" "$root/body-edit"
          compile_case "$ghc" "$fixture/ApiEdit.hs" "$root/api-edit"
          mkdir -p "$canon" "$root/consumer"

          if cmp -s "$root/baseline/IfaceSubject.hi" "$root/body-edit/IfaceSubject.hi"; then
            echo "$label: raw interfaces unexpectedly ignored a body edit" >&2
            exit 1
          fi

          penance-iface-canon \
            --input "$root/baseline/IfaceSubject.hi" \
            --output "$canon/IfaceSubject.hi" \
            --expect-version "$iface_version"
          penance-iface-canon \
            --input "$root/baseline/IfaceSubject.hi" \
            --output "$canon/IfaceSubject-again.hi" \
            --expect-version "$iface_version"
          penance-iface-canon \
            --input "$root/body-edit/IfaceSubject.hi" \
            --output "$canon/IfaceSubject-body.hi" \
            --expect-version "$iface_version"
          penance-iface-canon \
            --input "$root/api-edit/IfaceSubject.hi" \
            --output "$canon/IfaceSubject-api.hi" \
            --expect-version "$iface_version"
          penance-iface-canon \
            --input "$root/baseline/IfaceSubject.hi" \
            --output "$canon/IfaceSubject-dep-a.hi" \
            --expect-version "$iface_version" \
            --dependency-interface /nix/store/00000000000000000000000000000000-dep-a
          penance-iface-canon \
            --input "$root/baseline/IfaceSubject.hi" \
            --output "$canon/IfaceSubject-dep-b.hi" \
            --expect-version "$iface_version" \
            --dependency-interface /nix/store/00000000000000000000000000000000-dep-b
          penance-iface-canon \
            --input "$root/baseline/IfaceSubject.hi" \
            --output "$canon/IfaceSubject-deps-ab.hi" \
            --expect-version "$iface_version" \
            --dependency-interface /nix/store/00000000000000000000000000000000-dep-a \
            --dependency-interface /nix/store/00000000000000000000000000000000-dep-b
          penance-iface-canon \
            --input "$root/baseline/IfaceSubject.hi" \
            --output "$canon/IfaceSubject-deps-ba.hi" \
            --expect-version "$iface_version" \
            --dependency-interface /nix/store/00000000000000000000000000000000-dep-b \
            --dependency-interface /nix/store/00000000000000000000000000000000-dep-a

          cmp "$canon/IfaceSubject.hi" "$canon/IfaceSubject-again.hi"
          cmp "$canon/IfaceSubject.hi" "$canon/IfaceSubject-body.hi"
          if cmp -s "$canon/IfaceSubject.hi" "$canon/IfaceSubject-api.hi"; then
            echo "$label: API edit did not change the canonical interface" >&2
            exit 1
          fi
          if cmp -s "$canon/IfaceSubject-dep-a.hi" "$canon/IfaceSubject-dep-b.hi"; then
            echo "$label: dependency interface change did not propagate" >&2
            exit 1
          fi
          cmp "$canon/IfaceSubject-deps-ab.hi" "$canon/IfaceSubject-deps-ba.hi"

          "$ghc" --show-iface "$canon/IfaceSubject.hi" > "$root/show-iface.txt"
          awk '
            /^exports:$/ { in_exports = 1; next }
            /^module dependencies:/ { in_exports = 0 }
            in_exports { print }
          ' "$root/show-iface.txt" > "$root/exports.txt"
          grep -Fx '  foo' "$root/exports.txt"
          grep -Fx "  foo'" "$root/exports.txt"
          grep -Fx '  unsigned' "$root/exports.txt"

          cp "$fixture/Consumer.hs" "$root/consumer/Consumer.hs"
          cp "$canon/IfaceSubject.hi" "$root/consumer/IfaceSubject.hi"
          (
            cd "$root/consumer"
            "$ghc" \
              -O0 \
              -fomit-interface-pragmas \
              -fignore-interface-pragmas \
              -fhide-source-paths \
              -c Consumer.hs \
              -odir . \
              -hidir .
          )

          if penance-iface-canon \
            --input "$root/baseline/IfaceSubject.hi" \
            --output "$root/wrong-version.hi" \
            --expect-version wrong; then
            echo "$label: wrong producer version was accepted" >&2
            exit 1
          fi
        }

        prove_version ${hpkgs.ghc}/bin/ghc
        prove_version ${benchHpkgs.ghc}/bin/ghc

        mkdir -p "$out"
        printf '%s\n' \
          'GHC-Wasm canonicalizer proof passed for every configured native GHC.' \
          > "$out/proof.txt"
      '';
  penanceLib = import ../../../lib.nix {
    inherit pkgs;
    inherit (pkgs) lib;
    plannerWasm = ../../../planner.wasm;
    penancePlanner = plannerBin;
    ifaceCanonicalizer = ghcWasmIfaceCanonicalizer;
    repent = repentTool;
  };
  loweredLockFixtures = builtins.fromJSON (
    builtins.readFile ../../../../tests/fixtures/lowered-locks.json
  );
  lowererFixture =
    name: lockPath:
    let
      lock = builtins.fromJSON (builtins.readFile lockPath);
      pureNix = penanceLib.lowerLock lock;
      expected = loweredLockFixtures.${name};
    in
    {
      inherit expected pureNix;
      equal = builtins.deepSeq pureNix (builtins.deepSeq expected (pureNix == expected));
    };
  lowererWasmFixture =
    name: lockPath:
    let
      lock = builtins.fromJSON (builtins.readFile lockPath);
      wasm = builtins.fromJSON (
        builtins.wasm
          {
            path = ../../../planner.wasm;
          }
          (
            builtins.toJSON {
              operation = "lower-lock";
              inherit lock;
            }
          )
      );
      expected = loweredLockFixtures.${name};
    in
    {
      inherit expected wasm;
      equal = builtins.deepSeq wasm (builtins.deepSeq expected (wasm == expected));
    };
  lowererFixtures = [
    (lowererFixture "c-sources" (cSourcesSrc + "/penance.lock"))
    (lowererFixture "simple-lib" (simpleLibSrc + "/penance.lock"))
    (lowererFixture "lock-external" (lockExternalSrc + "/penance.lock"))
    (lowererFixture "penance-bench" (benchSrc + "/penance.lock"))
    (lowererFixture "local-th-dependency" (localThDependencySrc + "/penance.lock"))
    (lowererFixture "multi-instance-external" (multiInstanceExternalSrc + "/penance.lock"))
  ];
  lowererWasmFixtures = [
    (lowererWasmFixture "c-sources" (cSourcesSrc + "/penance.lock"))
    (lowererWasmFixture "simple-lib" (simpleLibSrc + "/penance.lock"))
    (lowererWasmFixture "lock-external" (lockExternalSrc + "/penance.lock"))
    (lowererWasmFixture "penance-bench" (benchSrc + "/penance.lock"))
    (lowererWasmFixture "local-th-dependency" (localThDependencySrc + "/penance.lock"))
    (lowererWasmFixture "multi-instance-external" (multiInstanceExternalSrc + "/penance.lock"))
  ];
  penanceLowererEquality =
    assert pkgs.lib.all (fixture: fixture.equal) lowererFixtures;
    assert pkgs.lib.all (
      fixture: fixture.pureNix != (fixture.expected // { compiler = "negative-control"; })
    ) lowererFixtures;
    pkgs.writeText "penance-lowerer-equality.json" (
      builtins.toJSON {
        schema = "penance/lowerer-equality/1";
        fixtures = [
          "c-sources"
          "simple-lib"
          "lock-external"
          "penance-bench"
          "local-th-dependency"
          "multi-instance-external"
        ];
        result = "equal";
        negativeControl = "different";
      }
    );
  penanceLowererWasmProvenance =
    assert pkgs.lib.all (fixture: fixture.equal) lowererWasmFixtures;
    pkgs.writeText "penance-lowerer-wasm-provenance.json" (
      builtins.toJSON {
        schema = "penance/lowerer-wasm-provenance/1";
        fixtures = [
          "c-sources"
          "simple-lib"
          "lock-external"
          "penance-bench"
          "local-th-dependency"
          "multi-instance-external"
        ];
        result = "equal";
      }
    );
  lockExternalRaw = builtins.fromJSON (builtins.readFile (lockExternalSrc + "/penance.lock"));
  simpleLibRaw = builtins.fromJSON (builtins.readFile (simpleLibSrc + "/penance.lock"));
  stateVarTemplate = pkgs.lib.findFirst (
    unit: unit.source == "hackage" && unit.name == "StateVar"
  ) (throw "cache-isolation fixture needs StateVar") lockExternalRaw.externalUnits;
  stateVarA = stateVarTemplate // {
    unitId = "StateVar-1.2.2-cache-a";
    flagHash = "aaaaaaaaaaaa";
  };
  stateVarB = stateVarTemplate // {
    unitId = "StateVar-1.2.2-cache-b";
    flagHash = "bbbbbbbbbbbb";
  };
  componentQualifiedStateVarFrontend = stateVarTemplate // {
    unitId = "StateVar-1.2.2-component-frontend";
    component = "lib:frontend";
  };
  componentQualifiedStateVarBackend = stateVarTemplate // {
    unitId = "StateVar-1.2.2-component-backend";
    component = "lib:backend";
  };
  componentQualifiedStateVarMain = stateVarTemplate // {
    unitId = "StateVar-1.2.2-component-main";
    depends = stateVarTemplate.depends ++ [
      componentQualifiedStateVarFrontend.unitId
      componentQualifiedStateVarBackend.unitId
    ];
  };
  cacheIsolationComponent = builtins.head (builtins.head simpleLibRaw.packages).components;
  cacheIsolationLock = simpleLibRaw // {
    inherit (lockExternalRaw) compiler indexState;
    externalUnits = builtins.filter (unit: unit.source != "hackage") lockExternalRaw.externalUnits ++ [
      stateVarA
      stateVarB
    ];
    packages = [
      (
        (builtins.head simpleLibRaw.packages)
        // {
          components = [
            (
              cacheIsolationComponent
              // {
                unitId = "simple-lib-cache-a";
                externalDepends = [
                  "base-4.20.1.0-79d1"
                  stateVarA.unitId
                ];
              }
            )
            (
              cacheIsolationComponent
              // {
                name = "lib:secondary";
                unitId = "simple-lib-cache-b";
                externalDepends = [
                  "base-4.20.1.0-79d1"
                  stateVarB.unitId
                ];
              }
            )
          ];
        }
      )
    ];
  };
  mutateExternalFlagHash =
    unitId: flagHash: lock:
    lock
    // {
      externalUnits = map (
        unit: if unit.unitId == unitId then unit // { inherit flagHash; } else unit
      ) lock.externalUnits;
    };
  cacheIsolationProject =
    lockOverride:
    penanceLib.penanceProject {
      contentAddressed = true;
      src = simpleLibSrc;
      hackageNix = ../../../penance-hackage;
      mode = "component";
      inherit lockOverride;
    };
  cacheBaseline = cacheIsolationProject cacheIsolationLock;
  cacheMutateA = cacheIsolationProject (
    mutateExternalFlagHash stateVarA.unitId "cccccccccccc" cacheIsolationLock
  );
  cacheMutateB = cacheIsolationProject (
    mutateExternalFlagHash stateVarB.unitId "dddddddddddd" cacheIsolationLock
  );
  componentDrvPath = project: component: project.packages.simple-lib.components.${component}.drvPath;
  danglingLock = cacheIsolationLock // {
    packages = map (
      package:
      package
      // {
        components = map (
          component:
          if component.name == "lib" then
            component // { externalDepends = [ "missing-unit-id" ]; }
          else
            component
        ) package.components;
      }
    ) cacheIsolationLock.packages;
  };
  danglingLowerResult = builtins.tryEval (builtins.deepSeq (penanceLib.lowerLock danglingLock) true);
  componentQualifiedDependencyLock = simpleLibRaw // {
    inherit (lockExternalRaw) compiler indexState;
    externalUnits = builtins.filter (unit: unit.source != "hackage") lockExternalRaw.externalUnits ++ [
      componentQualifiedStateVarFrontend
      componentQualifiedStateVarBackend
      componentQualifiedStateVarMain
    ];
    packages = [
      (
        (builtins.head simpleLibRaw.packages)
        // {
          components = map (
            component:
            component
            // {
              externalDepends =
                if component.name == "lib" then
                  [
                    "base-4.20.1.0-79d1"
                    componentQualifiedStateVarMain.unitId
                  ]
                else
                  component.externalDepends;
            }
          ) (builtins.head simpleLibRaw.packages).components;
        }
      )
    ];
  };
  componentQualifiedDependencyProject = penanceLib.penanceProject {
    src = simpleLibSrc;
    hackageNix = ../../../penance-hackage;
    mode = "component";
    lockOverride = componentQualifiedDependencyLock;
  };
  componentQualifiedDependencyEvaluation =
    builtins.tryEval
      componentQualifiedDependencyProject.packages.simple-lib.externalPackages.${componentQualifiedStateVarMain.unitId}.drvPath;
  penanceComponentQualifiedDependencies =
    assert componentQualifiedDependencyEvaluation.success;
    pkgs.writeText "penance-component-qualified-dependencies.json" (
      builtins.toJSON {
        schema = "penance/component-qualified-dependencies/1";
        duplicatePackageNames = "accepted";
        unitCount = 3;
      }
    );
  penanceUnitCacheIsolation =
    assert componentDrvPath cacheBaseline "lib" == componentDrvPath cacheMutateB "lib";
    assert
      componentDrvPath cacheBaseline "lib:secondary" != componentDrvPath cacheMutateB "lib:secondary";
    assert componentDrvPath cacheBaseline "lib" != componentDrvPath cacheMutateA "lib";
    assert
      componentDrvPath cacheBaseline "lib:secondary" == componentDrvPath cacheMutateA "lib:secondary";
    assert !danglingLowerResult.success;
    pkgs.writeText "penance-unit-cache-isolation.json" (
      builtins.toJSON {
        schema = "penance/unit-cache-isolation/1";
        unrelatedUnitMutation = "unchanged";
        directUnitMutation = "changed";
        danglingUnitEdge = "rejected";
      }
    );
in
{
  inherit
    plannerBin
    repentTool
    penanceDocs
    plannerNormalizerNative
    ghcWasmPlanner
    ghcWasmIfaceCanonicalizerBuilt
    ghcWasmIfaceCanonicalizer
    penanceIfaceCanonicalizerProof
    penanceLib
    loweredLockFixtures
    lowererFixture
    lowererWasmFixture
    lowererFixtures
    lowererWasmFixtures
    penanceLowererEquality
    penanceLowererWasmProvenance
    penanceComponentQualifiedDependencies
    penanceUnitCacheIsolation
    ;
}
