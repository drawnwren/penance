# PROGRESS — working MVP (Arc A), then module granularity (Arc B)

## Where the project actually stands

The benchmark/parity layer is real and green, and penance now has a usable
unit-granularity MVP for committed schema-1 locks. Concretely, in the current
tree:

- `penance-lock` (planner-bin/src/LockMain.hs) locks local packages and solved
  external units under schema `penance/strata-lock/1`, including exact
  StateVar sdist pins and `ghc-boot` markers for compiler-bundled packages.
- `penanceLib.penanceProject` (nix/lib.nix) lowers committed locks to real
  component derivations without IFD at unit granularity. Ordinary local
  libraries build split content-addressed `iface`/`out` outputs, compose
  `dbIface`/`dbFull` package DBs, and executable/test/benchmark components
  compile against `dbIface` before linking against `dbFull`.
- The main bench/simple/lock-external lanes consume those lock-backed
  derivations. The remaining hand-rolled lanes are intentional architecture
  targets: the module-granular seed, Backpack via cabal2nix, cross probes,
  and cache/warp harnesses.

**MVP definition (every clause mechanically checkable):** a user can point
`penanceProject` at a Cabal project with a committed `strata.lock` and get
(1) real component derivations that compile with GHC, external deps pinned by
the lock, evaluated without IFD; (2) a dev shell derived from the lock;
(3) `penance-lock --check` freshness guarding all of it; (4) the benchmark
matrices' penance attrs flowing through this lock path instead of hand-rolled
helpers; (5) `nix run .#bench` green throughout. All at `granularity = unit`.
Module granularity (Arc B) is the post-MVP differentiator.

## Hard sequencing gates

- Arc A items run in order A1 → A5; A2 depends on A1's lock schema.
- Arc B probes (B1–B4) are independent of Arc A and may be done at any point,
  but **B5–B10 must not begin until B1–B4 pass AND A2 has landed** — the CA
  split (B5) is implemented inside the A2 unit builder, and the C4 planner
  (B7) must emit an assemble drv matching A2's output contract.
- If a probe or mechanism fails because the pinned Nix cannot do it, record
  the exact error text and `nix --version` in the matching gap row's
  `failure` field, commit, and STOP that arc. Never substitute a stand-in
  mechanism to make a row pass.

## Scope guards (do not do these)

- Do NOT apply module granularity to Hackage or Backpack units (invariant 5
  in docs/NEW_ARCHITECTURE.MD). Backpack (M5) and cross (M6) gap rows are out
  of scope for both arcs.
- Do NOT widen any allow flag or weaken any static check to make a suite pass.
- Do NOT let `nix run .#bench` go red or become non-total; run it after each
  completed item. Do NOT break `devShells.default`.
- Component-mode lowering must be **pure Nix from the committed lock** (
  `builtins.fromJSON`), requiring neither IFD nor recursive-nix. The
  recursive-nix planner derivation is Arc B's mechanism for module mode only.

## Standing rules

- Failing row first: each item adds its gap-matrix row(s) before implementing,
  converts them only when the real mechanism is exercised by a check or suite
  that `nix run .#bench` runs, and updates the jq static-check `$expected`
  row-ID lists in flake.nix in the same commit.
- Banned words in matrix prose describing implemented mechanisms: proxy,
  placeholder, planned, hardening, surface.
- Every positive test needs its negative twin (a corrupted lock must fail; a
  harness that cannot detect a rebuild proves nothing).
- Compared artifacts must be equivalent (a manifest is not a library).
- Both sides of a comparison row share one proof/check script — the flake now
  has `runBenchChecks` and `stateVarProofScript` as the pattern; new
  comparison rows follow it rather than duplicating bodies per side.

---

# Arc A — MVP at unit granularity

## A1 — Solve and lock external dependencies

Extend `penance-lock` so `strata.lock` records **solved external units**, not
just local components with ranges. Schema bump to `penance/strata-lock/1`.
Each external unit needs at minimum: name, exact version, and a content hash
for its Hackage sdist (so A2 can `fetchurl` it without trust); mark
GHC-bundled boot libraries (base, template-haskell, containers, …) as
`"source": "ghc-boot"` instead of pinning sdists for them.

Mechanism latitude: running the pinned `cabal` at lock time to produce
`plan.json` and converting it is acceptable (commit-time, outside Nix), as is
using cabal-install's solver as a library. Hard requirements regardless of
mechanism: byte-deterministic output given the same inputs and `--index-state`
(sorted maps, no timestamps), and `--check` must fail when the lock is stale.

