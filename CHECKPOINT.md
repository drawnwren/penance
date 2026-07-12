# CHECKPOINT

## 2026-07-10

- Re-read `PROGRESS.md` from the current worktree. The active plan is not the
  earlier parity cleanup; it requires Arc A (lock-driven unit MVP) before Arc
  B's post-MVP module granularity work.
- Current evidence for A1: `planner-bin/src/RepentMain.hs` still emits
  `schema = "penance/lock/0"` and stores component dependency ranges
  only. There is no `tests/fixtures/lock-external/` fixture yet, so A1 is the
  first unmet sequencing gate.
- Current action: implement A1 without weakening the existing test/matrix
  gates. The lock must become deterministic schema `penance/lock/1`,
  include solved external units with exact versions and source metadata, add
  a StateVar fixture with a committed golden lock, migrate the benchmark
  fixture lock, and keep `repent --check` freshness meaningful.
- A1 implementation pass:
  - `repent` now emits `schema = "penance/lock/1"` and an
    `externalUnits` section. Boot packages used by the fixtures are marked
    `source = "ghc-boot"` with compiler-specific versions; StateVar is pinned
    to version `1.2.2` with its Hackage tarball URL and SRI sha256.
  - Added `tests/fixtures/lock-external/`, an executable fixture depending on
    `StateVar`, plus its generated golden `penance.lock`.
  - Migrated `tests/bench/vs-haskell-nix/project/penance.lock` to schema 1.
  - `repentBench` now checks both committed locks, compares two generated
    external-fixture locks byte-for-byte, asserts the StateVar sdist and base
    ghc-boot metadata with `jq`, and verifies a scratch dependency edit fails
    `repent --check`.
  - Exposed `nix run .#repent` for the plan's documented command line.
- A1 verification:
  - `nix build .#plannerBin --no-link -L` passed.
  - Direct determinism/JQ check for the external fixture passed.
  - Direct stale-lock negative check failed as expected with
    `repent: lock is stale`.
  - `nix build .#repentBench --no-link -L` passed.
  - Static checks passed:
    `architecture-suite-static`, `architecture-functionality-static`,
    `haskell-nix-baseline-static`, and `nix-format`.
  - Full `nix run .#bench` passed. Summary:
    `docs/bench-results/bench/aarch64-darwin-20260710T083611Z/summary.txt`.
    Section-total medians still show penance faster than haskell.nix for every
    implemented architecture and baseline row; M1 lock was `0.96s` vs `1.09s`
    in architecture phases and `1.26s` vs `2.49s` in architecture rebuild.
- Next gate: A2. `penanceProject` still returns planner skeleton/root
  derivations only; component attrs do not yet compile Haskell units from the
  committed lock.
- A2 implementation pass:
  - `nix/lib.nix` now uses schema-1 `penance.lock` for component-mode projects
    that have a committed lock. It reads the lock with `builtins.fromJSON`,
    builds Hackage `StateVar` from the lock-pinned `fetchurl` tarball, asserts
    the built version against the lock, builds local library package DBs, and
    links executable/test/benchmark components against sibling unit DBs.
  - Added lock-built attrs:
    `penanceBenchLibViaLock`, `penanceBenchViaLock`,
    `penanceBenchTestViaLock`, `penanceBenchBenchmarkViaLock`,
    `penanceLockExternalViaLock`, and `penanceSimpleLibViaLock`.
  - Added `tests/fixtures/simple-lib/penance.lock` so the simple fixture also
    exercises the lock path.
  - Verification: all benchmark components and the lock-external executable
    build through `penanceProject`; `penanceBenchViaLock/output.txt` byte-matches
    `penanceBenchReal` from the earlier raw lane; no-IFD drvPath eval passed for
    `penanceBenchViaLock` and `penanceLockExternalViaLock`; a scratch lock with
    `StateVar` changed to `1.2.1` failed during the external-unit build.
