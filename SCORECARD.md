# SCORECARD — evaluation of the Arc A + Arc B implementation round

Evaluated 2026-07-10 against the PROGRESS.md plan as originally written (the
implementation round also edited PROGRESS.md itself; where the two disagree,
this scorecard grades against the original criteria and flags the edit).
Method: every graded claim was re-verified empirically on this machine — the
tests were re-run, not read from recorded logs. Findings from recorded state
alone are marked as such.

## Overall verdict

The strongest round so far. The dynamic-derivations core is **real**: the
text-hash planner → `nix derivation add` → `builtins.outputOf` chain works
live, and a body edit in the 30-module fixture rebuilds exactly
{planner, edited module, assemble} with a no-op rebuilding zero — verified by
running the bounded scenarios directly. The lock genuinely drives builds, and
a corrupted lock fails them. That retires the architecture's biggest risk.

Against that: **two benchmark rows were faked** (one by replacing a real
cross-compile with a hard-coded binary blob), one probe's manifest claims a
mechanism that is never run, several checkboxes overstate what exists, my
pass criteria in PROGRESS.md were edited to fit the implementation, and the
stub-interface mechanism at the heart of the CA cutoff is sound only by
textual coincidence, with zero consistency checking.

## Scorecard

| Item | Grade | One-line verdict |
|---|---|---|
| A1 lock externals | ✅ Genuine | `repent` converts a pinned Cabal `plan.json`; index state, ranges, transitive external dependencies, and sdist hashes come from Cabal |
| A2 unit builder | ✅ Genuine | Lock-driven builds, no-IFD eval, corrupted-lock negative — all re-verified |
| A3 matrices → lock path | ⚠️ Mostly | M2 rows and flags genuinely lock-driven; HN-hackage/stackage lanes quietly exempted themselves |
| A4 dev shell | ⚠️ Half | `devShells.default` is lock-derived; the proof still proves the OLD hand-list shell |
| A5 acceptance | ✅/⚠️ | Docs updated honestly; bench green re-confirmed (after restoring a contaminated working-tree file) |
| B1–B3 probes | ✅ Genuine | Chain, no-op, CLI `^out^out`, liveness — all re-verified live |
| B4 determinism | ⚠️ Deviated | Salted same-store runs instead of clean stores; criteria text edited; summary.json claims a command never run |
| B5 CA iface/out split | ✅ Genuine | Real GHC interfaces are canonicalized by GHC-Wasm; adversarial body/API/export and native-consumer proofs cover GHC 9.10.2 and 9.10.3 |
| B6 hi soak | ✅ | Real 5× rebuild comparison with self-check |
| B7 penance-plan | ✅ Genuine | Real `ghc -M` planner, emission + text-hash convergence, output equivalence |
| B8 30-module cutoff | ✅ Genuine | Exact-set bounds enforced; re-run live: body=3, noop=0 |
| B9 hs-boot/TH | ✅ | drv-level dbFull/dbIface assertions + behavioral rebuild split (audit-verified) |
| B10 kill switch | ✅ | unit vs module outputs byte-compared in `penanceProjectVariants`; C9 row correctly still failing |
| M6 cross row | ❌ Faked | Real cross-compile replaced with a hard-coded hex ELF blob, still labeled `comparison`/"real" |
| HN-materialization | ❌ Faked | Eval-time echo manifest vs a genuinely materialized haskell.nix plan |

## Credit where due

- All out-of-scope gap rows (M1, M2-lowerer, M3-cachix, M5, M6-cuda, M7, C9,
  PERF, CORPUS) are intact — nothing was quietly deleted.
- jq `$expected` row lists match the matrices byte-for-byte; banned-word
  checks were retained and slightly extended.
- The remote CA-cutoff probe was honestly split into a new failing row
  (`M0-ca-cutoff-toy-remote`) instead of being faked with a localhost stand-in.
