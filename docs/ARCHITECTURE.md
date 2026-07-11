# penance Architecture

`penance` is the implementation track for the STRATA architecture described in
`docs/NEW_ARCHITECTURE.MD`: a haskell.nix replacement for Backpack-heavy,
embedded NixOS monorepos.

This document is intentionally not a copy of the full spec. It records the
target architecture, the current prototype state, the deficiencies we must
close, and the migration plan for getting from here to the STRATA design.

## Status

Current status: prototype, not production architecture.

The checkout currently implements a Wasm-assisted evaluation path that reads a
source tree, produces a `ProjectSkeleton`, and builds a root planner derivation
that emits graph-plan JSON. This validates the basic shape of cheap Nix eval
and graph planning, but it is still missing the architectural pieces that make
STRATA correct and useful at scale:

- an MVP lock-driven unit builder for ordinary local components and the
  StateVar external sdist fixture, including content-addressed split
  `iface`/`out` outputs for ordinary local units, but not a full Cabal solver
  or Backpack-aware lock
- no production module `.drv` emission through `nix derivation add`; the
  architecture suite currently exercises `ghc -M` and per-module GHC compile
  steps as the first real module-granular target
- no content-addressed split builder yet for Hackage, Backpack, or
  module-granular units
- only prototype Backpack graph artifacts, not Cabal-accurate unit nodes
- a lock-derived composed-package-DB dev shell for the benchmark fixture, but
  not the Backpack HLS projection; no production MSC bundle tool or SSH-backed
  warp device loop; the architecture suite currently exercises file-cache
  bundle and local hot-swap targets

Stack project translation is not part of the STRATA product target. Cabal is
the solver of record because the target architecture depends on Backpack-aware
unit planning, and Stack does not model the Backpack semantics this project
needs to preserve.

The target architecture below supersedes the prototype where they conflict.

## Target Invariants

Every implementation change must preserve these rules.

1. No import-from-derivation. `nix flake check` must pass with
   `allow-import-from-derivation = false`.
2. The committed lockfile is the source of truth. Nix evaluation must not solve
   dependencies, interpret Cabal semantics, or discover dependency edges by
   reading `.cabal` files.
3. Build graph nodes are Cabal/GHC units, not packages. Units include ordinary
   components, indefinite Backpack libraries, and fully instantiated Backpack
   libraries.
4. Haskell derivations are content-addressed by default and split compile-time
   interfaces from runtime/link outputs:
   - `iface`: `.hi`/`.hie` plus package confs that reference only interface
     paths
   - `out`: objects, libraries, executables, and full package confs
5. Dynamic derivations are used only where the graph is not known at lock time:
   the module DAG inside eligible local units. Hackage units and Backpack units
   remain unit-level derivations.
6. Devices see only input-addressed, realized store paths. CA derivations,
   dynamic derivations, and realisations are build-farm concerns.
7. Planner output is deterministic: sorted maps, canonical JSON, no clocks,
   hostnames, or ambient environment.
8. Experimental features have kill switches using the same lockfile:
   `granularity = "module" | "unit"`,
   `lowering = "wasm" | "nix"`, and
   `addressing = "ca" | "input"`.
9. Secrets never enter derivations. Bundle signing is a CI/post-build operation.
10. Haskell sources are minimal filesets. Large non-Haskell trees, including
    VHDL, must not enter Haskell derivation inputs.

## Architecture

### 1. Lock Layer

`penance-lock`/`strata-lock` is a Haskell CLI that links the pinned
`cabal-install` and `Cabal` libraries. It runs the Cabal solver at commit time,
elaborates the install plan down to units, and writes canonical JSON to
`strata.lock`.

The lock contains, per target platform:

- package name, version, component, flags, language, extensions, and source
  pins
- stable Cabal-compatible unit IDs
- direct build, exe, and setup dependencies as unit IDs
- Backpack kind: `ordinary`, `indefinite`, or `instantiation`
- Backpack substitutions as `{ SigName: { unit, module } }`
- per-unit granularity selection
- per-target toolchain tuple, including GHC, LLVM, and CUDA metadata where
  applicable

The lock layer fixes the largest current deficiency: the prototype lets Nix and
the Wasm scanner inspect Cabal project files during evaluation. That was useful
for bootstrapping, but it is not the final architecture.

