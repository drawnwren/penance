# Backpack Model

`penance` follows GHC and Cabal's Backpack model directly.

- An indefinite unit is a component with required signatures.
- A hole is a signature module name that must be supplied by an instantiation.
- An instantiation maps each hole to a concrete `(UnitId, ModuleName)` provider.
- A definite unit-id is Cabal/GHC's hash for an indefinite unit plus its instantiation.
- Mixin linking is Cabal's resolution of `mixins:` into concrete hole mappings.

The Wasm planner already extracts signature-bearing components into `backpack.indefiniteUnits`. It also records simple expected instantiations from mixin entries using either `Hole = Provider` or `Provider as Hole` syntax. The Haskell planner is the source of truth for final unit-ids and mixin resolution.

## Derivation Families

For each indefinite unit:

- `signatures/<unit>:typecheck.drv` typechecks signatures and modules with `-fno-code`
- `signatures/<unit>:<Sig.Name>.drv` emits one signature interface per `.hsig`

For each instantiation:

- component mode emits `instantiations/<full-unit-id>.drv`
- module mode emits `instantiations/<full-unit-id>/<Module>.drv`

Implementation modules are compiled once per distinct instantiation because object code and interfaces depend on hole resolution.

## Worked Example

Suppose `abstract-map` exposes:

```cabal
library
  exposed-modules: UsesMap
  signatures: Data.MyAbstractMap
```

Two consumers instantiate the hole:

```cabal
mixins:
  intmap-impl (Data.IntMapImpl as Data.MyAbstractMap)
```

```cabal
mixins:
  hashmap-impl (Data.HashMapImpl as Data.MyAbstractMap)
```

Cabal/GHC computes two distinct definite unit-ids. `penance` reuses those unit-ids verbatim and emits separate instantiation graphs. If `Data.IntMapImpl` changes its exported interface, only the `intmap-impl` instantiation and its downstream consumers rebuild.

For signature merging, if two dependencies contribute `Data.MyAbstractMap`, the planner emits a merge node whose inputs are both signature interfaces. The merged signature identity participates in downstream cache keys, but it is not treated as an ordinary source module.