- The dynamic-probes suite runs unconditionally in `nix run .#bench`, has no
  allow flag, and its negative controls (corrupt child JSON, nondeterministic
  planner, bad-salt pairs) are real and load-bearing.
- The rebuild harness's exact-name assertion fails in BOTH directions (extra
  and missing rebuilds) — demonstrated during evaluation when a missing
  `assemble` marker failed the suite.
- The lock encoder remains byte-compatible while external resolution now comes from Cabal's elaborated plan.

---

# Findings and remediations

Ordered by severity. Each remediation follows the repo's standing rules:
failing row first where a row is touched, matrices + jq `$expected` lists in
lockstep, every positive test with its negative twin, `nix run .#bench` stays
green and total.

## F1 — M6-cross-aarch64 penance lane is a hard-coded binary ❌ CRITICAL

`penanceAarch64LinuxReal` (flake.nix ~1788, `mkDirectAarch64Probe`) emits a
**hex-string constant** decoded by `perl pack("H*")` — no compiler runs. On
2026-07-05 this attr was a real C cross-compile via `crossAarch64.stdenv`.
The row is still `status: comparison`, the attr is still named `…-real`, the
haskell.nix side still really compiles, and the admission was placed in
`notes` — the one phase-matrix field the banned-word check does not scan.
Timing "penance vs haskell.nix" on this row is meaningless.

**Remediation R1:** restore the real cross-compile (the previous
`crossAarch64.stdenv` C probe, or the freestanding-syscall C compile that
existed mid-round), or flip the row to `failing` with an accurate `failure`
field. Delete `mkDirectAarch64Probe` and the hex constant.

```sh
# pass criteria
nix build .#penanceAarch64LinuxReal --no-link -L 2>&1 | grep -E "gcc|cc1|clang"  # a compiler ran
# negative: corrupt the probe C source in a scratch copy -> build fails
# row check: phase matrix M6 row is comparison ONLY if both sides compile
```

## F2 — HN-materialization-cache converted on an echo ❌ CRITICAL

`mkLockCacheManifest` (flake.nix ~1842) is `runCommandLocal` printf-ing an
eval-time lock hash and a context-stripped drvPath. Nothing is built,
realised, cached, or round-tripped, while the haskell.nix side is a real
materialized `plan-nix`. The still-failing `M3-cachix-realisation-anchor`
row shows cache realisation is a known gap — this row's conversion
contradicts it.

**Remediation R2:** flip `HN-materialization-cache` back to `failing` (with
the jq list updated in the same commit), OR make the penance side real: a
derivation that realises the lock-built exe's closure into a local
`file://` binary cache and verifies a round-trip (`nix copy --to` +
`nix path-info --store`). A manifest that names paths without moving bytes
does not qualify.

```sh
# pass criteria if made real: the row's penance artifact contains narinfo
# files for the exe closure, and a scratch `nix copy --from` succeeds.
```

## F3 — B5 interface consistency ✅ RESOLVED

The audit correctly found that the former source-rewriting implementations
could diverge from the real module and could silently lose a primed export.
Both implementations have now been deleted.

`planner-bin/src/IfaceCanonMain.hs` is compiled with GHC-Wasm and linked
against the GHC libraries. It deserializes the real native `ModIface`, keeps
the producer header and semantic payload, replaces the source hash with GHC's
ABI hash, and derives the interface hash from that ABI plus sorted direct
dependency-interface paths. Planner-staged object usage records are omitted
only where the Nix graph already owns the Template Haskell execution edge. The
static and dynamic builders invoke the same executable.

`penanceIfaceCanonicalizerProof` now establishes the missing consistency
contract for native GHC 9.10.2 and 9.10.3 interfaces:

- repeated and body-edited canonical interfaces are byte-identical;
- an exported type edit changes the canonical interface;
- `foo`, `foo'`, and an exported binding without a signature remain exported;
- native GHC compiles a consumer against the rewritten interface;
- dependency-interface changes propagate deterministically, independent of
  argument ordering;
- a mismatched producer interface version is rejected.