### 2. Eval Layer

Nix consumes `strata.lock` and lowers it to derivations in O(lock size).

Primary lowering uses a committed `strata-lower.wasm` via `builtins.wasm`.
Fallback lowering uses pure Nix `fromJSON` plus library functions. The two
lowerers must produce the same attrset shape and are golden-tested against each
other.

The flake surface should expose:

- `packages.<system>.<name>` for local package defaults
- `packages.<system>."<pkg>:<ctype>:<cname>"` for component compatibility
- `devShells.<system>.default`
- `legacyPackages.<system>.strata.{units,pkgdbs,toolchains,projection}`
- `lib.overlay`
- `apps.<system>.{warp,msc,penance-lock}`

The current `wasm-planner` and `nix/planner.wasm` remain bootstrap artifacts
until the lock-based lowerer exists. They should not grow into a second Cabal
implementation.

### 3. Build Layer

The build layer has two paths with the same output contract.

Unit builder:

- builds any unit as one derivation
- is the fallback for all units
- is the only path for Hackage and Backpack units
- drives Cabal `Setup configure/build/install/register`
- passes exact dependencies and Cabal-compatible `--cid`
- passes `--instantiate-with` for Backpack instantiations
- emits `iface` and `out` outputs

Module planner:

- applies only to local, ordinary, Simple-build units selected for
  `granularity = "module"`
- is itself a planner derivation requiring `recursive-nix`
- discovers the module DAG at build time
- emits one content-addressed derivation per module with `nix derivation add`
- emits an assemble/link derivation whose outputs match the unit builder
- is consumed through `builtins.outputOf`

The module planner starts with the STRATA mechanism: `ghc -M` against the
unit's package DB, conservative Template Haskell classification, per-file CA
source paths, and deterministic JSON derivation emission. Hard cases that the
planner cannot model safely, such as complicated `hs-boot`, plugins, generated
sources, or custom `Setup.hs`, must demote to unit granularity until explicitly
supported.

### 4. Backpack Model

Backpack is first-class. Indefinite libraries and instantiations are lock nodes,
not decorations on packages.

- Indefinite units typecheck signatures and modules and produce interface
  artifacts.
- Instantiation units compile with a concrete module substitution and depend on
  the indefinite source plus implementation unit interfaces.
- Implementation body edits should not rebuild instantiations when exported
  interfaces are unchanged.
- Signature edits should rebuild the indefinite unit and its instantiations.
- The HLS workflow for indefinite units uses a generated projection based on
  default instantiations, while CI keeps the real indefinite typecheck honest.

The prototype `signatures/` and `instantiations/` graph-plan outputs are a good
shape check, but Cabal's `ElaboratedInstallPlan`, `OpenUnitId`, `ModuleSubst`,
and `hashModuleSubst` are the source of truth for final unit IDs and
substitutions.

### 5. Dev Shell

`nix develop` currently consumes the benchmark fixture's lock-derived project
shell for pinned GHC, Cabal, and external package DBs. The target shell also
includes HLS, `warp`, and `msc`.

The current shell uses a composed package DB for external dependencies so
`cabal build all` compiles only local packages. Backpack-heavy development uses
a generated projection project for HLS and `multi-repl`, since the ecosystem
does not load indefinite units directly.

### 6. Fleet Layer

The fleet layer has two tools.

`msc` builds every host's `config.system.build.toplevel` and writes a standard
binary-cache directory containing the union of host closures plus
`manifest.json`. Devices install from this bundle with ordinary `nix copy` and
`switch-to-configuration`; they do not need experimental Nix features.

`warp` is the development loop:

- Tier 0 builds a host toplevel, copies the closure delta over `ssh-ng`, and
  runs `switch-to-configuration test`.
- Tier 1 hot-swaps a managed service executable through a `/run` overlay,
  restarts that service, and records taint state until reconciliation.

These tools are outside the current prototype and should be implemented only
after the static unit builder path is working.

## Current Prototype Contract

Until the lock and real dynamic derivation layers land, the root planner
derivation writes structured planning artifacts:

