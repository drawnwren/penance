{
  lib,
  pkgs,
  plannerWasm ? ./planner.wasm,
  penancePlanner ? null,
  ifaceCanonicalizer ? null,
  repent ? null,
}:

let
  callWasmPlanner = import ./shim.nix {
    inherit lib plannerWasm;
  };

  plannerDrv = import ./planner-drv.nix {
    inherit lib pkgs penancePlanner;
  };

  lowerLock = import ./lock-lowerer.nix { inherit lib; };

  lowerPackageSet =
    rawPackageSet:
    assert lib.assertMsg (
      rawPackageSet.schema or null == "penance/package-set/2"
    ) "penance package set: expected schema `penance/package-set/2`";
    let
      lowerRecipe =
        name: version: flagHash: recipe:
        assert lib.assertMsg (
          recipe ? flagHash && recipe ? nixExpression && recipe ? sdist
        ) "penance package set: package `${name}` is missing locked recipe fields";
        assert lib.assertMsg (
          recipe.flagHash == flagHash
        ) "penance package set: package `${name}` recipe key does not match its flagHash";
        assert lib.assertMsg (
          recipe.nixExpression == "${name}-${version}-${flagHash}.nix"
        ) "penance package set: package `${name}` has an invalid nixExpression";
        {
          inherit (recipe)
            flagHash
            nixExpression
            sdist
            ;
          flags = recipe.flags or { };
        };
      lowerPackage =
        name: package:
        assert lib.assertMsg (name != "") "penance package set: package name is required";
        assert lib.assertMsg (
          package ? version && package.version != ""
        ) "penance package set: package `${name}` version is required";
        assert lib.assertMsg (
          package ? recipes && package.recipes != { }
        ) "penance package set: package `${name}` has no locked recipes";
        {
          inherit (package) version;
          recipes = builtins.mapAttrs (lowerRecipe name package.version) package.recipes;
        };
      packages = builtins.mapAttrs lowerPackage (
        rawPackageSet.packages or (throw "penance package set: packages are required")
      );
    in
    {
      compiler = rawPackageSet.compiler or (throw "penance package set: compiler is required");
      indexState = rawPackageSet.indexState or (throw "penance package set: indexState is required");
      inherit packages;
      schema = "penance/package-set/2";
      stackage = rawPackageSet.stackage or null;
    };

  packageSetHashFor =
    packageSetData: "sha256:${builtins.hashString "sha256" (builtins.toJSON packageSetData)}";

  packageSetFor =
    {
      source,
      hackageNix,
      overrides ? { },
    }:
    let
      rawPackageSet = import source;
      data = lowerPackageSet rawPackageSet;
      basePackages = data.packages;
      overlay = if builtins.isFunction overrides then overrides else _final: _previous: overrides;
      packages = lib.fix (
        final:
        let
          changed = overlay final basePackages;
        in
        basePackages // builtins.mapAttrs (name: value: (basePackages.${name} or { }) // value) changed
      );
      metadata = {
        _type = "penance-package-set";
        inherit
          data
          hackageNix
          source
          ;
        inherit (data)
          compiler
          indexState
          schema
          stackage
          ;
        hash = packageSetHashFor data;
      };
    in
    packages
    // {
      __penance = metadata;
      overrideScope =
        extension:
        packageSetFor {
          inherit source hackageNix;
          overrides = lib.composeExtensions overlay (
            if builtins.isFunction extension then extension else _final: _previous: extension
          );
        };
    };

  validatePackageSetLock =
    packageSet: lock:
    let
      metadata = packageSet.__penance or { };
      hackageUnits = builtins.filter (unit: unit.source == "hackage") (lock.externalUnits or [ ]);
      mismatches = builtins.filter (
        unit:
        let
          package = metadata.data.packages.${unit.name} or null;
          recipe = if package == null then null else package.recipes.${unit.flagHash} or null;
          expected =
            if recipe == null then
              null
            else
              recipe
              // {
                inherit (unit) name;
                inherit (package) version;
              };
          actual = {
            inherit (unit)
              flagHash
              flags
              name
              nixExpression
              sdist
              version
              ;
          };
        in
        expected == null || expected != actual
      ) hackageUnits;
    in
    assert lib.assertMsg (
      metadata._type or null == "penance-package-set"
    ) "penanceProject: packageSet must come from penance.lib.<system>.packageSet";
    assert lib.assertMsg (
      lock.packageSetHash or null == metadata.hash
    ) "penanceProject: project lock does not reference package set `${metadata.hash}`";
    assert lib.assertMsg (
      lock.compiler == metadata.compiler
    ) "penanceProject: project lock compiler does not match the package set";
    assert lib.assertMsg (
      lock.indexState == metadata.indexState
    ) "penanceProject: project lock indexState does not match the package set";
    assert lib.assertMsg (mismatches == [ ])
      "penanceProject: Hackage unit `${(builtins.head mismatches).name}` is not permitted by the package set";
    lock;

  contentAddressedAttrs =
    enabled:
    lib.optionalAttrs enabled {
      __contentAddressed = true;
      outputHashMode = "recursive";
      outputHashAlgo = "sha256";
    };

  sourceManifestFor =
    src:
    let
      walk =
        prefix: dir:
        let
          entries = builtins.readDir dir;
        in
        lib.concatMap (
          name:
          let
            entryType = entries.${name};
            absPath = dir + "/${name}";
            relPath = if prefix == "" then name else "${prefix}/${name}";
          in
          if entryType == "directory" then
            walk relPath absPath
          else if entryType == "regular" then
            [
              {
                path = relPath;
                kind = "regular";
                sha256 = builtins.hashFile "sha256" absPath;
              }
            ]
          else if entryType == "symlink" then
            let
              targetHash = builtins.tryEval (builtins.hashFile "sha256" absPath);
            in
            if targetHash.success then
              [
                {
                  path = relPath;
                  kind = "regular";
                  sha256 = targetHash.value;
                }
              ]
            else
              throw "penanceProject: source symlink `${relPath}` must resolve to a regular file"
          else
            throw "penanceProject: unsupported source entry `${relPath}` of type `${entryType}`"
        ) (builtins.attrNames entries);
    in
    walk "" src;

  findCabalFile =
    src: packagePath:
    let
      dir = if packagePath == "." then src else src + "/${packagePath}";
      entries = builtins.readDir dir;
      cabalName =
        lib.findSingle (name: lib.hasSuffix ".cabal" name)
          (throw "penanceProject: no .cabal file found in package path `${packagePath}`")
          (throw "penanceProject: multiple .cabal files found in package path `${packagePath}`")
          (builtins.attrNames entries);
    in
    dir + "/${cabalName}";

  stripProjectComment = line: builtins.head (lib.splitString "--" line);

  projectLineRecords =
    cabalProjectText:
    let
      lines = lib.splitString "\n" cabalProjectText;
      record =
        rawLine:
        let
          withoutComment = stripProjectComment rawLine;
          text = lib.trim withoutComment;
        in
        {
          inherit text;
          indented =
            withoutComment != text && (lib.hasPrefix " " withoutComment || lib.hasPrefix "\t" withoutComment);
        };
    in
    builtins.filter (line: line.text != "") (map record lines);

  splitProjectPackageWords =
    value:
    lib.filter (part: part != "") (
      map (part: lib.trim (lib.removeSuffix "," part)) (
        lib.splitString " " (lib.replaceStrings [ "\n" "\t" ] [ " " " " ] value)
      )
    );

  collectProjectFieldPackages =
    field: records:
    let
      prefix = "${field}:";
      result =
        builtins.foldl'
          (
            state: line:
            if !line.indented then
              {
                collecting = lib.hasPrefix prefix line.text;
                chunks =
                  if lib.hasPrefix prefix line.text then
                    [ (lib.removePrefix prefix line.text) ] ++ state.chunks
                  else
                    state.chunks;
              }
            else if state.collecting then
              {
                collecting = true;
                chunks = [ line.text ] ++ state.chunks;
              }
            else
              state
          )
          {
            collecting = false;
            chunks = [ ];
          }
          records;
    in
    splitProjectPackageWords (lib.concatStringsSep "\n" (lib.reverseList result.chunks));

  simpleProjectPackages =
    cabalProjectText:
    let
      records = projectLineRecords cabalProjectText;
      inline =
        collectProjectFieldPackages "packages" records
        ++ collectProjectFieldPackages "optional-packages" records;
    in
    if inline == [ ] then [ "." ] else inline;

  collectLocalPackageManifests =
    src: cabalProjectText:
    map (
      packagePath:
      let
        cabalFile = findCabalFile src packagePath;
      in
      {
        path = packagePath;
        cabalText = builtins.readFile cabalFile;
      }
    ) (simpleProjectPackages cabalProjectText);

  compilerAttrFor =
    compiler:
    let
      version = lib.removePrefix "ghc-" compiler;
      packageAttr = "ghc${lib.replaceStrings [ "." ] [ "" ] version}";
    in
    if !lib.hasPrefix "ghc-" compiler || version == "" then
      throw "penanceProject: malformed compiler identifier `${compiler}`"
    else
      packageAttr;

  compilerPackagesFor =
    compiler:
    let
      packageAttr = compilerAttrFor compiler;
    in
    if builtins.hasAttr packageAttr pkgs.haskell.packages then
      builtins.getAttr packageAttr pkgs.haskell.packages
    else
      throw "penanceProject: compiler `${compiler}` is unavailable as pkgs.haskell.packages.${packageAttr}";

  compilerToolNames = [
    "cabal-fmt"
    "cabal-install"
    "fourmolu"
    "ghcid"
    "haskell-language-server"
    "hlint"
    "hoogle"
    "ormolu"
  ];

  compilerToolsFor =
    compiler:
    let
      compilerPackages = compilerPackagesFor compiler;
    in
    lib.genAttrs compilerToolNames (
      name:
      if builtins.hasAttr name compilerPackages then
        builtins.getAttr name compilerPackages
      else
        throw "penanceProject: compiler `${compiler}` does not provide developer tool `${name}`"
    );

  sanitizeName = value: lib.replaceStrings [ ":" "/" " " ] [ "-" "-" "-" ] value;

  dependencyPackageName = dependency: builtins.head (lib.splitString " " dependency);

  componentDependencyNames = component: map dependencyPackageName (component.dependencies or [ ]);

  modulePath =
    moduleName:
    if lib.hasSuffix ".hs" moduleName || lib.hasSuffix ".lhs" moduleName then
      moduleName
    else
      "${lib.replaceStrings [ "." ] [ "/" ] moduleName}.hs";

  normalizeSourceDir =
    dir:
    let
      noPrefix = lib.removePrefix "./" dir;
      noSuffix = lib.removeSuffix "/" noPrefix;
    in
    if noSuffix == "" then "." else noSuffix;

  componentForeignSourceFiles =
    component:
    (component.cSources or [ ]) ++ (component.includes or [ ]) ++ (component.installIncludes or [ ]);

  componentForeignSourceDirs =
    component: (component.includeDirs or [ ]) ++ (component.extraLibDirs or [ ]);

  componentSourceProjection =
    srcPath: pkg: component:
    let
      pkgRoot = if pkg.path == "." then srcPath else srcPath + "/${pkg.path}";
      rootString = toString pkgRoot;
      sourceDirs = map normalizeSourceDir (component.sourceDirs or [ "." ]);
      foreignDirs = map normalizeSourceDir (componentForeignSourceDirs component);
      foreignFiles = map normalizeSourceDir (componentForeignSourceFiles component);
      belongsToSourceDir =
        rel: dir: dir == "." || rel == dir || lib.hasPrefix "${dir}/" rel || lib.hasPrefix "${rel}/" dir;
      belongsToSourceFile = rel: file: rel == file || lib.hasPrefix "${rel}/" file;
    in
    builtins.path {
      path = pkgRoot;
      name = "penance-${sanitizeName pkg.name}-${sanitizeName component.name}-source";
      filter =
        path: type:
        let
          pathString = toString path;
          rel = if pathString == rootString then "" else lib.removePrefix "${rootString}/" pathString;
        in
        rel == ""
        || builtins.any (belongsToSourceDir rel) (sourceDirs ++ foreignDirs)
        || builtins.any (belongsToSourceFile rel) foreignFiles;
    };

  componentHaskellForeignFlags =
    component:
    map (dir: "-I${dir}") (component.includeDirs or [ ])
    ++ lib.concatMap (header: [
      "-#include"
      header
    ]) (component.includes or [ ]);

  componentCCompileFlags =
    component:
    [ "-optc-fPIC" ]
    ++ map (dir: "-optc-I${dir}") (component.includeDirs or [ ])
    ++ map (option: "-optc${option}") (component.ccOptions or [ ]);

  resolveProjectedPath =
    projectedSource: value:
    if lib.hasPrefix "/" value then value else "${projectedSource}/${normalizeSourceDir value}";

  componentResolvedIncludeDirs =
    projectedSource: component:
    map (resolveProjectedPath projectedSource) (component.includeDirs or [ ]);

  componentResolvedExtraLibDirs =
    projectedSource: component:
    map (resolveProjectedPath projectedSource) (component.extraLibDirs or [ ]);

  componentResolvedFrameworkDirs =
    projectedSource: component:
    map (resolveProjectedPath projectedSource) (component.extraFrameworkDirs or [ ]);

  componentLinkFlags =
    projectedSource: component:
    map (dir: "-L${dir}") (componentResolvedExtraLibDirs projectedSource component)
    ++ map (name: "-l${name}") (component.extraLibs or [ ])
    ++ map (option: "-optl${option}") (component.ldOptions or [ ])
    ++ lib.concatMap (dir: [
      "-framework-path"
      dir
    ]) (componentResolvedFrameworkDirs projectedSource component)
    ++ lib.concatMap (framework: [
      "-framework"
      framework
    ]) (component.frameworks or [ ]);

  shellArrayLines =
    values:
    lib.concatMapStringsSep "\n" (value: "              ${lib.escapeShellArg (toString value)}") values;

  heredocLines = values: lib.concatStringsSep "\n" (map toString values);

  externalUnitsById =
    lock:
    builtins.listToAttrs (
      map (unit: {
        name = unit.unitId;
        value = unit;
      }) (lock.externalUnits or [ ])
    );

  externalClosureIdsFor =
    unitsById: rootIds:
    map (item: item.key) (
      builtins.genericClosure {
        startSet = map (unitId: {
          key = unitId;
          value =
            unitsById.${unitId}
              or (throw "penanceProject: local component references missing external unit `${unitId}`");
        }) rootIds;
        operator =
          item:
          map (unitId: {
            key = unitId;
            value =
              unitsById.${unitId}
                or (throw "penanceProject: external unit `${item.key}` references missing unit `${unitId}`");
          }) ((item.value.depends or [ ]) ++ (item.value.exeDepends or [ ]));
      }
    );

  isExternalMainLibraryUnit =
    unit:
    let
      component = unit.component or null;
    in
    # Cabal plan.json uses both null and "lib" for public main libraries.
    component == null || component == "lib";

  isExternalLibraryUnit =
    unit:
    let
      component = unit.component or null;
    in
    isExternalMainLibraryUnit unit || (builtins.isString component && lib.hasPrefix "lib:" component);

  buildExternalSlice =
    hpkgs: contentAddressed: unit: package:
    let
      sliceName = "${sanitizeName unit.name}-${sanitizeName unit.version}-${unit.flagHash}";
      component = unit.component or null;
      registrationField =
        if isExternalMainLibraryUnit unit then
          "name"
        else if builtins.isString component && lib.hasPrefix "lib:" component then
          "lib-name"
        else
          throw "penanceProject: external unit `${unit.unitId}` is not a library component";
      registrationIdentity =
        if isExternalMainLibraryUnit unit then unit.name else lib.removePrefix "lib:" component;
    in
    pkgs.runCommand "penance-external-${sliceName}"
      (
        {
          nativeBuildInputs = [
            hpkgs.ghc
            pkgs.findutils
            pkgs.gnused
          ];
        }
        // contentAddressedAttrs contentAddressed
      )
      ''
        mkdir -p "$out/lib"
        ghc-pkg init "$out/lib/package.conf.d"

        find ${package}/lib -path '*/package.conf.d/*.conf' -type f -print \
          | while IFS= read -r candidate; do
              candidate_identity="$(
                sed -n 's/^${registrationField}:[[:space:]]*//p' "$candidate" \
                  | head -n 1
              )"
              if test "$candidate_identity" = ${lib.escapeShellArg registrationIdentity}; then
                printf '%s\n' "$candidate"
              fi
            done \
          | sort \
          > "$TMPDIR/confs"
        test "$(wc -l < "$TMPDIR/confs" | tr -d ' ')" = 1
        conf="$(cat "$TMPDIR/confs")"
        ghc-pkg --force --package-db "$out/lib/package.conf.d" register "$conf"
        ghc-pkg --package-db "$out/lib/package.conf.d" recache

        registration_name="$(sed -n 's/^name:[[:space:]]*//p' "$conf" | head -n 1)"
        test -n "$registration_name"
        ghc-pkg --package-db "$out/lib/package.conf.d" \
          field "$registration_name" id --simple-output > "$out/installed-id"
        test "$(wc -w < "$out/installed-id" | tr -d ' ')" = 1

        printf '%s\n' ${
          lib.escapeShellArg (
            builtins.toJSON {
              schema = "penance/external-unit/2";
              inherit (unit)
                unitId
                name
                version
                flags
                flagHash
                sdist
                ;
            }
          )
        } > "$out/metadata.json"
      '';

  externalContextFor =
    hpkgs: packageSet: hackageNix: contentAddressed: lock:
    let
      unitsById = externalUnitsById lock;
      closureIdsById = builtins.mapAttrs (
        unitId: _unit: externalClosureIdsFor unitsById [ unitId ]
      ) unitsById;
      packages = lib.fix (
        self:
        builtins.mapAttrs (
          unitId: unit:
          if unit.source == "ghc-boot" then
            hpkgs.${unit.name}
              or (throw "penanceProject: compiler package set has no GHC boot package `${unit.name}`")
          else
            let
              packageDefinition = if packageSet == null then { } else packageSet.${unit.name} or { };
              dependencyIds = (unit.depends or [ ]) ++ (unit.exeDepends or [ ]);
              dependencyUnits = map (dependencyId: unitsById.${dependencyId}) dependencyIds;
              # cabal2nix functions consume package-named arguments, while the
              # lock may contain several component-qualified units with that
              # name. listToAttrs provides the deterministic package argument;
              # unit identity remains intact in the lock graph and slices.
              namedDependencies = builtins.listToAttrs (
                map (dependency: {
                  inherit (dependency) name;
                  value = self.${dependency.unitId};
                }) dependencyUnits
              );
              expression = if hackageNix == null then null else hackageNix + "/${unit.nixExpression}";
              lockedSdist = pkgs.fetchurl {
                inherit (unit.sdist) url;
                hash = unit.sdist.sha256;
              };
              packageSource = packageDefinition.src or lockedSdist;
              expressionPackage =
                if expression != null && builtins.pathExists expression then
                  lib.callPackageWith (pkgs // hpkgs // namedDependencies) expression { }
                else
                  throw "penanceProject: locked Hackage unit `${unitId}` needs `${toString expression}`";
              defaultPackage = pkgs.haskell.lib.dontHaddock (
                pkgs.haskell.lib.dontCheck (
                  pkgs.haskell.lib.overrideCabal expressionPackage (_previous: {
                    src = packageSource;
                  })
                )
              );
              packageOverride = packageDefinition.package or null;
              componentOverride = packageDefinition.components.library or null;
              package =
                if packageOverride != null then
                  if builtins.isFunction packageOverride then
                    packageOverride {
                      inherit
                        hpkgs
                        namedDependencies
                        pkgs
                        unit
                        ;
                      previous = defaultPackage;
                    }
                  else
                    packageOverride
                else if componentOverride != null then
                  componentOverride
                else
                  defaultPackage;
            in
            if contentAddressed then
              package.overrideAttrs (_previous: {
                __contentAddressed = true;
              })
            else
              package
        ) unitsById
      );
      slices = builtins.mapAttrs (
        unitId: unit:
        if unit.source == "hackage" && isExternalLibraryUnit unit then
          let
            # Nixpkgs builds all libraries from a package together, so a main
            # library and its internal sublibraries must be sliced from the
            # same package derivation or their installed unit IDs will not
            # agree. Prefer the main library whose unit closure owns this
            # component; packages without a main library fall back to the
            # component's own derivation.
            owner = lib.findFirst (
              candidate:
              candidate.source == "hackage"
              && isExternalMainLibraryUnit candidate
              && candidate.name == unit.name
              && candidate.version == unit.version
              && candidate.flagHash == unit.flagHash
              && builtins.elem unitId closureIdsById.${candidate.unitId}
            ) null (builtins.attrValues unitsById);
            packageUnitId = if owner == null then unitId else owner.unitId;
          in
          buildExternalSlice hpkgs contentAddressed unit packages.${packageUnitId}
        else
          null
      ) unitsById;
    in
    {
      inherit
        unitsById
        closureIdsById
        packages
        slices
        ;
    };

  localPackagesByName =
    lock:
    builtins.listToAttrs (
      map (package: {
        inherit (package) name;
        value = package;
      }) (lock.packages or [ ])
    );

  localPackageClosure =
    lock: rootPackage:
    let
      packages = localPackagesByName lock;
    in
    builtins.genericClosure {
      startSet = [
        {
          key = rootPackage.name;
          value = rootPackage;
        }
      ];
      operator =
        item:
        map
          (name: {
            key = name;
            value = packages.${name};
          })
          (
            builtins.filter (name: builtins.hasAttr name packages) (
              lib.unique (lib.concatMap componentDependencyNames (item.value.components or [ ]))
            )
          );
    };

  shellProjectionFromLock =
    externalContext: lock: rootPackage:
    let
      localPackages =
        if rootPackage == null then
          lock.packages or [ ]
        else
          map (item: item.value) (localPackageClosure lock rootPackage);
      directExternalIds = lib.unique (
        lib.concatMap (
          package:
          lib.concatMap (
            component: (component.externalDepends or [ ]) ++ (component.externalExeDepends or [ ])
          ) (package.components or [ ])
        ) localPackages
      );
      externalUnitIds = lib.unique (
        lib.concatMap (unitId: externalContext.closureIdsById.${unitId}) directExternalIds
      );
      hackageUnitIds = builtins.filter (
        unitId: externalContext.unitsById.${unitId}.source == "hackage"
      ) externalUnitIds;
      externalPackages = map (unitId: externalContext.unitsById.${unitId}.name) hackageUnitIds;
    in
    {
      inherit
        externalPackages
        externalUnitIds
        hackageUnitIds
        ;
      localPackages = map (package: package.name) localPackages;
    };

  devShellFromLock =
    hpkgs: externalContext: includeRepent: packageSet: lock: rootPackage:
    let
      projection = shellProjectionFromLock externalContext lock rootPackage;
      ghc = hpkgs.ghcWithPackages (
        _packages: map (unitId: externalContext.packages.${unitId}) projection.hackageUnitIds
      );
    in
    pkgs.mkShell (
      {
        packages = [
          ghc
          pkgs.cabal-install
        ]
        ++ lib.optional (includeRepent && repent != null) repent;
        PENANCE_LOCK_SCHEMA = lock.schema;
        PENANCE_LOCK_PACKAGES = lib.concatStringsSep " " projection.externalPackages;
        PENANCE_LOCK_UNITS = lib.concatStringsSep " " projection.externalUnitIds;
        PENANCE_LOCAL_PACKAGES = lib.concatStringsSep " " projection.localPackages;
        PENANCE_COMPILER = lock.compiler;
        PENANCE_GHC_PKG = "${hpkgs.ghc}/bin/ghc-pkg";
        PENANCE_INDEX_STATE = lock.indexState;
        passthru = {
          penanceGhc = ghc;
          penanceProjection = projection;
        };
      }
      // lib.optionalAttrs (packageSet != null) {
        PENANCE_PACKAGE_SET = toString packageSet.__penance.source;
      }
      // lib.optionalAttrs (rootPackage != null) {
        PENANCE_PACKAGE = rootPackage.name;
        PENANCE_PACKAGE_PATH = rootPackage.path;
        PENANCE_CABAL_TARGET = rootPackage.name;
      }
    );

  packageDevShellsFromLock =
    hpkgs: externalContext: includeRepent: packageSet: lock:
    builtins.listToAttrs (
      map (package: {
        inherit (package) name;
        value = devShellFromLock hpkgs externalContext includeRepent packageSet lock package;
      }) (lock.packages or [ ])
    );

  componentBinName =
    component:
    if lib.hasPrefix "exe:" component.name then
      lib.removePrefix "exe:" component.name
    else if lib.hasPrefix "test:" component.name then
      lib.removePrefix "test:" component.name
    else if lib.hasPrefix "bench:" component.name then
      lib.removePrefix "bench:" component.name
    else
      sanitizeName component.name;

  stdDevGhcOptions = [
    "-O0"
    "-fomit-interface-pragmas"
    "-fignore-interface-pragmas"
    "-fhide-source-paths"
    "-fdiagnostics-color=never"
  ];

  componentNeedsFullDb = component: component.needsFullDb;

  componentExtensionFlags =
    component: map (extension: "-X${extension}") (component.defaultExtensions or [ ]);

  composePackageDb =
    hpkgs: contentAddressed: name: confDirs: orderAfter:
    pkgs.runCommand name
      (
        {
          buildInputs = orderAfter;
          nativeBuildInputs = [
            hpkgs.ghc
            pkgs.findutils
          ];
        }
        // contentAddressedAttrs contentAddressed
      )
      ''
              mkdir -p "$out/lib"
              ghc-pkg init "$out/lib/package.conf.d"

              while IFS= read -r conf_dir; do
                test -n "$conf_dir" || continue
                test -d "$conf_dir" || continue
                source_lib="$(dirname "$conf_dir")"
                for entry in "$source_lib"/*; do
                  name="$(basename "$entry")"
                  test "$name" != package.conf.d || continue
                  if [ ! -e "$out/lib/$name" ] && [ ! -L "$out/lib/$name" ]; then
                    ln -s "$entry" "$out/lib/$name"
                  fi
                done
                find -L "$conf_dir" -name '*.conf' -type f | sort | while IFS= read -r conf; do
                  unit_id="$(basename "$conf" .conf)"
                  if ghc-pkg --global --ipid field "$unit_id" id --simple-output >/dev/null 2>&1 \
                    || ghc-pkg --package-db "$out/lib/package.conf.d" --ipid field "$unit_id" id --simple-output >/dev/null 2>&1; then
                    continue
                  fi
                  ghc-pkg --force --package-db "$out/lib/package.conf.d" register "$conf"
                done
              done <<'CONF_DIRS'
        ${heredocLines confDirs}
        CONF_DIRS

              ghc-pkg --package-db "$out/lib/package.conf.d" recache
              ghc-pkg --global --package-db "$out/lib/package.conf.d" check
      '';

  componentFlagValues =
    {
      externalContext,
      pkg,
      component,
      componentBuilds,
      packageBuilds,
      localDbAttr,
    }:
    let
      dependencyNames = componentDependencyNames component;
      directExternalIds = component.externalDepends or [ ];
      directBootUnitIds = builtins.filter (
        unitId: externalContext.unitsById.${unitId}.source == "ghc-boot"
      ) directExternalIds;
      directHackageUnitIds = builtins.filter (
        unitId:
        let
          unit = externalContext.unitsById.${unitId};
        in
        unit.source == "hackage" && isExternalLibraryUnit unit
      ) directExternalIds;
      directBootPackageNames = map (unitId: externalContext.unitsById.${unitId}.name) directBootUnitIds;
      closureIds = lib.unique (
        lib.concatMap (unitId: externalContext.closureIdsById.${unitId}) directExternalIds
      );
      closureHackageUnitIds = builtins.filter (
        unitId:
        let
          unit = externalContext.unitsById.${unitId};
        in
        unit.source == "hackage" && isExternalLibraryUnit unit
      ) closureIds;
      localNames = builtins.filter (
        name: name != pkg.name && builtins.hasAttr name packageBuilds
      ) dependencyNames;
      hackageDbFlags = lib.concatMap (unitId: [
        "-package-db"
        "${externalContext.slices.${unitId}}/lib/package.conf.d"
      ]) closureHackageUnitIds;
      localFlags = lib.concatMap (
        name:
        [
          "-package-db"
          "${packageBuilds.${name}.components.lib.${localDbAttr}}/lib/package.conf.d"
          "-package"
          name
        ]
        ++ lib.optionals (localDbAttr == "dbFull") [
          "-L${packageBuilds.${name}.components.lib.dbFull}/lib"
        ]
      ) localNames;
      localLibFlags = lib.optionals (component.name != "lib" && builtins.elem pkg.name dependencyNames) (
        [
          "-package-db"
          "${componentBuilds.lib.${localDbAttr}}/lib/package.conf.d"
          "-package"
          pkg.name
        ]
        ++ lib.optionals (localDbAttr == "dbFull") [
          "-L${componentBuilds.lib.dbFull}/lib"
        ]
      );
      localDynamicLibraryDirs = lib.optionals (localDbAttr == "dbFull") (
        map (name: "${packageBuilds.${name}.components.lib.dbFull}/lib") localNames
        ++ lib.optional (
          component.name != "lib" && builtins.elem pkg.name dependencyNames
        ) "${componentBuilds.lib.dbFull}/lib"
      );
    in
    {
      flags = [
        "-hide-all-packages"
        "-no-user-package-db"
      ]
      ++ hackageDbFlags
      ++ localFlags
      ++ localLibFlags;
      inherit
        closureHackageUnitIds
        directBootPackageNames
        directBootUnitIds
        directHackageUnitIds
        localDynamicLibraryDirs
        ;
    };

  buildLocalLibrary = import ./component-builder.nix {
    inherit
      lib
      pkgs
      ifaceCanonicalizer
      modulePath
      componentDependencyNames
      componentFlagValues
      stdDevGhcOptions
      componentSourceProjection
      shellArrayLines
      heredocLines
      composePackageDb
      componentExtensionFlags
      componentNeedsFullDb
      componentHaskellForeignFlags
      componentCCompileFlags
      componentLinkFlags
      componentResolvedIncludeDirs
      componentResolvedExtraLibDirs
      componentResolvedFrameworkDirs
      sanitizeName
      ;
  };

  buildLocalProgram =
    {
      hpkgs,
      srcPath,
      lock,
      ghcOptions,
      runExecutables,
      pkg,
      component,
      componentBuilds,
      packageBuilds,
      externalContext,
      contentAddressed,
    }:
    let
      sourceDirs = component.sourceDirs or [ "." ];
      mainPath = modulePath component.main;
      binName = componentBinName component;
      projectedSource = componentSourceProjection srcPath pkg component;
      compileLocalDbAttr = if componentNeedsFullDb component then "dbFull" else "dbIface";
      compileFlagValues = componentFlagValues {
        inherit
          externalContext
          pkg
          component
          componentBuilds
          packageBuilds
          ;
        localDbAttr = compileLocalDbAttr;
      };
      compileFlags =
        compileFlagValues.flags
        ++ componentExtensionFlags component
        ++ componentHaskellForeignFlags component
        ++ stdDevGhcOptions
        ++ ghcOptions
        ++ lib.optionals pkgs.stdenv.hostPlatform.isDarwin [ "-dynamic-too" ];
      linkFlagValues = componentFlagValues {
        inherit
          externalContext
          pkg
          component
          componentBuilds
          packageBuilds
          ;
        localDbAttr = "dbFull";
      };
      linkFlags =
        linkFlagValues.flags
        ++ componentLinkFlags projectedSource component
        ++ stdDevGhcOptions
        ++ ghcOptions
        ++ lib.optionals pkgs.stdenv.hostPlatform.isDarwin [ "-dynamic" ];
      cSources = component.cSources or [ ];
      cCompileFlags = componentCCompileFlags component;
      objectSuffix = if pkgs.stdenv.hostPlatform.isDarwin then "*.dyn_o" else "*.o";
      directPackageIdShell =
        values:
        lib.concatMapStringsSep "\n" (packageName: ''
          package_id="$(ghc-pkg --global field ${lib.escapeShellArg packageName} id --simple-output)"
          test "$(printf '%s\n' "$package_id" | wc -w | tr -d ' ')" = 1
          package_flags+=("-package-id" "$package_id")
        '') values.directBootPackageNames
        + "\n"
        + lib.concatMapStringsSep "\n" (unitId: ''
          package_id="$(cat ${externalContext.slices.${unitId}}/installed-id)"
          test -n "$package_id"
          package_flags+=("-package-id" "$package_id")
        '') values.directHackageUnitIds;
      packageName = "penance-${sanitizeName pkg.name}-${sanitizeName component.name}";
      runField =
        if component.kind == "test-suite" then
          "test"
        else if component.kind == "benchmark" then
          "benchmark"
        else
          "output";
      compileDrv =
        pkgs.runCommand "${packageName}-compile"
          (
            {
              nativeBuildInputs = [
                hpkgs.ghc
                pkgs.findutils
              ];
              passthru.localDependencyDb = compileLocalDbAttr;
            }
            // contentAddressedAttrs contentAddressed
          )
          ''
                    mkdir -p "$out/build" build foreign-build
                    cp -R ${projectedSource} source
                    chmod -R u+w source
                    cd source

                    common_flags=(
            ${shellArrayLines (
              compileFlags
              ++ map (dir: "-i${dir}") sourceDirs
              ++ [
                "-odir"
                "../build"
                "-hidir"
                "../build"
                "-outputdir"
                "../build"
              ]
            )}
                    )
                    package_flags=()
            ${directPackageIdShell compileFlagValues}
                    common_flags+=("''${package_flags[@]}")
                    dynamic_library_path=${lib.escapeShellArg (lib.concatStringsSep ":" compileFlagValues.localDynamicLibraryDirs)}
                    export DYLD_LIBRARY_PATH="$dynamic_library_path''${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
                    export LD_LIBRARY_PATH="$dynamic_library_path''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

                    main_source=""
                    while IFS= read -r source_dir; do
                      candidate="$source_dir/${mainPath}"
                      if [ -f "$candidate" ]; then
                        main_source="$candidate"
                        break
                      fi
                    done <<'SOURCE_DIRS'
            ${heredocLines sourceDirs}
            SOURCE_DIRS
                    test -n "$main_source"

                    ghc --make -no-link "''${common_flags[@]}" "$main_source"

                    (cd ../build && find . \( -name '*.o' -o -name '*.dyn_o' -o -name '*.hi' -o -name '*.dyn_hi' \) -type f | sort | while IFS= read -r artifact; do
                      mkdir -p "$out/build/$(dirname "$artifact")"
                      cp "$artifact" "$out/build/$artifact"
                    done)

                    c_flags=(
            ${shellArrayLines cCompileFlags}
                    )
                    c_source_index=0
                    while IFS= read -r c_source; do
                      test -n "$c_source" || continue
                      test -f "$c_source"
                      ghc -c "''${c_flags[@]}" "$c_source" \
                        -o "../foreign-build/c-source-$c_source_index.o"
                      c_source_index=$((c_source_index + 1))
                    done <<'C_SOURCES'
            ${heredocLines cSources}
            C_SOURCES
                    if [ "$c_source_index" -gt 0 ]; then
                      mkdir -p "$out/build/foreign"
                      cp ../foreign-build/*.o "$out/build/foreign/"
                    fi

                    {
                      find "$out/build" -name ${lib.escapeShellArg objectSuffix} -type f
                      find "$out/build/foreign" -name '*.o' -type f 2>/dev/null || true
                    } | sort -u > "$out/objects"
                    test -s "$out/objects"

                    printf '%s\n' ${
                      lib.escapeShellArg (
                        builtins.toJSON {
                          schema = "penance/local-program-compile/1";
                          package = pkg.name;
                          inherit (pkg) version;
                          component = component.name;
                          inherit (component) kind;
                          lockSchema = lock.schema;
                          localDependencyDb = compileLocalDbAttr;
                          inherit (compileFlagValues) directHackageUnitIds;
                        }
                      )
                    } > "$out/metadata.json"
          '';
      linkDrv =
        pkgs.runCommand packageName
          (
            {
              nativeBuildInputs = [
                hpkgs.ghc
              ];
            }
            // contentAddressedAttrs contentAddressed
          )
          ''
                    mkdir -p "$out/bin"

                    object_args=()
                    while IFS= read -r object; do
                      test -n "$object" || continue
                      object_args+=("$object")
                    done < ${compileDrv}/objects

                    link_flags=(
            ${shellArrayLines linkFlags}
                    )
                    package_flags=()
            ${directPackageIdShell linkFlagValues}
                    link_flags+=("''${package_flags[@]}")

                    ghc "''${link_flags[@]}" "''${object_args[@]}" -o "$out/bin/${binName}"
            ${lib.optionalString runExecutables ''
              "$out/bin/${binName}" > "$out/${runField}.txt"
            ''}

                    printf '%s\n' ${
                      lib.escapeShellArg (
                        builtins.toJSON {
                          schema = "penance/local-program-link/1";
                          package = pkg.name;
                          inherit (pkg) version;
                          component = component.name;
                          inherit (component) kind;
                          lockSchema = lock.schema;
                          compile = compileDrv;
                          inherit (linkFlagValues) directHackageUnitIds;
                        }
                      )
                    } > "$out/metadata.json"
          '';
    in
    linkDrv
    // {
      compile = compileDrv;
    };

  buildLocalComponent =
    args@{
      hpkgs,
      srcPath,
      lock,
      ghcOptions,
      pkg,
      component,
      componentBuilds,
      packageBuilds,
      externalContext,
      contentAddressed,
      ...
    }:
    if component.kind == "library" then
      buildLocalLibrary {
        inherit
          hpkgs
          srcPath
          lock
          ghcOptions
          pkg
          component
          componentBuilds
          packageBuilds
          externalContext
          contentAddressed
          ;
      }
    else if
      component.kind == "executable" || component.kind == "test-suite" || component.kind == "benchmark"
    then
      buildLocalProgram args
    else
      throw "penanceProject: unsupported component kind `${component.kind}`";

  surfaceFromLock =
    lock:
    let
      packages = map (pkg: {
        package = pkg.name;
        inherit (pkg) version;
        components = map (component: {
          inherit (component) kind;
          component = component.name;
        }) (pkg.components or [ ]);
      }) (lock.packages or [ ]);
      modules = lib.concatMap (
        pkg:
        lib.concatMap (
          component:
          let
            listedModules = builtins.filter (module: module != (component.main or null)) (
              component.modules or [ ]
            );
            moduleNames = listedModules ++ lib.optional ((component.main or null) != null) "Main";
          in
          map (module: {
            package = pkg.name;
            component = component.name;
            inherit module;
          }) moduleNames
        ) (pkg.components or [ ])
      ) (lock.packages or [ ]);
    in
    pkgs.runCommand "penance-lock-surface" { } ''
      mkdir -p "$out/packages" "$out/modules"
      printf '%s\n' ${
        lib.escapeShellArg (
          builtins.toJSON {
            schema = "penance/package-graph/1";
            inherit packages;
          }
        )
      } > "$out/packages/package-graph.json"
      printf '%s\n' ${
        lib.escapeShellArg (
          builtins.toJSON {
            schema = "penance/module-graph/1";
            inherit modules;
          }
        )
      } > "$out/modules/module-graph.json"
    '';

  lockContextFor =
    packageSet: hackageNix: contentAddressed: lock:
    let
      hpkgs = compilerPackagesFor lock.compiler;
      externalContext = externalContextFor hpkgs packageSet hackageNix contentAddressed lock;
    in
    {
      inherit hpkgs externalContext;
    };

  packageAttrsFromLock =
    srcPath: lockContext: lock: ghcOptions: runExecutables: contentAddressed:
    let
      inherit (lockContext) hpkgs externalContext;
      packageBuilds = builtins.listToAttrs (
        map (
          pkg:
          let
            componentBuilds = builtins.listToAttrs (
              map (component: {
                inherit (component) name;
                value = buildLocalComponent {
                  inherit
                    hpkgs
                    srcPath
                    lock
                    ghcOptions
                    runExecutables
                    pkg
                    component
                    componentBuilds
                    packageBuilds
                    externalContext
                    contentAddressed
                    ;
                };
              }) (pkg.components or [ ])
            );
            packageDefault =
              componentBuilds.lib or (componentBuilds."exe:${pkg.name}"
                or (pkgs.writeText "penance-${sanitizeName pkg.name}-components.json" (
                  builtins.toJSON {
                    inherit (pkg) name version;
                    components = builtins.attrNames componentBuilds;
                  }
                ))
              );
          in
          {
            inherit (pkg) name;
            value = packageDefault // {
              components = componentBuilds;
              externalPackages = externalContext.packages;
              externalUnits = externalContext.slices;
            };
          }
        ) (lock.packages or [ ])
      );
      componentChecks = builtins.listToAttrs (
        lib.concatMap (
          pkg:
          let
            components = packageBuilds.${pkg.name}.components;
          in
          map
            (component: {
              name = "${sanitizeName pkg.name}-${sanitizeName component.name}";
              value =
                pkgs.runCommand "penance-check-${sanitizeName pkg.name}-${sanitizeName component.name}" { }
                  ''
                    mkdir -p "$out"
                    ${components.${component.name}}/bin/${componentBinName component} > "$out/output.txt"
                  '';
            })
            (
              builtins.filter (component: component.kind == "test-suite" || component.kind == "benchmark") (
                pkg.components or [ ]
              )
            )
        ) (lock.packages or [ ])
      );
    in
    {
      packages = packageBuilds;
      checks = componentChecks;
      surface = surfaceFromLock lock;
    };

  packageAttrs =
    rootPlanner: skeleton:
    builtins.listToAttrs (
      map (pkg: {
        inherit (pkg) name;
        value = rootPlanner // {
          components = builtins.listToAttrs (
            map (component: {
              name = component;
              value = rootPlanner;
            }) pkg.components
          );
          instantiations = builtins.listToAttrs (
            map (instantiation: {
              name = instantiation.unit;
              value = rootPlanner;
            }) skeleton.backpack.expectedInstantiations
          );
        };
      }) skeleton.localPackages
    );
in
{
  inherit lowerLock;
  packageSet = packageSetFor;

  penanceProject =
    {
      # `src` is the caller-owned cache boundary. Every admitted file is
      # planner- and projection-relevant; filter before this call when needed.
      src,
      projectRoot ? ".",
      lockFile ? "penance.lock",
      compiler ? null,
      index-state ? null,
      cabalProject ? "cabal.project",
      mode ? "component",
      flags ? { },
      ghcOptions ? [ ],
      hackageNix ? null,
      packageSet ? null,
      runExecutables ? false,
      includeRepent ? false,
      contentAddressed ? false,
      lockOverride ? null,
    }:
    let
      sourceRoot = src;
      srcPath = if projectRoot == "." then sourceRoot else sourceRoot + "/${projectRoot}";
      lockPath = if builtins.isPath lockFile then lockFile else srcPath + "/${lockFile}";
      hasLock = lockOverride != null || builtins.pathExists lockPath;
      rawLock =
        if lockOverride != null then
          lockOverride
        else if hasLock then
          builtins.fromJSON (builtins.readFile lockPath)
        else
          null;
      loweredLock = if rawLock != null then lowerLock rawLock else null;
      lock =
        if loweredLock != null && packageSet != null then
          validatePackageSetLock packageSet loweredLock
        else if loweredLock != null && loweredLock ? packageSetHash then
          throw "penanceProject: lock references a package set but no `packageSet` was provided"
        else
          loweredLock;
      projectCompiler =
        if compiler != null then
          compiler
        else if lock != null then
          lock.compiler
        else
          throw "penanceProject: `compiler` is required when no penance.lock exists";
      projectIndexState =
        if index-state != null then
          index-state
        else if lock != null then
          lock.indexState
        else
          throw "penanceProject: `index-state` is required when no penance.lock exists";
      useLockComponents = mode == "component" && hasLock && lock.schema == "penance/lowered-lock/2";
      effectiveHackageNix =
        if packageSet != null then
          if hackageNix != null && hackageNix != packageSet.__penance.hackageNix then
            throw "penanceProject: hackageNix conflicts with the selected package set"
          else
            packageSet.__penance.hackageNix
        else
          hackageNix;
      lockContext =
        if useLockComponents then
          lockContextFor packageSet effectiveHackageNix contentAddressed lock
        else
          null;
      supportsWasmPlanner = builtins ? wasm;
      cabalProjectPath = srcPath + "/${cabalProject}";
      cabalProjectText = builtins.readFile cabalProjectPath;
      localPackageManifests = collectLocalPackageManifests srcPath cabalProjectText;
      sourceManifest = sourceManifestFor srcPath;
      skeleton = callWasmPlanner {
        src = srcPath;
        compiler = projectCompiler;
        index-state = projectIndexState;
        inherit
          cabalProjectText
          flags
          localPackageManifests
          mode
          sourceManifest
          ;
      };
      rootPlanner = plannerDrv {
        src = srcPath;
        compiler = projectCompiler;
        index-state = projectIndexState;
        inherit skeleton;
        granularity = mode;
      };
      lockBuild =
        if useLockComponents then
          packageAttrsFromLock srcPath lockContext lock ghcOptions runExecutables contentAddressed
        else
          null;
    in
    {
      compiler = projectCompiler;
      indexState = projectIndexState;
      packageSetHash = if packageSet == null then null else packageSet.__penance.hash;
      inherit projectRoot;
      tools = compilerToolsFor projectCompiler;
      packages = if useLockComponents then lockBuild.packages else packageAttrs rootPlanner skeleton;
      checks =
        lib.optionalAttrs supportsWasmPlanner { planner = rootPlanner; }
        // lib.optionalAttrs useLockComponents lockBuild.checks;
      devShells =
        if useLockComponents then
          {
            default =
              devShellFromLock lockContext.hpkgs lockContext.externalContext includeRepent packageSet lock
                null;
            packages =
              packageDevShellsFromLock lockContext.hpkgs lockContext.externalContext includeRepent packageSet
                lock;
          }
        else
          { };
      apps = { };
      surface = if useLockComponents then lockBuild.surface else rootPlanner;
      capabilities = {
        lockEvaluation = useLockComponents;
        wasmPlanner = supportsWasmPlanner;
        dynamicDerivations = supportsWasmPlanner && mode == "module";
      };
      drvGraph =
        if supportsWasmPlanner then
          rootPlanner
        else
          throw "penanceProject.drvGraph requires a Nix evaluator with builtins.wasm; lock-backed component packages remain available";
    };
}