Add a fixture that actually exercises non-boot resolution:
`tests/fixtures/lock-external/` — a one-module executable depending on
`StateVar` — with its golden `strata.lock` committed.

Test:

```sh
# determinism: generate the lock twice, byte-identical
nix run .#penance-lock -- --project tests/fixtures/lock-external --out /tmp/l1
nix run .#penance-lock -- --project tests/fixtures/lock-external --out /tmp/l2
cmp /tmp/l1 /tmp/l2
# freshness (negative): add a dependency to the fixture .cabal in a scratch
# copy; --check against the committed lock must exit nonzero.
# content: jq asserts the lock has a StateVar unit with an exact version and
# a non-empty sdist hash, and base marked ghc-boot.
# bench fixture: regenerate tests/bench/vs-haskell-nix/project/strata.lock
# under the new schema; its existing freshness row must stay green.
```

Pass criteria:

- [x] Deterministic bytes; `--check` catches staleness (negative test).
- [x] `lock-external` golden lock committed with solved StateVar + sdist hash.
- [x] Bench-fixture lock migrated; M1 lock row still green.
- [x] Gap row(s) added-then-converted; jq lists in lockstep; bench green.

## A2 — Real unit builder behind `penanceProject`

Make `penanceProject { mode = "component"; }` return **buildable** component
derivations lowered purely in Nix from the committed lock:

- Local library units: compile with the locked GHC, install the hi tree, a
  static archive, and a registered package DB conf (the output contract
  `penanceSimpleLibReal` already demonstrates). Local executables/tests/
  benchmarks: link against sibling unit DBs, install `bin/`.
- External non-boot units (StateVar in the A1 fixture): build from the
  lock-pinned sdist via `fetchurl` + the recorded hash. Boot units resolve to
  the compiler's global DB. The built version MUST be asserted against the
  lock at build time (the StateVar proofs show the pattern).
- Evaluation must succeed with IFD disallowed — this item converts the
  `M2-no-ifd-suite` gap row. Component mode must not require recursive-nix.
- Expose the bench fixture's exe through the flake (suggested attr
  `penanceBenchViaLock`) plus the whole `lock-external` fixture project.

Test:

```sh
nix build .#penanceBenchViaLock --no-link -L
# equivalence: its run output must byte-match penanceBenchReal's output.txt
# no-IFD: nix eval of the drvPath with allow-import-from-derivation false
# negative: in a scratch copy of the lock, change StateVar's version (or its
# sdist hash) — the build must FAIL, proving the lock is load-bearing.
# component coverage: test: and bench: components of the bench fixture build
# and run through the same path.
```

Pass criteria:

- [x] All bench-fixture components + lock-external exe build via the lock.
- [x] Run-output equivalence with the hand-rolled lane.
- [x] No-IFD eval green; `M2-no-ifd-suite` converted.
- [x] Corrupted-lock negative test fails the build.
- [x] Gap rows converted; jq lists in lockstep; bench green.

## A3 — Point the matrices at the lock path

Replace hand-encoded dependency knowledge with lock-derived data:

- The M2 phase-matrix rows' penance attrs move to A2 outputs
  (`penanceBenchViaLock` and the lock-built simple-lib equivalent), with row
  notes updated to describe the real mechanism. The comparison must stay
  green under `--repeat 3 --require-penance-faster`.
- `benchGhcPackageFlags` in flake.nix (hand-encoded `-package` list, noted in
  the last cleanup pass) is deleted; anything still compiling the bench
  fixture outside the unit builder (the module-granular bench stays as Arc
  B's seed) derives its package list from `builtins.fromJSON` on the
  committed lock instead.
- Retire `mkPenanceBenchExecutable`'s non-module branch and
  `penanceSimpleLibReal`'s hand-rolled body once the matrix rows point at A2
  outputs — delete, don't keep dead lanes. (`penanceModuleGranularBench` and
  the perl topo-sort stay: they seed B7.)

Pass criteria:

- [x] No hand-encoded external-dep flags remain for lock-covered fixtures
      (grep `-package containers` in flake.nix returns only lock-derived or
      Arc-B-seed sites, with a comment saying which).
- [x] Phase matrix M2 rows compare lock-built artifacts; speed gate green.
- [x] Full `nix run .#bench` green.

## A4 — Dev shell from the lock

