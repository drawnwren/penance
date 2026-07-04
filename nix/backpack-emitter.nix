{ lib, pkgs }:

unit:

pkgs.writeText "penance-backpack-${unit.unit or "unknown"}.drv-template.json" (builtins.toJSON {
  kind = "backpack";
  inherit unit;
})
