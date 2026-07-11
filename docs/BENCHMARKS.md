# Benchmarks

The repository now contains an opt-in comparison harness against the real upstream `input-output-hk/haskell.nix` flake input.

The total benchmark entrypoint is:

```sh
nix run .#bench
```

This is the command that must stay complete as benchmark coverage grows. It runs
the architecture phase suite, an architecture rebuild pass, rebuild-count
scenarios, the haskell.nix advertised-baseline coverage suite, the architecture
functionality-gap suite, surface parity validation, the legacy vs-haskell.nix
harness, a default Hackage package validation, and a default Stackage package
closure benchmark.

The total runner captures each suite's detailed output in a per-run directory
and ends with one aggregate summary table. For suites that compare penance and
haskell.nix directly, the final output keeps the per-framework timings and the
green check next to the faster backend. TSV-producing child suites are folded
back into the final `Suite metrics` section. It also writes `summary.txt` and
`summary.tsv` next to the suite logs.

Gap suites stay strict when run directly, but the total runner records their
`not_implemented` rows as allowed gaps so `nix run .#bench` can be the complete
measurement command. The architecture rebuild pass also records haskell.nix-only
`--rebuild` nondeterminism without making the aggregate run fail.

The total runner uses three repeats for the architecture phase and
haskell.nix-baseline comparison suites. Those suites print section-total medians
and fail the aggregate run if an implemented section is not faster on penance
than on haskell.nix.

The default Stackage resolver/package pair is `lts-24.41` / `StateVar`. It
keeps the total benchmark's Stackage closure lane small and on the same GHC
9.10.3 snapshot family as the architecture baseline. To run the total suite
against a larger Stackage package such as `servant`, set
`PENANCE_BENCH_STACKAGE_PACKAGE`, for example:

```sh
PENANCE_BENCH_STACKAGE_PACKAGE=servant nix run .#bench
```

The Stackage suite realizes the full closure by default. For a local smoke run
that only evaluates and dry-runs the closure, pass:

```sh
nix run .#bench -- --stackage-dry-run
```

The default Hackage validation package is `StateVar-1.2.2`. Override it with:

```sh
PENANCE_BENCH_HACKAGE_PACKAGE=colour-2.3.6 nix run .#bench
```

If the Stackage benchmark pauses at `haskell_nix_eval_closure`, that time is in
the haskell.nix `stackProject'` dependency-closure path, not penance's planner
build. The penance side is reported separately as `penance_plan_build`. On
machines without the IOG haskell.nix cache configured, this step may build
haskell.nix helper GHCs locally.

For architecture milestone timing, use the phase benchmark suite in
`docs/ARCHITECTURE_TESTING.md`. Unlike the original harness below, it performs
real `nix build` commands by default and records penance/haskell.nix rows for
each architecture phase in `tests/architecture/phase-matrix.json`.

```sh
nix run .#bench-architecture-phases
```

Add `--repeat 3 --require-penance-faster` to enforce the same section-median
speed gate used by the total benchmark.

For haskell.nix advertised-baseline coverage, including explicit failing rows
for parity features penance does not implement yet, run:

```sh
nix run .#bench-haskell-nix-baseline -- --keep-going
```

Add `--repeat 3 --require-penance-faster` to enforce the same section-median
speed gate used by the total benchmark.

For required architecture functionality that still lacks a passing benchmark
row, run:

```sh
nix run .#bench-architecture-functionality -- --keep-going
```

Those rows are intentionally failures until a real test or build target exists.
The total benchmark passes `--allow-not-implemented` so the same rows remain in
the logs without failing the aggregate run.

For rebuild-count scenarios used by cutoff rows, run:

```sh
nix run .#bench-rebuild-scenarios -- --keep-going
```

The bounded no-op scenario enforces zero rebuilt derivations. Dyndrv cutoff
rows use real build logs to assert exact planner/module/assemble events, while
older rows still use dry-run derivation diffs. Scenarios without a bound report
current counts and fail until the matching mechanism exists. The total
benchmark allows only those `not_implemented` scenario rows; a broken bounded
scenario still fails the run.

The M4 dyndrv scenarios now include the benchmark body edit, the thirty-module
body/export/no-op fixture, and the hs-boot/Template-Haskell fixture where a
dependency body edit rebuilds the dependency object and splice module while the
ordinary sibling stays cut off.

The benchmark project lives at `tests/bench/vs-haskell-nix/project`. It is intentionally small enough to run while still including:

- a library plus executable
- ten local library modules
- `containers`
- Template Haskell via `Bench.Generated` and `Bench.TH`

Run:

```sh
scripts/bench-vs-haskell-nix.sh
```

or through the flake app:

```sh
nix run .#bench-vs-haskell-nix
```

The script writes TSV results and command logs under `docs/bench-results/`. It measures:

- `penanceBenchModule` eval
- `penanceBenchComponent` eval
- `penanceBenchModule` dry-run build
- `haskellNixBenchExe` eval
- `haskellNixBenchExe` dry-run build

The haskell.nix target is exposed as:

```sh
nix eval --raw .#packages.$(nix eval --raw --impure --expr builtins.currentSystem).haskellNixBenchExe.drvPath
nix build --dry-run .#packages.$(nix eval --raw --impure --expr builtins.currentSystem).haskellNixBenchExe
```

The penance targets are:

```sh
nix eval --raw .#packages.$(nix eval --raw --impure --expr builtins.currentSystem).penanceBenchModule.drvPath
nix eval --raw .#packages.$(nix eval --raw --impure --expr builtins.currentSystem).penanceBenchComponent.drvPath
```

This is currently an eval/planning comparison. `penance` still emits graph-plan JSON, not real Haskell build derivations, so first-build and incremental-rebuild timings are intentionally left blank until dynamic derivation emission lands.