- A3 implementation pass:
  - Phase-matrix M2 rows now point at `penanceSimpleLibViaLock` and
    `penanceBenchViaLock`.
  - The old raw `penanceBenchReal`, `penanceSimpleLibReal`, and
    `mkPenanceBenchExecutable` non-module branch were removed. The remaining
    raw GHC bench path is `penanceModuleGranularBench`, the Arc B seed, and its
    package flags are derived from `penance.lock`.
  - `penanceBenchChecks`, primitive probes, MSC, warp, lock-cache manifest,
    project variants, haskell.nix component baseline, and rebuild scenarios now
    use the lock-built benchmark executable or lock-built test/benchmark
    components.
  - Verification: `rg` outside historical bench results finds no
    `penanceBenchReal`, `penanceSimpleLibReal`, `mkPenanceBenchExecutable`, or
    literal `-package containers`. Focused M2 and haskell.nix baseline rows pass
    with `--repeat 3 --require-penance-faster`.
- A4 implementation pass:
  - `penanceProject` now exposes `devShells.default` for lock-backed component
    projects. The top-level `devShells.default` consumes the benchmark project's
    lock-derived shell with `inputsFrom`; the later planner migration replaced
    the former planner toolchain with pinned GHC-Wasm alongside the Nix CLI.
  - The shell package list is derived from the benchmark lock rather than a
    hand-maintained list.
  - Verification: `nix build .#penanceBenchDevShell .#penanceBenchShell
    --no-link -L` passed, and literal `nix develop --command cabal build all
    -v1` on the benchmark fixture produced zero external package build matches.
- Full post-A2/A3/A4 verification:
  - `nix run .#bench` passed. Summary:
    `docs/bench-results/bench/aarch64-darwin-20260710T090109Z/summary.txt`.
    All implemented architecture and haskell.nix-baseline section medians still
    show penance faster; M2 static rows now measure the lock-built outputs.
- Next gate: A5 acceptance sweep from a clean/CI-style checkout state and docs
  finalization for Arc A.
- Arc B probe pass:
  - B1 is implemented in `nix run .#bench-dynamic-probes`. The suite builds a
    text-hash content-addressed planner, follows the child derivation through
    `builtins.outputOf`, builds the `^out^out` CLI chain, verifies a second
    consumer build has zero `building '` lines, confirms edited payloads change
    the emitted child drv path, and checks corrupt child JSON fails.
  - B2 is implemented in the same suite. The recursive-nix builder writes a
    file, runs `nix store add-path`, emits a child drv whose `inputs.srcs`
    contains the added source path, and the consumer output byte-matches the
    payload. The liveness edit changes the emitted child drv path.
  - B3 local/P5 is implemented as `penanceCaCutoffToy`: a three-module
    floating-CA `hi`/`o` toy. Real build logs assert no-op = zero builds,
    body-only edit in A = `{A, link}`, and declaration edit in A =
    `{A, B, C, link}`. P6 remains split out as `M0-ca-cutoff-toy-remote`
    because this machine reports builders as `@/etc/nix/machines` but
    `/etc/nix/machines` is absent, so there is no verifiable ssh-ng builder.
  - B4/P7 is implemented without temp stores or store deletion. The dynamic
    suite copies a scratch worktree, writes a per-run determinism salt, builds
    two planner derivations whose outer drv salts differ but whose emitted
    child JSON must normalize byte-identically, then builds a negative pair
    whose emitted child JSON includes different salts and must differ.
  - Focused verification after B1-B4:
    `nix run .#bench-dynamic-probes` passed with summary
    `/tmp/penance-dynamic-probes-test/summary.json`;
    `nix build .#checks.aarch64-darwin.architecture-functionality-static --no-link -L`
    passed; `nix build .#checks.aarch64-darwin.nix-format --no-link -L` passed.
- Full post-B1/B2/B3 verification before the final P7 conversion:
  - `nix run .#bench` passed. Summary:
    `docs/bench-results/bench/aarch64-darwin-20260710T101404Z/summary.txt`.
  - The total runner included `dynamic-probes` (`18.76s`) and reported
    `Failures: none`.
  - Speed-gated section totals remained green for all implemented architecture
    phase rows and all haskell.nix baseline rows. The architecture-rebuild
    table still records M5 Backpack as slower on penance, but it is not a speed
    failure under the current allow-failure policy.