`penanceProject` gains a real `devShells` output: the composed
external-package DB for the selected local packages, derived from the lock's
solved externals (boot + non-boot). `devShells.default` in flake.nix consumes
it; `penanceBenchShellPackageNames` (the hand list single-sourced in the last
cleanup) is deleted in favor of the lock-derived list, and the shell proof's
manifest and `ghc-pkg list` assertions read the same derived list.

Test:

```sh
nix develop -c cabal build all   # bench fixture: zero external builds
nix build .#penanceBenchShell --no-link -L   # sandboxed proof still passes
# negative: add a dependency to the fixture .cabal without regenerating the
# lock — penance-lock --check (already wired into the M1 row) must fail,
# proving the shell cannot silently drift from the lock.
```

Pass criteria:

- [x] Shell proof green with lock-derived package list; hand list deleted.
- [x] `nix develop` still compiles only local packages.
- [x] Bench green end to end.

## A5 — MVP acceptance sweep

- Build the `lock-external` project end to end through `penanceProject`
  (lock → eval → build → run), plus the bench fixture with all components,
  from one fresh clone state (`git stash -u`-clean worktree or CI-style
  checkout) to prove no reliance on uncommitted state.
- Run the full `nix run .#bench`; record the summary path in this file.
- Update docs/ARCHITECTURE.md's current-state section: penanceProject is now
  the lock-driven build path at unit granularity; list what is still
  hand-rolled (module-granular seed, Backpack via cabal2nix, cross lanes).

Pass criteria:

- [x] Clean-tree end-to-end build of both projects via the lock path.
- [x] Bench summary recorded here; docs updated to match reality. Latest full
      clean-snapshot summary:
      `docs/bench-results/bench/aarch64-darwin-20260710T112908Z/summary.txt`.

---

# Arc B — module-granular dynamic derivations

(Gated: B5–B10 need B1–B4 green AND A2 landed. B1–B4 may be done anytime.)

## B1 — Probes P2+P3: text-hash planner consumed via `builtins.outputOf`

Closes `M0-planner-text-hash-outputof`. Build a probe under `tests/probes/`:
a planner derivation with `outputHashMode = "text"`, `outputHashAlgo =
"sha256"`, `__contentAddressed = true`, `requiredSystemFeatures =
["recursive-nix"]`, whose builder constructs one child derivation in JSON
derivation format, registers it with `nix derivation add`, and writes the
identical drv text to `$out` (text-hash convergence: the planner's output IS
the child `.drv`). Expose `penanceProbePlanner` and a consumer that reads the
child's output through `builtins.outputOf`.

Preflight (fix nix.conf if it fails; do not work around):

```sh
nix config show experimental-features  # needs ca-derivations dynamic-derivations recursive-nix
nix config show system-features        # needs recursive-nix
```

Test:

```sh
nix build .#penanceProbePlannerConsumer --no-link -L          # P2 chain
plan_drv=$(nix eval --raw .#penanceProbePlanner.drvPath)
nix build "${plan_drv}^out^out" --no-link -L                  # P3 CLI chain
# no-op: a second consumer build must emit no "building '" lines
# liveness (negative): edit the probe's input file → the emitted child drv
# path must CHANGE (proves emission happens at build time, not committed)
```

The no-op and liveness assertions need sequencing outside one derivation:
wire them into a runner that `nix run .#bench` executes and fails on.

- [x] Preflight, chain, no-op, liveness all green; wired into bench.
- [x] Forced failure (corrupt child JSON in a scratch copy) fails the suite.
- [x] Gap row converted; jq lists in lockstep.

## B2 — Probe P4: `nix store add-path` inside a recursive-nix builder

Closes `M0-recursive-nix-add-path`. Inside the recursive-nix sandbox, run
`nix store add-path` on a file the planner writes; emit a child drv whose
`inputSrcs` includes the added path and whose builder copies the file's
content to its output.

- [x] Consumer output byte-equals the add-path'd content.
- [x] Negative: change the content → output changes, exactly one new child drv.
- [x] Wired into bench; gap row converted.

## B3 — Probes P5+P6: three-module CA `hi`/`o` cutoff toy

Closes `M0-ca-cutoff-toy` (split the row if P6 is blocked). Three "modules"
A → B → C compiled by a fake deterministic compiler script (interface derived
from declarations only, object from the whole file); each module a derivation
with floating CA outputs `hi` and `o`; B depends on A's `hi`, C on B's `hi`;
a link step on all `o`.

Assert with real builds and build-log counting, NOT `--dry-run` drv-set
diffs — with CA cutoff the drv set is identical; what changes is which builds
run:

