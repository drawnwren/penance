{ lib
, pkgs
, penancePlanner ? null
}:

{ src
, compiler
, index-state
, skeleton
, granularity
}:

pkgs.stdenvNoCC.mkDerivation {
  pname = "penance-root-planner";
  version = "0.1.0";

  dontUnpack = true;
  preferLocalBuild = true;
  allowSubstitutes = false;

  passAsFile = [ "skeletonJson" ];
  skeletonJson = builtins.toJSON skeleton;

  nativeBuildInputs = lib.optional (penancePlanner != null) penancePlanner;

  buildCommand = ''
    set -eu

    mkdir -p "$out/packages" "$out/components" "$out/modules" "$out/signatures" "$out/instantiations"
    cp "$skeletonJsonPath" "$out/project-skeleton.json"

    cat > "$out/planner-input.json" <<EOF
    {
      "src": "${src}",
      "compiler": "${compiler}",
      "indexState": "${index-state}",
      "granularity": "${granularity}"
    }
    EOF

    if command -v penance-planner >/dev/null 2>&1; then
      penance-planner \
        --skeleton "$out/project-skeleton.json" \
        --src "${src}" \
        --index-state "${index-state}" \
        --granularity "${granularity}" \
        --out "$out"
    else
      echo "penance-planner not available; emitted no-op dynamic graph bootstrap" >&2
      cat > "$out/dynamic-graph.json" <<EOF
    {
      "status": "bootstrap",
      "componentGraphDrv": true,
      "moduleGraphDrv": true,
      "backpackGraphDrv": true
    }
    EOF
    fi
  '';

  requiredSystemFeatures = [ "recursive-nix" ];

  passthru = {
    inherit skeleton granularity;
  };
}
