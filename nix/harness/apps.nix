{
  self,
  forAllSystems,
  pkgsFor,
  stackageResolver,
  hackageStateVarVersion,
}:
forAllSystems (
  system:
  let
    pkgs = pkgsFor.${system};
    benchmarkNixConfig = pkgs.writeTextDir "nix.conf" ''
      experimental-features = nix-command flakes ca-derivations dynamic-derivations recursive-nix
    '';
    useBenchmarkNix = ''
      if [ -z "''${PENANCE_NIX_BIN:-}" ]; then
        export PENANCE_NIX_BIN=${pkgs.nix}/bin/nix
        export NIX_CONF_DIR=${benchmarkNixConfig}
      fi
    '';
    benchmarkSource = builtins.path {
      name = "penance-benchmark-source";
      path = ../..;
      filter =
        path: _type:
        let
          name = builtins.baseNameOf path;
        in
        name != ".git"
        && name != ".penance"
        && name != "dist-newstyle"
        && name != "target"
        && name != "result"
        && name != "bench-results"
        && !(pkgs.lib.hasPrefix "result-" name);
    };
    benchmarkFlake = "path:${benchmarkSource}";
    validationGhc = self.packages.${system}.penanceBenchShellGhc;
    stackageValidationGhc = pkgs.haskell.compiler.ghc9103 or validationGhc;
    validationGhcVersionParts = pkgs.lib.splitString "." validationGhc.version;
    validationCompiler = "ghc-${validationGhc.version}";
    validationCompilerNixName = "ghc${pkgs.lib.concatStrings (pkgs.lib.take 2 validationGhcVersionParts)}";
    serveDocs = pkgs.writeShellApplication {
      name = "penance-docs";
      runtimeInputs = [
        pkgs.mdbook
        pkgs.mdbook-mermaid
      ];
      text = ''
        book_root=''${PENANCE_DOCS_ROOT:-$PWD}
        if [ ! -f "$book_root/book.toml" ]; then
          book_root=${self}
        fi

        book_work="$(mktemp -d "''${TMPDIR:-/tmp}/penance-docs.XXXXXX")"
        trap 'rm -rf "$book_work"' EXIT
        cp -R "$book_root"/. "$book_work"
        chmod -R u+w "$book_work"
        mdbook-mermaid install "$book_work"

        mdbook serve "$book_work" \
          --hostname "''${PENANCE_DOCS_HOST:-127.0.0.1}" \
          --port "''${PENANCE_DOCS_PORT:-3000}" \
          "$@"
      '';
    };
    benchVsHaskellNix = pkgs.writeShellApplication {
      name = "bench-vs-haskell-nix";
      runtimeInputs = [
        pkgs.coreutils
        pkgs.time
      ];
      text = ''
        ${useBenchmarkNix}
        export PENANCE_BENCH_FLAKE=''${PENANCE_BENCH_FLAKE:-${benchmarkFlake}}
        exec ${../../scripts/bench-vs-haskell-nix.sh} ${system} "$@"
      '';
    };
    validateHackagePackage = pkgs.writeShellApplication {
      name = "validate-hackage-package";
      runtimeInputs = [
        self.packages.${system}.plannerBin
        pkgs.cabal-install
        pkgs.cabal2nix
        pkgs.coreutils
        pkgs.findutils
        pkgs.gawk
        pkgs.jq
        pkgs.perl
      ];
      text = ''
        ${useBenchmarkNix}
        export PENANCE_REPO=''${PENANCE_REPO:-${self}}
        export PENANCE_COMPILER=''${PENANCE_COMPILER:-${validationCompiler}}
        export PENANCE_COMPILER_NIX_NAME=''${PENANCE_COMPILER_NIX_NAME:-${validationCompilerNixName}}
        export PENANCE_GHC_PKG=''${PENANCE_GHC_PKG:-${validationGhc}/bin/ghc-pkg}
        export PENANCE_REPENT_BIN=''${PENANCE_REPENT_BIN:-${self.packages.${system}.plannerBin}/bin/repent}
        exec ${../../scripts/validate-hackage-package.sh} "$@"
      '';
    };
    benchStackagePackage = pkgs.writeShellApplication {
      name = "bench-stackage-package";
      runtimeInputs = [
        self.packages.${system}.plannerBin
        pkgs.cabal-install
        pkgs.cabal2nix
        pkgs.coreutils
        pkgs.curl
        pkgs.findutils
        pkgs.jq
        pkgs.perl
      ];
      text = ''
        ${useBenchmarkNix}
        export PENANCE_REPO=''${PENANCE_REPO:-${self}}
        export PENANCE_GHC_PKG=''${PENANCE_GHC_PKG:-${stackageValidationGhc}/bin/ghc-pkg}
        export PENANCE_REPENT_BIN=''${PENANCE_REPENT_BIN:-${self.packages.${system}.plannerBin}/bin/repent}
        exec ${../../scripts/bench-stackage-package.sh} "$@"
      '';
    };
    benchHaskellNixBaseline = pkgs.writeShellApplication {
      name = "bench-haskell-nix-baseline";
      text = ''
        ${useBenchmarkNix}
        export PENANCE_PHASE_BENCH_FLAKE=''${PENANCE_PHASE_BENCH_FLAKE:-${benchmarkFlake}}
        exec ${self.packages.${system}.plannerBin}/bin/penance-architecture-bench \
          --matrix ${../../tests/architecture/haskell-nix-baseline-matrix.json} \
          "$@"
      '';
    };
    benchArchitectureFunctionality = pkgs.writeShellApplication {
      name = "bench-architecture-functionality";
      text = ''
        ${useBenchmarkNix}
        export PENANCE_PHASE_BENCH_FLAKE=''${PENANCE_PHASE_BENCH_FLAKE:-${benchmarkFlake}}
        exec ${self.packages.${system}.plannerBin}/bin/penance-architecture-bench \
          --matrix ${../../tests/architecture/functionality-gap-matrix.json} \
          "$@"
      '';
    };
    benchArchitecturePhases = pkgs.writeShellApplication {
      name = "bench-architecture-phases";
      text = ''
        ${useBenchmarkNix}
        export PENANCE_PHASE_BENCH_FLAKE=''${PENANCE_PHASE_BENCH_FLAKE:-${benchmarkFlake}}
        exec ${self.packages.${system}.plannerBin}/bin/penance-architecture-bench "$@"
      '';
    };
    benchDynamicProbes = pkgs.writeShellApplication {
      name = "bench-dynamic-probes";
      runtimeInputs = [
        pkgs.coreutils
        pkgs.findutils
        pkgs.gnugrep
        pkgs.gnused
        pkgs.jq
        pkgs.perl
        pkgs.rsync
      ];
      text = ''
        ${useBenchmarkNix}

        nix_bin=''${PENANCE_NIX_BIN:-nix}
        sandbox_state="$($nix_bin config show sandbox 2>/dev/null || printf unknown)"
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
        out_root=''${PENANCE_DYNAMIC_PROBES_OUT:-$flake_dir/.penance/bench-results/dynamic-probes/${system}-$stamp}
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
          --raw "path:$flake_dir#penanceBenchViaLock.drvPath" > "$out_root/no-ifd-penanceBenchViaLock.drvPath"
        "$nix_bin" "''${nix_common[@]}" eval --option allow-import-from-derivation false \
          --raw "path:$flake_dir#penanceSimpleLibViaLock.drvPath" > "$out_root/no-ifd-penanceSimpleLibViaLock.drvPath"
        "$nix_bin" "''${nix_common[@]}" eval --option allow-import-from-derivation false \
          --raw "path:$flake_dir#penanceLockExternalViaLock.drvPath" > "$out_root/no-ifd-penanceLockExternalViaLock.drvPath"

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
          { grep -E -o "building '/nix/store/[0-9a-z]{32}-$1\\.drv'" "$2" || true; } \
            | sort -u \
            | wc -l \
            | tr -d ' '
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

        "$nix_bin" "''${nix_common[@]}" build "path:$flake_dir#penanceProbePlannerConsumer" \
          --no-link -L > "$out_root/logs/consumer-build.log" 2>&1

        plan_drv="$("$nix_bin" "''${nix_common[@]}" eval --raw "path:$flake_dir#penanceProbePlanner.drvPath")"
        printf "%s\n" "$plan_drv" > "$out_root/planner-drv.txt"
        "$nix_bin" "''${nix_common[@]}" build "$plan_drv^out^out" \
          --no-link -L > "$out_root/logs/cli-chain.log" 2>&1

        "$nix_bin" "''${nix_common[@]}" build "path:$flake_dir#penanceProbePlannerConsumer" \
          --no-link -L > "$out_root/logs/no-op-build.log" 2>&1
        if grep -q "building '" "$out_root/logs/no-op-build.log"; then
          echo "second planner-consumer build rebuilt derivations unexpectedly" >&2
          exit 1
        fi

        base_plan_out="$("$nix_bin" "''${nix_common[@]}" build "path:$flake_dir#penanceProbePlanner" \
          --print-out-paths --no-link -L 2> "$out_root/logs/planner-build.log" | tail -n 1)"
        test -n "$base_plan_out"
        printf "%s\n" "$base_plan_out" > "$out_root/planner-output.txt"
        det_scratch="$(mktemp -d "$tmp_root/penance-determinism.XXXXXX")"
        det_scratch="$(cd "$det_scratch" && pwd -P)"
        trap 'rm -rf "$det_scratch"' EXIT
        rsync -a \
          --exclude .git \
          --exclude 'result' \
          --exclude 'result-*' \
          --exclude '.penance/bench-results' \
          --exclude 'docs/bench-results' \
          --exclude 'target' \
          --exclude 'dist-newstyle' \
          "$flake_dir/" "$det_scratch/"
        chmod -R u+w "$det_scratch"
        printf "determinism %s\n" "$stamp" > "$det_scratch/tests/probes/determinism-salt.txt"
        det_a="$("$nix_bin" "''${nix_common[@]}" build "path:$det_scratch#penanceProbePlannerDeterminismA" \
          --print-out-paths --no-link -L 2> "$out_root/logs/planner-determinism-a.log" | tail -n 1)"
        det_b="$("$nix_bin" "''${nix_common[@]}" build "path:$det_scratch#penanceProbePlannerDeterminismB" \
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
        bad_a="$("$nix_bin" "''${nix_common[@]}" build "path:$det_scratch#penanceProbePlannerDeterminismBadA" \
          --print-out-paths --no-link -L 2> "$out_root/logs/planner-determinism-bad-a.log" | tail -n 1)"
        bad_b="$("$nix_bin" "''${nix_common[@]}" build "path:$det_scratch#penanceProbePlannerDeterminismBadB" \
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

        add_consumer_out="$("$nix_bin" "''${nix_common[@]}" build "path:$flake_dir#penanceAddPathConsumer" \
          --print-out-paths --no-link -L > "$out_root/logs/add-path-consumer.stdout" 2> "$out_root/logs/add-path-consumer.log" && tail -n 1 "$out_root/logs/add-path-consumer.stdout")"
        test -n "$add_consumer_out"
        cmp "$add_consumer_out/payload.txt" "$flake_dir/tests/probes/add-path-payload.txt"
        add_plan_drv="$("$nix_bin" "''${nix_common[@]}" eval --raw "path:$flake_dir#penanceAddPathPlanner.drvPath")"
        printf "%s\n" "$add_plan_drv" > "$out_root/add-path-planner-drv.txt"
        "$nix_bin" "''${nix_common[@]}" build "$add_plan_drv^out^out" \
          --no-link -L > "$out_root/logs/add-path-cli-chain.log" 2>&1
        "$nix_bin" "''${nix_common[@]}" build "path:$flake_dir#penanceAddPathConsumer" \
          --no-link -L > "$out_root/logs/add-path-no-op-build.log" 2>&1
        if grep -q "building '" "$out_root/logs/add-path-no-op-build.log"; then
          echo "second add-path consumer build rebuilt derivations unexpectedly" >&2
          exit 1
        fi
        add_plan_out="$("$nix_bin" "''${nix_common[@]}" build "path:$flake_dir#penanceAddPathPlanner" \
          --print-out-paths --no-link -L 2> "$out_root/logs/add-path-planner-build.log" | tail -n 1)"
        test -n "$add_plan_out"
        printf "%s\n" "$add_plan_out" > "$out_root/add-path-planner-output.txt"
        "$nix_bin" "''${nix_common[@]}" derivation show "$add_plan_out" > "$out_root/add-path-child.json"
        grep -q 'penance-added-source.txt' "$out_root/add-path-child.json"
        child_count="$(grep -o '"[0-9a-z]\{32\}-penance-add-path-planner\.drv"' "$out_root/add-path-child.json" | wc -l | tr -d ' ')"
        test "$child_count" = 1

        "$nix_bin" "''${nix_common[@]}" build "path:$flake_dir#penanceCaCutoffToy" \
          --no-link -L > "$out_root/logs/ca-toy-baseline.log" 2>&1
        "$nix_bin" "''${nix_common[@]}" build "path:$flake_dir#penanceCaCutoffToy" \
          --no-link -L > "$out_root/logs/ca-toy-no-op.log" 2>&1
        if grep -q "building '" "$out_root/logs/ca-toy-no-op.log"; then
          echo "second CA cutoff toy build rebuilt derivations unexpectedly" >&2
          exit 1
        fi

        hi_soak_count=5
        hi_hash_count=0
        "$nix_bin" "''${nix_common[@]}" build "path:$flake_dir#penanceBenchLibViaLock^iface" \
          --no-link -L > "$out_root/logs/hi-soak-seed.log" 2>&1
        for run in $(seq 1 "$hi_soak_count"); do
          hi_out="$("$nix_bin" "''${nix_common[@]}" build "path:$flake_dir#penanceBenchLibViaLock^iface" \
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
        scratch="$(cd "$scratch" && pwd -P)"
        trap 'rm -rf "$scratch"' EXIT
        rsync -a \
          --exclude .git \
          --exclude 'result' \
          --exclude 'result-*' \
          --exclude '.penance/bench-results' \
          --exclude 'docs/bench-results' \
          --exclude 'target' \
          --exclude 'dist-newstyle' \
          "$flake_dir/" "$scratch/"
        chmod -R u+w "$scratch"
        printf "hello dynamic child edited %s\n" "$stamp" > "$scratch/tests/probes/planner-payload.txt"
        printf "hello recursive add-path edited %s\n" "$stamp" > "$scratch/tests/probes/add-path-payload.txt"
        edited_plan_out="$("$nix_bin" "''${nix_common[@]}" build "path:$scratch#penanceProbePlanner" \
          --print-out-paths --no-link -L 2> "$out_root/logs/liveness-build.log" | tail -n 1)"
        test -n "$edited_plan_out"
        printf "%s\n" "$edited_plan_out" > "$out_root/planner-output-edited.txt"
        if [ "$base_plan_out" = "$edited_plan_out" ]; then
          echo "editing the probe payload did not change the emitted child drv path" >&2
          exit 1
        fi
        edited_add_plan_out="$("$nix_bin" "''${nix_common[@]}" build "path:$scratch#penanceAddPathPlanner" \
          --print-out-paths --no-link -L 2> "$out_root/logs/add-path-liveness-build.log" | tail -n 1)"
        test -n "$edited_add_plan_out"
        printf "%s\n" "$edited_add_plan_out" > "$out_root/add-path-planner-output-edited.txt"
        if [ "$add_plan_out" = "$edited_add_plan_out" ]; then
          echo "editing the add-path payload did not change the emitted child drv path" >&2
          exit 1
        fi
        printf "module A\ndecl: value :: Int\nbody: value = 1\ncomment: body edit %s\n" "$stamp" \
          > "$scratch/tests/probes/ca-cutoff-toy/A.toy"
        "$nix_bin" "''${nix_common[@]}" build "path:$scratch#penanceCaCutoffToy" \
          --no-link -L > "$out_root/logs/ca-toy-body-edit.log" 2>&1
        assert_built_count penance-ca-toy-A "$out_root/logs/ca-toy-body-edit.log" 1
        assert_built_count penance-ca-toy-B "$out_root/logs/ca-toy-body-edit.log" 0
        assert_built_count penance-ca-toy-C "$out_root/logs/ca-toy-body-edit.log" 0
        assert_built_count penance-ca-toy-link "$out_root/logs/ca-toy-body-edit.log" 1
        printf "module A\ndecl: value_%s :: Integer\nbody: value = 1\ncomment: declaration edit %s\n" "$stamp" "$stamp" \
          > "$scratch/tests/probes/ca-cutoff-toy/A.toy"
        "$nix_bin" "''${nix_common[@]}" build "path:$scratch#penanceCaCutoffToy" \
          --no-link -L > "$out_root/logs/ca-toy-declaration-edit.log" 2>&1
        assert_built_count penance-ca-toy-A "$out_root/logs/ca-toy-declaration-edit.log" 1
        assert_built_count penance-ca-toy-B "$out_root/logs/ca-toy-declaration-edit.log" 1
        assert_built_count penance-ca-toy-C "$out_root/logs/ca-toy-declaration-edit.log" 1
        assert_built_count penance-ca-toy-link "$out_root/logs/ca-toy-declaration-edit.log" 1

        cutoff_token="B5$(printf "%s" "$stamp" | tr -cd 'A-Za-z0-9')"
        sanitize_drv_name() {
          printf '%s' "$1" | sed 's#[:/ ]#-#g'
        }
        bench_package_name="$(jq -r '.packages[0].name' "$scratch/tests/bench/vs-haskell-nix/project/penance.lock")"
        bench_exe_component="$(jq -r '.packages[0].components[] | select(.kind == "executable") | .name' "$scratch/tests/bench/vs-haskell-nix/project/penance.lock")"
        bench_lib_drv="penance-$(sanitize_drv_name "$bench_package_name")-lib"
        bench_db_iface_drv="$bench_lib_drv-dbIface"
        bench_db_full_drv="$bench_lib_drv-dbFull"
        bench_exe_drv="penance-$(sanitize_drv_name "$bench_package_name")-$(sanitize_drv_name "$bench_exe_component")"
        "$nix_bin" "''${nix_common[@]}" build "path:$scratch#penanceBenchViaLock" \
          --no-link -L > "$out_root/logs/static-cutoff-baseline.log" 2>&1
        "$nix_bin" "''${nix_common[@]}" build "path:$scratch#penanceBenchViaLock" \
          --no-link -L > "$out_root/logs/static-cutoff-no-op.log" 2>&1
        if grep -q "building '" "$out_root/logs/static-cutoff-no-op.log"; then
          echo "second static-unit cutoff build rebuilt derivations unexpectedly" >&2
          exit 1
        fi
        perl -0pi -e "s#    Users -> \"/users\"#    Users -> \"/people-$cutoff_token\"#" \
          "$scratch/tests/bench/vs-haskell-nix/project/src/Bench/Route.hs"
        body_out="$("$nix_bin" "''${nix_common[@]}" build "path:$scratch#penanceBenchViaLock" \
          --print-out-paths --no-link -L > "$out_root/logs/static-cutoff-body.stdout" 2> "$out_root/logs/static-cutoff-body.log" && tail -n 1 "$out_root/logs/static-cutoff-body.stdout")"
        test -n "$body_out"
        "$body_out/bin/penance-bench" > "$out_root/static-cutoff-body.output"
        grep -q "/people-$cutoff_token" "$out_root/static-cutoff-body.output"
        assert_built_count "$bench_lib_drv" "$out_root/logs/static-cutoff-body.log" 1
        assert_built_count "$bench_db_iface_drv" "$out_root/logs/static-cutoff-body.log" 0
        assert_built_count "$bench_db_full_drv" "$out_root/logs/static-cutoff-body.log" 1
        assert_built_count "$bench_exe_drv-compile" "$out_root/logs/static-cutoff-body.log" 0
        assert_built_count "$bench_exe_drv" "$out_root/logs/static-cutoff-body.log" 1

        perl -0pi -e "s/module Bench\\.App \\(runApp\\) where/module Bench.App (runApp, runVersion$cutoff_token) where/" \
          "$scratch/tests/bench/vs-haskell-nix/project/src/Bench/App.hs"
        printf '\nrunVersion%s :: String\nrunVersion%s = "%s"\n' "$cutoff_token" "$cutoff_token" "$cutoff_token" \
          >> "$scratch/tests/bench/vs-haskell-nix/project/src/Bench/App.hs"
        "$nix_bin" "''${nix_common[@]}" build "path:$scratch#penanceBenchViaLock" \
          --no-link -L > "$out_root/logs/static-cutoff-export.log" 2>&1
        assert_built_count "$bench_lib_drv" "$out_root/logs/static-cutoff-export.log" 1
        assert_built_count "$bench_db_iface_drv" "$out_root/logs/static-cutoff-export.log" 1
        assert_built_count "$bench_db_full_drv" "$out_root/logs/static-cutoff-export.log" 1
        assert_built_count "$bench_exe_drv-compile" "$out_root/logs/static-cutoff-export.log" 1
        assert_built_count "$bench_exe_drv" "$out_root/logs/static-cutoff-export.log" 1

        if "$nix_bin" "''${nix_common[@]}" build "path:$flake_dir#penanceProbePlannerCorrupt" \
          --no-link -L > "$out_root/logs/corrupt-child-json.log" 2>&1; then
          echo "corrupt child JSON unexpectedly succeeded" >&2
          exit 1
        fi

        jq '(.externalUnits[] | select(.source == "hackage") | .sdist.sha256) = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="' \
          "$scratch/tests/fixtures/lock-external/penance.lock" \
          > "$scratch/tests/fixtures/lock-external/penance.lock.tmp"
        mv "$scratch/tests/fixtures/lock-external/penance.lock.tmp" \
          "$scratch/tests/fixtures/lock-external/penance.lock"
        if "$nix_bin" "''${nix_common[@]}" build "path:$scratch#penanceLockExternalViaLock" \
          --no-link -L > "$out_root/logs/corrupt-sdist-hash.log" 2>&1; then
          echo "corrupted locked Hackage sdist hash unexpectedly built" >&2
          exit 1
        fi
        grep -Eq 'hash mismatch|specified:.*sha256-AAAA|got:.*sha256-' \
          "$out_root/logs/corrupt-sdist-hash.log"

        cat > "$out_root/summary.json" <<JSON
        {
          "schema": "penance/dynamic-probes/1",
          "sandbox": "$sandbox_state",
          "probes": ["P2-outputOf-chain", "P3-cli-chain", "P4-recursive-add-path", "P5-ca-cutoff-toy-local", "P7-planner-determinism", "M1-locked-sdist-hash", "M2-no-ifd-static-unit-suite", "M2-dbIface-dbFull-cutoff", "M3-hi-determinism-soak"],
          "plannerDrv": "$plan_drv",
          "plannerOut": "$base_plan_out",
          "editedPlannerOut": "$edited_plan_out",
          "plannerDeterminism": "independently salted same-store executions",
          "plannerDeterminismLimitation": "remote and clean-store builders are not covered by this probe",
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
          "corruptChildJson": "failed",
          "corruptSdistHash": "failed"
        }
        JSON

        echo "wrote dynamic probe metrics:"
        echo "  $out_root/summary.json"
      '';
    };
    benchRebuildScenarios = pkgs.writeShellApplication {
      name = "bench-rebuild-scenarios";
      text = ''
        ${useBenchmarkNix}
        exec ${self.packages.${system}.plannerBin}/bin/penance-rebuild-bench \
          --scenarios ${../../tests/architecture/rebuild-scenarios.json} \
          "$@"
      '';
    };
    benchSurfaceParity = pkgs.writeShellApplication {
      name = "bench-surface-parity";
      text = ''
        ${useBenchmarkNix}
        nix_bin=''${PENANCE_NIX_BIN:-nix}
        exec "$nix_bin" build path:${self}#checks.${system}.bench-surface-parity --no-link -L "$@"
      '';
    };
    benchAll = pkgs.writeShellApplication {
      name = "bench";
      text = ''
        ${useBenchmarkNix}

        live_root_dir="$(mktemp -d "''${TMPDIR:-/tmp}/penance-bench-live.XXXXXX")"
        NIX_CONF_DIR=${benchmarkNixConfig} ${pkgs.nix}/bin/nix-store \
          --add-root "$live_root_dir/root" \
          --realise "$(dirname "$(dirname "$0")")" \
          >/dev/null
        trap 'rm -rf "$live_root_dir"' EXIT

        # Keep the suite defaults on the same pins the flake proofs use.
        export PENANCE_BENCH_STACKAGE_RESOLVER=''${PENANCE_BENCH_STACKAGE_RESOLVER:-${stackageResolver}}
        export PENANCE_BENCH_HACKAGE_PACKAGE=''${PENANCE_BENCH_HACKAGE_PACKAGE:-StateVar-${hackageStateVarVersion}}
        export PENANCE_DYNAMIC_PROBES_FLAKE=''${PENANCE_DYNAMIC_PROBES_FLAKE:-${benchmarkSource}}

        ${self.packages.${system}.plannerBin}/bin/penance-bench \
          --system ${system} \
          --architecture-runner ${benchArchitecturePhases}/bin/bench-architecture-phases \
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
    docs = {
      type = "app";
      program = "${serveDocs}/bin/penance-docs";
    };
    # Total benchmark entrypoint. New benchmark suites should be wired here
    # so `nix run .#bench` remains the one command for complete coverage.
    bench = {
      type = "app";
      program = "${benchAll}/bin/bench";
    };
    bench-architecture-phases = {
      type = "app";
      program = "${benchArchitecturePhases}/bin/bench-architecture-phases";
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
    repent = {
      type = "app";
      program = "${self.packages.${system}.repent}/bin/repent";
    };
  }
)
