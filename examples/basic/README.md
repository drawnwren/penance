# Basic Library

From the Penance repository root:

```sh
nix build path:./examples/basic --override-input penance path:$PWD
nix develop path:./examples/basic#simple-lib --override-input penance path:$PWD
```

After replacing the local Penance input with a published URL, ordinary
`nix build` and `nix develop` commands work from this directory.
