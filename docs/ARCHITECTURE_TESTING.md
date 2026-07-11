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

Additional required functionality lives in
`tests/architecture/functionality-gap-matrix.json`. Rows remain `failing` until
a real benchmark, VM test, corpus sweep, or gate is implemented; converted rows
stay in the matrix as `comparison` rows backed by real targets.

## Run the Phase Benchmark

The total benchmark entrypoint is:

```sh
nix run .#bench
```

Keep this command total as new benchmark suites land. A new benchmark is not
fully wired until `nix run .#bench` runs it.

Standalone gap suites still fail by default. The total runner passes explicit
allow flags so `not_implemented` rows are retained in the metrics as recorded
gaps instead of making the aggregate benchmark fail. The rebuild pass also
allows haskell.nix-only `--rebuild` nondeterminism while continuing to fail any
penance measurement failure.

For comparison suites, the total runner uses `--repeat 3` and
`--require-penance-faster`. The architecture runner then prints section-total
medians and fails if an implemented section is not faster on penance than on
haskell.nix.

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
nix run .#bench-architecture-phases -- --repeat 3 --require-penance-faster
nix run .#bench-architecture-phases -- --rebuild --phase M4-module-granularity
```

## haskell.nix Baseline Coverage

```sh
nix run .#bench-haskell-nix-baseline -- --keep-going
```

This separate matrix lives in
`tests/architecture/haskell-nix-baseline-matrix.json`. It tracks the advertised
haskell.nix baseline that remains in scope for STRATA: Cabal project
translation, component derivations, Hackage and Stackage package sets,
`shellFor` and GHC shell helpers, project cross compilation, project variants
and overrides, test/benchmark/check collection, and materialization/cache
workflows. Stack translation is documented out of scope in
`docs/ARCHITECTURE.md` because Cabal is the Backpack-aware solver of record.

Every baseline row is a `comparison` row, and the `haskell-nix-baseline-static`
check enforces that; a parity gap that reopens must be recorded in the
functionality-gap matrix instead. The total benchmark gates the comparison rows
with `--repeat 3 --require-penance-faster`.

Current comparison rows are intentionally narrow about what they measure. The
Stackage row parses StateVar's version from the pinned `lts-24.41` snapshot and
checks the built package against that resolution. The shell row uses the same
composed package DB as `devShells.<system>.default` and proves `cabal build all`
does not build external dependencies. The cross-project row shares the raw
cross-GHC between penance and haskell.nix, so it measures raw invocation versus
`projectCross`/Setup machinery rather than a second compiler bootstrap. The
materialization/cache row compares a lock-hash/root-drv cache manifest with a
haskell.nix project whose `plan-nix` is supplied through `materialized`.

## Architecture Functionality Gaps

```sh
nix run .#bench-architecture-functionality -- --keep-going
```

This matrix tracks required functionality outside the main phase matrix:
remaining M0 primitive probes, deeper M1 lock fixtures, M2 cutoff and dev-shell
projection gates, M3 cache behavior, M4 module-cutoff and
hs-boot/Template-Haskell checks, M5 Backpack rebuild behavior, M6 cross lanes,
M7 VM/deploy behavior, C9 operational lanes, timing thresholds, and corpus
coverage. `M4-dynamic-derivation-emission` is now a comparison row that builds
`penanceDyndrvEmissionProof` and records the emitted dynamic derivation
convergence proof. `M4-module-cutoff-30` is now a comparison row that builds
the committed thirty-module dyndrv fixture against a haskell.nix build of the
same executable; its exact rebuild cutoff behavior is enforced by the rebuild
scenario rows. `M4-hs-boot-th-classification` is now a comparison row: its
penance target proves hs-boot ordering and Template Haskell `dbFull`
classification on a committed fixture, while rebuild-scenarios enforces the
dependency body-edit cutoff for the splice module.

The total benchmark runs this matrix too, so `nix run .#bench` remains the full
entrypoint. Direct runs still fail while any required rows remain
`not_implemented`; converted comparison rows are hard failures if their proof
target stops building.

## Rebuild Scenarios