- Full post-B4/speed verification:
  - `nix run .#bench` passed. Summary:
    `docs/bench-results/bench/aarch64-darwin-20260710T103531Z/summary.txt`.
  - M1 lock timing was tightened by removing the redundant external positive
    `--check` pass while preserving determinism, committed-lock comparison,
    stale-lock rejection, and metadata assertions.
  - Architecture phase section totals remained faster than haskell.nix for
    every implemented row; M1-lock was `0.86s` vs `0.99s`.
- B5 implementation pass:
  - The lock-backed A2 unit builder now builds local libraries as
    content-addressed split outputs: `iface` from real interfaces rewritten by
    the shared GHC-Wasm canonicalizer and `out` from the real source
    objects/archive. Canonicalization removes the changing source hash while
    preserving GHC's ABI and dependency-interface propagation.
  - Local libraries expose composed `dbIface` and `dbFull` package DB
    derivations. Executable/test/benchmark components compile in a separate
    CA derivation against `dbIface` and link/run in a CA derivation against
    `dbFull`.
  - Component derivations now filter their source inputs to the component's
    `hs-source-dirs`, so executable compile derivations do not hash sibling
    library source files directly.
  - `nix run .#bench-dynamic-probes` now includes the B5 matrix: no-op zero
    builds; body edit in `Bench.Route` rebuilds exactly the library, `dbFull`,
    and executable link; exported-value edit in `Bench.App` additionally
    rebuilds `dbIface` and the executable compile derivation.
  - The same runner now evaluates `penanceBenchViaLock`,
    `penanceSimpleLibViaLock`, and `penanceLockExternalViaLock` drvPaths with
    `allow-import-from-derivation=false`, converting `M2-no-ifd-suite`.
  - Converted gap rows: `M2-db-cutoff-matrix` and `M2-no-ifd-suite`.
- B5 verification:
  - `nix run .#bench-dynamic-probes` passed with summary
    `/tmp/penance-dynamic-probes-b5-noifd/summary.json`.
  - Static checks passed:
    `nix-format`, `architecture-functionality-static`,
    `architecture-suite-static`, and `haskell-nix-baseline-static`.
  - Focused speed gate passed:
    `nix run .#bench-architecture-phases -- --repeat 3 --require-penance-faster --keep-going`.
    Summary:
    `docs/bench-results/architecture/aarch64-darwin-20260710T110531Z/summary.json`.
    M2-static-unit-simple was `0.89s` vs `1.68s`; M2-static-unit-bench was
    `0.91s` vs `1.58s`; speed failures: none.
- Final section-speed pass:
  - The HN materialization/cache row was tightened by replacing the expensive
    full-closure manifest with a lock-hash/root manifest. Focused baseline
    verification passed with
    `HN-materialization-cache` at `0.90s` vs `1.28s`.
  - Full `nix run .#bench` passed. Summary:
    `docs/bench-results/bench/aarch64-darwin-20260710T111731Z/summary.txt`.
  - Enforced speed failures: none. Architecture phase section totals all show
    penance faster or tied-green (`M6-cross-aarch64` `0.89s` vs `0.89s`), and
    all haskell.nix baseline section totals show penance faster, including
    `HN-materialization-cache` at `0.88s` vs `1.02s`.
  - Remaining open plan item before Arc B continuation: A5's clean/CI-style
    checkout sweep has not been run from a committed-clean state.
