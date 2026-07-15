{
  benchSrc,
  hpkgs,
  lockExternalSrc,
  pkgs,
  plannerBin,
  repentTool,
  ...
}:
let
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
          --ghc-pkg ${hpkgs.ghc}/bin/ghc-pkg \
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

        jq -e '
          .schema == "penance/lock/2"
          and any(.externalUnits[]; .name == "StateVar" and .version == "1.2.2" and .source == "hackage" and (.sdist.sha256 | length > 0))
          and any(.externalUnits[]; .name == "base" and .source == "ghc-boot")
        ' "$out/lock-external.penance.lock" >/dev/null

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