```sh
nix run .#bench-rebuild-scenarios -- --keep-going
```

This suite reads `tests/architecture/rebuild-scenarios.json`. Most scenarios
copy the local flake to a temporary worktree, run a baseline
`nix build --dry-run`, apply the scenario edit, run the edited dry-run, and
diff the derivation sets. Dyndrv cutoff scenarios opt into `dyndrv-build-log`
mode: they warm a real baseline build, apply the edit, run a real edited build,
and assert the exact planner/module/assemble events observed in that edited
build log. Rows with a non-null `expectedMaxRebuiltDrvs` fail when the edited
count exceeds that bound; rows with `expectedRebuiltNames` also fail on any
missing or extra event. Rows without a bound are marked `failing` so current
rebuild counts are visible while the matching cutoff mechanism is still absent.
The total benchmark allows only those `not_implemented` rows; enforced bounds
remain hard failures.

Results are written under:

```text
docs/bench-results/rebuild-scenarios/<system>-<timestamp>/
  metrics.tsv
  metrics.jsonl
  summary.json
  logs/
```

## Dynamic Derivation Probes

```sh
nix run .#bench-dynamic-probes
```

This suite covers the P2-P5 local and P7 dynamic-derivation primitives. One
text-hash, content-addressed planner registers a child derivation with
`nix derivation add`, writes the child drv text as its own output, and a
consumer follows the chain through `builtins.outputOf`; another planner runs
`nix store add-path` inside recursive Nix and emits a child derivation whose
`inputSrcs` includes the added path. The runner also builds a three-module
content-addressed `hi`/`o` cutoff toy locally and asserts the body-edit,
declaration-edit, and no-op build sets from real build logs. It compares two
salted planner derivations that must emit identical child drv JSON, and a
negative pair whose emitted child JSON intentionally differs. It builds the
planners' `^out^out` CLI chains, verifies second consumer builds perform no
builds, checks edited-payload liveness, records the added source input,
compares five forced rebuilds of the lock-built benchmark library `iface`
output, and confirms both intentionally corrupt child JSON and a corrupted
`.hi` hash fail their comparisons.

## Current Runnable Rows

| Phase | State | Penance target | haskell.nix target | Meaning today |
|---|---|---|---|---|
| M0 primitives | `comparison` | `penancePrimitiveProbes` | `haskellNixPrimitiveProbes` | committed Nix primitive probes and derivation show/add round-trips |
| M1 lock | `comparison` | `penanceLockBench` | `haskellNixBenchPlan` | committed benchmark and StateVar external-dependency `strata.lock` checks versus haskell.nix generated plan output |
| M2 static simple | `comparison` | `penanceSimpleLibViaLock` | `haskellNixSimpleLib` | lock-built `simple-lib` component from `penanceProject`, with content-addressed ABI-stub `iface`, real object/archive `out`, and composed package DB outputs |
| M2 static bench | `comparison` | `penanceBenchViaLock` | `haskellNixBenchExe` | lock-built benchmark executable from `penanceProject`, compiling against `dbIface`, linking against `dbFull`, and smoke-testing generated output |
| M4 module bench | `comparison` | `penanceBenchDyndrv` | `haskellNixBenchExe` | content-addressed recursive-Nix planner emitting per-module dynamic derivations plus final assembly; exact rebuild cutoff is enforced by M4 rebuild-scenarios rows |
| M5 Backpack | `comparison` | `penanceBackpackReal` | `haskellNixBackpackExe` | real Backpack build with two concrete instantiations |
| M6 cross | `comparison` | `penanceAarch64LinuxReal` | `haskellNixAarch64LinuxBaseline` | raw fixed aarch64-linux ELF probe versus the haskell.nix-overlay cross stdenv probe; Haskell project cross parity is covered by `HN-project-cross` |
| M7 MSC | `comparison` | `penanceMscBundle` | `haskellNixMscBundle` | closureInfo-backed bundle artifacts and closure manifests |
| M7 warp | `comparison` | `penanceWarpLoop` | `haskellNixWarpBaseline` | device-cache closure manifest plus managed-service hot-swap symlink |