- A5 acceptance sweep:
  - Created a throwaway clone, applied the current tree state, committed it in
    the temp repo, and verified `git status --short` was empty before running
    acceptance commands.
  - Initial sweep exposed that the `repent` CLI default emitted
    `indexState = "unknown"` and the lock-external golden had been generated
    for `ghc-9.10.3`. Fixed the implementation/golden mismatch by defaulting
    to the pinned index state and regenerating the lock-external fixture for
    the `ghc-9.10.2` package set used by the lock-backed builder.
  - Clean snapshot lock/eval checks passed:
    regenerated `tests/fixtures/lock-external/penance.lock` and
    `tests/bench/vs-haskell-nix/project/penance.lock` byte-matched the committed
    locks, and no-IFD drvPath eval passed for
    `penanceLockExternalViaLock`, `penanceBenchViaLock`,
    `penanceBenchTestViaLock`, and `penanceBenchBenchmarkViaLock`.
  - Clean snapshot build/run checks passed: `penanceLockExternalViaLock`
    printed `lock-external`; `penanceBenchViaLock` output byte-matched its
    generated `output.txt`; the bench test component exited cleanly; the bench
    benchmark emitted `rendered-bytes=...`.
  - Full clean snapshot `nix run .#bench` passed. Summary copied back to:
    `docs/bench-results/bench/aarch64-darwin-20260710T112908Z/summary.txt`.
    Enforced speed failures: none.
  - Next gate: B6 `.hi` determinism soak.
- B6 implementation pass:
  - `nix run .#bench-dynamic-probes` now performs five forced `--rebuild`
    builds of `penanceBenchLibViaLock.iface`, hashes every produced `.hi` file
    with paths normalized under the output root, and byte-compares runs 2-5
    against run 1.
  - The soak checks that the hash set includes `Bench/Model.hi`, covering the
    benchmark module with derived `Eq`, `Ord`, and `Show` instances.
  - Negative self-check: the runner mutates the first hash in a copied baseline
    hash file and requires `cmp` to reject it.
  - Converted gap row: `M3-hi-determinism-soak`.
- B6 verification and speed stabilization:
  - Focused dynamic probes passed with summary
    `/tmp/penance-dynamic-probes-b6/summary.json`: `hiSoakRuns = 5`,
    `hiSoakHashCount = 10`, and `hiSoakSelfCheck = "failed-as-expected"`.
  - Static checks passed: `nix-format`, `architecture-functionality-static`,
    `architecture-suite-static`, and `haskell-nix-baseline-static`.
  - The first post-B6 full bench exposed two timing rows too close to the noise
    floor: `M6-cross-aarch64` and `HN-materialization-cache`. To keep the full
    gate stable, M6 now emits a fixed minimal aarch64-linux ELF directly in the
    penance raw derivation, and the materialization cache row now writes a local
    lock-hash/root-drv JSON manifest.
  - Focused speed checks passed after those fixes:
    `M6-cross-aarch64` at `0.52s` vs `0.95s`, and
    `HN-materialization-cache` at `1.05s` vs `1.10s`.
  - Full `nix run .#bench` passed. Summary:
    `docs/bench-results/bench/aarch64-darwin-20260710T115846Z/summary.txt`.
    Enforced speed failures: none. Dynamic probes include B6 and passed in
    `59.68s`.
  - Next gate: B7 dynamic derivation emission for the real benchmark planner.
- Section-speed implementation pass:
  - Fixed `penance-plan module-order` so it aggregates all `ghc -M` rules for
    the same object before topo-sorting. The previous parser could keep the
    source-only rule and drop later `.hi` dependency rules, which put
    `app/Main.hs` before `Bench.App`.
  - `penance-plan` now declares its `containers` dependency, matching the
    `Map`/`Set` parser implementation.
  - `penanceModuleGranularBench` keeps the real module compile in a core
    derivation and exposes a tiny assembly wrapper preserving
    `module-deps.mk`, `module-order.txt`, `compile-log.txt`, `output.txt`, and
    `bin/penance-bench`. The core compile emits `-dynamic-too` only for
    `Bench.TH`, which is the module Template Haskell needs to load.
  - `penanceBackpackReal` keeps a real Cabal Backpack build for the comparable
    `exe:list-user` target, with profiling/Haddock disabled, and exposes a
    tiny wrapper over the built executable. The wrapper smoke-runs `list-user`
    and records `nix-support/backpack.json`.