- comment-only edit in A ⇒ exactly {A, link} rebuild; B, C cut off
- declaration edit in A ⇒ B rebuilds (mandatory negative control)
- no-op ⇒ zero rebuilds

P6 (same toy via a real ssh-ng remote builder): if no remote builder exists
in this environment, split into `...-local` (converted) and `...-remote`
(failing, with the missing capability named in `failure`), jq lists updated
in the same commit. No localhost fakes unless the daemon genuinely uses the
ssh-ng store protocol — and say so in the notes if it does.

- [x] All three edit classes assert correctly; wired into bench; row(s)
      converted/split.

## B4 — Probe P7: planner determinism from clean stores

Closes `M0-planner-determinism`. Run the B1 planner twice such that the
second run cannot reuse the first's emitted drvs (fresh `--store` chroot if
recursive-nix tolerates it, else `nix store delete` + `--rebuild`; record the
mechanism in the row notes). Normalize (`nix derivation show`, sorted keys)
and byte-compare the emitted drv set.

- [x] Two independently salted planner runs byte-identical.
- [x] Negative: emitted JSON salt injection in a scratch copy is detected.
- [x] Wired into bench; gap row converted.

## B5 — CA `iface`/`out` split and `dbIface`/`dbFull` in the A2 unit builder

Closes `M2-db-cutoff-matrix`. Give the **A2 unit builder** (not any ad-hoc
helper) split floating-CA outputs per the spec — `iface` (hi tree + conf) and
`out` (objects/archive) — plus composed `dbIface`/`dbFull` DB derivations.
Downstream compile steps depend only on `dbIface`; link steps on `dbFull`.
Use the dev-flavor interface-pragma-omission GHC flags from
docs/NEW_ARCHITECTURE.MD's appendix so `.hi` is a function of the interface.

Rebuild matrix over three edit classes (build-log counting, as in B3), on the
lock-built simple-lib + consumer:

- body-only edit ⇒ lib `out` changes, `iface` identical ⇒ consumer compile
  CUT OFF, only its link reruns
- export/type edit ⇒ consumer compile reruns (negative control)
- no-op ⇒ zero rebuilds

- [x] Both directions assert; results recorded as suite artifacts; row
      converted; focused bench green. Implementation note: raw GHC `.hi`
      files still include a changing `src_hash` under the dev pragma flags, so
      the A2 builder compiles `iface` from body-erased ABI stubs and `out` from
      the real source; the dynamic-probes B5 matrix proves the resulting
      `dbIface`/`dbFull` cutoff behavior.

## B6 — `.hi` determinism soak

Closes `M3-hi-determinism-soak`. ≥5 forced rebuilds of the B5 library
(`--rebuild` or scratch stores); sha256 every `.hi`; all runs identical.
Include a module with typeclass/deriving code. Harness self-check: a
corrupted hash in a scratch copy must fail the comparison.

- [x] 5/5 identical; self-check green; wired into bench; row converted.

## B7 — `strata-plan`: real planner with dynamic derivation emission

Closes `M4-dynamic-derivation-emission`. Implement the C4 planner as a
planner-bin executable (suggested `penance-plan`), pinned into a store path,
run inside a planner derivation shaped like B1's probe but on real GHC and
the bench fixture:

1. `ghc -M -dep-suffix '' -include-pkg-deps` against `dbIface` → module DAG
   (the perl topo-sort in `penanceModuleGranularBench` is the logic to port).
