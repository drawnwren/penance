{ lib }:

lock:

assert lib.assertMsg (
  lock.schema or null == "penance/lock/2"
) "penance lowerer: expected penance/lock/2";

let
  sortBy = field: builtins.sort (left: right: left.${field} < right.${field});

  lowerComponent = component: {
    inherit (component)
      name
      unitId
      kind
      needsFullDb
      ;
    sourceDirs = component.sourceDirs or [ ];
    modules = component.modules or [ ];
    main = component.main or null;
    signatures = component.signatures or [ ];
    dependencies = component.dependencies or [ ];
    externalDepends = component.externalDepends or [ ];
    externalExeDepends = component.externalExeDepends or [ ];
    defaultExtensions = component.defaultExtensions or [ ];
  };

  lowerPackage = package: {
    inherit (package)
      name
      version
      path
      cabalFile
      setupType
      ;
    components = map lowerComponent (sortBy "name" (package.components or [ ]));
  };

  lowerExternal =
    external:
    {
      inherit (external)
        unitId
        name
        version
        flags
        component
        style
        source
        ;
      depends = external.depends or [ ];
      exeDepends = external.exeDepends or [ ];
      instantiatedWith = external.instantiatedWith or { };
    }
    // lib.optionalAttrs (external ? sdist) {
      inherit (external) sdist flagHash nixExpression;
    };

  externalUnits = lock.externalUnits or [ ];
  unitIds = map (unit: unit.unitId) externalUnits;
  unitsById = builtins.listToAttrs (
    map (unit: {
      name = unit.unitId;
      value = unit;
    }) externalUnits
  );
  externalEdges = lib.concatMap (
    unit:
    (unit.depends or [ ])
    ++ (unit.exeDepends or [ ])
    ++ builtins.attrValues (unit.instantiatedWith or { })
  ) externalUnits;
  componentEdges = lib.concatMap (
    package:
    lib.concatMap (
      component: (component.externalDepends or [ ]) ++ (component.externalExeDepends or [ ])
    ) (package.components or [ ])
  ) (lock.packages or [ ]);
  danglingEdges = builtins.filter (unitId: !(builtins.hasAttr unitId unitsById)) (
    externalEdges ++ componentEdges
  );
  validSource =
    unit:
    if unit.source == "ghc-boot" then
      !(unit ? sdist) && !(unit ? flagHash) && !(unit ? nixExpression)
    else if unit.source == "hackage" then
      unit ? sdist && unit ? flagHash && unit ? nixExpression
    else
      false;
in
assert lib.assertMsg (
  builtins.length unitIds == builtins.length (lib.unique unitIds)
) "penance lowerer: externalUnits contains duplicate unitId values";
assert lib.assertMsg (
  danglingEdges == [ ]
) "penance lowerer: lock contains a dangling unit-id edge `${builtins.head danglingEdges}`";
assert lib.assertMsg (builtins.all validSource externalUnits)
  "penance lowerer: external source/sdist invariant failed";
{
  schema = "penance/lowered-lock/2";
  inherit (lock) compiler indexState;
  packages = map lowerPackage (sortBy "name" (lock.packages or [ ]));
  externalUnits = map lowerExternal (sortBy "unitId" externalUnits);
}
// lib.optionalAttrs (lock ? packageSetHash) {
  inherit (lock) packageSetHash;
}
