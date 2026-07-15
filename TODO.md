## Limitations
1. I don't have a single coherent cabal.project. I might have i.e. server-dog that relies on server and also server-cat that relies on server. can I put a different cabal.project in each of these subdirs? 
**Cabal supports exactly that**, and Penance should too:

```text
monorepo/
├── server/
│   └── server.cabal
├── server-dog/
│   ├── server-dog.cabal
│   └── cabal.project
└── server-cat/
    ├── server-cat.cabal
    └── cabal.project
```

`server-dog/cabal.project`:

```cabal
packages:
  .
  ../server

index-state: 2026-04-01T00:00:00Z
```

`server-cat/cabal.project`:

```cabal
packages:
  .
  ../server

index-state: 2026-05-01T00:00:00Z
```

These are independent solver universes. They may select different dependency versions or flags while sharing the local `server` source.

**Current Penance Limitation**
Penance cannot consume this layout cleanly today. It currently conflates:

- The source-tree root.
- The directory containing `cabal.project`.
- The directory containing `penance.lock`.
- The base against which package paths are resolved.

`repent --project server-dog` correctly interprets `../server`, but writes paths relative to `server-dog`. Meanwhile, `penanceProject { src = ./server-dog; }` copies only that subtree into Nix, so `../server` is outside its source boundary.

Conversely:

```nix
penanceProject {
  src = ./.;
  cabalProject = "server-dog/cabal.project";
}
```

reads the nested project file but currently resolves its `packages:` entries relative to the monorepo root, rather than relative to `server-dog`.

So the honest answer is: **yes in Cabal; not properly in Penance yet.**

**What Penance Needs**
The API should separate these paths:

```nix
dog = penanceProject {
  src = ./.;
  projectRoot = "server-dog";
  cabalProject = "server-dog/cabal.project";
  lockFile = "server-dog/penance.lock";
  hackageNix = ./server-dog/nix/penance-hackage;
};

cat = penanceProject {
  src = ./.;
  projectRoot = "server-cat";
  cabalProject = "server-cat/cabal.project";
  lockFile = "server-cat/penance.lock";
  hackageNix = ./server-cat/nix/penance-hackage;
};
```

`repent` would canonicalize package paths against the shared source root:

```text
dog lock: server-dog, server
cat lock: server-cat, server
```

That gives each application an independent lock and dev shell without forcing a monorepo-wide solve. If both locks elaborate `server` identically, Nix can share its derivations. If their compiler, flags, or dependencies differ, they correctly produce separate units.

This is the model Penance should implement; requiring one root `cabal.project` for your example would reproduce exactly the monorepo coupling you are trying to avoid.
2. mode = "module";
currently enters the Wasm/recursive-Nix planner path, but generic penanceProject.packages still points components at the root planner derivation. The complete module-build pipeline exists in the benchmark fixtures, such as penanceBenchDyndrv, but is not yet generalized into the public project API. 
3. 