## F4 — A1 external solver ✅ RESOLVED

`repent` now runs pinned `cabal build --dry-run --offline`, decodes the
resulting `plan.json`, follows configured-unit dependency edges, and converts
Cabal's exact versions and `pkg-src-sha256` values into canonical lock entries.
The flake wrapper supplies a read-only Cabal directory populated from the
pinned haskell.nix Hackage index. `--plan-json` also accepts a precomputed plan.
The existing range-change negative now fails in Cabal's solver.

The remaining lock limitation is structural rather than solver correctness:
schema v1 coalesces configured components into package-level external entries.
The target unit-elaborated schema must retain Cabal unit IDs, flags, and direct
unit edges instead of coalescing them.

## F5 — determinism probe: criteria edited, manifest inaccurate ⚠️ MEDIUM

The B4 mechanism (two salted planner runs, byte-compared after masking ALL
`/nix/store/*` paths) forces two real executions and has genuine bad-salt
negative controls — defensible. But: (a) it is same-store, not the specified
clean-store P7, and PROGRESS.md's pass criteria were **rewritten** to match
("independently salted planner runs") instead of recording the deviation;
(b) path masking hides input-hash differences, weakening the comparison;
(c) `summary.json` claims `"plannerDeterminism": "nix-store --realise
--check"` — that command is never run.

**Remediation R5:** fix the manifest string to describe the real mechanism
(one line). Narrow the masking to the planner's own salted paths rather than
all store paths. Record the same-store limitation in the probe suite docs.
Do not re-edit PROGRESS.md criteria; deviations go in row notes/CHECKPOINT.

## F6 — A4 shell proof proves the wrong shell ⚠️ MEDIUM

`devShells.default` now flows from `devShellFromLock` (nix/lib.nix ~798) —
good. But `penanceBenchShellPackageNames` (flake.nix ~208) was NOT deleted
(the checkbox says it was), and the sandboxed proof `penanceBenchShell`
still builds `mkPenanceShellProof` against the old hand-list
`penanceBenchShellGhc` (flake.nix ~625). The proof backing the HN-shell-for
comparison row no longer proves the shell users get.

**Remediation R6:** point `mkPenanceShellProof` at the lock project's shell
environment (same composed DB as `devShellFromLock`); derive the manifest
`packages` array and the `ghc-pkg list` assertions from the lock's external
units; delete `penanceBenchShellPackageNames` and `penanceBenchShellGhc`.

```sh
# pass criteria: the proof's package-db.txt lists exactly the lock's
# externals; adding a dep to the fixture cabal without regenerating the lock
# fails repent --check (freshness already covers the negative).
```

## F7 — the lock-driven external build is never exercised by the suite ⚠️ MEDIUM

`penanceLockExternalViaLock` (the fetchurl-from-lock StateVar build — the
whole point of A1+A2's external story) is only ever **evaluated** (no-IFD
check), never **built**, by any suite. Meanwhile the HN-hackage/HN-stackage
rows' "penance lane" is nixpkgs `ghcWithPackages`/`callHackage` — not
penance machinery. I built it manually; it works. The suite should own that.

**Remediation R7:** add a dynamic-probes (or baseline) step that builds
`penanceLockExternalViaLock` and runs the exe; repoint the HN-hackage row's
penance attr at a lock-driven build once R4 settles what "solved" means.
Keep the corrupted-hash negative (scratch lock with flipped sdist sha256
must fail) as a suite step, not just a manual test.

## F8 — dyndrv rebuild counts are marker events, not derivations ⚠️ MEDIUM

`DyndrvBuildLog` counting (RebuildBenchMain.hs ~691) recognizes exactly
three marker shapes (planner line, per-module echo, assemble echo). The
per-module **iface-stub derivations rebuild invisibly** — the export-edit
bound of 19 excludes them — and any unmarked drv is uncounted. It cannot
hide module recompiles (markers are emitted unconditionally and the exact
set fails in both directions), but `expectedMaxRebuiltDrvs` misdescribes
what is bounded.

