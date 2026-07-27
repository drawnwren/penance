# Penance

Penance is an alpha Haskell build system for Nix. It moves Cabal solving to a
committed lock step, lowers that lock without import from derivation, and
builds local components with explicit package and interface dependency graphs.
Its experimental module backend uses dynamic derivations to narrow rebuilds
beyond package boundaries.

> **Alpha software:** lock and Nix APIs may change without migration support.
> Use it for experiments and evaluation, not production build infrastructure.

## Prerequisites

- Determinate Nix with flakes and `wasm-builtin` for planner-backed evaluation
- GHC 9.10.2 or 9.10.3 as selected by the committed lock
- `ca-derivations`, `dynamic-derivations`, and `recursive-nix` for the module backend

| Nix environment | Available Penance surface |
|---|---|
| Stock Nix, IFD disabled | Lock-backed component packages and development shells |
| Determinate Nix with `wasm-builtin` | Planner graph plus lock-backed component mode |
| Determinate Nix with `ca-derivations` | Optional content-addressed component builds |
| Determinate Nix plus recursive Nix/dynamic derivations | Experimental module mode |

## Quick Start

Add Penance as a flake input, expose a project, and commit the generated lock:

```nix
{
  inputs.penance.url = "github:OWNER/penance";
  inputs.nixpkgs.follows = "penance/nixpkgs";

  outputs = { nixpkgs, penance, ... }:
    let
      systems = [ "aarch64-darwin" "aarch64-linux" "x86_64-darwin" "x86_64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
      projectFor = system: penance.lib.${system}.penanceProject {
        src = ./.;
        mode = "component";
        hackageNix = ./nix/penance-hackage;
        includeRepent = true;
        contentAddressed = false;
      };
    in {
      packages = forAllSystems (system: (projectFor system).packages);
      devShells = forAllSystems (system: (projectFor system).devShells.packages);
    };
}
```

```sh
nix develop
repent
git add penance.lock nix/penance-hackage
nix build
```

`repent` runs Cabal's solver outside Nix evaluation, writes a canonical
`penance.lock`, and generates one hash-pinned Nix expression per locked Hackage
sdist. Bare package constraints in `cabal.project` are applied to every solver
scope, including setup dependencies and build tools; explicitly scoped
constraints such as `setup.foo` are preserved. Lock-backed components also
preserve Cabal C sources, include/header settings, compiler options, and native
linker settings. See
[Using `penanceProject`](docs/USING_PENANCE_PROJECT.md) and the
[examples](examples/README.md) for complete flakes.

## Documentation

- [Developer architecture](docs/DEVELOPER_ARCHITECTURE.md)
- [Architecture contract and supported Nix features](docs/ARCHITECTURE.md)
- [Verification and benchmarks](docs/ARCHITECTURE_TESTING.md)
- [Target architecture](docs/NEW_ARCHITECTURE.md)

Run `nix run .#docs` for the navigable mdBook or `nix run .#bench` for the full
comparison suite. Benchmark artifacts default to `.penance/bench-results/`.

## Wasm Provenance

`nix/planner.wasm` is committed because building it during evaluation would be
IFD. `checks.<system>.planner-wasm-provenance` rebuilds it with GHC's wasm32-wasi
backend and byte-compares the result. Regenerate it with:

```sh
nix build .#ghcWasmPlanner -o result-planner
chmod u+w nix/planner.wasm
cp result-planner/planner.wasm nix/planner.wasm
chmod 0555 nix/planner.wasm
nix build .#checks.$(nix eval --raw --impure --expr builtins.currentSystem).planner-wasm-provenance
```

Penance does not yet have a license; all rights are reserved until one is
chosen. Do not redistribute before a LICENSE file lands.
