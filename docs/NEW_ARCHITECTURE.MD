# STRATA — a haskell.nix replacement for a Backpack-heavy embedded NixOS monorepo

**Status:** implementation spec v2 · **Audience:** implementing engineers (written to be executable by a junior dev with review) · **Nix:** Determinate Nix, pinned release (see Appendix A) · **Working name:** `strata` (lock → eval → build layers)

This revision extends the v1 architecture with four new requirements:

1. **First-class Backpack** — indefinite units and their instantiations are nodes in the build graph, not an afterthought.
2. **Multi-System Closure bundles (MSC)** — one artifact containing the NixOS system closure of every embedded host, deduplicated.
3. **Fast source→device mirroring** — iterate on a device without rebuilding/re-uploading the whole MSC.
4. **Dynamic derivations are mandatory from day one**, implemented directly on Nix primitives (`dynamic-derivations` + `ca-derivations` + `recursive-nix`), **not** on Sandstone.

---

## 0. Executive summary

strata is three layers plus a fleet layer:

- **Lock layer** (`strata-lock`, a Haskell CLI linking `cabal-install` as a library): runs the cabal solver at *commit time*, elaborates the install plan down to **units** (components + Backpack instantiations), and writes a deterministic `strata.lock`. No IFD, ever.
- **Eval layer** (`strata-nix` + `strata-lower.wasm`): Nix consumes the lock via `builtins.wasm` (pure-Nix `fromJSON` fallback behind a flag) and lowers it to derivations in milliseconds-to-seconds instead of haskell.nix's minutes. Determinate Nix `parallel-eval` and lazy trees are enabled.
- **Build layer**: every Haskell unit is a **content-addressed** derivation with split `iface`/`out` outputs for ABI-level early cutoff. **Local, non-Backpack units are built at module granularity via dynamic derivations**: a per-unit planner derivation runs `ghc -M`, emits one CA derivation per module with `nix derivation add`, and returns the root `.drv` as its text-hashed output, consumed by `builtins.outputOf`. External (Hackage) units and Backpack units stay unit-level CA derivations.
- **Fleet layer** (`msc` + `warp`): `msc` builds each host's `config.system.build.toplevel` and packs all hosts into one **binary-cache-layout bundle** (natural cross-host dedup, incremental regeneration, signed narinfos). `warp` is the dev loop: Tier 0 pushes a closure *delta* to one device over `ssh-ng` and runs `switch-to-configuration test`; Tier 1 hot-swaps a single service binary via a `/run` overlay in under ~10 s.

Everything the *device* sees is input-addressed; CA and dynamic derivations live strictly inside the build farm. Devices run stock Nix with zero experimental features.

Kill switches (one boolean each) degrade: module→unit granularity, wasm→fromJSON, CA→input-addressed. The same lockfile drives all modes.

---

## 1. Requirements → design constraints

| # | Requirement | Design consequence |
|---|---|---|
| R1 | Eval is slow in haskell.nix | No IFD; no Nix-side cabal reimplementation; lock is pre-elaborated to units; wasm lowering; parallel-eval |
| R2 | Whole-world rebuilds on dep change | CA derivations + `iface`/`out` split + per-unit composed package DBs (no monolithic `ghcWithPackages`-style DB) |
| R3 | Unergonomic dev on large set | cabal-in-shell hybrid dev; module-granular Nix builds; warp device loop |
| R4 | Backpack first-class | Lock nodes are **units** incl. instantiations; builders drive `Setup configure --cid --instantiate-with`; dev-shell "projection" for HLS |
| R5 | MSC bundles | `msc` component; binary-cache bundle format; manifest schema |
| R6 | Fast device mirroring | `warp` Tier 0/1; `devOverlay` NixOS module |
| R7 | Dyndrv today, no Sandstone | `strata-plan` emits drvs with `nix derivation add` inside a `recursive-nix` planner; text-hash output + `outputOf` |
| R8 | Dev shells + cross + CUDA (accelerate, jetpack-nixos) | Per-target toolchain tuples in lock; native aarch64-linux builds on Mac Studios via linux-builder VM preferred over GHC cross |
| R9 | Huge VHDL files in repo | lazy trees + `lib.fileset` per-unit sources; planner slices per-module sources at build time |

Non-goals: materialization compatibility; Stack support (Stack has no Backpack support, so the solver of record is cabal); building Hackage deps at module granularity.

---

## 2. System invariants

These are the rules every component must preserve. Violating one is a design bug, not a style issue.