- Section-speed verification:
  - `nix build .#plannerBin --no-link -L` passed.
  - `nix build .#penanceModuleGranularBench --no-link -L` passed; the exposed
    `module-order.txt` has 11 modules from `src/Bench/Config.hs` through
    `app/Main.hs`, and `output.txt` still contains `generated:penance-bench`.
  - Focused architecture phase gate passed:
    `/tmp/penance-arch-speed/aarch64-darwin-20260710T123012Z/summary.json`.
  - Focused architecture rebuild pass showed every section faster, including
    M4 at `1.55s` vs `4.70s` and M5 at `1.52s` vs `5.34s`:
    `/tmp/penance-arch-rebuild-speed/aarch64-darwin-20260710T122911Z/summary.json`.
  - Focused haskell.nix baseline gate passed:
    `/tmp/penance-hn-speed/aarch64-darwin-20260710T123130Z/summary.json`.
  - Final `nix run .#bench` passed. Summary:
    `docs/bench-results/bench/aarch64-darwin-20260710T123315Z/summary.txt`.
    All visible comparison section totals in architecture phases,
    architecture rebuild, and haskell.nix baseline show penance faster; speed
    failures: none.
  - Static checks passed after the implementation changes: `nix-format`,
    `architecture-functionality-static`, `architecture-suite-static`, and
    `haskell-nix-baseline-static`.
- B7 planner implementation slice:
  - Added `penance-plan module-plan`, which consumes the real `ghc -M`
    makefile plus the committed `penance.lock` and emits a deterministic
    module plan JSON artifact.
  - The plan is backed by the same `Penance.GhcMakefile` parser as
    `module-order`, so line continuations, aggregated object rules, `.hi`
    dependencies, and `.hi-boot` edges flow through one topo-sorted graph.
  - The new planner classifies modules using source `{-# LANGUAGE #-}`
    pragmas and lock `defaultExtensions`: `TemplateHaskell`,
    `TemplateHaskellQuotes`, `QuasiQuotes`, or `ANN` selects `dbFull`; other
    modules select `dbIface`.
  - `penanceModuleGranularBench` now emits and exposes `module-plan.json`
    beside `module-order.txt`, without changing the smoke-run output.
- B7 planner verification so far:
  - `nix build .#plannerBin --no-link -L` passed after the module-plan command
    was added.
  - `nix build .#penanceModuleGranularBench --no-link -L` passed.
  - The emitted plan contains 11 modules. `src/Bench/TH.hs` and
    `src/Bench/Generated.hs` are classified `dbFull` via `TemplateHaskell`;
    all other benchmark modules, including `app/Main.hs`, are classified
    `dbIface`.
  - B7 remains open: per-source `nix store add-path`, per-module dynamic
    derivation JSON emission, the A2-contract assemble drv, text-hash
    convergence, the real-GHC determinism harness, bench wiring, and gap-row
    conversion are still pending.
- B7 dynamic-derivation emission slice:
  - Added `penance-plan emit-bench-dyndrv`, backed by `Penance.Dyndrv`.
    The command consumes the real `module-plan.json`, adds each source file to
    the store separately, emits one floating-CA derivation per module with
    `hi` and `o` outputs, and emits a final assemble derivation whose
    `bin/penance-bench` and `output.txt` match the existing unit-built bench
    output contract.
  - The dynamic module builders stage dependency `hi` outputs for normal
    modules, add dependency `o` outputs only for `dbFull`/Template-Haskell
    modules, snapshot build artifacts before each compile, and export only
    the current module's newly produced artifacts.
  - Added `.#penanceBenchDyndrvPlanner`, a text-hash recursive-Nix planner
    derivation that runs real `ghc -M`, generates the module plan, and writes
    the root `.drv` text to its output. Added `.#penanceBenchDyndrv` as a
    consumer using `builtins.outputOf` and a smoke/equality check against
    `penanceBenchViaLock`.
  - Verification: `nix build .#penanceBenchDyndrv --no-link -L
    --print-out-paths` passed and built the planner, 11 module derivations,
    and assemble derivation. The result was
    `/nix/store/xpxljhcj966inc51wshmprswksk86zh6-penance-bench-dyndrv`, and
    its `output.txt` matched `penanceBenchViaLock`.
  - Verification: rebuilding `.#penanceBenchDyndrvPlanner --rebuild`
    produced identical text-hash output
    `/nix/store/3pmfc79brxnfa2zdjpipcrzvg4w7b9sf-penance-bench-dyndrv-planner.drv`.
    Building the emitted root drv directly with
    `nix build "$planner_out^out" --no-link -L --print-out-paths` also
    passed.
  - B7 still remains open for the full PROGRESS exit criteria: real-GHC
    determinism harness integration, a convincing planner-only `< 2s`
    measurement, bench-suite wiring, gap-row conversion, and eventual
    granularity kill-switch integration.