- `project-skeleton.json`
- `planner-input.json`
- `graph-plan.json`
- `drv-index.json`
- `packages/package-graph.json`
- `packages/<package>/package.drv.plan.json`
- `components/component-graph.json`
- per-component `*.drv.plan.json`
- `modules/module-graph.json`
- per-module `*.drv.plan.json`
- `signatures/backpack-graph.json`
- signature and instantiation `*.drv.plan.json`

`checks.<system>.graph-plan-prototype` validates this contract with the
Backpack multi-instantiation fixture. This check remains useful as a planning
surface test, but it is not sufficient for the target architecture because it
does not prove real derivation emission, content addressing, or rebuild cutoff.

## Deficiencies and Remediation

| Deficiency | Consequence | Remedy | Exit criterion |
|---|---|---|---|
| Nix eval reads Cabal files and source manifests | Eval can become a partial Cabal implementation | Add `penance-lock`; eval consumes only `strata.lock` | `allow-import-from-derivation=false` check passes and eval does not parse `.cabal` files |
| No committed unit lock | Unit IDs and Backpack substitutions are provisional | Use Cabal `ElaboratedInstallPlan` and canonical JSON lock emission | Golden lock is byte-stable across machines |
| Wasm planner is a scanner | Hackage/Cabal edge cases are under-modeled | Restrict Wasm to lock lowering; move Cabal semantics into lock tool | Wasm and Nix lowerers are golden-equal on lock fixtures |
| Planner emits `*.drv.plan.json`, not `.drv` files | Builds cannot exercise dynamic derivations or cutoff | Implement `nix derivation add` emission and `builtins.outputOf` consumption | Probe chain builds from planner to child drv to assemble drv |
| CA `iface`/`out` split is only proven for ordinary lock-backed local units | Hackage, Backpack, and module-granular paths can still rebuild more than necessary | Extend the split builder contract to the remaining unit classes | Body-only edits cut off downstream compiles across each supported unit class |
| Module backend does not build modules | Incremental rebuild promise is untested | Add planner derivation, per-module drvs, and assemble drv | 30-module fixture rebuilds one module plus assemble on body edit |
| Backpack data is prototype-level | Instantiation rebuild scope may be wrong | Lock indefinite and instantiation units from Cabal internals | Backpack matrix passes: impl body, impl interface, and hsig edits rebuild only expected nodes |
| Dev shell lacks Backpack projection | Ordinary local development can use a composed package DB, but Backpack-heavy HLS and multi-repl workflows are not represented | Generate HLS/multi-repl projection from lock units after Backpack lock data is real | Projection smoke test exposes indefinite and instantiated units without rebuilding external packages |
| No device boundary tools | Embedded iteration still requires ad hoc deploys | Add `msc`, `warp`, and `devOverlay` after unit builder | VM install/deploy/swap tests pass with no experimental features on device |
| Experimental features are not probed | Nix upgrades can silently break primitives | Vendor dynamic-derivation probes and run on every Nix bump | P1-P7 probe suite is green on dev box, CI, and remote builder |

## Implementation Plan

1. M0: pin Determinate Nix and add primitive probes for JSON derivation add,
   text-hash planner output, `builtins.outputOf`, recursive-nix `add-path`,
   CA interface cutoff, remote builders, and planner determinism.
2. M1: implement `penance-lock` for ordinary units, including `--check`,
   canonical lock output, source pins, and golden tests.
3. M2: implement pure Nix lowering, static unit builder, `dbIface`/`dbFull`,
   initial dev shell, and the input-addressed kill-switch baseline.
4. M3: enable content addressing, harden `.hi` determinism, verify Cachix or
   implement cache-anchor fallback.
5. M4: implement module-granular dynamic derivations behind per-unit opt-in,
   then broaden only after cutoff tests are stable.
6. M5: implement first-class Backpack locking, unit building, instantiation
   rebuild tests, and HLS projection.
7. M6: add per-target toolchains and aarch64-linux builder support, preferring
   native Linux builder VMs for Jetson over GHC cross compilation.
8. M7: implement `msc`, `warp`, `devOverlay`, VM tests, and bench-device
   latency tracking.
9. M8: migrate real users from haskell.nix, keep the old lane for two release
   trains, then remove it once parity and rollback paths are proven.

M2 is the first shippable product: fast eval, lock-driven static builds, and
ABI-level rebuild cutoff. M4 and later improve inner-loop speed but must remain
behind kill switches.