1. **No IFD anywhere.** `nix flake check` must pass with `allow-import-from-derivation = false`.
2. **The lock is the single source of truth.** Eval never solves, parses `.cabal` files, or globs the repo for dependencies. If it's not in `strata.lock`, it doesn't exist.
3. **Graph nodes are units, not packages.** A unit is: an ordinary component (lib/sublib/exe/test/bench/flib), an *indefinite* Backpack library (typecheck-only), or a *fully-instantiated* Backpack library (cid + module substitution). Unit IDs are computed by `strata-lock` and are stable across machines.
4. **Every Haskell derivation is content-addressed** (`__contentAddressed = true`) with split outputs: `iface` (`.hi`/`.hie` + compile-time pkg conf) and `out` (objects/libs + full conf). Compile steps of non-TH modules depend only on `iface` of deps. This is the early-cutoff mechanism.
5. **Dynamic derivations are used exactly where the graph is unknown at lock time**: the module DAG inside a local unit. Unit-to-unit edges are known at lock time and are lowered statically at eval. (Dyndrv-ifying 400 Hackage packages multiplies drv count ~50× for zero dev-loop benefit and stresses an experimental scheduler; don't.)
6. **The device boundary is input-addressed.** `system.build.toplevel`, everything in the MSC, and everything `warp` copies are ordinary resolved store paths. Devices need no experimental features and never see a realisation.
7. **Planners are deterministic.** Same inputs ⇒ byte-identical emitted `.drv` files. Sorted maps, no timestamps, pinned env whitelist. This is tested (T-C4-1).
8. **Every experimental dependency has a kill switch** that degrades gracefully using the *same* lockfile: `granularity = "module" | "unit"`, `lowering = "wasm" | "nix"`, `addressing = "ca" | "input"`. CI runs the degraded matrix weekly.
9. **Secrets never enter derivations.** Bundle signing happens in CI post-build (`nix copy` with `secret-key-files` configured), never inside a sandbox.
10. **Sources are minimal.** Each unit's `src` is a `lib.fileset` union of exactly its Haskell-relevant files; VHDL never reaches a Haskell derivation's input closure.

---

## 3. Component map

```
             ┌───────────────────────── commit time ─────────────────────────┐
 cabal.project / snapshot.yaml / strata.toml
        │
        ▼
 ┌──────────────┐     strata.lock (JSON, committed)
 │ C1 strata-lock│ ──────────────┐
 └──────────────┘                │
                                 ▼        ┌── eval time (per nix invocation) ──┐
                       ┌──────────────────────────┐
                       │ C2 strata-nix + lower.wasm│  → flake outputs:
                       └──────────────────────────┘     packages.* devShells.*
                                 │                       legacyPackages.strata.*
              ┌──────────────────┼───────────────────────────────┐
              ▼                  ▼                               ▼
   ┌────────────────┐   ┌─────────────────┐            ┌─────────────────┐
   │ C3 unit builders│   │ C4 strata-plan  │            │ C5 dev shell    │
   │ (Setup-driven,  │   │ (dyndrv module  │            │ (cabal hybrid,  │
   │  Backpack insts)│   │  planner)       │            │  HLS projection)│
   └────────────────┘   └─────────────────┘            └─────────────────┘
              │                  │
              └───────┬──────────┘        C6 toolchains (per-target: ghc, llvm, cuda)
                      ▼
        nixosConfigurations.<host>  (unchanged user code, consumes overlay)
                      │
        ┌─────────────┴─────────────┐
        ▼                           ▼
 ┌─────────────┐             ┌─────────────┐
 │ C7 msc      │             │ C8 warp     │──── C8b devOverlay (NixOS module on device)
 │ (bundle/    │             │ (deploy/    │
 │  install)   │             │  swap)      │
 └─────────────┘             └─────────────┘
                      C9: CI / Cachix / Mac Studio builders
```

Repository layout for the strata tooling itself:

```
strata/
  lock/          # C1: Haskell CLI (cabal-install as a library)
  nix/           # C2: Nix library (lower.nix, mkUnit.nix, mkPkgDb.nix, shell.nix, msc.nix)
  lower-wasm/    # C2: Rust crate → strata-lower.wasm (committed artifact + source)
  plan/          # C4: strata-plan (Rust or Haskell; runs inside planner drvs)
  warp/          # C8: warp CLI (shell/Rust) + devOverlay NixOS module
  msc/           # C7: msc CLI
  tests/         # spike probes, golden tests, integration fixtures, benchmarks
```

---

## 4. Components

### C1 — `strata-lock` (solver + elaborator)

**Purpose.** Replace haskell.nix's IFD-time `plan-to-nix` with a commit-time CLI that produces a fully elaborated, unit-level lockfile.

**Why cabal-as-a-library, not plan.json scraping.** `plan.json` represents Backpack instantiations only as opaque unit IDs of the form `<cid>+<hash>` and does not expose the module substitution; tooling that needs the instantiation mapping has to reverse-engineer it (this is cabal issue #6201). `strata-lock` therefore links `cabal-install`/`Cabal` and reads the **ElaboratedInstallPlan** directly, where `OpenUnitId` / `ModuleSubst` (see `Distribution.Backpack`) carry exactly the "which hole is filled by which module of which unit" data we need. `hashModuleSubst` gives us cabal-compatible instantiation hashes for unit IDs.

**Inputs.**
- `cabal.project` — the repo's local packages (globs fine; the CLI expands them).
- `snapshot.yaml` — your curated "stackage": a constraints set (exact versions + Hackage revision per package). Generated once from your current haskell.nix snapshot by a migration script (M8).
- `strata.toml` — strata config: GHC version(s), target list, per-target toolchain tuple `{ghc, llvm, cudaArch?}`, per-unit overrides (`granularity`, extra flags, `defaultInstantiations` for Backpack dev projection).
- Hackage index state (pinned timestamp).

**Algorithm.**
1. Run the cabal solver per target platform (host, `aarch64-linux`, …) with the snapshot as hard constraints. One solve per target because flags/conditionals differ.
2. Elaborate to units. For each unit emit: kind (`ordinary` | `indefinite` | `instantiation`), package name/version, component name, `cid`, `instantiatedWith: {SigName → {unit, module}}` (instantiations only), direct build/exe/setup deps as unit IDs, resolved flags, language/extensions, exposed modules, `hsSourceDirs`, `setupType` (`Simple`|`Custom`|`Configure`), C sources / pkgconfig / extra-libraries, and for local units the `srcRoot` relative path.
3. Compute stable IDs: `cid = base32(sha256(canonical-json(pkg, ver, srcHash|hackageSha, flags, ghcId, targetId, sorted dep cids)))[0:20]`; instantiation `uid = cid ++ "+" ++ hashModuleSubst(subst)`.
4. Pin sources: Hackage sdist sha256 + `.cabal` revision hash from the index; local units get `srcRoot` only (content addressed at eval by fileset, not here).
5. Assign `granularity`: `"module"` iff local ∧ `setupType == Simple` ∧ kind == ordinary ∧ no `.hsig`/mixin-renames ∧ not overridden in `strata.toml`; else `"unit"`.
6. Emit `strata.lock` (schema §5.1), canonical JSON (sorted keys, no floats), plus a `lockHash` self-field. Emission is deterministic (T-C1-2).

**CLI.**
```
strata lock                 # solve all targets, write strata.lock
strata lock --check         # CI freshness gate: re-solve, byte-compare
strata lock --update PKG…   # relax snapshot pins for PKG, re-solve
strata lock --explain UID   # print why-depends within the lock
```

**Notes for the implementer.** Vendor the exact `cabal-install` version as a source dep; its internal APIs move. Solve with `--enable-tests --enable-benchmarks` for local packages only. Treat `setupType == Custom` as `granularity = unit` and record the setup closure as an extra unit (`kind: setup`).

### C2 — eval layer (`strata-nix` + `strata-lower.wasm`)

**Purpose.** Turn `strata.lock` into derivations in O(lock size) with near-zero interpreter overhead, and present a haskell.nix-compatible flake surface.

**Lowering.** `lower.wasm` is a Rust function (built with the `nix-wasm-rust` interface, compiled to `wasm32`, the `.wasm` committed to the repo so eval never builds it) invoked as:

```nix
lowered = builtins.wasm {
  path = ./lower-wasm/strata-lower.wasm;
  function = "lower";
} { lock = builtins.readFile ../strata.lock; target = system; };
```

It parses, validates `lockHash`, filters to the target, topologically sorts, resolves flag-conditional fields, and returns a flat attrset `{ units = { <uid> = {...}; }; roots = {...}; toolchain = {...}; }`. `builtins.wasm` is an experimental Determinate Nix feature (`wasm-builtin`); therefore:

```nix
lowered = if (builtins ? wasm) && cfg.lowering == "wasm"
          then wasmLower else nixLower;   # nixLower: fromJSON + lib-based port, same output shape
```

Both lowerers are golden-tested against each other (T-C2-1). Enable `parallel-eval` and lazy trees in Determinate Nix (Appendix A) — with no IFD and no giant `callPackage` forests, eval cost is parsing + N× `mkUnit` calls.

**Flake surface (drop-in contract).**
```nix
packages.<sys>.<name>                         # default component of local package <name>
packages.<sys>."<pkg>:<ctype>:<cname>"        # haskell.nix-style component attrs (compat shim)
devShells.<sys>.default                       # C5
legacyPackages.<sys>.strata.{units,pkgdbs,toolchains,projection}
lib.overlay                                   # final: prev: { strataPackages = ...; } for nixosConfigurations
apps.<sys>.{warp,msc,strata-lock}
```
Your `nixosConfigurations` keep referencing `pkgs.strataPackages.<name>`; only the overlay import changes during migration.

### C3 — unit builders (static, CA, Backpack-aware)

**Purpose.** Build any lock unit as a single CA derivation. This is the universal fallback (`granularity = "unit"`) and the only mode for Hackage and Backpack units.

**`mkPkgDb`** — package DB composition that kills whole-world rebuilds. Two DB flavors per unit, both tiny symlink-forest derivations ending in `ghc-pkg recache`, both CA:

- `dbIface(unit)` = union of transitive deps' **`iface`** confs (import-dirs only). Used to *compile* non-TH modules.
- `dbFull(unit)` = union of transitive deps' **`out`** confs (import-dirs + library-dirs). Used for TH modules, linking, and `Setup`-driven builds.

Because confs live in the `iface` output and reference only `iface` paths, a dependency whose *body* changed but whose ABI (and thus `.hi` bytes and conf) did not produces an identical `iface` output under CA ⇒ identical `dbIface` ⇒ **downstream compiles are cut off**. Links still redo (correct: object code changed).

**`mkUnit`** — generic builder. Phases (Setup-driven path, used for all `granularity = unit`):

```
configurePhase:
  Setup configure <componentTarget>
    --with-ghc=$ghc --with-ghc-pkg=$ghcPkg --ghc-options="$stdGhcOpts"
    --package-db=clear --package-db=global $(for db: --package-db=$db)
    --exact-configuration $(for dep: --dependency=NAME=UID)
    --cid=$cid
    [--instantiate-with='Sig=DEP_UID:Impl.Module' …]     # kind == instantiation
    --prefix=$out --libdir=$out/lib --dynlibdir=$out/lib
buildPhase:    Setup build -j$NIX_BUILD_CORES <componentTarget>
installPhase:  Setup install (or copy for exes)
registerPhase (libraries):
  Setup register --gen-pkg-config=$conf
  split: write iface output (hi tree + iface-conf with library-dirs stripped)
         write out   output (libs + full conf)
```

Standard `stdGhcOpts` per flavor:
- **dev**: `-O0 -fomit-interface-pragmas -fignore-interface-pragmas -fhide-source-paths -fdiagnostics-color=never -j1-per-module`
- **release**: `-O2 -fhide-source-paths` (no pragma omission — accept coarser cutoff; release builds are CI-only)

The pragma-omission flags are what make `.hi` files a function of the *interface* rather than the optimizer's mood; they are the linchpin of module-level cutoff in dev flavor and are validated by T-C3-4.

**Backpack specifics.**
- `kind == indefinite`: run configure/build *without* `--instantiate-with`. GHC typechecks against signatures and produces interface artifacts only (no code — this is upstream Backpack semantics). Output: `iface` only, conf marked indefinite. Value: CI proves impls-agnostic code still typechecks, and instantiations depend on this unit's source via its `cid`.
- `kind == instantiation`: full compile with the substitution. **Rebuild scoping falls out of the graph**: instantiation X depends on (a) the indefinite unit's source (via cid) and (b) each implementing unit's `iface`. Edit impl `A`'s body ⇒ A's `iface` unchanged ⇒ instantiations cut off. Edit the `.hsig` ⇒ indefinite cid changes ⇒ all instantiations rebuild. Exactly right.
- TH restriction (upstream, document loudly): you cannot splice TH code *imported from* a still-indefinite unit; splicing from definite units into indefinite ones is fine.
- The number of instantiation units can be large; they are ordinary lock nodes, sorted and lowered like everything else. This is why haskell.nix-style per-package modeling was never going to give you first-class Backpack: the graph's real nodes are instantiations.

### C4 — `strata-plan` (module-granular dynamic derivations)

**Purpose.** For `granularity = "module"` units, discover the module DAG at *build* time and emit one CA derivation per module, so a one-line edit rebuilds one module (+ its true dependents + a link), not a package.

**Mechanism (the exact dyndrv pattern, no Sandstone).** Eval lowers a module-granular unit not to a compile derivation but to a **planner** derivation:

```nix
unitDrv = builtins.outputOf (mkPlanner {
  name = "${uid}-plan.drv";
  outputHashMode = "text";              # output IS a .drv (text-hashed store object)
  outputHashAlgo = "sha256";
  __contentAddressed = true;
  requiredSystemFeatures = [ "recursive-nix" ];
  src = unitSrcFileset;                 # this unit's files only (fileset, lazy tree)
  env.UNIT_JSON = builtins.toJSON unitLockEntry;  # deps' db paths, flags, ghc
}).outPath "out";
```

Inside the sandbox, `strata-plan`:

1. Runs `ghc -M -dep-suffix '' -include-pkg-deps` over the unit's modules against `dbIface` to get the intra-unit module DAG (parse the emitted Makefile).
2. Classifies each module `TH?` by scanning `{-# LANGUAGE #-}` pragmas plus the unit's `default-extensions` from `UNIT_JSON` (conservative: `TemplateHaskell`, `QuasiQuotes`, ANN ⇒ TH).
3. For each source file: `nix store add-path Foo.hs` (allowed under the restricted `recursive-nix` daemon) → a per-file CA source path. Editing one file therefore invalidates exactly one compile drv.
4. For each module, in topo order, constructs a derivation in **JSON derivation format** and registers it: `nix derivation add < module.json` → `/nix/store/…-M.drv`. Shape:
   - outputs: `hi` and `o`, both `{ "method": "nar", "hashAlgo": "sha256" }` (floating CA);
   - inputSrcs: the module's source path (+ literal `.hi-boot` sources);
   - inputDrvs: sibling module drvs (paths now exist in the store — plain references requesting output `hi`), plus `dbIface` (or `dbFull` iff TH), toolchain;
   - builder: the pinned `ghc-module-compile` wrapper (a store path passed into the planner), args = `ghc -c Foo.hs -this-unit-id $uid -package-db $db -i$hiDirPlaceholders -ohi $hi -o $o` + flavor flags.
5. Emits a link/assemble drv: inputs = all module `o` outputs + `dbFull`; produces the unit's `iface` and `out` outputs (hi tree, `.a`/`.so` or exe, conf) exactly matching `mkUnit`'s output contract, so C3 consumers can't tell the difference.
6. Writes the assemble drv's byte content to `$out`. Because `$out` is text-hashed and `nix derivation add` stored the identical text, both converge on the same store path — the planner's output *is* the root `.drv`.

The scheduler then follows the chain: build planner → read root drv → build modules → assemble. Consumers written in Nix reference the unit through `builtins.outputOf`, which encodes the dependency as `dynamicOutputs` in *their* `.drv`; on the CLI the chain is addressable as `nix build '/nix/store/…-plan.drv^out^out'`. This is precisely the pattern demonstrated by the MakeNix/NpmNix write-ups and the nix-ninja docs (references §9); we are productionizing it, with the planner itself being cheap (ghc -M + JSON emission, ~100 ms–1 s per unit) and rebuilt only when the unit's fileset or deps change.

**Determinism rules (hard requirements, tested):** sort all maps and dep lists; canonical JSON; no clocks, hostnames, or env leakage (whitelist `PATH`-free, everything by store path); identical inputs ⇒ byte-identical drv set (T-C4-1).

**Cutoff semantics achieved (dev flavor):**
- comment/body edit in `Foo.hs` ⇒ rebuild `Foo` (its `o` changes, `hi` byte-identical) ⇒ dependent module compiles cut off ⇒ assemble relinks. Seconds.
- export/type change ⇒ `hi` changes ⇒ true dependents recompile. Correct by construction.
- dep package body-only change ⇒ `dbIface` unchanged ⇒ zero module rebuilds here; only final link.

**Scoping.** TH modules use `dbFull` (they must load object code) and therefore rebuild when any dep's `out` changes — conservative and correct. `hs-boot` cycles: planner supports them (compile `-boot` first) but if parsing gets hairy, `strata-lock` may demote such units to `granularity = unit` with a warning; correctness beats granularity.

### C5 — dev shell (shellFor parity + HLS)

**Contract.** `nix develop` gives: pinned GHC, cabal, HLS, all *external* lock deps pre-built and visible to cabal/GHC so `cabal build all` compiles **only local packages**; ghciwatch; `warp`/`msc` on PATH.

**Mechanism.**
- Shell includes `dbFull(shellRoots)` — one composed package DB covering every external dep of the selected local packages (haskell.nix `shellFor` equivalent, but it's a symlink forest over already-CA-built units, so entering the shell after a dep bump downloads deltas from Cachix rather than rebuilding the world).
- Generate `cabal.project.local.strata` pinning `with-compiler` and wiring the DB. Primary mechanism: the `package-dbs:` project field pointing at `[global, dbFull]`; **verify against the pinned cabal release in M2** — if unsupported there, fallback is a GHC package-environment file plus a thin `cabal` wrapper injecting the DB (implementer task, escalate with findings, do not silently pick a third mechanism).
- HLS: works unmodified via cabal + `cabal multi-repl` over local packages.
- **Backpack projection.** HLS/`multi-repl`/GHC multiple-home-units do not load indefinite units. `strata projection` (subcommand of the lock tool) emits `dist-strata/projection/` where each indefinite local unit is textually specialized using `defaultInstantiations` from `strata.toml` (signatures replaced by re-exports of the default impl), plus a generated `cabal.project.projection`. Devs open *that* project in HLS when editing indefinite code; CI's indefinite-typecheck derivations (C3) keep them honest against the real signatures. Document this limitation prominently; it is an ecosystem gap, not a strata gap.
- VHDL never enters the shell closure: shell `src` is the fileset union of local Haskell package roots only.

### C6 — toolchains, cross, CUDA (delta view; full analysis in v1 report)

- `strata.toml` targets carry `{ghc, llvm, cudaArch}` tuples; `strata-lock` solves per target; eval lowers per target. accelerate-llvm-ptx pins the LLVM major via `llvm-hs` — record it in the tuple and let CI assert `ghc ↔ llvm` compatibility at lock time, not at 40 minutes into a build.
- **Primary path for Jetson (aarch64-linux): native builds, not GHC cross.** The Mac Studios are aarch64; run the standard `darwin.linux-builder` VM (native aarch64-linux, Virtualization.framework) as the builder for `aarch64-linux` derivations, with the jetpack-nixos overlay supplying L4T/CUDA userspace. This sidesteps GHC cross + TH entirely for your device target. GPU is not needed at build time (accelerate-llvm-ptx JITs via libNVVM on-device at runtime; build needs headers/libs only).
- Keep an x86_64-linux → aarch64-linux GHC cross lane (iserv/qemu for TH) as CI-parity fallback; gate it as allowed-to-fail initially.
- Backpack × cross: instantiation graphs are per-target in the lock (flags/conditionals differ); nothing special beyond that. Remember the TH-from-indefinite restriction applies on all targets.
- Builder VMs must enable the same experimental features + `system-features = recursive-nix` (Appendix A) or planners will silently queue forever with "no machine can build this".

### C7 — `msc` (Multi-System Closure bundles)

**Format = a standard Nix binary cache in a directory, plus a manifest.** This buys: cross-host dedup for free (shared store paths appear once), incremental regeneration (existing NARs skipped), integrity via signed narinfos, and device-side consumption with plain `nix copy` — no custom unpacker.

```
bundle/
  manifest.json          # §5.2
  nix-cache-info         # StoreDir: /nix/store
  <hash>.narinfo …       # signed
  nar/<hash>.nar.zst …
```

**Producer (imperative CLI, primary):**
```
msc bundle --flake .#fleet --out ./bundle [--hosts a,b,…] [--jobs N]
  1. nix build .#nixosConfigurations.<h>.config.system.build.toplevel  (per host; farm does the work)
  2. nix copy --to "file://$out?compression=zstd" <toplevels>          (delta vs existing bundle dir)
  3. write manifest.json (hosts→toplevel, sizes, lockHash, flake rev)
  4. narinfos signed via nix.conf secret-key-files on the CI runner    (never inside a drv)
msc verify ./bundle      # narinfo sigs + closure completeness per host
msc diff  A/ B/          # per-host path/size delta report
```
Persist the bundle dir between releases (or hydrate with `--seed s3://…`): regeneration cost is proportional to *changed* paths. A hermetic pure-derivation variant (closureInfo + in-sandbox NAR packing) is specified in Appendix C for release provenance, but the imperative path is the daily driver.

**Consumer (on device, baked into the image by the strata NixOS module):**
```
msc install /media/msc [--host $(hostname)] [--test|--switch|--boot]
  → nix copy --from file:///media/msc --to daemon <toplevel-for-host>   # only missing paths
  → <toplevel>/bin/switch-to-configuration $mode
```
Because of invariant 6, the device pulls plain resolved paths: **no CA, no realisations, no experimental features on devices.** On the farm side, the CA→input-addressed resolution happens when the (input-addressed) toplevel is built against realized CA outputs; the bundle only ever contains post-resolution paths.

### C8 — `warp` (fast source→device mirroring) + `devOverlay`

Design principle: never rebuild or re-upload the MSC during iteration; the MSC is a release artifact. Iteration flows through two tiers, both driven by the *same* incremental Nix graph, so "fast" is a corollary of C3/C4 cutoffs plus delta transfer.

**Tier 0 — closure-delta deploy (default, always correct):**
```
warp deploy <host> [--test]      # --test is default; --switch to persist
  1. nix build .#nixosConfigurations.<host>…toplevel     # incremental: touched module + link + system rewiring
  2. nix copy --to ssh-ng://<host> <toplevel>             # transfers only paths the device lacks
  3. ssh <host> <toplevel>/bin/switch-to-configuration test
```
`test` mode doesn't touch the bootloader: a power cycle returns the device to its last MSC-installed generation — ideal failure semantics for embedded bring-up. Expected inner-loop latency after a body-only edit: module compile + exe link + tiny system-path rewires + LAN copy of the changed exe closure ⇒ target **< 30 s** (benchmarked in M7, see §6.3; dominated by GHC link + exe transfer, so prefer dynamic linking for dev flavor on-device).

**Tier 1 — service hot-swap (< ~10 s, code-only changes):**
```
warp swap <host> <service> [--exe .#pkg:exe:name]
  1. nix build the exe (module-granular)                   # usually: 1 module + link
  2. nix copy --to ssh-ng://<host> <exeClosure>
  3. ssh <host> strata-overlay activate <service> <exePath> && systemctl restart <service>
warp reconcile <host>    # clear overlays, full switch-to-configuration to current system
warp status <host>       # taint state, active overlays, generation info
```
`devOverlay` NixOS module (`strata.devOverlay.enable`, dev images only — assert `!isProduction`):
- For each managed service, installs a systemd drop-in replacing `ExecStart` with a shim: `exec $(readlink -f /run/strata-overlay/bin/<svc> 2>/dev/null || readlink /etc/strata/default/<svc>) "$@"`, where `/etc/strata/default/<svc>` points at the store default for the current generation.
- `strata-overlay` CLI (root-only, SSH `ForceCommand`-able): `activate <svc> <storePath>` (validates the path exists locally — warp copied it first — then atomically swaps the `/run` symlink), `clear [svc]`, `status --json`.
- `/run` is tmpfs ⇒ overlays self-heal on reboot. A taint marker (`/run/strata-overlay/tainted`, surfaced in motd + a Prometheus textfile metric) makes "this device is running non-declared code" impossible to miss; `switch-to-configuration` via Tier 0 or `msc install` clears overlays by activation hook.
- Non-service payloads (data files, plugins): `activate --bind <svc-or-tag> <storePath> <targetStorePath>` uses a bind mount over the target path; same tmpfs lifetime, listed in `status`. Use sparingly; symlink swap is the sanctioned path.

Tier choice heuristic in `warp`: if the toplevel diff touches only managed services' exes ⇒ offer Tier 1; anything touching config/units/etc ⇒ Tier 0.

### C9 — CI & caching integration

- **Gates:** `strata lock --check`; `nix flake check` with IFD disallowed; eval-time budget assertion; kill-switch matrix (weekly): `{granularity=unit}`, `{lowering=nix}`, `{addressing=input}` all must stay green.
- **Builders:** Linux x86_64 runners + Mac Studios hosting `darwin.linux-builder` aarch64-linux VMs. All builders: pinned Determinate Nix, Appendix A features, `recursive-nix` in `system-features`, shared trusted signing keys.
- **Cachix + CA:** pushing/substituting CA paths requires realisation metadata to flow with signatures. **M3 includes an explicit verification task** of Cachix realisation support with your account tier. Fallback that preserves all dev-loop benefits: designate one resolver builder per target that realises the CA graph and pushes *resolved* closures keyed by input-addressed anchor derivations (a 20-line wrapper emitted by C2 when `addressing=ca` and `cacheAnchor=true`); other machines substitute anchors like any normal path.
- **Large-repo hygiene:** lazy trees on; all Haskell `src`s are filesets (invariant 10); CI checkout uses sparse/partial clone so Mac VMs never materialize VHDL blobs.


---

## 5. Data schemas

### 5.1 `strata.lock` (v2, canonical JSON, committed)

```jsonc
{
  "schema": "strata/2",
  "lockHash": "sha256-…",                  // over everything below, canonical form
  "solver": { "cabal": "3.14.1.0", "indexState": "2026-06-20T00:00:00Z" },
  "toolchains": {
    "x86_64-linux":  { "ghc": "9.8.4", "llvm": null,  "cuda": null },
    "aarch64-linux": { "ghc": "9.8.4", "llvm": "15",  "cuda": { "jetpack": "6.x", "capability": "8.7" } }
  },
  "targets": {
    "aarch64-linux": {
      "units": {
        "aeson-2.2.3.0-8f3ka92jd0amq1xz51tg": {
          "kind": "ordinary", "pkg": "aeson", "version": "2.2.3.0",
          "component": "lib", "granularity": "unit",
          "src": { "type": "hackage", "sha256": "…", "revision": 2, "cabalSha256": "…" },
          "flags": { "ordered-keymap": true },
          "deps": ["base-…", "…"], "exeDeps": [], "setup": null,
          "language": "Haskell2010", "extensions": ["…"],
          "cbits": true, "pkgconfig": [], "extraLibs": []
        },
        "regex-indef-0.1-k2m…": {
          "kind": "indefinite", "component": "lib:regex-indef",
          "signatures": ["Str"], "granularity": "unit",
          "src": { "type": "local", "root": "libs/regex-indef" }, "…": "…"
        },
        "regex-indef-0.1-k2m…+G4x…": {
          "kind": "instantiation", "of": "regex-indef-0.1-k2m…",
          "instantiatedWith": { "Str": { "unit": "str-bytestring-0.1-9ss…", "module": "Str.ByteString" } },
          "granularity": "unit", "deps": ["…includes impl units…"]
        },
        "ourapp-3.2-pp1…": {
          "kind": "ordinary", "component": "exe:ourapp", "granularity": "module",
          "src": { "type": "local", "root": "apps/ourapp" },
          "hsSourceDirs": ["src"], "modules": null,   // module set discovered by planner, not lock
          "deps": ["…"], "…": "…"
        }
      },
      "roots": { "packages": ["ourapp", "…"], "shell": ["ourapp", "…"] }
    },
    "x86_64-linux": { "…": "…" }
  },
  "projection": { "defaults": { "regex-indef-0.1-k2m…": { "Str": "str-bytestring…" } } }
}
```

Rules: unit maps sorted by uid; dep lists sorted; no nulls omitted-vs-present ambiguity (schema-validated); local `src.root` paths are repo-relative.

### 5.2 `manifest.json` (MSC, v1)

```jsonc
{
  "schema": "msc/1",
  "created": "2026-07-03T18:04:11Z",
  "flake": { "rev": "…", "lockHash": "sha256-…" },
  "hosts": {
    "line-ctrl-01": { "system": "aarch64-linux",
      "toplevel": "/nix/store/…-nixos-system-line-ctrl-01-…",
      "closurePaths": 2841, "closureNarSize": 1934772224 },
    "vision-02":    { "…": "…" }
  },
  "signingKeys": ["fleet-1:MCowBQYDK2VwAyEA…"],
  "notes": "free-form release notes"
}
```

### 5.3 Module derivation JSON (emitted by `strata-plan`, consumed by `nix derivation add`)

Template — exact field spelling **must be validated in M0 (P1)** against the pinned Nix's `nix derivation show`/`add` round-trip and then frozen in a golden test:

```jsonc
{
  "name": "ourapp-M-App.Widgets",
  "system": "aarch64-linux",
  "builder": "/nix/store/…-ghc-module-compile/bin/compile",
  "args": ["App/Widgets.hs"],
  "env": { "hiOut": "<hi placeholder>", "oOut": "<o placeholder>",
           "pkgdb": "/nix/store/…-dbIface", "deps": "/nix/store/…Foo.drv!hi …" },
  "outputs": { "hi": { "method": "nar", "hashAlgo": "sha256" },
               "o":   { "method": "nar", "hashAlgo": "sha256" } },
  "inputSrcs": ["/nix/store/…-App.Widgets.hs"],
  "inputDrvs": { "/nix/store/…-ourapp-M-App.Core.drv": { "outputs": ["hi"], "dynamicOutputs": {} },
                 "/nix/store/…-dbIface.drv":           { "outputs": ["out"], "dynamicOutputs": {} } }
}
```

### 5.4 `devOverlay` on-device state

```
/etc/strata/default/<svc>          -> store path (per-generation default, managed by module)
/run/strata-overlay/bin/<svc>      -> store path (dev override; absent = no override)
/run/strata-overlay/tainted        # newline list: "<svc> <path> <iso8601>"
strata-overlay {activate|clear|status --json}
```

---

## 6. Test plan

### 6.1 M0 spike probes (must all pass before any strata code is written)

Run on a pinned Determinate Nix with Appendix A config. Each probe is a tiny committed fixture under `tests/probes/`.

| ID | Probe | Pass criterion |
|----|-------|----------------|
| P1 | Hand-write minimal module-drv JSON; `nix derivation add`; `nix build '<drv>^out'` | builds; `nix derivation show` round-trips byte-stable |
| P2 | Planner drv (`outputHashMode="text"`, `recursive-nix`) emitting one child drv; consume via `builtins.outputOf` | `nix build` follows the chain; second build is a no-op |
| P3 | Two-level chain `plan.drv^out^out` from CLI | resolves and builds |
| P4 | `nix store add-path` inside a recursive-nix builder | path added; usable as `inputSrcs` of an added drv |
| P5 | 3-module toy (A→B→C), CA `hi`/`o` split with a fake deterministic "compiler"; touch a comment in A | only A rebuilds; B, C cut off (assert via `nix log` build-count harness) |
| P6 | P5 on a **remote** ssh-ng builder with matching features | identical cutoff behavior; realisations visible to the client |
| P7 | Planner determinism: run P2 planner twice from clean stores | byte-identical `.drv` set |

Any P-failure: capture `nix --version`, full logs, minimal repro; check the dynamic-derivations tracking issue for known regressions; escalate before proceeding. These probes become the permanent vendored regression suite pinning our Nix upgrades (run in CI on every Nix bump).

### 6.2 Per-component tests

**C1 strata-lock** — golden lock for a fixture workspace (byte-stable across machines/OSes, T-C1-2); solver-freshness (`--check` fails on edited `.cabal`); Backpack fixture: indefinite lib + 2 impls + 2 instantiations ⇒ lock contains 1 indefinite + 2 instantiation units with correct `instantiatedWith` (T-C1-3, cross-checked against `ghc-pkg field` unit-ids from a real cabal build); custom-Setup demotion to `granularity=unit`; per-target flag divergence fixture.

**C2 eval** — wasm and Nix lowerers produce `deepSeq`-equal attrsets on all fixtures (T-C2-1); eval wall-time budget test: synthetic 600-unit lock evals `nix flake show` under 3 s warm / 20 s cold on the reference dev box (fail = perf regression); `allow-import-from-derivation=false` full-suite run.

**C3 builders** — build aeson-class fixture from Hackage pins; **cutoff matrix** (the core value test, T-C3-4):

| Edit in dep `libA` | Expect for `libB` (deps on A), dev flavor |
|---|---|
| comment / function body only | compile cut off; `dbIface` identical; only exe relink |
| new exported function | recompile importing modules only |
| type change in used export | recompile dependents (compile error surfaces = correct) |

Plus Backpack matrix (T-C3-5): edit impl A body ⇒ neither instantiation recompiles; edit impl A exported type ⇒ only A-instantiation rebuilds; edit `.hsig` ⇒ indefinite + both instantiations rebuild. Plus `.hi` determinism soak: 20 rebuilds of a TH-free unit at dev flags ⇒ identical `iface` output hash.

**C4 strata-plan** — determinism (T-C4-1 = P7 on real GHC); `ghc -M` DAG vs known fixture graph; TH classification fixture (TH module gets `dbFull`, others `dbIface`); hs-boot fixture (either correct order or clean demotion warning); **module cutoff end-to-end**: 30-module app, body edit ⇒ exactly 1 module drv + assemble rebuild (assert from build logs); planner overhead budget: < 2 s per unit on reference box.

**C5 shell** — `nix develop` then `cabal build all` compiles zero external packages (assert via cabal log); HLS loads multi-package fixture; projection fixture: HLS loads specialized indefinite unit; `package-dbs:` mechanism verification recorded as an ADR.

**C6 cross/CUDA** — aarch64-linux fixture unit builds on the darwin linux-builder VM; accelerate-llvm-ptx sample links against jetpack CUDA (build-only in CI); lock asserts ghc↔llvm tuple; HIL smoke (nightly): sample accelerate binary runs a kernel on a bench Jetson.

**C7 msc** — 2-host fixture sharing ~95% closure ⇒ bundle size ≈ union not sum (assert < 1.15× larger host); `msc verify` catches a corrupted nar and a stripped signature; incremental rebundle after 1-module change adds only new nars (count assertion); device-sim test in a NixOS VM: `msc install --test` boots the target config with **no experimental features enabled in the VM**.

**C8 warp** — VM-based: Tier 0 after body edit transfers < N paths (record baseline, alert on regression) and `switch-to-configuration test` activates; Tier 1 swap end-to-end < 10 s in VM; reboot clears overlay + taint; `reconcile` clears overlay and re-activates cleanly; production-image assertion test (module refuses `isProduction = true`).

**C9 CI** — kill-switch matrix builds the full fixture set weekly; cachix realisation round-trip test or documented anchor fallback active; Nix-version canary job runs §6.1 probes against the next DetNix release before any fleet upgrade.

### 6.3 Benchmarks (tracked in CI, regression-gated)

On the reference dev box + one Mac Studio, against the current haskell.nix baseline (capture baseline numbers in M2 before cutover):

1. cold `nix flake show`; warm re-eval
2. no-op `nix build .#ourapp`
3. body-only edit → `.#ourapp` rebuild wall time; number of derivations rebuilt
4. dep-package body edit → rebuild count downstream (haskell.nix baseline: "world"; target: link steps only)
5. `warp deploy` and `warp swap` latency on bench Jetson (LAN)
6. `msc bundle` full vs incremental wall time; bundle size for the fleet

Targets (to validate, not promises): eval warm < 3 s; no-op < 5 s; (3) < 30 s Tier 0 path; (4) ≥ 95% fewer rebuilt drvs; (5) Tier 1 < 10 s.

---

## 7. Implementation plan (milestones, junior-dev executable)

Conventions: every milestone ends with its tests green in CI + a short ADR (`docs/adr/`) recording surprises. "Verify" means: read the pinned manual page, write a probe, record the result — never assume.

**M0 — Environment + primitives spike (wk 1).**
Pin Determinate Nix (Appendix A) on your box, one Linux runner, one Studio VM. Implement the P1–P7 probes exactly as §6.1. Deliverables: `tests/probes/*`, CI job `probes`, ADR-000 with observed Nix version/behaviors. **Gate: all probes green on all three machines.**

**M1 — strata-lock MVP, no Backpack (wk 2–3).**
Haskell project vendoring cabal-install; implement solve→elaborate→emit for `ordinary` units; `--check`; golden + determinism tests (T-C1-*). Fixture workspace: 3 local packages + 15 Hackage deps. Skip: instantiations, custom Setup (demote + TODO).

**M2 — static eval + unit builder + shell (wk 3–5). Kill-switch baseline.**
`nixLower` (pure Nix) first; `mkPkgDb` (dbIface/dbFull); `mkUnit` Setup-driven for ordinary units; flake surface; dev shell incl. the `package-dbs:` verification ADR; benchmark harness + haskell.nix baseline capture. Everything input-addressed at first, then flip `addressing=ca` and make T-C3-4 row 1 pass (this forces the iface/out split to be real). **Gate: fixture repo fully builds; cutoff matrix green; eval budget green.** *This milestone alone already fixes R1 and most of R2 — it is the fallback product if later milestones slip.*

**M3 — CA hardening + cache ops (wk 5–6).**
`.hi` determinism soak; remote-builder CA trust config; Cachix realisation verification task → either "supported, tested" or anchor-fallback implemented (C9). Weekly kill-switch matrix job.

**M4 — dyndrv module granularity (wk 6–9).**
`strata-plan` per §C4 in Rust or Haskell (static musl binary, becomes a pinned store input): `ghc -M` parse → TH classify → `add-path` sources → emit module/assemble drvs (JSON, golden-frozen per P1) → text-hash convergence. `mkPlanner` in C2; `granularity=module` for fixture app; T-C4-* + end-to-end cutoff; wire benchmark (3)/(4). Roll out to real repo behind per-unit opt-in in `strata.toml`, expand as soak passes. **Gate: 30-module fixture rebuilds exactly 1 module + assemble on body edit; kill switch back to `unit` stays green.**

**M5 — Backpack (wk 9–11).**
Lock: elaborate `indefinite`/`instantiation` (ElaboratedInstallPlan → OpenUnitId/ModuleSubst; `hashModuleSubst` ids); T-C1-3. Build: `mkUnit` gains `--cid`/`--instantiate-with` + indefinite typecheck-only mode + iface/out split for both; T-C3-5 matrix. Shell: `strata projection` generator + HLS fixture. Docs: TH-from-indefinite limitation, projection workflow.

**M6 — cross + CUDA lanes (wk 11–13).**
linux-builder VM as `aarch64-linux` builder (features per Appendix A); jetpack-nixos overlay wiring; per-target lowering; accelerate-llvm-ptx fixture; lock-time ghc↔llvm assertion; nightly HIL smoke. x86 cross lane scaffolded, allowed-to-fail.

**M7 — msc + warp + devOverlay (wk 13–15).**
`msc bundle/verify/diff/install` per §C7 + VM device-sim test; `devOverlay` module + `strata-overlay` CLI + assertions; `warp deploy/swap/reconcile/status`; VM tests then bench-Jetson latency numbers into benchmarks (5)/(6).

**M8 — migration + hardening (wk 15–17).**
Snapshot→`snapshot.yaml` converter from your existing haskell.nix stackage; overlay shim so `nixosConfigurations` swap sources without edits; run both systems in CI comparing built exe closures per host; flip default; keep haskell.nix lane for two release trains; delete. Runbooks: "Nix upgrade procedure (probes first)", "dyndrv incident: flip granularity kill switch", "device taint audit".

Sequencing rationale: M2 is a complete, shippable improvement; M4/M5 are independent after M3; M7 depends only on M2. If dyndrv misbehaves in soak, you still land eval speed, granular unit rebuilds, Backpack, MSC, and warp.

---

## 8. Risk register & kill switches

| Risk | Likelihood | Blast radius | Mitigation / switch |
|---|---|---|---|
| dyndrv scheduler bugs in pinned Nix | med | dev builds stall | KS-1 `granularity=unit` (same lock); probes gate every Nix bump; vendored repro suite |
| CA realisation flow through Cachix immature | med | cache misses across farm | M3 verification; anchor-derivation fallback (C9); ssh-ng direct between builders |
| `.hi` nondeterminism edge (plugins, custom preprocessors) | low-med | lost cutoff (correctness intact) | soak test; per-unit `granularity=unit` demotion; keep pragma-omission flags dev-only |
| `builtins.wasm` interface drift (experimental) | med | eval breaks on upgrade | KS-2 `lowering=nix` golden-equal; wasm committed + pinned |
| recursive-nix restrictions surprise planner (no substitutes inside) | med | planner failures | planners depend only on explicit inputs; probes P2/P4 encode the contract |
| Backpack HLS gap frustrates devs | high | DX only | projection workflow (C5); CI indefinite typecheck keeps truth |
| accelerate/llvm-hs pins vs GHC bump | med | target lane blocked | tuple asserted at lock time; upgrade spikes in a branch lane |
| Mac VM builder throughput/uid-range quirks | med | aarch64 queue | benchmark early (M6); scale VM count; x86 cross lane as backup |
| Device drift via overlays | med | debugging confusion | taint surfacing + `warp reconcile`; overlays tmpfs-only; prod images assert-off |
| cabal-install internal API churn in strata-lock | high over years | lock tool maintenance | vendor + pin; upgrade only with golden-lock diff review |

Kill switches (flake-level `strata.settings`): `granularity`, `lowering`, `addressing`, `cacheAnchor` — each independently CI-exercised weekly (C9).

---

## 9. References

- Determinate Systems — *A new chapter for the Nix language, courtesy of WebAssembly* (`builtins.wasm`, experimental `wasm-builtin`): determinate.systems/blog/builtins-wasm
- Determinate Systems — *Determinate is the future of Nix today* (Wasm/WASI, provenance, flake schemas): determinate.systems/blog/determinate-nix-future
- Determinate Nix manual — experimental features (incl. `wasm-builtin`, `parallel-eval`, `dynamic-derivations`, `external-builders`) and `nix.conf`: manual.determinate.systems
- F. Zakaria — *An early look at Nix Dynamic Derivations*, *A practical application (MakeNix)*, *A lang2nix practicum (NpmNix)*: fzakaria.com (2025-03) — the text-hash + `outputOf` + recursive-nix planner pattern this spec productionizes
- pdtpartners/nix-ninja — `docs/dynamic-derivations.md` (JSON drv format, `dynamicOutputs`, `^out.drv^out` chaining) — closest prior art (C++/ninja)
- Nix reference manual — `builtins.outputOf`, experimental features, recursive-nix semantics (no arbitrary substitutions inside builders)
- haskell/cabal #6201 — instantiated Backpack units in `plan.json` are opaque (`+hash`) — motivates cabal-as-a-library in C1
- Cabal user's guide — *How to use Backpack* (instantiation = recompilation; Stack unsupported; TH-from-indefinite restriction)
- `Distribution.Backpack` (Cabal) — `OpenUnitId`, `ModuleSubst`, `hashModuleSubst`
- RFC 92 — dynamic derivations; John Ericson's PlanetNix 2025 Sandstone demo (context only; not a dependency)

---

## Appendix A — Nix configuration (build farm; pin exact DetNix release in `flake.nix` + `nix.conf` provisioning)

```ini
# every farm machine (dev boxes, runners, Studio VMs) — NOT devices
extra-experimental-features = nix-command flakes ca-derivations dynamic-derivations recursive-nix wasm-builtin parallel-eval
lazy-trees = true
eval-cores = 0                      # parallel eval (DetNix)
system-features = nixos-test benchmark big-parallel kvm recursive-nix uid-range
substituters = https://cache.nixos.org https://<team>.cachix.org
trusted-public-keys = … fleet-1:…
secret-key-files = /etc/nix/fleet-1.key        # CI signers only
builders = ssh-ng://studio-01-vm aarch64-linux … ; ssh-ng://runner-… x86_64-linux …
```
Devices: stock Determinate Nix, **no** extra experimental features, `trusted-public-keys` includes `fleet-1`.

Verify option spellings against the pinned manual during M0; record in ADR-000.

## Appendix B — GHC flag sets

```
dev:     -O0 -fomit-interface-pragmas -fignore-interface-pragmas -fhide-source-paths -fdiagnostics-color=never
release: -O2 -fhide-source-paths  (granularity forced to "unit"; full inlining across modules)
```
Rationale: dev `.hi` ≈ ABI only ⇒ maximal cutoff; release trades cutoff for optimization and is CI-only.

## Appendix C — Hermetic MSC derivation (optional release path)

Pure derivation via `pkgs.closureInfo { rootPaths = toplevels; }`: pack each registered path with in-sandbox `nix nar pack` (no daemon needed), hash, emit narinfos unsigned, tar the cache layout; CI signs narinfos afterwards (`nix store sign --store file://…` — verify in M7, fallback: sign paths in the local store pre-copy). Use for provenance-critical releases; the imperative `msc bundle` remains the daily driver.