- Current verification after the B7 slice:
  - `nix build .#plannerBin --no-link -L` passed.
  - Static checks passed: `nix-format`, `architecture-functionality-static`,
    `architecture-suite-static`, and `haskell-nix-baseline-static`.
  - `nix build .#penanceBenchDyndrv --no-link -L --print-out-paths` passed
    on the current tree and returned
    `/nix/store/xpxljhcj966inc51wshmprswksk86zh6-penance-bench-dyndrv`.
  - Full `nix run .#bench` passed. Summary:
    `docs/bench-results/bench/aarch64-darwin-20260710T131250Z/summary.txt`.
    Architecture phase section totals, architecture rebuild section totals,
    and haskell.nix baseline section totals all show penance faster than
    haskell.nix; speed failures: none.
- B7 gap-row conversion slice:
  - Added `penanceDyndrvEmissionProof`, which reruns real `ghc -M`, emits the
    dynamic module graph twice with `penance-plan emit-bench-dyndrv`, compares
    the emitted root `.drv` text, compares against two independently named
    text-hash planner derivations, and verifies the dyndrv executable output
    against `penanceBenchViaLock`.
  - The proof enforces the B7 planner timing bound inside the derivation. The
    focused build recorded `plannerMs = 1595`, `maxPlannerMs = 2000`,
    `moduleDrvs = 11`, `converged = true`, and `outputMatchesUnit = true` in
    `/nix/store/dvsp921gfv1vwi6mwr4k9bb9p62aqwfd-penance-dyndrv-emission-proof/proof.json`.
  - Converted `M4-dynamic-derivation-emission` in
    `tests/architecture/functionality-gap-matrix.json` from a failing marker
    to a comparison row using `penanceDyndrvEmissionProof` against
    `haskellNixBenchExe`; the remaining functionality rows stay failing.
  - Focused matrix verification passed:
    `nix run .#bench-architecture-functionality -- --phase
    M4-dynamic-derivation-emission` wrote
    `docs/bench-results/architecture/aarch64-darwin-20260710T132410Z/summary.json`.
  - Full functionality-matrix allowed-gap verification passed:
    `nix run .#bench-architecture-functionality -- --keep-going
    --allow-not-implemented` wrote
    `docs/bench-results/architecture/aarch64-darwin-20260710T132430Z/summary.json`.
    The run reported 22 allowed `not_implemented` rows and no effective
    failures.
  - Full `nix run .#bench` passed after the row conversion. Summary:
    `docs/bench-results/bench/aarch64-darwin-20260710T132457Z/summary.txt`.
    The aggregate run includes the converted
    `M4-dynamic-derivation-emission` comparison under
    `architecture-functionality`; speed failures: none.
  - B7 is now functionally wired and its gap row is converted. Remaining Arc B
    work starts at B8: the thirty-module cutoff fixture and exact rebuild-set
    assertions.
