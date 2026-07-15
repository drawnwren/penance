{
  haskellNixBenchExe,
  penanceBenchViaLock,
  pkgs,
  ...
}:
let
  probeNixConfig = pkgs.writeTextDir "nix.conf" ''
    experimental-features = nix-command flakes ca-derivations dynamic-derivations recursive-nix
  '';
  mkPrimitiveProbes =
    name: drv:
    pkgs.runCommand name
      {
        nativeBuildInputs = [
          pkgs.gnugrep
          pkgs.gnused
          pkgs.jq
          pkgs.nix
        ];
        requiredSystemFeatures = [ "recursive-nix" ];
        NIX_CONF_DIR = probeNixConfig;
        probeTarget = drv;
        probeTargetDrv = drv.drvPath;
      }
      ''
        mkdir -p "$out"
        work="$(mktemp -d)"
        test -e "$probeTarget"

        nix --version > "$out/nix-version.txt"
        nix config show > "$work/nix-config.txt"
        grep -q "ca-derivations" "$work/nix-config.txt"
        grep -q "dynamic-derivations" "$work/nix-config.txt"
        grep -q "recursive-nix" "$work/nix-config.txt"
        nix eval --expr 'builtins.hasAttr "outputOf" builtins' > "$out/outputOf.txt"
        grep -q true "$out/outputOf.txt"

        nix derivation show "$probeTargetDrv" > "$work/derivation-show.json"
        jq '.derivations | to_entries[0].value' "$work/derivation-show.json" > "$work/derivation-add.json"
        roundtrip="$(nix derivation add < "$work/derivation-add.json")"
        test "$roundtrip" = "$probeTargetDrv"
        nix derivation show "$roundtrip" > "$work/roundtrip.json"

        for file in nix-config.txt derivation-show.json derivation-add.json roundtrip.json; do
          sed -E \
            -e 's#/nix/store/[0-9a-z]{32}-[A-Za-z0-9._+?=-]+#<store-path>#g' \
            -e 's#^store = .*#store = <recursive-store>#' \
            "$work/$file" > "$out/$file"
        done
        drv_name="$(basename "$probeTargetDrv")"
        roundtrip_name="$(basename "$roundtrip")"

        cat > "$out/probes.json" <<JSON
        {"schema":"penance/primitive-probes/1","drv":"$drv_name","roundtrip":"$roundtrip_name","outputOf":true}
        JSON
      '';
  penancePrimitiveProbes = mkPrimitiveProbes "penance-primitive-probes" penanceBenchViaLock;
  haskellNixPrimitiveProbes = mkPrimitiveProbes "haskell-nix-primitive-probes" haskellNixBenchExe;
in
{
  inherit
    mkPrimitiveProbes
    penancePrimitiveProbes
    haskellNixPrimitiveProbes
    ;
}
