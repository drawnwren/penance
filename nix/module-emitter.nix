{ lib, pkgs }:

module:

pkgs.writeText "penance-module-${module.name or "unknown"}.drv-template.json" (builtins.toJSON {
  kind = "module";
  thAware = true;
  inherit module;
})