The harness uses `PENANCE_NIX_BIN` when set. The flake app points it at `/nix/var/nix/profiles/default/bin/nix` when available so Determinate-only features such as `builtins.wasm` are not hidden by a plain `pkgs.nix` binary.

## First Local Run

Run timestamp: `2026-05-22T04:35:25Z`

Hardware and software:

- Apple M4
- 10 logical CPUs
- 16 GiB RAM
- macOS 26.5 build 25F71
- `nix (Determinate Nix 3.20.0) 2.34.6`
- haskell.nix input: `github:input-output-hk/haskell.nix/a384319` from 2026-05-22

This was a warm-cache validation run after the first haskell.nix eval had already fetched and materialized its inputs.

| Scenario | Status | Wall seconds | Max RSS |
|---|---:|---:|---:|
| `penanceBenchModule` eval | 0 | 1 | 333,594,624 |
| `penanceBenchComponent` eval | 0 | 1 | 319,389,696 |
| `penanceBenchModule` dry-run build | 0 | 2 | 318,160,896 |
| `haskellNixBenchExe` eval | 0 | 2 | 536,576,000 |
| `haskellNixBenchExe` dry-run build | 0 | 4 | 316,162,048 |

The flake app was also validated after fixing the Nix binary selection:

```sh
PENANCE_BENCH_OUT=/tmp/penance-bench-app-fixed nix run .#bench-vs-haskell-nix
```

All five scenarios exited `0`.

## Surface Parity Validation

The stronger validation is:

```sh
nix build .#checks.$(nix eval --raw --impure --expr builtins.currentSystem).bench-surface-parity
jq . result/surface-parity.json
```

It normalizes three inputs:

- `penanceBenchModule` root-planner output
- `haskellNixBenchSurface`, a JSON projection of the real haskell.nix package/component attrs
- `tests/bench/vs-haskell-nix/project/penance-bench.cabal`

The check compares package/component parity across Cabal, penance, and haskell.nix. It compares module parity across Cabal and penance, because haskell.nix exposes component derivations and unit identifiers in Nix attrs but does not expose the local module list as a simple stable attr surface.

The current validated result is:

```json
{
  "status": "ok",
  "counts": {
    "packages": 1,
    "components": 4,
    "modules": 11
  },
  "compared": {
    "packageComponents": ["cabal", "penance", "haskell.nix"],
    "modules": ["cabal", "penance"]
  }
}
```

## Arbitrary Hackage Package

Use the Hackage validation app with a package name or `name-version`:

```sh
nix run .#validate-hackage-package -- StateVar-1.2.2
```

Optional flags:

```sh
nix run .#validate-hackage-package -- --index-state HEAD colour
nix run .#validate-hackage-package -- --index-state 2026-02-01T00:00:00Z StateVar-1.2.2
```

The app:

1. runs `cabal get` for the requested Hackage package
2. creates a temporary one-package `cabal.project`
3. creates a temporary flake pointing back at this checkout
4. evaluates `penance` in module mode
5. evaluates real haskell.nix for the same source
6. runs `validate-surface-parity.sh`

The result is linked in the current working directory at `result-hackage-<package>/surface-parity.json`. Override that with `PENANCE_HACKAGE_OUT_DIR` or `PENANCE_HACKAGE_OUT_LINK` when needed.

For Hackage packages the runner compares all declared component surfaces by default, including libraries, executables, tests, and benchmarks. If a package has unusually expensive or intentionally broken auxiliary components, `validate-surface-parity.sh` still supports an opt-in `PENANCE_SURFACE_COMPONENT_KINDS` filter for local debugging.

Validated examples:

```sh
nix run .#validate-hackage-package -- StateVar-1.2.2
nix run .#validate-hackage-package -- colour-2.3.6
```

Current limitation: this validates the package/component surface against haskell.nix and the package/module surface against the Cabal manifest. The early Wasm parser now tolerates common Hackage metadata stanzas, conditionals, imports, case-insensitive stanza headers, and named sublibraries, but it is still a surface scanner rather than a complete Cabal interpreter.

## Stackage Dependency Closure

Use the Stackage package benchmark when you want the package selected from a snapshot and the Nix build to realize its dependency closure:

```sh
nix run .#bench-stackage-package -- lts-24.41 StateVar
```

Equivalent long-form flags:

```sh
nix run .#bench-stackage-package -- --resolver lts-24.41 --package StateVar
```

For a fast smoke test that still resolves the snapshot and computes the closure JSON without realizing the full compiler/package closure:

```sh
nix run .#bench-stackage-package -- --dry-run lts-24.41 StateVar
```

The app:

1. downloads the Stackage snapshot YAML
2. resolves the package to the exact Hackage version in that snapshot
3. fetches that source with `cabal get`
4. writes a temporary `stack.yaml` and `cabal.project`
5. builds penance's planner output for the local package
6. builds a haskell.nix closure derivation for all components of the selected package
7. writes `dependency-closure.json` with target components and their transitive haskell.nix component dependency closure

The default output link is:

```sh
result-stackage-<resolver>-<package>/dependency-closure.json
```

Benchmark timing rows are written under `docs/bench-results/`.

Required scenarios:

| Scenario | Metric |
|---|---|
| `nix eval .#packages.x86_64-linux.default` | wall time, max RSS |
| `nix flake check --dry-run` | wall time |
| First build (cold) | wall time |
| Single non-exported function edit | wall time, rebuilt drv count |
| Single exported signature edit | wall time, rebuilt drv count |
| Add one Hackage dep | eval time, new drv count |
| Flip a Cabal flag | eval time, rebuilt drv count |
| Add a new Backpack instantiation | eval time, new drv count |
| Edit a Backpack hole provider | wall time, rebuilt drv count |
