{ lib
, pkgs
, plannerWasm ? ./planner.wasm
, penancePlanner ? null
, ifaceCanonicalizer ? null
, repent ? null
}:

let
  callWasmPlanner = import ./shim.nix {
    inherit lib plannerWasm;
  };

  plannerDrv = import ./planner-drv.nix {
    inherit lib pkgs penancePlanner;
  };

  sourceManifestFor = src:
    let
      walk = prefix: dir:
        let
          entries = builtins.readDir dir;
        in
          lib.concatMap
            (name:
              let
                entryType = entries.${name};
                absPath = dir + "/${name}";
                relPath = if prefix == "" then name else "${prefix}/${name}";
              in
                if entryType == "directory" then
                  walk relPath absPath
                else if entryType == "regular" then
                  [{
                    path = relPath;
                    kind = "regular";
                    sha256 = builtins.hashFile "sha256" absPath;
                  }]
                else
                  throw "penanceProject: unsupported source entry `${relPath}` of type `${entryType}`")
            (builtins.attrNames entries);
    in
      walk "" src;

  findCabalFile = src: packagePath:
    let
      dir = if packagePath == "." then src else src + "/${packagePath}";
      entries = builtins.readDir dir;
      cabalName = lib.findSingle
        (name: lib.hasSuffix ".cabal" name)
        (throw "penanceProject: no .cabal file found in package path `${packagePath}`")
        (throw "penanceProject: multiple .cabal files found in package path `${packagePath}`")
        (builtins.attrNames entries);
    in
      dir + "/${cabalName}";

  stripProjectComment = line:
    builtins.head (lib.splitString "--" line);

  projectLineRecords = cabalProjectText:
    let
      lines = lib.splitString "\n" cabalProjectText;
      record = rawLine:
        let
          withoutComment = stripProjectComment rawLine;
          text = lib.trim withoutComment;
        in {
          inherit text;
          indented =
            withoutComment != text
            && (lib.hasPrefix " " withoutComment || lib.hasPrefix "\t" withoutComment);
        };
    in
      builtins.filter (line: line.text != "") (map record lines);

  splitProjectPackageWords = value:
    lib.filter (part: part != "")
      (map
        (part: lib.trim (lib.removeSuffix "," part))
        (lib.splitString " " (lib.replaceStrings [ "\n" "\t" ] [ " " " " ] value)));

  collectProjectFieldPackages = field: records:
    let
      prefix = "${field}:";
      result = builtins.foldl'
        (state: line:
          if !line.indented then {
            collecting = lib.hasPrefix prefix line.text;
            chunks =
              if lib.hasPrefix prefix line.text then
                [ (lib.removePrefix prefix line.text) ] ++ state.chunks
              else
                state.chunks;
          } else if state.collecting then {
            collecting = true;
            chunks = [ line.text ] ++ state.chunks;
          } else
            state)
        { collecting = false; chunks = []; }
        records;
    in
      splitProjectPackageWords
        (lib.concatStringsSep "\n" (lib.reverseList result.chunks));

  simpleProjectPackages = cabalProjectText:
    let
      records = projectLineRecords cabalProjectText;
      inline =
        collectProjectFieldPackages "packages" records
        ++ collectProjectFieldPackages "optional-packages" records;
    in
      if inline == [] then [ "." ] else inline;

  collectLocalPackageManifests = src: cabalProjectText:
    map
      (packagePath:
        let cabalFile = findCabalFile src packagePath;
        in {
          path = packagePath;
          cabalText = builtins.readFile cabalFile;
        })
      (simpleProjectPackages cabalProjectText);

  compilerPackagesFor = compiler:
    let
      version = lib.removePrefix "ghc-" compiler;
      packageAttr = "ghc${lib.replaceStrings [ "." ] [ "" ] version}";
    in
      if !lib.hasPrefix "ghc-" compiler || version == "" then
        throw "penanceProject: malformed compiler identifier `${compiler}`"
      else if builtins.hasAttr packageAttr pkgs.haskell.packages then
        builtins.getAttr packageAttr pkgs.haskell.packages
      else
        throw "penanceProject: compiler `${compiler}` is unavailable as pkgs.haskell.packages.${packageAttr}";

  sanitizeName = value:
    lib.replaceStrings [ ":" "/" " " ] [ "-" "-" "-" ] value;

  dependencyPackageName = dependency:
    builtins.head (lib.splitString " " dependency);

  componentDependencyNames = component:
    map dependencyPackageName (component.dependencies or []);

  modulePath = moduleName:
    if lib.hasSuffix ".hs" moduleName || lib.hasSuffix ".lhs" moduleName then
      moduleName
    else
      "${lib.replaceStrings [ "." ] [ "/" ] moduleName}.hs";

  normalizeSourceDir = dir:
    let
      noPrefix = lib.removePrefix "./" dir;
      noSuffix = lib.removeSuffix "/" noPrefix;
    in
      if noSuffix == "" then "." else noSuffix;

  componentSourceProjection = srcPath: pkg: component:
    let
      pkgRoot = if pkg.path == "." then srcPath else srcPath + "/${pkg.path}";
      rootString = toString pkgRoot;
      sourceDirs = map normalizeSourceDir (component.sourceDirs or [ "." ]);
      belongsToSourceDir = rel: dir:
        dir == "."
        || rel == dir
        || lib.hasPrefix "${dir}/" rel
        || lib.hasPrefix "${rel}/" dir;
    in
      builtins.path {
        path = pkgRoot;
        name = "penance-${sanitizeName pkg.name}-${sanitizeName component.name}-source";
        filter = path: type:
          let
            pathString = toString path;
            rel =
              if pathString == rootString then
                ""
              else
                lib.removePrefix "${rootString}/" pathString;
          in
            rel == ""
            || builtins.any (belongsToSourceDir rel) sourceDirs;
      };

  shellArrayLines = values:
    lib.concatMapStringsSep "\n" (value: "              ${lib.escapeShellArg (toString value)}") values;

  heredocLines = values:
    lib.concatStringsSep "\n" (map toString values);

  externalUnitsByName = lock:
    builtins.listToAttrs (map
      (unit: {
        name = unit.name;
        value = unit;
      })
      (lock.externalUnits or []));

  externalUnitFor = lock: name:
    (externalUnitsByName lock).${name} or null;

  externalUnitNamesBySource = lock: source:
    map (unit: unit.name) (builtins.filter (unit: unit.source == source) (lock.externalUnits or []));

  bootDependencyNames = lock: dependencyNames:
    builtins.filter
      (name:
        let unit = externalUnitFor lock name;
        in unit != null && unit.source == "ghc-boot")
      dependencyNames;

  hackageDependencyNames = lock: dependencyNames:
    builtins.filter
      (name:
        let unit = externalUnitFor lock name;
        in unit != null && unit.source == "hackage")
      dependencyNames;

  lockedHackagePackageSet = hpkgs: hackageNix: lock:
    hpkgs.override {
      overrides = final: previous:
        builtins.listToAttrs (map
          (unit:
            let
              sdist = pkgs.fetchurl {
                inherit (unit.sdist) url;
                hash = unit.sdist.sha256;
              };
              packageArgs = lib.optionalAttrs (unit.name == "zlib") { inherit (pkgs) zlib; };
              expression =
                if hackageNix == null then null
                else hackageNix + "/${unit.name}-${unit.version}.nix";
              usePackageSet =
                builtins.hasAttr unit.name previous
                && (builtins.getAttr unit.name previous).version == unit.version;
              package =
                if usePackageSet then
                  builtins.getAttr unit.name previous
                else if expression != null && builtins.pathExists expression then
                  final.callPackage expression packageArgs
                else
                  throw "penanceProject: locked Hackage package `${unit.name}-${unit.version}` needs a committed cabal2nix expression at `${toString expression}`";
              lockedPackage =
                if usePackageSet then package
                else pkgs.haskell.lib.overrideCabal package (_previous: { src = sdist; });
            in {
              name = unit.name;
              value = pkgs.haskell.lib.dontHaddock (
                pkgs.haskell.lib.dontCheck (
                  lockedPackage
                )
              );
            })
          (builtins.filter (unit: unit.source == "hackage") (lock.externalUnits or [])));
    };

  buildExternalUnit = lockedHpkgs: packageEnvironment: unit:
    let
      unitId = "${unit.name}-${unit.version}";
      packageLib = "${packageEnvironment}/lib/ghc-${lockedHpkgs.ghc.version}/lib";
    in
      pkgs.runCommand "penance-external-${unitId}" {} ''
        mkdir -p "$out/lib"
        for entry in ${packageLib}/*; do
          ln -s "$entry" "$out/lib/$(basename "$entry")"
        done
        ${lockedHpkgs.ghc}/bin/ghc-pkg \
          --package-db "$out/lib/package.conf.d" \
          field ${lib.escapeShellArg unit.name} version --simple-output \
          | grep -qx ${lib.escapeShellArg unit.version}

        printf '%s\n' ${lib.escapeShellArg (builtins.toJSON {
          schema = "penance/external-unit/1";
          name = unit.name;
          version = unit.version;
          source = "hackage";
          sdist = unit.sdist;
        })} > "$out/metadata.json"
      '';

  buildExternalUnits = hpkgs: hackageNix: lock:
    let
      lockedHpkgs = lockedHackagePackageSet hpkgs hackageNix lock;
      units = builtins.filter (unit: unit.source == "hackage") (lock.externalUnits or []);
      packageEnvironment = lockedHpkgs.ghcWithPackages (
        packages: map (unit: packages.${unit.name}) units
      );
    in
      builtins.listToAttrs (map
        (unit: {
          name = unit.name;
          value = buildExternalUnit lockedHpkgs packageEnvironment unit;
        })
        units);

  localPackagesByName = lock:
    builtins.listToAttrs (map
      (package: {
        name = package.name;
        value = package;
      })
      (lock.packages or []));

  localPackageClosure = lock: rootPackage:
    let
      packages = localPackagesByName lock;
    in
      builtins.genericClosure {
        startSet = [{ key = rootPackage.name; value = rootPackage; }];
        operator = item:
          map
            (name: { key = name; value = packages.${name}; })
            (builtins.filter
              (name: builtins.hasAttr name packages)
              (lib.unique (lib.concatMap componentDependencyNames (item.value.components or []))));
      };

  shellProjectionFromLock = lock: rootPackage:
    let
      localPackages =
        if rootPackage == null then
          lock.packages or []
        else
          map (item: item.value) (localPackageClosure lock rootPackage);
      dependencyNames = lib.unique (lib.concatMap
        (package: lib.concatMap componentDependencyNames (package.components or []))
        localPackages);
      externalPackages = builtins.filter
        (name:
          name != "base"
          && name != "template-haskell"
          && externalUnitFor lock name != null)
        dependencyNames;
    in {
      inherit externalPackages;
      localPackages = map (package: package.name) localPackages;
    };

  devShellFromLock = hackageNix: lock: rootPackage:
    let
      hpkgs = compilerPackagesFor lock.compiler;
      projection = shellProjectionFromLock lock rootPackage;
      lockedHpkgs = lockedHackagePackageSet hpkgs hackageNix lock;
      ghc = lockedHpkgs.ghcWithPackages (
        packages: map (name: packages.${name}) projection.externalPackages
      );
    in
      pkgs.mkShell ({
        packages = [
          ghc
          pkgs.cabal-install
        ] ++ lib.optional (repent != null) repent;
        PENANCE_LOCK_SCHEMA = lock.schema;
        PENANCE_LOCK_PACKAGES = lib.concatStringsSep " " projection.externalPackages;
        PENANCE_LOCAL_PACKAGES = lib.concatStringsSep " " projection.localPackages;
        PENANCE_COMPILER = lock.compiler;
        PENANCE_GHC_PKG = "${hpkgs.ghc}/bin/ghc-pkg";
        PENANCE_INDEX_STATE = lock.indexState;
      } // lib.optionalAttrs (rootPackage != null) {
        PENANCE_PACKAGE = rootPackage.name;
        PENANCE_PACKAGE_PATH = rootPackage.path;
        PENANCE_CABAL_TARGET = rootPackage.name;
      });

  packageDevShellsFromLock = hackageNix: lock:
    builtins.listToAttrs (map
      (package: {
        name = package.name;
        value = devShellFromLock hackageNix lock package;
      })
      (lock.packages or []));

  componentBinName = component:
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

  composePackageDb = hpkgs: name: confDirs:
    pkgs.runCommand name {
      __contentAddressed = true;
      outputHashMode = "recursive";
      outputHashAlgo = "sha256";
      nativeBuildInputs = [
        hpkgs.ghc
        pkgs.findutils
      ];
    } ''
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

  componentFlagValues = lock: pkg: component: componentBuilds: packageBuilds: externalBuilds: localDbAttr:
    let
      dependencyNames = componentDependencyNames component;
      bootNames = bootDependencyNames lock dependencyNames;
      hackageNames = hackageDependencyNames lock dependencyNames;
      localNames = builtins.filter
        (name: name != pkg.name && builtins.hasAttr name packageBuilds)
        dependencyNames;
      bootFlags = lib.concatMap (name: [ "-package" name ]) bootNames;
      hackageFlags = lib.concatMap
        (name: [ "-package-db" "${externalBuilds.${name}}/lib/package.conf.d" "-package" name ])
        hackageNames;
      localFlags = lib.concatMap
        (name: [
          "-package-db"
          "${packageBuilds.${name}.components.lib.${localDbAttr}}/lib/package.conf.d"
          "-package"
          name
        ])
        localNames;
      localLibFlags =
        lib.optionals (component.name != "lib" && builtins.elem pkg.name dependencyNames)
          [ "-package-db" "${componentBuilds.lib.${localDbAttr}}/lib/package.conf.d" "-package" pkg.name ];
    in
      [ "-hide-all-packages" "-no-user-package-db" ]
      ++ bootFlags
      ++ hackageFlags
      ++ localFlags
      ++ localLibFlags;

  buildLocalLibrary = hpkgs: srcPath: lock: ghcOptions: pkg: component: componentBuilds: packageBuilds: externalBuilds:
    let
      unitId = "${pkg.name}-${pkg.version}";
      sourceDirs = component.sourceDirs or [ "." ];
      moduleNames = component.modules or [];
      modulePaths = map modulePath moduleNames;
      dependencyNames = componentDependencyNames component;
      flags = componentFlagValues lock pkg component componentBuilds packageBuilds externalBuilds "dbIface" ++ stdDevGhcOptions ++ ghcOptions;
      hackageDeps = hackageDependencyNames lock (componentDependencyNames component);
      hackageConfDirs = map (package: "${externalBuilds.${package}}/lib/package.conf.d") hackageDeps;
      localDeps = builtins.filter
        (name: name != pkg.name && builtins.hasAttr name packageBuilds)
        dependencyNames;
      localConfDirs = map
        (package: "${packageBuilds.${package}.components.lib.dbIface}/lib/package.conf.d")
        localDeps;
      dependencyConfDirs = hackageConfDirs ++ localConfDirs;
      registrationDbFlags = lib.concatMap (confDir: [ "--package-db" confDir ]) dependencyConfDirs;
      projectedSource = componentSourceProjection srcPath pkg component;
      hackageDependsShell = lib.concatMapStringsSep "\n"
        (package: ''
          depends+=("$(ghc-pkg --package-db ${externalBuilds.${package}}/lib/package.conf.d field ${package} id --simple-output)")
        '')
        hackageDeps;
      localDependsShell = lib.concatMapStringsSep "\n"
        (package: ''
          depends+=("$(ghc-pkg --package-db ${packageBuilds.${package}.components.lib.dbIface}/lib/package.conf.d field ${package} id --simple-output)")
        '')
        localDeps;
      packageName = "penance-${sanitizeName pkg.name}-${sanitizeName component.name}";
      canonicalizer =
        if ifaceCanonicalizer == null then
          throw "penanceProject: lock-backed libraries require ifaceCanonicalizer"
        else
          ifaceCanonicalizer;
      libDrv = pkgs.runCommand packageName {
        __contentAddressed = true;
        outputHashMode = "recursive";
        outputHashAlgo = "sha256";
        outputs = [ "out" "iface" ];
        nativeBuildInputs = [
          hpkgs.ghc
          canonicalizer
          pkgs.findutils
        ];
      } ''
        mkdir -p "$out/lib" "$iface/lib/ghc/${unitId}" build
        cp -R ${projectedSource} source
        chmod -R u+w source
        cd source

        common_flags=(
${shellArrayLines (flags ++ [ "-this-unit-id" unitId ] ++ map (dir: "-i${dir}") sourceDirs ++ [
  "-odir" "../build"
  "-hidir" "../build"
  "-outputdir" "../build"
])}
        )

        module_sources=()
        while IFS= read -r module_path; do
          test -n "$module_path" || continue
          found=""
          while IFS= read -r source_dir; do
            candidate="$source_dir/$module_path"
            if [ -f "$candidate" ]; then
              found="$candidate"
              break
            fi
          done <<'SOURCE_DIRS'
${heredocLines sourceDirs}
SOURCE_DIRS
          test -n "$found"
          module_sources+=("$found")
        done <<'MODULES'
${heredocLines modulePaths}
MODULES

        ghc --make -no-link "''${common_flags[@]}" "''${module_sources[@]}"

        compiler_version="$(ghc --numeric-version)"
        iface_version="$(printf '%s' "$compiler_version" | tr -d .)"
        case "$iface_version" in
          ""|*[!0-9]*)
            echo "penanceProject: cannot derive interface version from GHC $compiler_version" >&2
            exit 1
            ;;
        esac

        (cd ../build && find . -name '*.hi' -type f | sort | while IFS= read -r hi; do
          mkdir -p "$iface/lib/ghc/${unitId}/$(dirname "$hi")"
          penance-iface-canon \
            --input "$PWD/''${hi#./}" \
            --output "$iface/lib/ghc/${unitId}/$hi" \
            --expect-version "$iface_version"
        done)
        find ../build -name '*.o' -type f | sort > "$TMPDIR/objects"
        ${pkgs.stdenv.cc.bintools.bintools}/bin/ar rcs "$out/lib/libHS${unitId}.a" $(cat "$TMPDIR/objects")

        depends=()
        while IFS= read -r package; do
          test -n "$package" || continue
          depends+=("$(ghc-pkg field "$package" id --simple-output)")
        done <<'BOOT_DEPS'
${heredocLines (bootDependencyNames lock (componentDependencyNames component))}
BOOT_DEPS
${hackageDependsShell}
${localDependsShell}

cat > iface.conf <<EOF
name: ${pkg.name}
version: ${pkg.version}
id: ${unitId}
key: ${unitId}
exposed: True
exposed-modules: ${lib.concatStringsSep " " moduleNames}
import-dirs: $iface/lib/ghc/${unitId}
library-dirs:
hs-libraries:
depends: ''${depends[*]}
EOF

cat > full.conf <<EOF
name: ${pkg.name}
version: ${pkg.version}
id: ${unitId}
key: ${unitId}
exposed: True
exposed-modules: ${lib.concatStringsSep " " moduleNames}
import-dirs: $iface/lib/ghc/${unitId}
library-dirs: $out/lib
hs-libraries: HS${unitId}
depends: ''${depends[*]}
EOF

        ghc-pkg init "$iface/lib/package.conf.d"
        dependency_package_dbs=(
${shellArrayLines registrationDbFlags}
        )
        ghc-pkg "''${dependency_package_dbs[@]}" --package-db "$iface/lib/package.conf.d" register iface.conf
        ghc-pkg --package-db "$iface/lib/package.conf.d" field ${pkg.name} exposed-modules --simple-output >/dev/null

        ghc-pkg init "$out/lib/package.conf.d"
        ghc-pkg "''${dependency_package_dbs[@]}" --package-db "$out/lib/package.conf.d" register full.conf
        ghc-pkg --package-db "$out/lib/package.conf.d" field ${pkg.name} exposed-modules --simple-output >/dev/null

        metadata=${lib.escapeShellArg (builtins.toJSON {
          schema = "penance/local-library/3";
          package = pkg.name;
          version = pkg.version;
          component = component.name;
          lockSchema = lock.schema;
          outputs = [ "iface" "out" ];
          interfaceCanonicalizer = "ghc-wasm";
        })}
        printf '%s\n' "$metadata" > "$out/metadata.json"
        printf '%s\n' "$metadata" > "$iface/metadata.json"
      '';
      dbIface = composePackageDb hpkgs "${packageName}-dbIface"
        (dependencyConfDirs ++ [ "${libDrv.iface}/lib/package.conf.d" ]);
      dbFull = composePackageDb hpkgs "${packageName}-dbFull"
        (dependencyConfDirs ++ [ "${libDrv}/lib/package.conf.d" ]);
    in
      libDrv // {
        inherit dbIface dbFull;
      };

  buildLocalProgram = hpkgs: srcPath: lock: ghcOptions: runExecutables: pkg: component: componentBuilds: packageBuilds: externalBuilds:
    let
      sourceDirs = component.sourceDirs or [ "." ];
      mainPath = modulePath component.main;
      binName = componentBinName component;
      projectedSource = componentSourceProjection srcPath pkg component;
      compileFlags = componentFlagValues lock pkg component componentBuilds packageBuilds externalBuilds "dbIface" ++ stdDevGhcOptions ++ ghcOptions;
      linkFlags = componentFlagValues lock pkg component componentBuilds packageBuilds externalBuilds "dbFull" ++ stdDevGhcOptions ++ ghcOptions;
      packageName = "penance-${sanitizeName pkg.name}-${sanitizeName component.name}";
      runField =
        if component.kind == "test-suite" then "test"
        else if component.kind == "benchmark" then "benchmark"
        else "output";
      compileDrv = pkgs.runCommand "${packageName}-compile" {
        __contentAddressed = true;
        outputHashMode = "recursive";
        outputHashAlgo = "sha256";
        nativeBuildInputs = [
          hpkgs.ghc
          pkgs.findutils
        ];
      } ''
        mkdir -p "$out/build" build
        cp -R ${projectedSource} source
        chmod -R u+w source
        cd source

        common_flags=(
${shellArrayLines (compileFlags ++ map (dir: "-i${dir}") sourceDirs ++ [
  "-odir" "../build"
  "-hidir" "../build"
  "-outputdir" "../build"
])}
        )

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

        (cd ../build && find . \( -name '*.o' -o -name '*.hi' \) -type f | sort | while IFS= read -r artifact; do
          mkdir -p "$out/build/$(dirname "$artifact")"
          cp "$artifact" "$out/build/$artifact"
        done)
        find "$out/build" -name '*.o' -type f | sort > "$out/objects"
        test -s "$out/objects"

        printf '%s\n' ${lib.escapeShellArg (builtins.toJSON {
          schema = "penance/local-program-compile/1";
          package = pkg.name;
          version = pkg.version;
          component = component.name;
          kind = component.kind;
          lockSchema = lock.schema;
        })} > "$out/metadata.json"
      '';
      linkDrv = pkgs.runCommand packageName {
        __contentAddressed = true;
        outputHashMode = "recursive";
        outputHashAlgo = "sha256";
        nativeBuildInputs = [
          hpkgs.ghc
        ];
      } ''
        mkdir -p "$out/bin"

        object_args=()
        while IFS= read -r object; do
          test -n "$object" || continue
          object_args+=("$object")
        done < ${compileDrv}/objects

        link_flags=(
${shellArrayLines linkFlags}
        )

        ghc "''${link_flags[@]}" "''${object_args[@]}" -o "$out/bin/${binName}"
${lib.optionalString (component.kind != "executable" || runExecutables) ''
        "$out/bin/${binName}" > "$out/${runField}.txt"
''}

        printf '%s\n' ${lib.escapeShellArg (builtins.toJSON {
          schema = "penance/local-program-link/1";
          package = pkg.name;
          version = pkg.version;
          component = component.name;
          kind = component.kind;
          lockSchema = lock.schema;
          compile = compileDrv;
        })} > "$out/metadata.json"
      '';
    in
      linkDrv // {
        compile = compileDrv;
      };

  buildLocalComponent = hpkgs: srcPath: lock: ghcOptions: runExecutables: pkg: component: componentBuilds: packageBuilds: externalBuilds:
    if component.kind == "library" then
      buildLocalLibrary hpkgs srcPath lock ghcOptions pkg component componentBuilds packageBuilds externalBuilds
    else if component.kind == "executable" || component.kind == "test-suite" || component.kind == "benchmark" then
      buildLocalProgram hpkgs srcPath lock ghcOptions runExecutables pkg component componentBuilds packageBuilds externalBuilds
    else
      throw "penanceProject: unsupported component kind `${component.kind}`";

  packageAttrsFromLock = srcPath: hackageNix: lock: ghcOptions: runExecutables:
    let
      hpkgs = compilerPackagesFor lock.compiler;
      externalBuilds = buildExternalUnits hpkgs hackageNix lock;
      packageBuilds = builtins.listToAttrs (map
        (pkg:
          let
            componentBuilds = builtins.listToAttrs (map
              (component: {
                name = component.name;
                value = buildLocalComponent hpkgs srcPath lock ghcOptions runExecutables pkg component componentBuilds packageBuilds externalBuilds;
              })
              (pkg.components or []));
            packageDefault =
              if componentBuilds ? lib then componentBuilds.lib
              else if componentBuilds ? "exe:${pkg.name}" then componentBuilds."exe:${pkg.name}"
              else pkgs.writeText "penance-${sanitizeName pkg.name}-components.json" (builtins.toJSON {
                inherit (pkg) name version;
                components = builtins.attrNames componentBuilds;
              });
          in {
            name = pkg.name;
            value = packageDefault // {
              components = componentBuilds;
              externalUnits = externalBuilds;
            };
          })
        (lock.packages or []));
    in
      packageBuilds;

  packageAttrs = rootPlanner: skeleton:
    builtins.listToAttrs (map
      (pkg: {
        name = pkg.name;
        value = rootPlanner // {
          components = builtins.listToAttrs (map
            (component: {
              name = component;
              value = rootPlanner;
            })
            pkg.components);
          instantiations = builtins.listToAttrs (map
            (instantiation: {
              name = instantiation.unit;
              value = rootPlanner;
            })
            skeleton.backpack.expectedInstantiations);
        };
      })
      skeleton.localPackages);
in
{
  penanceProject =
    { src
    , compiler ? null
    , index-state ? null
    , cabalProject ? "cabal.project"
    , mode ? "component"
    , flags ? {}
    , ghcOptions ? []
    , hackageNix ? null
    , runExecutables ? true
    }:
    let
      srcPath = src;
      lockPath = srcPath + "/penance.lock";
      hasLock = builtins.pathExists lockPath;
      lock =
        if hasLock then
          builtins.fromJSON (builtins.readFile lockPath)
        else
          null;
      projectCompiler =
        if compiler != null then compiler
        else if lock != null then lock.compiler
        else throw "penanceProject: `compiler` is required when no penance.lock exists";
      projectIndexState =
        if index-state != null then index-state
        else if lock != null then lock.indexState
        else throw "penanceProject: `index-state` is required when no penance.lock exists";
      useLockComponents = mode == "component" && hasLock && lock.schema == "penance/lock/1";
      cabalProjectPath = srcPath + "/${cabalProject}";
      cabalProjectText = builtins.readFile cabalProjectPath;
      localPackageManifests = collectLocalPackageManifests srcPath cabalProjectText;
      sourceManifest = sourceManifestFor srcPath;
      skeleton = callWasmPlanner {
        src = srcPath;
        compiler = projectCompiler;
        index-state = projectIndexState;
        inherit cabalProjectText flags localPackageManifests mode sourceManifest;
      };
      rootPlanner = plannerDrv {
        src = srcPath;
        compiler = projectCompiler;
        index-state = projectIndexState;
        inherit skeleton;
        granularity = mode;
      };
    in {
      compiler = projectCompiler;
      compilerPackages = compilerPackagesFor projectCompiler;
      indexState = projectIndexState;
      packages =
        if useLockComponents then
          packageAttrsFromLock srcPath hackageNix lock ghcOptions runExecutables
        else
          packageAttrs rootPlanner skeleton;
      checks = {
        planner = rootPlanner;
      };
      devShells =
        if useLockComponents then
          {
            default = devShellFromLock hackageNix lock null;
            packages = packageDevShellsFromLock hackageNix lock;
          }
        else
          {};
      apps = {};
      drvGraph = rootPlanner;
    };
}
