{ lib
, plannerWasm ? ./planner.wasm
}:

{ src
, srcTreeDigest ? null
, sourceManifest ? []
, compiler
, index-state
, cabalProjectText
, localPackageManifests
, flags
, mode
}:

let
  input = {
    inherit compiler flags localPackageManifests sourceManifest;
    indexState = index-state;
    cabalProjectText = cabalProjectText;
    materializationMode = "dynamic";
    granularity = mode;
  } // lib.optionalAttrs (srcTreeDigest != null) {
    inherit srcTreeDigest;
  };

  inputJson = builtins.toJSON input;
in
  if !(builtins.elem mode [ "component" "module" ]) then
    throw "penanceProject: mode must be `component` or `module`, got `${mode}`"
  else if !(builtins ? wasm) then
    throw ''
      penanceProject requires Determinate Nix with the `wasm-builtin` experimental feature.
      This checkout has the Rust planner source, but evaluation cannot call builtins.wasm.
    ''
  else if !(builtins.pathExists plannerWasm) then
    throw ''
      penanceProject expected a committed planner Wasm blob at ${toString plannerWasm}.
      Build wasm-planner for wasm32-wasip1 and commit/copy the result to nix/planner.wasm.
    ''
  else
    builtins.fromJSON (builtins.wasm {
      path = plannerWasm;
      function = "normalize_project";
    } inputJson)
