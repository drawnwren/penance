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

Additional required functionality that does not yet have a passing row lives in
`tests/architecture/functionality-gap-matrix.json`. This is a failure matrix:
every row is required and remains `failing` until a real benchmark, VM test,
corpus sweep, or gate is implemented.

## Run the Phase Benchmark

The total benchmark entrypoint is:

```sh
nix run .#bench
```

Keep this command total as new benchmark suites land. A new benchmark is not
fully wired until `nix run .#bench` runs it.

```sh
nix run .#bench-architecture-phases
```

The underlying executable is `penance-architecture-bench`, built from the
`planner-bin` Haskell package.

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
nix run .#bench-architecture-phases -- --list
nix run .#bench-architecture-phases -- --phase M2-static-unit-bench
nix run .#bench-architecture-phases -- --repeat 3 --keep-going
nix run .#bench-architecture-phases -- --rebuild --phase M4-module-granularity
```

## haskell.nix Baseline Coverage

```sh
nix run .#bench-haskell-nix-baseline -- --keep-going
```

This separate matrix lives in
`tests/architecture/haskell-nix-baseline-matrix.json`. It tracks the advertised
haskell.nix baseline: Cabal and Stack project translation, component
derivations, Hackage and Stackage package sets, `shellFor` and GHC shell
helpers, project cross compilation, project variants and overrides,
test/benchmark/check collection, and materialization/cache workflows.

Rows that penance already covers are `comparison` rows. Rows that haskell.nix
advertises but penance does not yet implement are `failing` rows. That is
intentional: the suite should fail until the parity gap is closed or explicitly
removed from the product target.

## Architecture Functionality Gaps

```sh
nix run .#bench-architecture-functionality -- --keep-going
```

This matrix tracks required functionality that is not represented by a passing
benchmark yet: missing M0 primitive probes, deeper M1 lock fixtures, M2 cutoff
and dev-shell gates, M3 cache behavior, M4 dynamic derivation and
incremental-module checks, M5 Backpack rebuild behavior, M6 cross lanes, M7
VM/deploy behavior, C9 operational lanes, timing thresholds, and corpus
coverage.

The total benchmark runs this matrix too, so `nix run .#bench` remains the full
entrypoint. The suite is expected to fail until those rows are converted to real
comparisons or real workflow checks.

## Rebuild Scenarios

```sh
nix run .#bench-rebuild-scenarios -- --keep-going
```

This suite reads `tests/architecture/rebuild-scenarios.json`. For each scenario
it copies the local flake to a temporary worktree, runs a baseline
`nix build --dry-run`, applies the scenario edit, runs the edited dry-run, and
diffs the derivation sets. Rows with a non-null `expectedMaxRebuiltDrvs` fail
when the edited count exceeds that bound. Rows without a bound are marked
`failing` so current rebuild counts are visible while the matching cutoff
mechanism is still absent.

Results are written under:

```text
docs/bench-results/rebuild-scenarios/<system>-<timestamp>/
  metrics.tsv
  metrics.jsonl
  summary.json
  logs/
```

## Current Runnable Rows

| Phase | State | Penance target | haskell.nix target | Meaning today |
|---|---|---|---|---|
| M0 primitives | `comparison` | `penancePrimitiveProbes` | `haskellNixPrimitiveProbes` | committed Nix primitive probes and derivation show/add round-trips |
| M1 lock | `comparison` | `penanceLockBench` | `haskellNixBenchPlan` | committed `strata.lock` freshness check versus haskell.nix generated plan output |
| M2 static simple | `comparison` | `penanceSimpleLibReal` | `haskellNixSimpleLib` | nixpkgs `callCabal2nix` build timing baseline for the simple fixture; lock-driven cutoff is tracked by `M2-db-cutoff-matrix` |
| M2 static bench | `comparison` | `penanceBenchReal` | `haskellNixBenchExe` | nixpkgs `callCabal2nix` build timing baseline for the module-heavy benchmark; lock-driven cutoff is tracked by `M2-db-cutoff-matrix` |
| M4 module bench | `comparison` | `penanceModuleGranularBench` | `haskellNixBenchExe` | one monolithic derivation running `ghc -M`, per-module `ghc -c`, and final link; dynamic derivations are tracked by `M4-dynamic-derivation-emission` and `M4-module-cutoff-30` |
| M5 Backpack | `comparison` | `penanceBackpackReal` | `haskellNixBackpackExe` | real Backpack build with two concrete instantiations |
| M6 cross | `comparison` | `penanceAarch64LinuxReal` | `haskellNixAarch64LinuxBaseline` | C-language aarch64-linux ELF probes; full Haskell cross build is tracked by `M6-haskell-cross-aarch64` |
| M7 MSC | `comparison` | `penanceMscBundle` | `haskellNixMscBundle` | closureInfo-backed bundle artifacts and closure manifests |
| M7 warp | `comparison` | `penanceWarpLoop` | `haskellNixWarpBaseline` | device-cache closure manifest plus managed-service hot-swap symlink |

Those labels are deliberately explicit: a row is either a real measured target
or a failure. The current matrix has no failure rows; future architecture work
should add a failing row first, then turn it into `comparison` only when there is
a real target on both sides.

## Required Gates by Milestone

M0 primitives:

- Nix feature flag probes for CA derivations, dynamic derivations, and recursive Nix
- `builtins.outputOf` availability check
- JSON derivation show/add round-trip for penance and haskell.nix benchmark derivations
- functionality-gap rows track the missing P2-P7 probes:
  `M0-planner-text-hash-outputof`, `M0-recursive-nix-add-path`,
  `M0-ca-cutoff-toy`, and `M0-planner-determinism`

M1 lock:

- canonical `strata.lock` golden test for the benchmark fixture
- explicit `project.pathBase = "project-root"` metadata for lock-local paths
- `penance-lock --check` wired into `penanceLockBench`
- haskell.nix `plan-nix` materialization wired into `haskellNixBenchPlan`
- Backpack unit ID and substitution fixture
- per-target flag divergence fixture

M2 static unit builder:

- pure Nix lowerer fixtures
- no-IFD flake check
- unit builder for Hackage and local units
- `dbIface`/`dbFull` cutoff matrix
- dev shell compiles zero external packages
- phase benchmark rows updated so penance targets are real Haskell builds
- rebuild-scenarios no-op benchmark has an enforced zero-rebuild bound

M4 module dynamic derivations:

- `ghc -M` or GHC API DAG fixture
- per-module GHC compile fixture on the Template Haskell benchmark
- final executable link with output validation
- dynamic `nix derivation add` emission and 30-module incremental cutoff test

M5 Backpack:

- Cabal-derived indefinite and instantiation lock nodes
- implementation body/interface/signature rebuild matrix
- Cabal-valid Backpack real build fixture
- haskell.nix Backpack baseline target added to the phase matrix

M6 cross:

- aarch64-linux ELF target build through cross stdenv
- per-target toolchain tuple assertions
- cross target phase benchmark rows for penance and haskell.nix-overlay lanes
- native linux-builder VM smoke and full Haskell target build

M7 fleet:

- MSC closureInfo-backed bundle with manifest
- warp closure manifest in a device-cache directory
- warp managed-service hot-swap symlink
- bundle size and closure path count comparisons
- NixOS VM install without experimental features and SSH deploy timing

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
