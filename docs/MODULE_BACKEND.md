# Module Backend

The module backend is a first-class backend, not a research mode. The bootstrap planner already carries `granularity = "module"` through the Wasm skeleton and into `planner-bin`.

## Planned Graph Shape

- one derivation per compiled module, producing `.o` and `.hi`
- optional `.dyn_o` and `.dyn_hi` outputs when dynamic linking is requested
- one link derivation per component
- generator derivations for `alex`, `happy`, `hsc2hs`, `c2hs`, and declared generated modules
- source plugin derivations as build-time inputs for modules using `-fplugin`

## GHC API Requirement

Plain `ghc -M` is insufficient because it cannot faithfully model Template Haskell, plugins, generated sources, or Backpack. `Penance.Graph.Module` will use the GHC API after Cabal has produced an install plan and component-local compiler options.

## Hard Cases

Template Haskell modules depend on runnable splice dependencies, not only interfaces. The backend must record `addDependentFile` paths as explicit derivation inputs.

CPP-enabled modules must be preprocessed before graph extraction so imports match the post-CPP source.

Custom `Setup.hs` is a v1 whole-package fallback with an explicit warning, except Backpack components where fallback is forbidden. A later v2 can interpret `UserHooks`.

Recompilation avoidance uses interface hashes: downstream modules should skip rebuilds when an upstream implementation body changes without changing exported interfaces.
