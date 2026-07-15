{
  benchDyndrvGhcFlagsText,
  benchGhc,
  benchGhcPackageFlags,
  benchGhcPackageNames,
  benchHpkgs,
  benchSrc,
  cutoff30DyndrvGhcFlagsText,
  ghcWasmIfaceCanonicalizer,
  hsBootThDyndrvGhcFlagsText,
  hsBootThSrc,
  mkPenanceModuleGranularBench,
  moduleCutoff30Src,
  penanceBenchViaLock,
  pkgs,
  plannerBin,
  system,
  ...
}:
let
  probePlannerPayload = ../../../../tests/probes/planner-payload.txt;
  probeAddPathPayload = ../../../../tests/probes/add-path-payload.txt;
  probeDeterminismSalt = pkgs.lib.replaceStrings [ "\n" "\r" ] [ "" "" ] (
    builtins.readFile ../../../../tests/probes/determinism-salt.txt
  );
  caCutoffToySrc = ../../../../tests/probes/ca-cutoff-toy;
  recursiveNixConfig = pkgs.writeTextDir "nix.conf" ''
    experimental-features = nix-command flakes ca-derivations dynamic-derivations recursive-nix
  '';
  mkPenanceProbePlanner =
    name:
    {
      corruptChildJson ? false,
      nondeterministic ? false,
      childName ? "penance-probe-planner",
      plannerRunSalt ? "",
      messageSuffix ? "",
    }:
    pkgs.runCommand name
      {
        __contentAddressed = true;
        outputHashMode = "text";
        outputHashAlgo = "sha256";
        requiredSystemFeatures = [ "recursive-nix" ];
        NIX_CONF_DIR = recursiveNixConfig;
        PENANCE_PROBE_PLANNER_SALT = plannerRunSalt;
      }
      ''
        set -euo pipefail
        nix_bin=${pkgs.nix}/bin/nix
        message="$(cat ${probePlannerPayload})"
        ${
          if messageSuffix != "" then
            ''
              message="$message ${messageSuffix}"
            ''
          else
            ""
        }
        ${
          if nondeterministic then
            ''
              message="$message $RANDOM"
            ''
          else
            ""
        }
        child_json="$TMPDIR/penance-probe-child.json"
        case "$message" in
          *\"*|*\\*)
            echo "probe payload contains characters not supported by the JSON emitter" >&2
            exit 1
            ;;
        esac

        ${
          if corruptChildJson then
            ''
              printf '{ "name": "${childName}", "outputs": ' > "$child_json"
            ''
          else
            ''
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
            ''
        }

        child_drv="$("$nix_bin" derivation add < "$child_json")"
        cp "$child_drv" "$out"
      '';
  mkPenanceAddPathPlanner =
    name:
    pkgs.runCommand name
      {
        __contentAddressed = true;
        outputHashMode = "text";
        outputHashAlgo = "sha256";
        requiredSystemFeatures = [ "recursive-nix" ];
        NIX_CONF_DIR = recursiveNixConfig;
      }
      ''
        set -euo pipefail
        nix_bin=${pkgs.nix}/bin/nix
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
  penanceProbePlanner = mkPenanceProbePlanner "penance-probe-planner.drv" { };
  penanceProbePlannerCorrupt = mkPenanceProbePlanner "penance-probe-planner-corrupt.drv" {
    corruptChildJson = true;
  };
  penanceProbePlannerNondeterministic =
    mkPenanceProbePlanner "penance-probe-planner-nondeterministic.drv"
      {
        childName = "penance-probe-planner-nondeterministic";
        nondeterministic = true;
      };
  penanceProbePlannerDeterminismA = mkPenanceProbePlanner "penance-probe-planner-determinism.drv" {
    childName = "penance-probe-planner-determinism";
    plannerRunSalt = "${probeDeterminismSalt}-a";
  };
  penanceProbePlannerDeterminismB = mkPenanceProbePlanner "penance-probe-planner-determinism.drv" {
    childName = "penance-probe-planner-determinism";
    plannerRunSalt = "${probeDeterminismSalt}-b";
  };
  penanceProbePlannerDeterminismBadA =
    mkPenanceProbePlanner "penance-probe-planner-determinism-bad.drv"
      {
        childName = "penance-probe-planner-determinism-bad";
        plannerRunSalt = "${probeDeterminismSalt}-bad-a";
        messageSuffix = "${probeDeterminismSalt}-bad-a";
      };
  penanceProbePlannerDeterminismBadB =
    mkPenanceProbePlanner "penance-probe-planner-determinism-bad.drv"
      {
        childName = "penance-probe-planner-determinism-bad";
        plannerRunSalt = "${probeDeterminismSalt}-bad-b";
        messageSuffix = "${probeDeterminismSalt}-bad-b";
      };
  penanceProbePlannerConsumer =
    let
      childOut = builtins.outputOf (builtins.unsafeDiscardOutputDependency penanceProbePlanner.outPath) "out";
    in
    pkgs.runCommand "penance-probe-planner-consumer" { } ''
      mkdir -p "$out"
      cp ${childOut} "$out/payload.txt"
      grep -q "hello dynamic child" "$out/payload.txt"
    '';
  penanceAddPathPlanner = mkPenanceAddPathPlanner "penance-add-path-planner.drv";
  penanceAddPathConsumer =
    let
      childOut = builtins.outputOf (builtins.unsafeDiscardOutputDependency penanceAddPathPlanner.outPath) "out";
    in
    pkgs.runCommand "penance-add-path-consumer" { } ''
      mkdir -p "$out"
      cp ${childOut} "$out/payload.txt"
      grep -q "hello recursive add-path" "$out/payload.txt"
    '';
  mkCaCutoffToy =
    srcRoot:
    let
      mkModule =
        moduleName: srcFile: depIfaces:
        pkgs.runCommand "penance-ca-toy-${moduleName}"
          {
            __contentAddressed = true;
            outputHashMode = "recursive";
            outputHashAlgo = "sha256";
            outputs = [
              "out"
              "hi"
              "o"
            ];
            nativeBuildInputs = [
              pkgs.coreutils
              pkgs.gnugrep
              pkgs.gnused
            ];
          }
          ''
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
      a = mkModule "A" (srcRoot + "/A.toy") [ ];
      b = mkModule "B" (srcRoot + "/B.toy") [ a.hi ];
      c = mkModule "C" (srcRoot + "/C.toy") [ b.hi ];
      link =
        pkgs.runCommand "penance-ca-toy-link"
          {
            nativeBuildInputs = [
              pkgs.coreutils
            ];
          }
          ''
            set -euo pipefail
            mkdir -p "$out"
            cat ${a.o}/object.txt ${b.o}/object.txt ${c.o}/object.txt > "$out/linked.txt"
            echo "linked penance-ca-toy" >&2
          '';
    };
  penanceCaCutoffToyGraph = mkCaCutoffToy caCutoffToySrc;
  penanceCaCutoffToyA = penanceCaCutoffToyGraph.a;
  penanceCaCutoffToyB = penanceCaCutoffToyGraph.b;
  penanceCaCutoffToyC = penanceCaCutoffToyGraph.c;
  penanceCaCutoffToy = penanceCaCutoffToyGraph.link;
  penanceModuleGranularBench = mkPenanceModuleGranularBench "penance-module-granular-bench";
  dyndrvToolDrvsFor = compiler: [
    pkgs.bash
    compiler
    pkgs.coreutils
    pkgs.findutils
    pkgs.gnugrep
    ghcWasmIfaceCanonicalizer
  ];
  dyndrvToolDrvArgsFor =
    compiler:
    pkgs.lib.concatMapStringsSep " \\\n          " (
      tool: "--tool-drv ${pkgs.lib.escapeShellArg (builtins.unsafeDiscardStringContext tool.drvPath)}"
    ) (dyndrvToolDrvsFor compiler);
  mkDyndrvPlanner =
    {
      name,
      src,
      compiler,
      component,
      ghcFlagsText,
      binName,
      smoke,
      dependencyFlags ? [ ],
      validatePlan ? "",
    }:
    let
      toolDrvs = dyndrvToolDrvsFor compiler;
      toolDrvArgs = dyndrvToolDrvArgsFor compiler;
    in
    pkgs.runCommand name
      {
        __contentAddressed = true;
        outputHashMode = "text";
        outputHashAlgo = "sha256";
        requiredSystemFeatures = [ "recursive-nix" ];
        NIX_CONF_DIR = recursiveNixConfig;
        nativeBuildInputs = [
          compiler
          plannerBin
          pkgs.coreutils
          pkgs.findutils
          pkgs.jq
          pkgs.nix
        ];
      }
      ''
                set -euo pipefail
                nix_bin=${pkgs.nix}/bin/nix

                cp -R ${src} source
                chmod -R u+w source
                cd source

                dep_flags=(
                  -dep-suffix ""
                  -include-pkg-deps
                  -isrc
                  -iapp
                  -odir ../make-build
                  -hidir ../make-build
        ${pkgs.lib.concatMapStringsSep "\n" (
          flag: "          ${pkgs.lib.escapeShellArg flag}"
        ) dependencyFlags}
                )
                mkdir -p ../make-build
                make_sources=()
                while IFS= read -r source_file; do
                  make_sources+=("$source_file")
                done < <(find app src -name '*.hs' -type f | sort)
                test "''${#make_sources[@]}" -gt 0
                ghc -M "''${dep_flags[@]}" -dep-makefile "$TMPDIR/module-deps.mk" "''${make_sources[@]}"

                penance-plan module-plan \
                  --makefile "$TMPDIR/module-deps.mk" \
                  --lock penance.lock \
                  --component ${pkgs.lib.escapeShellArg component} \
                  --out "$TMPDIR/module-plan.json"

        ${validatePlan}

                printf '%s\n' ${pkgs.lib.escapeShellArg ghcFlagsText} > "$TMPDIR/ghc-flags.txt"

                penance-plan emit-bench-dyndrv \
                  --module-plan "$TMPDIR/module-plan.json" \
                  --src-root "$PWD" \
                  --out "$TMPDIR/root.drv" \
                  --system ${pkgs.lib.escapeShellArg system} \
                  --nix-bin "$nix_bin" \
                  --builder ${pkgs.lib.escapeShellArg "${pkgs.bash}/bin/bash"} \
                  --path ${pkgs.lib.escapeShellArg (pkgs.lib.makeBinPath toolDrvs)} \
                  --ghc-flags "$TMPDIR/ghc-flags.txt" \
                  --bin-name ${pkgs.lib.escapeShellArg binName} \
                  --smoke ${pkgs.lib.escapeShellArg smoke} \
                  ${toolDrvArgs}
                cp "$TMPDIR/root.drv" "$out"
      '';
  mkPenanceBenchDyndrvPlanner =
    name:
    mkDyndrvPlanner {
      inherit name;
      src = benchSrc;
      compiler = benchGhc;
      component = "exe:penance-bench";
      ghcFlagsText = benchDyndrvGhcFlagsText;
      binName = "penance-bench";
      smoke = "generated:penance-bench";
      dependencyFlags = pkgs.lib.concatMap (name: [
        "-package"
        name
      ]) benchGhcPackageNames;
    };
  penanceBenchDyndrvPlanner = mkPenanceBenchDyndrvPlanner "penance-bench-dyndrv-planner.drv";
  penanceBenchDyndrvPlannerRepeat = mkPenanceBenchDyndrvPlanner "penance-bench-dyndrv-planner-repeat.drv";
  penanceBenchDyndrv =
    let
      dyndrvOut = builtins.outputOf (builtins.unsafeDiscardOutputDependency penanceBenchDyndrvPlanner.outPath) "out";
    in
    pkgs.runCommand "penance-bench-dyndrv" { } ''
      mkdir -p "$out"
      cp -R ${dyndrvOut}/. "$out/"
      "$out/bin/penance-bench" > "$out/output.txt.check"
      cmp "$out/output.txt" "$out/output.txt.check"
      ${penanceBenchViaLock}/bin/penance-bench > "$TMPDIR/static-output.txt"
      cmp "$TMPDIR/static-output.txt" "$out/output.txt"
    '';
  penanceDyndrvEmissionProof =
    pkgs.runCommand "penance-dyndrv-emission-proof"
      {
        requiredSystemFeatures = [ "recursive-nix" ];
        NIX_CONF_DIR = recursiveNixConfig;
        nativeBuildInputs = [
          benchGhc
          plannerBin
          pkgs.coreutils
          pkgs.diffutils
          pkgs.findutils
          pkgs.gnugrep
          pkgs.jq
          pkgs.nix
        ];
      }
      ''
                      set -euo pipefail
                      nix_bin=${pkgs.nix}/bin/nix
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
                          make_sources=()
                          while IFS= read -r source_file; do
                            make_sources+=("$source_file")
                          done < <(find app src -name '*.hs' -type f | sort)
                          test "''${#make_sources[@]}" -gt 0
                          ghc -M "''${dep_flags[@]}" -dep-makefile "$work/module-deps.mk" "''${make_sources[@]}"

                          penance-plan module-plan \
                            --makefile "$work/module-deps.mk" \
                            --lock penance.lock \
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
                            --path ${pkgs.lib.escapeShellArg (pkgs.lib.makeBinPath (dyndrvToolDrvsFor benchGhc))} \
                            --ghc-flags "$work/ghc-flags.txt" \
                            --bin-name penance-bench \
                            --smoke generated:penance-bench \
                            ${dyndrvToolDrvArgsFor benchGhc}
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
                      ${penanceBenchViaLock}/bin/penance-bench > "$TMPDIR/static-output.txt"
                      cmp "$TMPDIR/static-output.txt" "$out/output.txt"

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
  penanceModuleCutoff30DyndrvPlanner = mkDyndrvPlanner {
    name = "penance-module-cutoff-30-dyndrv-planner.drv";
    src = moduleCutoff30Src;
    compiler = benchHpkgs.ghc;
    component = "exe:module-cutoff-30";
    ghcFlagsText = cutoff30DyndrvGhcFlagsText;
    binName = "module-cutoff-30";
    smoke = "cutoff-30:";
    validatePlan = ''
      module_count="$(${pkgs.jq}/bin/jq '.modules | length' "$TMPDIR/module-plan.json")"
      test "$module_count" -eq 31
    '';
  };
  penanceModuleCutoff30Dyndrv =
    let
      dyndrvOut = builtins.outputOf (builtins.unsafeDiscardOutputDependency penanceModuleCutoff30DyndrvPlanner.outPath) "out";
    in
    pkgs.runCommand "penance-module-cutoff-30-dyndrv" { } ''
      mkdir -p "$out"
      cp -R ${dyndrvOut}/. "$out/"
      "$out/bin/module-cutoff-30" > "$out/output.txt.check"
      cmp "$out/output.txt" "$out/output.txt.check"
      grep -q "cutoff-30:" "$out/output.txt"
    '';
  penanceHsBootThDyndrvPlanner = mkDyndrvPlanner {
    name = "penance-hs-boot-th-dyndrv-planner.drv";
    src = hsBootThSrc;
    compiler = benchHpkgs.ghc;
    component = "exe:hs-boot-th";
    ghcFlagsText = hsBootThDyndrvGhcFlagsText;
    binName = "hs-boot-th";
    smoke = "hs-boot-th:";
    dependencyFlags = [
      "-package"
      "template-haskell"
    ];
    validatePlan = ''
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
    '';
  };
  penanceHsBootThDyndrv =
    let
      dyndrvOut = builtins.outputOf (builtins.unsafeDiscardOutputDependency penanceHsBootThDyndrvPlanner.outPath) "out";
    in
    pkgs.runCommand "penance-hs-boot-th-dyndrv" { } ''
      mkdir -p "$out"
      cp -R ${dyndrvOut}/. "$out/"
      "$out/bin/hs-boot-th" > "$out/output.txt.check"
      cmp "$out/output.txt" "$out/output.txt.check"
      grep -q "hs-boot-th:42:base:dep-v1:splice:base:dep-v1:sibling" "$out/output.txt"
    '';
  penanceHsBootThClassificationProof =
    pkgs.runCommand "penance-hs-boot-th-classification-proof"
      {
        nativeBuildInputs = [
          benchHpkgs.ghc
          plannerBin
          pkgs.coreutils
          pkgs.findutils
          pkgs.jq
        ];
      }
      ''
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
          --lock penance.lock \
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
in
{
  inherit
    probePlannerPayload
    probeAddPathPayload
    probeDeterminismSalt
    caCutoffToySrc
    mkPenanceProbePlanner
    mkPenanceAddPathPlanner
    penanceProbePlanner
    penanceProbePlannerCorrupt
    penanceProbePlannerNondeterministic
    penanceProbePlannerDeterminismA
    penanceProbePlannerDeterminismB
    penanceProbePlannerDeterminismBadA
    penanceProbePlannerDeterminismBadB
    penanceProbePlannerConsumer
    penanceAddPathPlanner
    penanceAddPathConsumer
    mkCaCutoffToy
    penanceCaCutoffToyGraph
    penanceCaCutoffToyA
    penanceCaCutoffToyB
    penanceCaCutoffToyC
    penanceCaCutoffToy
    penanceModuleGranularBench
    mkPenanceBenchDyndrvPlanner
    penanceBenchDyndrvPlanner
    penanceBenchDyndrvPlannerRepeat
    penanceBenchDyndrv
    penanceDyndrvEmissionProof
    penanceModuleCutoff30DyndrvPlanner
    penanceModuleCutoff30Dyndrv
    penanceHsBootThDyndrvPlanner
    penanceHsBootThDyndrv
    penanceHsBootThClassificationProof
    ;
}
