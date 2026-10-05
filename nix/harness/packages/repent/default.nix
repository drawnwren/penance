{
  benchSrc,
  cSourcesSrc,
  hpkgs,
  lockExternalSrc,
  pkgs,
  plannerBin,
  repentTool,
  ...
}:
let
  parallelCabal2nix = pkgs.writeShellScript "penance-parallel-cabal2nix" ''
    set -euo pipefail

    target=""
    for argument in "$@"; do
      target="$argument"
    done
    token="$(printf '%s' "$target" | ${pkgs.coreutils}/bin/tr -c 'A-Za-z0-9_.-' '_')"
    invocation="$PENANCE_PARALLEL_TEST_STATE/invoked-$token"
    if ! ${pkgs.coreutils}/bin/mkdir "$invocation"; then
      echo "duplicate cabal2nix invocation for $target" >&2
      exit 91
    fi

    attempts=0
    while true; do
      started="$(
        ${pkgs.findutils}/bin/find "$PENANCE_PARALLEL_TEST_STATE" \
          -mindepth 1 -maxdepth 1 -type d -name 'invoked-*' -print \
          | ${pkgs.coreutils}/bin/wc -l \
          | ${pkgs.coreutils}/bin/tr -d ' '
      )"
      if [ "$started" -ge 2 ]; then
        break
      fi
      attempts=$((attempts + 1))
      if [ "$attempts" -ge 200 ]; then
        echo "cabal2nix invocations did not overlap" >&2
        exit 92
      fi
      ${pkgs.coreutils}/bin/sleep 0.05
    done

    if [ "''${PENANCE_PARALLEL_TEST_FAIL_TARGET:-}" = "$target" ]; then
      echo "injected cabal2nix failure for $target" >&2
      exit 93
    fi

    printf '{ mkDerivation }:\nmkDerivation { pname = "%s"; version = "1.0"; }\n' "$token"
  '';
  repentBenchPlan =
    pkgs.runCommand "repent-bench-plan"
      {
        nativeBuildInputs = [ pkgs.cabal-install ];
      }
      ''
        mkdir -p "$out"
        export HOME="$TMPDIR/home"
        export CABAL_DIR="$TMPDIR/cabal"
        mkdir -p "$HOME" "$CABAL_DIR"
        cat > "$CABAL_DIR/config" <<'EOF'
        active-repositories: none
        EOF

        ${plannerBin}/bin/repent \
          --project ${benchSrc} \
          --compiler ghc-9.10.2 \
          --ghc-pkg ${pkgs.haskell.compiler.ghc9102}/bin/ghc-pkg \
          --index-state 2026-02-01T00:00:00Z \
          --check ${benchSrc}/penance.lock \
          --out "$out/penance.lock"
      '';
  repentBench =
    pkgs.runCommand "repent-bench"
      {
        nativeBuildInputs = [
          pkgs.jq
          repentTool
        ];
      }
      ''
        mkdir -p "$out"
        repent \
          --project ${benchSrc} \
          --compiler ghc-9.10.2 \
          --index-state 2026-02-01T00:00:00Z \
          --check ${benchSrc}/penance.lock \
          --out "$out/penance.lock"

        repent \
          --project ${lockExternalSrc} \
          --compiler ghc-9.10.2 \
          --ghc-pkg ${hpkgs.ghc}/bin/ghc-pkg \
          --index-state 2026-02-01T00:00:00Z \
          --out "$out/lock-external-1.lock"
        repent \
          --project ${lockExternalSrc} \
          --compiler ghc-9.10.2 \
          --ghc-pkg ${hpkgs.ghc}/bin/ghc-pkg \
          --index-state 2026-02-01T00:00:00Z \
          --out "$out/lock-external-2.lock"
        cmp "$out/lock-external-1.lock" "$out/lock-external-2.lock"
        cmp "$out/lock-external-1.lock" ${lockExternalSrc}/penance.lock
        cp "$out/lock-external-1.lock" "$out/lock-external.penance.lock"

        repent \
          --project ${cSourcesSrc} \
          --compiler ghc-9.10.2 \
          --ghc-pkg ${hpkgs.ghc}/bin/ghc-pkg \
          --index-state 2026-04-01T00:00:00Z \
          --check ${cSourcesSrc}/penance.lock \
          --out "$out/c-sources.penance.lock"

        jq -e '
          .schema == "penance/lock/2"
          and any(.externalUnits[]; .name == "StateVar" and .version == "1.2.2" and .source == "hackage" and (.sdist.sha256 | length > 0))
          and any(.externalUnits[]; .name == "base" and .source == "ghc-boot")
        ' "$out/lock-external.penance.lock" >/dev/null
        jq -e '
          any(
            .packages[].components[];
            .name == "lib"
            and .cSources == ["cbits/foreign_answer.c"]
            and .includeDirs == ["cbits/include"]
            and .installIncludes == ["foreign_answer.h"]
            and .ccOptions == [
              "-DPENANCE_C_BIAS=0",
              "-UPENANCE_C_BIAS",
              "-DPENANCE_C_BIAS=1"
            ]
          )
        ' "$out/c-sources.penance.lock" >/dev/null

        jq '
          def external($id; $name; $component):
            {
              "type": "configured",
              "id": $id,
              "pkg-name": $name,
              "pkg-version": "1.0",
              "flags": {},
              "style": "global",
              "pkg-src": {
                "type": "repo-tar",
                "repo": {
                  "type": "remote-repo",
                  "uri": "https://hackage.haskell.org/"
                }
              },
              "pkg-src-sha256": "0000000000000000000000000000000000000000000000000000000000000000",
              "depends": ["base-4.15.1.0"],
              "exe-depends": [],
              "component-name": $component
            };
          .["install-plan"] += [
            external("parallel-a-1.0-main"; "parallel-a"; "lib"),
            external("parallel-a-1.0-duplicate-component"; "parallel-a"; "lib:duplicate"),
            external("parallel-b-1.0-main"; "parallel-b"; "lib")
          ]
          | (
              .["install-plan"][]
              | select(.id == "real-plan-fixture-0.1.0.0-inplace")
              | .components.lib["exe-depends"]
            ) += [
              "parallel-a-1.0-main",
              "parallel-a-1.0-duplicate-component",
              "parallel-b-1.0-main"
            ]
        ' ${../../../../planner-bin/test/data/plan.json} > "$out/parallel-plan.json"

        mkdir "$out/parallel-state" "$out/parallel-expressions"
        export PENANCE_PARALLEL_TEST_STATE="$out/parallel-state"
        repent \
          --project ${../../../../planner-bin/test/data/plan-project} \
          --compiler ghc-9.0.2 \
          --ghc-pkg ${hpkgs.ghc}/bin/ghc-pkg \
          --index-state 2026-02-01T00:00:00Z \
          --plan-json "$out/parallel-plan.json" \
          --cabal2nix ${parallelCabal2nix} \
          --hackage-nix-dir "$out/parallel-expressions" \
          --jobs 2 \
          --out "$out/parallel.lock" \
          | tee "$out/parallel.log"
        grep -q 'refreshing 3 Hackage expressions .* with 2 jobs' "$out/parallel.log"
        test "$(${pkgs.findutils}/bin/find "$out/parallel-state" -mindepth 1 -maxdepth 1 -type d -name 'invoked-*' | wc -l | tr -d ' ')" = 3
        test "$(${pkgs.findutils}/bin/find "$out/parallel-expressions" -mindepth 1 -maxdepth 1 -type f -name '*.nix' | wc -l | tr -d ' ')" = 3
        jq -e '
          [.externalUnits[] | select(.source == "hackage") | .nixExpression]
          | length == 4 and (unique | length) == 3
        ' "$out/parallel.lock" >/dev/null

        touch "$out/parallel-expressions/stale.nix"
        repent \
          --project ${../../../../planner-bin/test/data/plan-project} \
          --compiler ghc-9.0.2 \
          --ghc-pkg ${hpkgs.ghc}/bin/ghc-pkg \
          --index-state 2026-02-01T00:00:00Z \
          --plan-json "$out/parallel-plan.json" \
          --cabal2nix ${parallelCabal2nix} \
          --hackage-nix-dir "$out/parallel-expressions" \
          --jobs 2 \
          --out "$out/parallel-unchanged.lock" \
          | tee "$out/parallel-unchanged.log"
        cmp "$out/parallel.lock" "$out/parallel-unchanged.lock"
        grep -q 'Hackage expressions are current in' "$out/parallel-unchanged.log"
        test ! -e "$out/parallel-expressions/stale.nix"
        test "$(${pkgs.findutils}/bin/find "$out/parallel-state" -mindepth 1 -maxdepth 1 -type d -name 'invoked-*' | wc -l | tr -d ' ')" = 3

        mkdir "$out/forced-state"
        export PENANCE_PARALLEL_TEST_STATE="$out/forced-state"
        repent \
          --project ${../../../../planner-bin/test/data/plan-project} \
          --compiler ghc-9.0.2 \
          --ghc-pkg ${hpkgs.ghc}/bin/ghc-pkg \
          --index-state 2026-02-01T00:00:00Z \
          --plan-json "$out/parallel-plan.json" \
          --cabal2nix ${parallelCabal2nix} \
          --hackage-nix-dir "$out/parallel-expressions" \
          --jobs 2 \
          --refresh \
          --out "$out/parallel-forced.lock" \
          | tee "$out/parallel-forced.log"
        cmp "$out/parallel.lock" "$out/parallel-forced.lock"
        grep -q 'refreshing 3 Hackage expressions .* with 2 jobs' "$out/parallel-forced.log"
        test "$(${pkgs.findutils}/bin/find "$out/forced-state" -mindepth 1 -maxdepth 1 -type d -name 'invoked-*' | wc -l | tr -d ' ')" = 3

        mkdir "$out/failure-state" "$out/failure-expressions"
        touch "$out/failure-expressions/stale.nix"
        export PENANCE_PARALLEL_TEST_STATE="$out/failure-state"
        export PENANCE_PARALLEL_TEST_FAIL_TARGET="cabal://parallel-b-1.0"
        if repent \
          --project ${../../../../planner-bin/test/data/plan-project} \
          --compiler ghc-9.0.2 \
          --ghc-pkg ${hpkgs.ghc}/bin/ghc-pkg \
          --index-state 2026-02-01T00:00:00Z \
          --plan-json "$out/parallel-plan.json" \
          --cabal2nix ${parallelCabal2nix} \
          --hackage-nix-dir "$out/failure-expressions" \
          --jobs 2 \
          --out "$out/failure.lock" \
          > "$out/failure.log" 2>&1; then
          echo "repent unexpectedly accepted a cabal2nix failure" >&2
          exit 1
        fi
        unset PENANCE_PARALLEL_TEST_FAIL_TARGET
        grep -q 'cabal2nix failed for parallel-b-1.0' "$out/failure.log"
        test -f "$out/failure-expressions/stale.nix"
        test "$(${pkgs.findutils}/bin/find "$out/failure-expressions" -type f -name '*.tmp' | wc -l | tr -d ' ')" = 0

        if repent --jobs 0 --help > "$out/invalid-jobs.log" 2>&1; then
          echo "repent unexpectedly accepted --jobs 0" >&2
          exit 1
        fi
        grep -q 'must be a positive integer' "$out/invalid-jobs.log"

        scratch="$(mktemp -d "$TMPDIR/lock-external-stale.XXXXXX")"
        trap 'rm -rf "$scratch"' EXIT
        cp -R ${lockExternalSrc}/. "$scratch/"
        chmod -R u+w "$scratch"
        sed -i 's/StateVar >=1\.2 && <1\.3/StateVar >=1.2 \&\& <1.3,\n    bytestring/' "$scratch/lock-external.cabal"
        if repent \
          --project "$scratch" \
          --compiler ghc-9.10.2 \
          --ghc-pkg ${hpkgs.ghc}/bin/ghc-pkg \
          --index-state 2026-02-01T00:00:00Z \
          --check ${lockExternalSrc}/penance.lock \
          > "$out/stale-lock.log" 2>&1; then
          echo "repent --check unexpectedly accepted a stale lock" >&2
          exit 1
        fi
      '';
in
{
  inherit
    repentBenchPlan
    repentBench
    ;
}
