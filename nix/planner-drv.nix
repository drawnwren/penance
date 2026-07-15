{
  lib,
  pkgs,
  penancePlanner ? null,
}:

assert penancePlanner != null;
{
  src,
  compiler,
  index-state,
  skeleton,
  granularity,
}:

pkgs.stdenvNoCC.mkDerivation {
  pname = "penance-root-planner";
  version = "0.1.0";

  dontUnpack = true;
  preferLocalBuild = true;
  allowSubstitutes = false;
  __contentAddressed = true;
  outputHashMode = "recursive";
  outputHashAlgo = "sha256";

  passAsFile = [ "skeletonJson" ];
  skeletonJson = builtins.toJSON skeleton;

  nativeBuildInputs = [ penancePlanner ];

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

    penance-planner \
      --skeleton "$out/project-skeleton.json" \
      --src "${src}" \
      --index-state "${index-state}" \
      --granularity "${granularity}" \
      --out "$out"
  '';

  requiredSystemFeatures = [ "recursive-nix" ];

  passthru = {
    inherit skeleton granularity;
  };
}
