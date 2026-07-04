# Architecture Testing

The architecture test suite turns the milestones in `docs/ARCHITECTURE.md` into
repeatable checks and benchmark rows. It has two jobs:

1. prove architecture invariants as implementation lands
2. compare real build time against haskell.nix at every project phase

The phase matrix lives in `tests/architecture/phase-matrix.json`. Rows have a
state:

- `comparison`: equivalent real penance build vs real haskell.nix build
- `failing`: a required comparison whose real penance build target does not
  exist yet, or whose architecture test is otherwise not implemented yet

## Run the Phase Benchmark

```sh
scripts/bench-architecture-phases.sh
```

or through the flake app:

```sh
nix run .#bench-architecture-phases
```

The runner performs real `nix build` commands by default. It also times
`drvPath` evaluation for the same attrs so eval cost and build realization cost
are visible side by side. At the end of each run it prints a human-readable
summary with the PASS/FAIL result, failure reasons, measured rows, and skipped
rows.

Results are written under:

```text
docs/bench-results/architecture/<system>-<timestamp>/
  metrics.tsv
  metrics.jsonl
  summary.json
  logs/
  results/
```

Use `--dry-run` only for quick smoke checks. Architecture comparisons should use
the default real build mode. Use `--rebuild` when you want local rebuild timing
instead of ordinary realization/substitution timing.

Useful examples:

```sh
scripts/bench-architecture-phases.sh --list
scripts/bench-architecture-phases.sh --phase M2-static-unit-bench
scripts/bench-architecture-phases.sh --repeat 3 --keep-going
scripts/bench-architecture-phases.sh --rebuild --phase M4-module-granularity
```

## Current Runnable Rows

| Phase | State | Penance target | haskell.nix target | Meaning today |
|---|---|---|---|---|
| M0 primitives | `failing` | none yet | none | dynamic derivation probes are missing |
| M1 lock | `failing` | none yet | `haskellNixBenchExe` | lock generation benchmark is missing |
| M2 static simple | `failing` | none yet | `haskellNixSimpleLib` | real penance unit-builder target is missing |
| M2 static bench | `failing` | none yet | `haskellNixBenchExe` | real penance static component target is missing |
| M4 module bench | `failing` | none yet | `haskellNixBenchExe` | real penance module dynamic-derivation target is missing |
| M5 Backpack | `failing` | none yet | none yet | equivalent real Backpack comparison is missing |
| M6 cross | `failing` | none yet | none yet | aarch64-linux comparison is missing |
| M7 MSC | `failing` | none yet | none yet | bundle comparison is missing |
| M7 warp | `failing` | none yet | none yet | deploy comparison is missing |

Those labels are deliberately explicit: until M2/M4 build derivations land,
penance is not doing the same Haskell compile work as haskell.nix. The suite
records those rows as failures instead of producing substitute benchmark data.

## Required Gates by Milestone

M0 primitives:

- hand-written JSON derivation add and round-trip
- text-hash planner output consumed through `builtins.outputOf`
- recursive-nix `nix store add-path`
- CA interface/output cutoff probe
- remote builder probe
- planner determinism probe

M1 lock:

- canonical `strata.lock` golden tests
- `penance-lock --check`
- Backpack unit ID and substitution fixture
- per-target flag divergence fixture

M2 static unit builder:

- pure Nix lowerer fixtures
- no-IFD flake check
- unit builder for Hackage and local units
- `dbIface`/`dbFull` cutoff matrix
- dev shell compiles zero external packages
- phase benchmark rows updated so penance targets are real Haskell builds

M4 module dynamic derivations:

- planner determinism on real GHC inputs
- `ghc -M` or GHC API DAG fixture
- Template Haskell classification fixture
- 30-module incremental cutoff test
- phase benchmark row updated from graph-plan target to real module builder

M5 Backpack:

- Cabal-derived indefinite and instantiation lock nodes
- implementation body/interface/signature rebuild matrix
- Cabal-valid Backpack real build fixture
- haskell.nix Backpack baseline target added to the phase matrix

M6 cross:

- aarch64-linux builder VM smoke
- per-target toolchain tuple assertions
- cross target phase benchmark rows for penance and haskell.nix

M7 fleet:

- MSC VM install without experimental Nix features
- warp Tier 0 closure-delta deploy timing
- warp Tier 1 service swap timing
- bundle size and closure path count comparisons

## Benchmark Interpretation

Use three modes and keep them separate:

- ordinary build: includes substitution and realization time in the current
  store state
- `--rebuild`: forces local rebuilds and is the closest thing to compile-time
  measurement
- clean-store CI: measures cold path behavior and should be run on dedicated
  builders, not developer laptops

The suite writes both TSV and JSON so CI can graph wall time, closure NAR size,
and failure count over time. A milestone is not complete until its phase row is
`comparison`, required, and comparing equivalent real build products.
