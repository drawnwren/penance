{ lib, pkgs }:

component:

pkgs.writeText "penance-component-${component.name or "unknown"}.drv-template.json" (builtins.toJSON {
  kind = "component";
  inherit component;
})
