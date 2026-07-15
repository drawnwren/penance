# Independent Package Shells

`example-model` is a local library. `example-server` is a separate executable
whose Cabal dependency on the model determines the Nix edge.

```sh
nix build path:./examples/multi-package#model --override-input penance path:$PWD
nix build path:./examples/multi-package#server --override-input penance path:$PWD
nix develop path:./examples/multi-package#model --override-input penance path:$PWD
nix develop path:./examples/multi-package#server --override-input penance path:$PWD
```

Run these commands from the Penance repository root. After replacing the local
Penance input with a published URL, the usual commands work from this example
directory without an override.