2. TH classification from `{-# LANGUAGE #-}` pragmas + the lock's
   `defaultExtensions` (conservative: TemplateHaskell, QuasiQuotes, ANN ⇒
   that module's drv depends on `dbFull`; others on `dbIface`).
3. `nix store add-path` per source file (one edit invalidates one drv).
4. Per module in topo order: emit JSON drv (outputs `hi`+`o` floating CA;
   inputSrcs = its source; inputDrvs = sibling drvs requesting `hi`, plus
   `dbIface`/`dbFull`, toolchain) → `nix derivation add`.
5. Emit an assemble drv whose outputs match the **A2 unit builder's
   contract** exactly, and write its text to `$out` (text-hash convergence).

Determinism is a hard requirement: sorted maps, canonical JSON, no clocks/
hostnames/env leakage. Expose as `penanceBenchDyndrv` behind the
`granularity` kill switch; the existing module-granular attr and phase row
stay untouched until B8 flips them.

- [x] Dyndrv exe output equals the unit-built exe output.
- [x] Emission + text-hash convergence; B4's determinism harness green on
      real GHC; planner < 2 s on this box.
- [x] Wired into bench; gap row converted.

## B8 — Thirty-module cutoff end to end

Closes `M4-module-cutoff-30`; bounds `M4-bench-body-edit-rebuild-count`. Add
`tests/fixtures/module-cutoff-30/` (30 modules, mixed fan-out with at least
one diamond) built through B7.

- body-only edit in one mid-graph module ⇒ ONLY {planner, edited module,
  assemble} build — assert from real build logs; the rebuild-scenarios
  harness needs a build-log counting mode for dyndrv rows, because module
  drvs do not exist until the planner runs and `--dry-run` drv diffing
  cannot see them
- export edit ⇒ its true dependents recompile, unrelated modules do not
  (assert both directions)
- no-op ⇒ planner not rebuilt, zero compiles

Then bound the rebuild scenario for the dyndrv attr at the measured minimal
set (expected 3: planner + module + assemble; document each member in row
notes), strictly below the recorded unit-level count, status `comparison`;
update the M4 phase row to compare the dyndrv attr vs `haskellNixBenchExe`
with an accurate mechanism note.

- [x] Exact-set assertion both directions; scenario bounded; matrices + jq
      consistent; bench green.

## B9 — hs-boot ordering and TH classification fixtures

Closes `M4-hs-boot-th-classification`. Two fixtures through the planner:

- hs-boot cycle: either `-boot` compiled first and the build succeeds, or a
  clean logged demotion to `granularity = unit` — silence or wrong-order
  failure does not pass.
- TH: splice-using module vs plain siblings. Assert at drv level (`nix
  derivation show`: TH module depends on `dbFull`, siblings on `dbIface`)
  AND behaviorally (dep body-only change ⇒ TH module rebuilds, siblings do
  not).

- [x] Both fixtures assert; wired into bench; gap row converted.

## B10 — Kill switch: `granularity = unit` stays green

Partial progress on `C9-kill-switch-matrix` (granularity axis; narrow the
row's notes to the remaining axes, keep it failing). Same lock, both modes,
run outputs byte-equal, both wired into bench.

- [x] Both modes green from one lock; outputs equivalent; full
      `nix run .#bench` green — record the summary path here. This is the
      exit criterion for Arc B.

---

## Notes from the 2026-07-10 cleanup pass (conventions to preserve)

- **Pins are single-sourced** in the flake's outer `let`: `stackageResolver`
  and `hackageStateVarVersion`. The snapshot fixture path is derived from the
  resolver, and `nix run .#bench` exports both as env defaults (env overrides
  still win). Bump procedure: edit the two constants, add the new fixture
  file `tests/fixtures/stackage/<resolver>-StateVar.yaml`, and recompute
  `stackageStateVarSnapshotHash`.
- **`stackageStateVarSnapshotHash` is load-bearing — do not remove it.** The
  eval-time version parse follows an edited fixture, so without the frozen
  hash an edited snapshot would silently resolve to whatever it claims; the
  hash is what makes unauthorized fixture edits fail (parity item 9's
  negative test).
- **Shared comparison-row scripts**: `runBenchChecks` and
  `stateVarProofScript` exist so both sides of a row run identical checks;
  extend them rather than re-inlining per side.
- **Ignored-artifact lists exist in two places**: `skipCopyPath`
  (RebuildBenchMain.hs, basename-matched) and `ignoredSourceName`
  (nix/lib.nix). When adding a new build-artifact directory name, update
  both — or better, unify them when touching either for other reasons.
- The allow-failure accounting (`rowIsAllowedFailure` etc.) is intentionally
  duplicated between ArchitectureBenchMain and RebuildBenchMain; it gets
  restructured when the per-row matrix fields land (below), not before.

## Carried-over notes (not blocking)

- Express `--allow-haskell-nix-failures` and `--require-penance-faster` as
  per-row matrix fields (`allowRebuildFailure`, `speedGate`).
- Make the Hackage/Stackage proof mechanism package-parametric when
  implementing `CORPUS-hackage-stackage` (A1/A2 land most of the machinery
  this needs: solved locks and sdist-pinned external builds).

## Archive

Previous round (haskell.nix parity, items 1–15) verified complete 2026-07-05:
all 10 baseline rows real comparisons, `nix run .#bench` green across all
nine suites (docs/bench-results/bench/aarch64-darwin-20260706T041931Z). A
cleanup pass on 2026-07-10 deduplicated flake helpers and runner code with no
behavior change (cross-lane drv verified byte-identical). See git history of
this file for details.
