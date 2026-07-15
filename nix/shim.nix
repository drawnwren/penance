{
  lib,
  plannerWasm ? ./planner.wasm,
}:

{
  src,
  sourceManifest ? [ ],
  compiler,
  index-state,
  cabalProjectText,
  localPackageManifests,
  flags,
  mode,
}:

let
  input = {
    inherit
      compiler
      flags
      localPackageManifests
      sourceManifest
      ;
    indexState = index-state;
    inherit cabalProjectText;
    materializationMode = "dynamic";
    granularity = mode;
  };

  inputJson = builtins.toJSON input;
in
if
  !(builtins.elem mode [
    "component"
    "module"
  ])
then
  throw "penanceProject: mode must be `component` or `module`, got `${mode}`"
else if !(builtins ? wasm) then
  throw ''
    penanceProject requires Determinate Nix with the `wasm-builtin` experimental feature.
    This checkout has the Haskell planner source, but evaluation cannot call builtins.wasm.
  ''
else if !(builtins.pathExists plannerWasm) then
  throw ''
    penanceProject expected a committed planner Wasm blob at ${toString plannerWasm}.
    Build .#ghcWasmPlanner with GHC's wasm32-wasi backend and commit/copy
    the result to nix/planner.wasm.
  ''
else
  builtins.fromJSON (
    builtins.wasm {
      path = plannerWasm;
    } inputJson
  )
