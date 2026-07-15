# Examples

- [`basic`](basic/) is one lock-backed library with no Hackage dependencies.
- [`multi-package`](multi-package/) has independent `model` and `server`
  packages, builds, and development shells.

Both flakes follow the local checkout for demonstration. Replace the Penance
input URL when copying an example to another repository.

Because the checked-in flakes use the parent checkout as a path input, invoke
them from the repository root with an explicit override. A standalone
`path:./examples/...` flakeref is copied without its parent and cannot resolve
`path:../..` by itself.

```sh
nix flake check path:./examples/basic --override-input penance path:$PWD --no-build
nix flake check path:./examples/multi-package --override-input penance path:$PWD --no-build
```
