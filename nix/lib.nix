{ lib
, pkgs
, plannerWasm ? ./planner.wasm
, penancePlanner ? null
}:

let
  callWasmPlanner = import ./shim.nix {
    inherit lib plannerWasm;
  };

  plannerDrv = import ./planner-drv.nix {
    inherit lib pkgs penancePlanner;
  };

  ignoredSourceName = name:
    name == ".direnv"
    || name == ".git"
    || name == "dist-newstyle"
    || name == "target"
    || name == "result"
    || lib.hasPrefix "result-" name;

  cleanSource = src:
    lib.cleanSourceWith {
      inherit src;
      filter = path: type:
        let
          name = builtins.baseNameOf path;
        in
          !(ignoredSourceName name);
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
                if ignoredSourceName name then
                  []
                else if entryType == "directory" then
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
      cabalNames = builtins.filter
        (name: lib.hasSuffix ".cabal" name)
        (builtins.attrNames entries);
    in
      if cabalNames == [] then
        throw "penanceProject: no .cabal file found in package path `${packagePath}`"
      else if builtins.length cabalNames > 1 then
        throw "penanceProject: multiple .cabal files found in package path `${packagePath}`"
      else
        dir + "/${builtins.head cabalNames}";

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

  collectIndentedProjectLines = records:
    if records == [] then
      []
    else
      let
        line = builtins.head records;
        rest = builtins.tail records;
      in
        if line.indented then [ line.text ] ++ collectIndentedProjectLines rest else [];

  dropIndentedProjectLines = records:
    if records == [] then
      []
    else
      let
        line = builtins.head records;
        rest = builtins.tail records;
      in
        if line.indented then dropIndentedProjectLines rest else records;

  splitProjectPackageWords = value:
    lib.filter (part: part != "")
      (map
        (part: lib.trim (lib.removeSuffix "," part))
        (lib.splitString " " (lib.replaceStrings [ "\n" "\t" ] [ " " " " ] value)));

  collectProjectFieldPackages = field: records:
    if records == [] then
      []
    else
      let
        line = builtins.head records;
        rest = builtins.tail records;
        prefix = "${field}:";
      in
        if !line.indented && lib.hasPrefix prefix line.text then
          let
            inline = lib.removePrefix prefix line.text;
            continuation = collectIndentedProjectLines rest;
            remaining = dropIndentedProjectLines rest;
            value = lib.concatStringsSep "\n" ([ inline ] ++ continuation);
          in
            splitProjectPackageWords value ++ collectProjectFieldPackages field remaining
        else
          collectProjectFieldPackages field rest;

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
    if compiler == "ghc-9.10.3" && pkgs.haskell.packages ? ghc9103 then
      pkgs.haskell.packages.ghc9103
    else if compiler == "ghc-9.10.2" && pkgs.haskell.packages ? ghc9102 then
      pkgs.haskell.packages.ghc9102
    else
      pkgs.haskellPackages;

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

  componentSourceFor = srcPath: pkg: component:
    let
      pkgRoot = if pkg.path == "." then srcPath else srcPath + "/${pkg.path}";
      rootString = toString pkgRoot;
      sourceDirs = map normalizeSourceDir (component.sourceDirs or [ "." ]);
      inSourceDir = rel: dir:
        dir == "."
        || rel == dir
        || lib.hasPrefix "${dir}/" rel;
    in
      lib.cleanSourceWith {
        src = pkgRoot;
        filter = path: type:
          let
            pathString = toString path;
            rel =
              if pathString == rootString then
                ""
              else
                lib.removePrefix "${rootString}/" pathString;
            name = builtins.baseNameOf path;
          in
            rel == ""
            || (!ignoredSourceName name && builtins.any (inSourceDir rel) sourceDirs);
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

  buildExternalUnit = hpkgs: unit:
    if unit.name != "StateVar" then
      throw "penanceProject: unsupported hackage external unit `${unit.name}`"
    else
      let
        unitId = "${unit.name}-${unit.version}";
        srcTarball = pkgs.fetchurl {
          inherit (unit.sdist) url;
          hash = unit.sdist.sha256;
        };
      in
        pkgs.runCommand "penance-external-${unitId}" {
          nativeBuildInputs = [
            hpkgs.ghc
            pkgs.findutils
            pkgs.gnutar
            pkgs.gzip
          ];
        } ''
          mkdir -p "$out/lib/ghc/${unitId}" "$out/lib" build unpack
          tar -xzf ${srcTarball} -C unpack --strip-components=1
          cd unpack

          cabal_version="$(sed -n 's/^version:[[:space:]]*//p' StateVar.cabal | head -n 1)"
          test "$cabal_version" = "${unit.version}"

          ghc \
            -hide-all-packages \
            -no-user-package-db \
            -this-unit-id ${unitId} \
            -package base \
            -package stm \
            -package transformers \
            -isrc \
            -odir ../build \
            -hidir ../build \
            -outputdir ../build \
            -DUSE_DEFAULT_SIGNATURES=1 \
            -c src/Data/StateVar.hs

          mkdir -p "$out/lib/ghc/${unitId}/Data"
          cp ../build/Data/StateVar.hi "$out/lib/ghc/${unitId}/Data/"
          ${pkgs.stdenv.cc.bintools.bintools}/bin/ar rcs "$out/lib/libHS${unitId}.a" ../build/Data/StateVar.o

          ghc-pkg init "$out/lib/package.conf.d"
          depends=()
          for package in base stm transformers; do
            depends+=("$(ghc-pkg field "$package" id --simple-output)")
          done
cat > StateVar.conf <<EOF
name: StateVar
version: ${unit.version}
id: ${unitId}
key: ${unitId}
exposed: True
exposed-modules: Data.StateVar
import-dirs: $out/lib/ghc/${unitId}
library-dirs: $out/lib
hs-libraries: HS${unitId}
depends: ''${depends[*]}
EOF
          ghc-pkg --package-db "$out/lib/package.conf.d" register StateVar.conf
          ghc-pkg --package-db "$out/lib/package.conf.d" field StateVar version --simple-output | grep -qx "${unit.version}"

          printf '%s\n' ${lib.escapeShellArg (builtins.toJSON {
            schema = "penance/external-unit/1";
            name = unit.name;
            version = unit.version;
            source = "hackage";
            sdist = unit.sdist;
          })} > "$out/metadata.json"
        '';

  buildExternalUnits = hpkgs: lock:
    builtins.listToAttrs (map
      (unit: {
        name = unit.name;
        value = buildExternalUnit hpkgs unit;
      })
      (builtins.filter (unit: unit.source == "hackage") (lock.externalUnits or [])));

  shellPackageNamesFromLock = lock:
    builtins.filter
      (name: name != "base" && name != "template-haskell")
      (externalUnitNamesBySource lock "ghc-boot");

  devShellFromLock = lock:
    let
      hpkgs = compilerPackagesFor (lock.compiler or "ghc-9.10.2");
      packageNames = shellPackageNamesFromLock lock;
      ghc = hpkgs.ghcWithPackages (ps: map (name: ps.${name}) packageNames);
    in
      pkgs.mkShell {
        packages = [
          ghc
          pkgs.cabal-install
        ];
        PENANCE_LOCK_SCHEMA = lock.schema;
        PENANCE_LOCK_PACKAGES = lib.concatStringsSep " " packageNames;
      };

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
        find "$conf_dir" -name '*.conf' -type f | sort | while IFS= read -r conf; do
          ghc-pkg --package-db "$out/lib/package.conf.d" register "$conf"
        done
      done <<'CONF_DIRS'
${heredocLines confDirs}
CONF_DIRS

      ghc-pkg --package-db "$out/lib/package.conf.d" recache
    '';

  componentFlagValues = lock: pkg: component: componentBuilds: externalBuilds: localDbAttr:
    let
      dependencyNames = componentDependencyNames component;
      bootNames = bootDependencyNames lock dependencyNames;
      hackageNames = hackageDependencyNames lock dependencyNames;
      bootFlags = lib.concatMap (name: [ "-package" name ]) bootNames;
      hackageFlags = lib.concatMap
        (name: [ "-package-db" "${externalBuilds.${name}}/lib/package.conf.d" "-package" name ])
        hackageNames;
      localLibFlags =
        lib.optionals (component.name != "lib" && builtins.elem pkg.name dependencyNames)
          [ "-package-db" "${componentBuilds.lib.${localDbAttr}}/lib/package.conf.d" "-package" pkg.name ];
    in
      [ "-hide-all-packages" "-no-user-package-db" ] ++ bootFlags ++ hackageFlags ++ localLibFlags;

  buildLocalLibrary = hpkgs: srcPath: lock: ghcOptions: pkg: component: componentBuilds: externalBuilds:
    let
      unitId = "${pkg.name}-${pkg.version}";
      sourceDirs = component.sourceDirs or [ "." ];
      moduleNames = component.modules or [];
      modulePaths = map modulePath moduleNames;
      flags = componentFlagValues lock pkg component componentBuilds externalBuilds "dbIface" ++ stdDevGhcOptions ++ ghcOptions;
      hackageDeps = hackageDependencyNames lock (componentDependencyNames component);
      hackageConfDirs = map (package: "${externalBuilds.${package}}/lib/package.conf.d") hackageDeps;
      componentSrc = componentSourceFor srcPath pkg component;
      hackageDependsShell = lib.concatMapStringsSep "\n"
        (package: ''
          depends+=("$(ghc-pkg --package-db ${externalBuilds.${package}}/lib/package.conf.d field ${package} id --simple-output)")
        '')
        hackageDeps;
      packageName = "penance-${sanitizeName pkg.name}-${sanitizeName component.name}";
      libDrv = pkgs.runCommand packageName {
        __contentAddressed = true;
        outputHashMode = "recursive";
        outputHashAlgo = "sha256";
        outputs = [ "out" "iface" ];
        nativeBuildInputs = [
          hpkgs.ghc
          pkgs.findutils
          pkgs.perl
        ];
      } ''
        mkdir -p "$out/lib" "$iface/lib/ghc/${unitId}" build
        cp -R ${componentSrc} source
        chmod -R u+w source
        cd source

        common_flags=(
${shellArrayLines (flags ++ [ "-this-unit-id" unitId ] ++ map (dir: "-i${dir}") sourceDirs ++ [
  "-odir" "../build"
  "-hidir" "../build"
  "-outputdir" "../build"
])}
        )

        iface_flags=(
${shellArrayLines (flags ++ [ "-this-unit-id" unitId ] ++ map (dir: "-i${dir}") sourceDirs ++ [
  "-odir" "../iface-build"
  "-hidir" "../iface-build"
  "-outputdir" "../iface-build"
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

        cat > "$TMPDIR/penance-iface-stub.pl" <<'PERL'
use strict;
use warnings;

my $pending;
while (my $line = <STDIN>) {
  if (defined $pending) {
    if ($line =~ /^\s*$/ || $line =~ /^\s/ || $line =~ /^\Q$pending\E\b/) {
      next;
    }
    undef $pending;
  }

  if ($line =~ /^([a-z_][A-Za-z0-9_']*)\s*::/) {
    my $name = $1;
    print $line;
    print "$name = error \"penance iface stub\"\n";
    $pending = $name;
    next;
  }

  print $line;
}
PERL

        cp -R . ../iface-source
        find ../iface-source -name '*.hs' -type f | sort | while IFS= read -r hs; do
          perl "$TMPDIR/penance-iface-stub.pl" < "$hs" > "$hs.stub"
          mv "$hs.stub" "$hs"
        done
        (
          cd ../iface-source
          ghc --make -no-link "''${iface_flags[@]}" "''${module_sources[@]}"
        )

        (cd ../iface-build && find . -name '*.hi' -type f | while IFS= read -r hi; do
          mkdir -p "$iface/lib/ghc/${unitId}/$(dirname "$hi")"
          cp "$hi" "$iface/lib/ghc/${unitId}/$hi"
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
        ghc-pkg --package-db "$iface/lib/package.conf.d" register iface.conf
        ghc-pkg --package-db "$iface/lib/package.conf.d" field ${pkg.name} exposed-modules --simple-output >/dev/null

        ghc-pkg init "$out/lib/package.conf.d"
        ghc-pkg --package-db "$out/lib/package.conf.d" register full.conf
        ghc-pkg --package-db "$out/lib/package.conf.d" field ${pkg.name} exposed-modules --simple-output >/dev/null

        metadata=${lib.escapeShellArg (builtins.toJSON {
          schema = "penance/local-library/2";
          package = pkg.name;
          version = pkg.version;
          component = component.name;
          lockSchema = lock.schema;
          outputs = [ "iface" "out" ];
        })}
        printf '%s\n' "$metadata" > "$out/metadata.json"
        printf '%s\n' "$metadata" > "$iface/metadata.json"
      '';
      dbIface = composePackageDb hpkgs "${packageName}-dbIface"
        ([ "${libDrv.iface}/lib/package.conf.d" ] ++ hackageConfDirs);
      dbFull = composePackageDb hpkgs "${packageName}-dbFull"
        ([ "${libDrv}/lib/package.conf.d" ] ++ hackageConfDirs);
    in
      libDrv // {
        inherit dbIface dbFull;
      };

  buildLocalProgram = hpkgs: srcPath: lock: ghcOptions: pkg: component: componentBuilds: externalBuilds:
    let
      sourceDirs = component.sourceDirs or [ "." ];
      mainPath = modulePath component.main;
      binName = componentBinName component;
      componentSrc = componentSourceFor srcPath pkg component;
      compileFlags = componentFlagValues lock pkg component componentBuilds externalBuilds "dbIface" ++ stdDevGhcOptions ++ ghcOptions;
      linkFlags = componentFlagValues lock pkg component componentBuilds externalBuilds "dbFull" ++ stdDevGhcOptions ++ ghcOptions;
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
        cp -R ${componentSrc} source
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
        "$out/bin/${binName}" > "$out/${runField}.txt"

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

  buildLocalComponent = hpkgs: srcPath: lock: ghcOptions: pkg: component: componentBuilds: externalBuilds:
    if component.kind == "library" then
      buildLocalLibrary hpkgs srcPath lock ghcOptions pkg component componentBuilds externalBuilds
    else if component.kind == "executable" || component.kind == "test-suite" || component.kind == "benchmark" then
      buildLocalProgram hpkgs srcPath lock ghcOptions pkg component componentBuilds externalBuilds
    else
      throw "penanceProject: unsupported component kind `${component.kind}`";

  packageAttrsFromLock = srcPath: lock: ghcOptions:
    let
      hpkgs = compilerPackagesFor (lock.compiler or "ghc-9.10.2");
      externalBuilds = buildExternalUnits hpkgs lock;
    in
      builtins.listToAttrs (map
        (pkg:
          let
            componentBuilds = builtins.listToAttrs (map
              (component: {
                name = component.name;
                value = buildLocalComponent hpkgs srcPath lock ghcOptions pkg component componentBuilds externalBuilds;
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
    , compiler
    , index-state
    , cabalProject ? "cabal.project"
    , mode ? "component"
    , flags ? {}
    , ghcOptions ? []
    }:
    let
      srcPath = cleanSource src;
      lockPath = srcPath + "/strata.lock";
      hasLock = builtins.pathExists lockPath;
      lock =
        if hasLock then
          builtins.fromJSON (builtins.readFile lockPath)
        else
          null;
      useLockComponents = mode == "component" && hasLock && lock.schema == "penance/strata-lock/1";
      cabalProjectPath = srcPath + "/${cabalProject}";
      cabalProjectText = builtins.readFile cabalProjectPath;
      localPackageManifests = collectLocalPackageManifests srcPath cabalProjectText;
      sourceManifest = sourceManifestFor srcPath;
      skeleton = callWasmPlanner {
        src = srcPath;
        inherit
          cabalProjectText
          compiler
          flags
          index-state
          localPackageManifests
          mode
          sourceManifest
          ;
      };
      rootPlanner = plannerDrv {
        src = srcPath;
        inherit compiler index-state skeleton;
        granularity = mode;
      };
    in {
      packages =
        if useLockComponents then
          packageAttrsFromLock src lock ghcOptions
        else
          packageAttrs rootPlanner skeleton;
      checks = {
        planner = rootPlanner;
      };
      devShells =
        if useLockComponents then
          { default = devShellFromLock lock; }
        else
          {};
      apps = {};
      drvGraph = rootPlanner;
    };
}
