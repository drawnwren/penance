{
  benchSrc,
  haskellNixBenchExe,
  haskellNixBenchO0Exe,
  mkVariantBundle,
  penanceBenchDyndrv,
  penanceBenchO0ViaLock,
  penanceBenchViaLock,
  pkgs,
  ...
}:
let
  copyClosureCache = closure: dir: ''
    mkdir -p "${dir}"
    cp ${closure}/store-paths "${dir}/store-paths"
    cp ${closure}/registration "${dir}/registration"
    cp ${closure}/total-nar-size "${dir}/total-nar-size"
  '';
  mkMscBundle =
    name: root:
    let
      closure = pkgs.closureInfo { rootPaths = [ root ]; };
    in
    pkgs.runCommand name
      {
        nativeBuildInputs = [
          pkgs.coreutils
        ];
      }
      ''
        ${copyClosureCache closure "$out/cache"}
        path_count="$(wc -l < "$out/cache/store-paths" | tr -d ' ')"
        nar_size="$(cat "$out/cache/total-nar-size")"
        test "$path_count" -gt 0
        cat > "$out/manifest.json" <<JSON
        {"schema":"penance/msc-bundle/1","root":"${root}","pathCount":$path_count,"narSize":$nar_size,"closureInfo":"${closure}"}
        JSON
      '';
  mkLockCacheManifest =
    name: lockPath: root:
    let
      lockHash = builtins.hashFile "sha256" lockPath;
      manifest = builtins.toJSON {
        schema = "penance/lock-cache-manifest/1";
        inherit lockHash;
        rootDrv = builtins.unsafeDiscardStringContext root.drvPath;
      };
    in
    pkgs.runCommandLocal name { } ''
      printf '%s\n' ${pkgs.lib.escapeShellArg manifest} > "$out"
    '';
  penanceMscBundle = mkMscBundle "penance-msc-bundle" penanceBenchViaLock;
  haskellNixMscBundle = mkMscBundle "haskell-nix-msc-bundle" haskellNixBenchExe;
  penanceLockCacheManifest = mkLockCacheManifest "penance-cache-manifest" (
    benchSrc + "/penance.lock"
  ) penanceBenchViaLock;
  penanceProjectVariants = pkgs.runCommand "penance-project-variants" { } ''
    mkdir -p "$out/variants" "$out/nix-support"
    ln -s ${penanceBenchViaLock} "$out/variants/granularity-unit"
    ln -s ${penanceBenchDyndrv} "$out/variants/granularity-module"
    ln -s ${penanceBenchO0ViaLock} "$out/variants/ghcOptions-O0"

    "$out/variants/granularity-unit/bin/penance-bench" > "$out/granularity-unit.out"
    "$out/variants/granularity-module/bin/penance-bench" > "$out/granularity-module.out"
    cmp "$out/granularity-unit.out" "$out/granularity-module.out"
    cmp ${penanceBenchDyndrv}/output.txt "$out/granularity-module.out"

    cat > "$out/variants.json" <<'JSON'
    {"schema":"penance/project-variants/1","variants":["granularity-unit","granularity-module","ghcOptions-O0"],"granularity":{"unit":"penanceBenchViaLock","module":"penanceBenchDyndrv","sameLock":"tests/bench/vs-haskell-nix/project/penance.lock","outputsEquivalent":true}}
    JSON
  '';
  haskellNixProjectVariants = mkVariantBundle "haskell-nix-project-variants" [
    {
      name = "baseline";
      path = haskellNixBenchExe;
    }
    {
      name = "appendModule-ghcOptions-O0";
      path = haskellNixBenchO0Exe;
    }
  ];
  mkWarpLoop =
    name: root:
    let
      closure = pkgs.closureInfo { rootPaths = [ root ]; };
    in
    pkgs.runCommand name
      {
        nativeBuildInputs = [
          pkgs.coreutils
        ];
      }
      ''
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
  penanceWarpLoop = mkWarpLoop "penance-warp-loop" penanceBenchViaLock;
  haskellNixWarpBaseline = mkWarpLoop "haskell-nix-warp-baseline" haskellNixBenchExe;
in
{
  inherit
    copyClosureCache
    mkMscBundle
    mkLockCacheManifest
    penanceMscBundle
    haskellNixMscBundle
    penanceLockCacheManifest
    penanceProjectVariants
    haskellNixProjectVariants
    mkWarpLoop
    penanceWarpLoop
    haskellNixWarpBaseline
    ;
}
