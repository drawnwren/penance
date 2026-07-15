# Contributing

Penance is alpha software. Changes should preserve the distinction between an
implemented mechanism, a proof of that mechanism, and a documented gap.

## Development

```sh
nix develop
nix build .#plannerBin
nix build .#checks.$(nix eval --raw --impure --expr builtins.currentSystem).nix-format
```

Run `nix run .#bench` after changing a mechanism, benchmark matrix, lock
lowering, or derivation graph. New mechanisms need a positive proof and a
negative control. Do not relax a bound or relabel a proxy measurement to make
a failing row pass.

Use `repent --check` when changing Cabal fixtures and regenerate
`nix/planner.wasm` only from `.#ghcWasmPlanner`; the provenance check must
byte-compare successfully.