## Required Nix Configuration

Build farm machines, CI runners, and development boxes need pinned Determinate
Nix with these features:

```conf
extra-experimental-features = nix-command flakes ca-derivations dynamic-derivations recursive-nix wasm-builtin parallel-eval
lazy-trees = true
eval-cores = 0
system-features = nixos-test benchmark big-parallel kvm recursive-nix uid-range
```

`wasm-builtin` is required for eval-time lowering. `dynamic-derivations` and
`recursive-nix` are required for the module planner. `ca-derivations` is
required for the final Haskell derivations. `parallel-eval` and lazy trees are
performance features, not semantic dependencies.

Devices use stock Nix with trusted public keys only. They must not require CA,
dynamic derivations, recursive-nix, or Wasm.

## Bootstrap Rule

Eval-time Wasm artifacts must be committed. Building the Wasm blob during the
same evaluation would reintroduce IFD in disguise.

The current bootstrap artifact is `nix/planner.wasm`. It should eventually be
replaced or supplemented by the lock lowerer artifact, but the rule stays the
same: build the Wasm artifact out of band, commit it, and make evaluation read
that file directly.

For the current prototype artifact:

```sh
nix build .#wasmPlannerBuiltin -o result-wasm-builtin
chmod u+w nix/planner.wasm
cp result-wasm-builtin/planner.wasm nix/planner.wasm
chmod 0555 nix/planner.wasm
```

## Validation

The existing checks remain:

- `checks.<system>.graph-plan-prototype`
- `checks.<system>.bench-surface-parity`
- `checks.<system>.nix-format`
- `checks.<system>.haskell-nix-baseline-static`
- `checks.<system>.architecture-functionality-static`

The architecture phase benchmark is:

- `nix run .#bench-architecture-phases`

The haskell.nix advertised-baseline coverage benchmark is:

- `nix run .#bench-haskell-nix-baseline -- --keep-going`

The required architecture functionality gap benchmark is:

- `nix run .#bench-architecture-functionality -- --keep-going`

The dynamic-derivation primitive probe benchmark is:

- `nix run .#bench-dynamic-probes`

The phase benchmark reads `tests/architecture/phase-matrix.json` and records
eval plus `nix build` timings for penance and haskell.nix phase targets. Rows
marked `comparison` are equivalent real builds. Rows marked `failing` are
unfinished or broken required comparisons; there is no separate future-work
state.

The baseline benchmark reads
`tests/architecture/haskell-nix-baseline-matrix.json`. It intentionally keeps
missing haskell.nix parity features as `failing` rows so they remain visible in
CI and benchmark output.

The functionality benchmark reads
`tests/architecture/functionality-gap-matrix.json`. It keeps required
architecture work visible as failing rows until a real proof target exists, and
converted rows stay there as comparison rows. The dynamic-probes runner now
covers the M0 P2/P3 text-hash planner and `builtins.outputOf` chain, the P4
recursive-nix `add-path` probe, the P5 local content-addressed cutoff toy, the
P7 salted planner determinism comparison, the M2 `dbIface`/`dbFull` cutoff
matrix for the lock-built benchmark library and executable consumer, and the M3
`.hi` determinism soak. The `M4-dynamic-derivation-emission` row now builds the
real benchmark dyndrv emission proof. `M4-module-cutoff-30` builds the committed
thirty-module dyndrv fixture against a haskell.nix build of the same executable,
while rebuild-scenarios enforce the body/edit/no-op exact event sets.
`M4-hs-boot-th-classification` proves hs-boot ordering and Template Haskell
`dbFull` classification through the module planner, with a rebuild-scenarios row
covering the splice dependency body-edit cutoff. The P6 remote-builder probe
stays visible as a functionality gap.

They must be hardened by architecture-gating tests before cutover:

- full lock determinism beyond the benchmark `penance-lock --check`
- wasm-vs-Nix lowerer equality
- Backpack rebuild matrix
- dev shell HLS and multi-repl projection beyond the current external-package
  suppression smoke
- MSC install in a VM with no experimental features beyond the current
  file-cache bundle target
- warp Tier 0 and Tier 1 VM tests beyond the current local hot-swap target
- kill-switch axes beyond the current granularity unit/module output-equivalence
  proof