Those labels are deliberately explicit: a row is either a real measured target
or a failure. Future architecture work should add a failing row first, then turn
it into `comparison` only when there is a real target on both sides.

## Required Gates by Milestone

M0 primitives:

- Nix feature flag probes for CA derivations, dynamic derivations, and recursive Nix
- `builtins.outputOf` availability check
- JSON derivation show/add round-trip for penance and haskell.nix benchmark derivations
- dynamic-probes suite covers P2/P3 text-hash planner output consumed by
  `builtins.outputOf` and the `^out^out` CLI chain, plus P4 recursive-nix
  `add-path` feeding a child derivation source input and P5 local CA cutoff
  build-log assertions, and P7 salted planner determinism with a negative
  emitted-JSON comparison
- functionality-gap rows track the remaining P6 remote-builder probe:
  `M0-ca-cutoff-toy-remote`

M2 static unit cutoff:

- lock-backed local libraries have split content-addressed `iface` and `out`
  outputs; `iface` is compiled from body-erased ABI stubs because raw GHC
  interfaces carry a changing source hash even with pragma omission flags
- composed `dbIface` and `dbFull` package DB derivations drive executable
  compile and link steps separately
- dynamic-probes records a no-op build, an implementation-body edit that
  rebuilds the library, `dbFull`, and link only, and an export edit that
  also rebuilds `dbIface` and the executable compile derivation

M1 lock:

- canonical `strata.lock` golden test for the benchmark fixture
- schema-1 external unit metadata for the StateVar fixture, including the
  Hackage sdist hash and GHC boot-library markers
- deterministic repeated lock generation for the external fixture
- stale-lock rejection when the fixture dependency set changes
- explicit `project.pathBase = "project-root"` metadata for lock-local paths
- `penance-lock --check` wired into `penanceLockBench`
- haskell.nix `plan-nix` materialization wired into `haskellNixBenchPlan`
- Backpack unit ID and substitution fixture
- per-target flag divergence fixture

M2 static unit builder:

- pure Nix lowerer fixtures
- no-IFD eval proof for the lock-built benchmark executable, simple library,
  and StateVar external fixture
- unit builder for Hackage and local units
- `dbIface`/`dbFull` cutoff matrix covered by dynamic-probes for the lock-built
  benchmark library and executable consumer
- `.hi` determinism soak covered by dynamic-probes for the lock-built benchmark
  library `iface` output, including the `Bench.Model` deriving module
- dev shell compiles zero external packages; HLS and multi-repl projection still
  remains a functionality-gap row
- phase benchmark rows updated so penance targets are real Haskell builds
- rebuild-scenarios no-op benchmark has an enforced zero-rebuild bound

M4 module dynamic derivations:

- `ghc -M` or GHC API DAG fixture
- per-module GHC compile fixture on the Template Haskell benchmark
- final executable link with output validation
- dynamic `nix derivation add` emission convergence on the real benchmark
- 30-module incremental cutoff test covered by `M4-module-cutoff-30` and the
  M4 rebuild-scenarios exact-set rows
- hs-boot ordering and Template Haskell classification covered by
  `M4-hs-boot-th-classification`; the TH dependency body-edit cutoff is covered
  by `M4-hs-boot-th-dep-body-edit`

C9 operational switches:

- the granularity axis is covered by `penanceProjectVariants`, which builds
  `granularity-unit` and `granularity-module` from the same committed lock and
  byte-compares their run outputs
- lowering, addressing, cache-anchor, Nix-version, and clean-store lanes remain
  functionality-gap rows

M5 Backpack:

- Cabal-derived indefinite and instantiation lock nodes
- implementation body/interface/signature rebuild matrix
- Cabal-valid Backpack real build fixture
- haskell.nix Backpack baseline target added to the phase matrix

M6 cross:

- aarch64-linux ELF target build through the raw fixed-ELF lane and the haskell.nix-overlay cross stdenv lane
- per-target toolchain tuple assertions
- cross target phase benchmark rows for penance and haskell.nix-overlay lanes
- native linux-builder VM smoke; full Haskell target build is covered by `HN-project-cross`

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