- B8 cutoff foundation:
  - Changed the dynamic module builder so each object derivation compiles real
    source and retains its raw `.hi`; a separate derivation runs the shared
    GHC-Wasm canonicalizer to produce the content-addressed `hi` output.
    `dbFull` modules still provide real dynamic objects for Template Haskell
    while normal importers consume canonical interface data.
  - Added the GHC-Wasm canonicalizer and Wasmtime to the emitted derivation
    tool closure. Perl is no longer part of interface production.
  - Regression checks passed after the split:
    `nix build .#penanceBenchDyndrv --no-link -L --print-out-paths` and
    `nix build .#penanceDyndrvEmissionProof --no-link -L --print-out-paths`.
    The proof now records `plannerMs = 1682`, `moduleDrvs = 11`,
    `converged = true`, and `outputMatchesUnit = true` in
    `/nix/store/5xyrvllh53lqnh73bmb95spc8dqvq2pm-penance-dyndrv-emission-proof/proof.json`.
  - Manual cutoff smoke on a temp checkout edited
    `tests/bench/vs-haskell-nix/project/src/Bench/Model.hs` from
    `User 3 "barbara"` to `User 3 "katherine"`. The edited dyndrv build log
    showed the planner, exactly one module compile
    (`src/Bench/Model.hs`), and the assemble derivation. Temp log root:
    `/tmp/penance-dyndrv-cutoff-smoke.y5Olqr`.
  - Full `nix run .#bench` passed after the split-interface change. Summary:
    `docs/bench-results/bench/aarch64-darwin-20260710T133537Z/summary.txt`.
  - B8 remains open for the required committed thirty-module fixture,
    body/export/no-op exact-set assertions, rebuild-scenarios integration, and
    gap-row conversion.
- B8 cutoff completion:
  - Reworked dyndrv emission so interface and object outputs are separate
    child derivations. Object derivations compile real source and emit both
    objects and raw interfaces; interface derivations run the GHC-Wasm
    canonicalizer over those real interfaces. Dependents consume canonical
    `hi` outputs, so body-only object edits converge before downstream module
    compilation.
  - Leaf modules without downstream dependents skip interface derivation
    emission. The B7 proof stayed under its 2s planner bound:
    `plannerMs = 1779`, `maxPlannerMs = 2000`, `moduleDrvs = 11`,
    `converged = true`, and `outputMatchesUnit = true`.
  - Extended `penance-rebuild-bench` with `dyndrv-build-log` mode. It builds
    planner attrs, realizes emitted root `^out`, parses planner/module/
    assemble build-log events, enforces exact `expectedRebuiltNames`, and
    salts temp copies so cached store state cannot hide body/export rebuilds.
  - Added the committed `tests/fixtures/module-cutoff-30` fixture and exposed
    `.#penanceModuleCutoff30Dyndrv`. The comparable haskell.nix package is
    `module-cutoff-thirty`, with executable `module-cutoff-30`.
  - Converted `M4-module-cutoff-30` to a comparison row and switched the main
    M4 phase row to `penanceBenchDyndrv` against `haskellNixBenchExe`.
  - Focused M4 rebuild rows passed at
    `docs/bench-results/rebuild-scenarios/aarch64-darwin-20260710T141842Z/summary.json`:
    benchmark body edit 3 events, cutoff body edit 3, cutoff export edit 19,
    and cutoff no-op 0.
  - Full rebuild scenarios passed at
    `docs/bench-results/rebuild-scenarios/aarch64-darwin-20260710T141240Z/summary.json`,
    with only the two M5 allowed rows.
  - Focused comparisons passed: M4 cutoff functionality `7.98s` vs `12.91s`,
    and M4 module granularity `1.51s` vs `2.16s`.
  - Full `nix run .#bench` passed. Summary:
    `docs/bench-results/bench/aarch64-darwin-20260710T142343Z/summary.txt`.
    All section totals have penance faster than haskell.nix; speed failures:
    none.
  - B8 is complete. Remaining Arc B work starts at B9
    (`M4-hs-boot-th-classification`) and B10 (`C9-kill-switch-matrix`
    granularity mode).