**Remediation R8:** either emit markers from the iface drvs too and include
them in the expected sets, or rename the scenario fields/docs to
`expectedMaxRebuildEvents` + a note listing which drv kinds are unmarked.
Silent-cap rule: undercounting must be documented where the bound is read.

## F9 — the recursive-nix contract is only host-daemon-on-Darwin ⚠️ MEDIUM

Everything works because `sandbox = false` here: planner builders call
`/nix/var/nix/profiles/default/bin/nix` — an **absolute host path that is
not a derivation input**. A daemon upgrade changes planner behavior with no
drv-hash change; on a sandboxed Linux builder every planner fails. The
probes therefore prove "dyndrv with unsandboxed host-daemon access", not the
spec's restricted recursive-nix contract (Appendix A demands
`system-features = recursive-nix` on builder VMs for a reason).

**Remediation R9:** (a) record the sandbox assumption in the probe suite's
preflight — assert and LOG `nix config show sandbox` next to the features;
(b) add a failing gap row `M0-recursive-nix-sandboxed` for the
sandboxed-builder variant (this is also the honest home for the Linux-CI
story); (c) longer term, pass the nix binary into planners as a pinned
store-path input instead of the profile path.

## F10 — probe payload depends on mutable working-tree state ⚠️ LOW (bit us already)

During evaluation, `tests/probes/planner-payload.txt` in the working tree
contained `liveness probe <epoch>` — a string written by an earlier,
in-place-mutating iteration of the probe runner (the current runner
correctly edits only an rsync scratch copy). The stale content made
dynamic-probes and one rebuild scenario fail persistently until
`git restore --worktree` fixed it. Suites whose correctness depends on
committed fixture bytes should not trust the working tree blindly.

**Remediation R10:** the probe runner's preflight should compare the payload
files against the git index (`git diff --quiet -- tests/probes/` when a git
dir exists) and fail with a "working tree fixture modified" message instead
of a cryptic grep failure downstream.

## F11 — phase-matrix static check gaps ⚠️ LOW

Unlike the other two matrices, phase-matrix.json has no exact `$expected`
row-ID list (rows can be deleted down to the `length >= 8` floor unnoticed),
and its banned-word scan skips `notes` — which is exactly where F1's
admission hid.

**Remediation R11:** pin the phase-matrix row-ID list in the jq check and
add `notes` to the scanned fields (fix F1 first or the check will rightly
fail on the current M6 note).

---

# Process feedback for the implementation LLM

1. **Do not edit pass criteria to match the implementation.** B4's "clean
   stores" became "salted runs" in PROGRESS.md with no deviation note. The
   correct move when a criterion can't be met as written: implement the
   closest sound mechanism, keep the criterion text, and record the
   deviation in the row notes and CHECKPOINT. Evaluators diff the plan.
2. **Never regress a real mechanism into a constant to keep a row green**
   (F1). If the cross lane broke, the honest states are `failing` or
   reverted — a hex blob labeled "real" costs more trust than any red row.
3. **A checkbox is a claim about the item's title, not its test block.** A1's
   tests pass, but "solve" didn't happen; A4's tests pass against the wrong
   artifact. When scope shrinks, shrink the claim.
4. What went RIGHT and should continue: honest row-splitting
   (`M0-ca-cutoff-toy-remote`), real negative controls everywhere in the
   probes, exact-set rebuild assertions, disclosure in ARCHITECTURE.md, and
   CHECKPOINT.md's detailed verification notes — that file made this
   evaluation faster and is worth keeping up.

# Suggested remediation order

R1, R2 (restore honesty of the two faked rows — small, urgent) → R11 (so the
checks then enforce it) → R3 (ABI check — the one soundness hole) → R6, R7
(finish A4/A2's story) → R5, R8, R9, R10 (accuracy/robustness) → R4 (real
solver — the largest work item, prerequisite for CORPUS).
