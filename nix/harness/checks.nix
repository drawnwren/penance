{
  self,
  forAllSystems,
  pkgsFor,
}:
forAllSystems (
  system:
  let
    pkgs = pkgsFor.${system};
    stateVarOverrideSource = pkgs.fetchurl {
      name = "StateVar-1.2.2-package-set-override.tar.gz";
      url = "https://hackage.haskell.org/package/StateVar-1.2.2/StateVar-1.2.2.tar.gz";
      hash = "sha256-Xks52jlWVqWYJ7AoBQiq/ccDNXmLUOXW/VJZYCYlGCU=";
    };
    sharedPackageSet = self.lib.${system}.packageSet {
      source = ../../planner-bin/test/data/package-set.nix;
      hackageNix = ../penance-hackage;
      overrides = {
        StateVar = {
          src = stateVarOverrideSource;
          package =
            { previous, ... }:
            assert previous.src == stateVarOverrideSource;
            previous.overrideAttrs (old: {
              postInstall = (old.postInstall or "") + ''
                conf_dir="$(find "$out/lib" -type d -name package.conf.d | head -n 1)"
                test -n "$conf_dir"
                cat > "$conf_dir/penance-regression-internal.conf" <<'EOF'
                name: z-StateVar-z-penance-regression-internal
                lib-name: penance-regression-internal
                version: 1.2.2
                id: z-StateVar-z-penance-regression-internal-1.2.2
                key: z-StateVar-z-penance-regression-internal-1.2.2
                exposed: False
                exposed-modules:
                import-dirs:
                library-dirs:
                hs-libraries:
                depends:
                EOF
                touch "$out/penance-package-set-override"
              '';
            });
        };
      };
    };
    sharedPackageSetRawLock = builtins.fromJSON (
      builtins.readFile ../../tests/fixtures/lock-external/penance.lock
    );
    sharedStateVarUnit = pkgs.lib.findFirst (
      unit: unit.source == "hackage" && unit.name == "StateVar"
    ) (throw "shared package-set fixture needs StateVar") sharedPackageSetRawLock.externalUnits;
    sharedStateVarInternalUnit = sharedStateVarUnit // {
      unitId = "StateVar-1.2.2-penance-regression-internal";
      component = "lib:penance-regression-internal";
    };
    sharedPackageSetLock = sharedPackageSetRawLock // {
      packageSetHash = sharedPackageSet.__penance.hash;
      externalUnits =
        map (
          unit:
          if unit.unitId == sharedStateVarUnit.unitId then
            unit
            // {
              depends = unit.depends ++ [ sharedStateVarInternalUnit.unitId ];
            }
          else
            unit
        ) sharedPackageSetRawLock.externalUnits
        ++ [ sharedStateVarInternalUnit ];
    };
    sharedPackageSetProject = self.lib.${system}.penanceProject {
      src = ../../tests/fixtures;
      projectRoot = "lock-external";
      packageSet = sharedPackageSet;
      lockOverride = sharedPackageSetLock;
    };
    corruptedSharedPackageSetLock = sharedPackageSetLock // {
      externalUnits = map (
        unit:
        if unit.source == "hackage" then
          unit
          // {
            sdist = unit.sdist // {
              sha256 = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
            };
          }
        else
          unit
      ) sharedPackageSetLock.externalUnits;
    };
    corruptedSharedPackageSetEvaluation =
      builtins.tryEval
        (self.lib.${system}.penanceProject {
          src = ../../tests/fixtures;
          projectRoot = "lock-external";
          packageSet = sharedPackageSet;
          lockOverride = corruptedSharedPackageSetLock;
        }).packages.lock-external.components."exe:lock-external".drvPath;
    sharedPackageSetUnitId =
      (builtins.head (
        builtins.filter (unit: unit.source == "hackage") sharedPackageSetLock.externalUnits
      )).unitId;
    overriddenExternalPackage =
      sharedPackageSetProject.packages.lock-external.externalPackages.${sharedPackageSetUnitId};
    overriddenExternalSlice =
      sharedPackageSetProject.packages.lock-external.externalUnits.${sharedPackageSetUnitId};
    overriddenExternalInternalSlice =
      sharedPackageSetProject.packages.lock-external.externalUnits.${sharedStateVarInternalUnit.unitId};
  in
  {
    ghc-wasm-planner = self.packages.${system}.plannerNormalizerNative;
    penance-tests =
      pkgs.runCommand "penance-tests-check"
        {
          nativeBuildInputs = [ pkgs.gnugrep ];
        }
        ''
          logs=${self.packages.${system}.plannerBin}/share/penance-tests
          test -f "$logs/penance-planner-0.1.0.0-penance-tests.log"
          test -f "$logs/penance-planner-0.1.0.0-wasm-planner-tests.log"
          grep -Eq 'All [0-9]+ tests passed' "$logs/penance-planner-0.1.0.0-penance-tests.log"
          grep -q 'penance-wasm-planner: tests passed' "$logs/penance-planner-0.1.0.0-wasm-planner-tests.log"
          touch "$out"
        '';
    repent-lock-proof = self.packages.${system}.repentBench;
    c-sources = self.packages.${system}.penanceCSources;
    shared-package-set =
      assert !corruptedSharedPackageSetEvaluation.success;
      assert
        sharedPackageSetProject.devShells.default.PENANCE_PACKAGE_SET
        == toString sharedPackageSet.__penance.source;
      pkgs.runCommand "penance-shared-package-set-proof" { } ''
        test -x ${
          sharedPackageSetProject.packages.lock-external.components."exe:lock-external"
        }/bin/lock-external
        test -f ${overriddenExternalPackage}/penance-package-set-override
        test "$(find ${overriddenExternalPackage}/lib -path '*/package.conf.d/*.conf' -type f | wc -l | tr -d ' ')" = 2
        test "$(find ${overriddenExternalSlice}/lib/package.conf.d -name '*.conf' -type f | wc -l | tr -d ' ')" = 1
        grep -R '^name:[[:space:]]*StateVar$' ${overriddenExternalSlice}/lib/package.conf.d
        test "$(find ${overriddenExternalInternalSlice}/lib/package.conf.d -name '*.conf' -type f | wc -l | tr -d ' ')" = 1
        grep -R '^lib-name:[[:space:]]*penance-regression-internal$' ${overriddenExternalInternalSlice}/lib/package.conf.d
        test ${pkgs.lib.escapeShellArg sharedPackageSetProject.packageSetHash} = ${pkgs.lib.escapeShellArg sharedPackageSet.__penance.hash}
        touch "$out"
      '';
    hackage-lock-resolution =
      pkgs.runCommand "penance-hackage-lock-resolution"
        {
          nativeBuildInputs = [ pkgs.jq ];
        }
        ''
          root=${../..}
          while IFS= read -r -d $'\0' lock; do
            lock_dir="$(dirname "$lock")"
            while IFS= read -r expression; do
              test -n "$expression"
              if test -f "$lock_dir/nix/penance-hackage/$expression"; then
                continue
              fi
              if test -f "$root/nix/penance-hackage/$expression"; then
                continue
              fi
              echo "$lock: missing generated Hackage expression $expression" >&2
              exit 1
            done < <(jq -r '.externalUnits[] | select(.source == "hackage") | .nixExpression' "$lock")
          done < <(find "$root" -type f -name penance.lock -print0)

          test -x ${self.packages.${system}.penanceBenchViaLock}/bin/penance-bench
          test -x ${self.packages.${system}.penanceLockExternalViaLock}/bin/lock-external
          test -f ${self.packages.${system}.penanceMultiInstanceExternal}/enabled-metadata.json
          test -f ${self.packages.${system}.penanceMultiInstanceExternal}/disabled-metadata.json
          touch "$out"
        '';
    planner-wasm-provenance =
      pkgs.runCommand "penance-planner-wasm-provenance"
        {
          nativeBuildInputs = [
            pkgs.coreutils
            pkgs.diffutils
          ];
        }
        ''
          built=${self.packages.${system}.ghcWasmPlanner}/planner.wasm
          cmp ${../planner.wasm} "$built"

          cp "$built" corrupt.wasm
          chmod u+w corrupt.wasm
          printf '\\000' | dd of=corrupt.wasm bs=1 seek=1 count=1 conv=notrunc status=none
          if cmp -s ${../planner.wasm} corrupt.wasm; then
            echo "corrupted planner.wasm unexpectedly matched the committed artifact" >&2
            exit 1
          fi

          touch "$out"
        '';
    lowerer-wasm-provenance = self.packages.${system}.penanceLowererWasmProvenance;
    component-qualified-dependencies = self.packages.${system}.penanceComponentQualifiedDependencies;
    unit-cache-isolation = self.packages.${system}.penanceUnitCacheIsolation;
    multi-instance-external = self.packages.${system}.penanceMultiInstanceExternal;
    local-th-dependency = self.packages.${system}.penanceLocalThDependency;
    ghc-wasm-iface-canonicalizer = self.packages.${system}.ghcWasmIfaceCanonicalizer;
    iface-canonicalizer-wasm-provenance =
      pkgs.runCommand "penance-iface-canonicalizer-wasm-provenance"
        {
          nativeBuildInputs = [
            pkgs.coreutils
            pkgs.diffutils
          ];
        }
        ''
          built=${self.packages.${system}.ghcWasmIfaceCanonicalizerBuilt}/libexec/penance-iface-canon.wasm
          cmp ${../iface-canonicalizer.wasm} "$built"

          cp "$built" corrupt.wasm
          chmod u+w corrupt.wasm
          printf '\\000' | dd of=corrupt.wasm bs=1 seek=1 count=1 conv=notrunc status=none
          if cmp -s ${../iface-canonicalizer.wasm} corrupt.wasm; then
            echo "corrupted interface canonicalizer unexpectedly matched the committed artifact" >&2
            exit 1
          fi

          touch "$out"
        '';
    ghc-wasm-iface-canonicalizer-proof = self.packages.${system}.penanceIfaceCanonicalizerProof;
    simple-lib-component = self.packages.${system}.simpleLibComponent;
    backpack-signatures-module = self.packages.${system}.backpackSignaturesModule;
    backpack-multi-instance-module = self.packages.${system}.backpackMultiInstanceModule;
    graph-plan-prototype =
      pkgs.runCommand "penance-graph-plan-prototype-check"
        {
          nativeBuildInputs = [ pkgs.jq ];
        }
        ''
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
    bench-surface-parity =
      pkgs.runCommand "penance-bench-surface-parity"
        {
          nativeBuildInputs = [
            pkgs.diffutils
            pkgs.jq
            pkgs.perl
          ];
        }
        ''
          mkdir -p "$out"
          ${../../scripts/validate-surface-parity.sh} \
            ${self.packages.${system}.penanceBenchSurface} \
            ${self.packages.${system}.haskellNixBenchSurface} \
            ${../../tests/bench/vs-haskell-nix/project/penance-bench.cabal} \
            "$out"
        '';
    architecture-suite-static =
      pkgs.runCommand "penance-architecture-suite-static"
        {
          nativeBuildInputs = [
            pkgs.jq
          ];
        }
        ''
          ${self.packages.${system}.plannerBin}/bin/penance-architecture-bench \
            --matrix ${../../tests/architecture/phase-matrix.json} \
            --list >/dev/null
          jq -e '
            .schema == "penance/architecture-phase-matrix/1"
            and (.phases | length) >= 8
            and all(.phases[]; has("id") and has("milestone") and has("status") and has("required"))
            and all(.phases[]; .status == "comparison")
            and all(.phases[]; (.penanceAttr != null and .haskellNixAttr != null))
            and all(.phases[]; [(.comparison // ""), (.penanceAttr // ""), (.haskellNixAttr // "")] | join(" ") | test("(?i)(proxy|placeholder|planned|surface)") | not)
          ' ${../../tests/architecture/phase-matrix.json} >/dev/null
          touch "$out"
        '';
    haskell-nix-baseline-static =
      pkgs.runCommand "penance-haskell-nix-baseline-static"
        {
          nativeBuildInputs = [
            pkgs.jq
          ];
        }
        ''
          ${self.packages.${system}.plannerBin}/bin/penance-architecture-bench \
            --matrix ${../../tests/architecture/haskell-nix-baseline-matrix.json} \
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
          ' ${../../tests/architecture/haskell-nix-baseline-matrix.json} >/dev/null
          touch "$out"
        '';
    architecture-functionality-static =
      pkgs.runCommand "penance-architecture-functionality-static"
        {
          nativeBuildInputs = [
            pkgs.jq
          ];
        }
        ''
          ${self.packages.${system}.plannerBin}/bin/penance-architecture-bench \
            --matrix ${../../tests/architecture/functionality-gap-matrix.json} \
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
            and ([.phases[] | select(.status == "proof").id] | sort) == ["M2-lowerer-equality"]
            and all(.phases[]; .status == "failing" or .status == "proof" or .status == "comparison")
            and all(.phases[];
              if .status == "failing" then
                (.penanceAttr == null and .haskellNixAttr == null and (.failure | type == "string") and (.failure | length > 0))
              elif .status == "proof" then
                (.penanceAttr != null and .haskellNixAttr == null and .failure == null)
              else
                (.penanceAttr != null and .haskellNixAttr != null and .failure == null)
              end)
            and (([.description // ""] + [.phases[] | [(.id // ""), (.title // ""), (.comparison // ""), (.failure // ""), (.notes // "")] | join(" ")] | join(" ")) | test("(?i)(proxy|placeholder|planned|hardening)") | not)
          ' ${../../tests/architecture/functionality-gap-matrix.json} >/dev/null
          touch "$out"
        '';
    nix-format =
      pkgs.runCommand "penance-nix-format-check"
        {
          nativeBuildInputs = [
            pkgs.findutils
            pkgs.nix
            pkgs.nixfmt
            pkgs.statix
          ];
        }
        ''
          mkdir nix-conf
          touch nix-conf/nix.conf
          export NIX_CONF_DIR="$PWD/nix-conf"

          find ${../..} -type f -name '*.nix' -print0 | sort -z > nix-files
          xargs -0 -n1 nix-instantiate --parse < nix-files >/dev/null
          xargs -0 nixfmt --check < nix-files
          statix check ${../..}
          touch "$out"
        '';
  }
)