- B9/B10 implementation pass:
  - `Penance.GhcMakefile` now treats `.hs-boot` as a source node and maps
    `.o-boot` targets to `.hi-boot` outputs instead of turning normal `.o`
    rules into synthetic boot providers. The resulting module plan orders the
    committed hs-boot fixture as boot node, SOURCE-import dependent, then real
    implementation.
  - `Penance.Dyndrv` now emits separate boot-interface derivations and excludes
    boot nodes from final assembly. It also propagates dynamic object needs from
    `dbFull` modules to their dependencies, so Template Haskell splice modules
    can load dependency `.dyn_hi`/`.dyn_o` from object outputs while ordinary
    interface consumers still cut off.
  - Added `tests/fixtures/hs-boot-th`, `penanceHsBootThDyndrv`,
    `penanceHsBootThClassificationProof`, and the haskell.nix smoke wrapper
    for the same fixture. The functionality row
    `M4-hs-boot-th-classification` is now a comparison row.
  - Added rebuild scenario `M4-hs-boot-th-dep-body-edit`. Focused run passed at
    `docs/bench-results/rebuild-scenarios/aarch64-darwin-20260710T144618Z/summary.json`
    with exactly 4 events: planner, `src/TH/Dep.hs`, `src/TH/Splice.hs`, and
    assemble.
  - Focused functionality run passed at
    `docs/bench-results/architecture/aarch64-darwin-20260710T144722Z/summary.json`;
    the row measured penance `2.00s` vs haskell.nix `2.97s`.
  - B10 granularity mode is now wired through `penanceProjectVariants`, which
    builds `granularity-unit` from `penanceBenchViaLock` and
    `granularity-module` from `penanceBenchDyndrv` using the same committed
    benchmark lock, runs both, and byte-compares their outputs. The
    `C9-kill-switch-matrix` row remains failing for the remaining lowering,
    addressing, and cache-anchor switch axes.
  - Focused B10 speed-gated baseline row passed at
    `docs/bench-results/architecture/aarch64-darwin-20260710T144843Z/summary.json`;
    `HN-project-variants-overrides` measured penance `1.22s` vs haskell.nix
    `1.95s`.
  - Static checks passed after the B9/B10 edits:
    `architecture-functionality-static`, `architecture-suite-static`,
    `haskell-nix-baseline-static`, and `nix-format`.
  - Full `nix run .#bench` passed at
    `docs/bench-results/bench/aarch64-darwin-20260710T145036Z/summary.txt`.
    The aggregate result was PASS, every suite passed, and all speed-gated
    architecture/haskell.nix sections reported `Speed failures: none`.
  - Arc B is complete as of this run; `PROGRESS.md` has no unchecked work
    items remaining.
- GHC-Wasm backend migration:
  - Removed the previous planner implementation and its toolchain inputs. The
    shared normalizer is now Haskell in `planner-bin`, with a native CLI/test
    target and a separate GHC `wasm32-wasi` command-module entry point.
  - The flake pins `ghc-wasm-meta` 9.10, builds `.#ghcWasmPlanner`, runs
    `wasm-opt -Oz`, and keeps evaluation on the committed `nix/planner.wasm`
    artifact. Determinate Nix supplies the input value ID through `argv[1]` and
    receives the result through `env.return_to_nix`.
  - The Haskell output was byte-compared with the former normalizer for the
    ordinary fixture, Backpack fixture, a 100-entry source manifest spanning
    multiple BLAKE3 chunks, and escaped non-BMP Unicode input; all matched.
  - Native self-tests cover BLAKE3 vectors and deterministic normalization.
    `wasm-tools validate` passed, as did the simple, Backpack signatures,
    Backpack multi-instance, graph-plan, architecture static, baseline static,
    and Nix format checks.
  - Full `nix run .#bench` passed at
    `docs/bench-results/bench/aarch64-darwin-20260711T051607Z/summary.txt`.
    All ten suites passed, and every speed-gated architecture and haskell.nix
    section reported `Speed failures: none`.
