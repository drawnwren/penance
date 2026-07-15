{
  lib,
  pkgs,
  ifaceCanonicalizer,
  modulePath,
  componentDependencyNames,
  componentFlagValues,
  stdDevGhcOptions,
  componentSourceProjection,
  shellArrayLines,
  heredocLines,
  composePackageDb,
  componentExtensionFlags,
  componentNeedsFullDb,
  sanitizeName,
}:

{
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
}:
let
  inherit (component) unitId;
  sourceDirs = component.sourceDirs or [ "." ];
  moduleNames = component.modules or [ ];
  modulePaths = map modulePath moduleNames;
  dependencyNames = componentDependencyNames component;
  compileLocalDbAttr = if componentNeedsFullDb component then "dbFull" else "dbIface";
  flagValues = componentFlagValues {
    inherit
      externalContext
      pkg
      component
      componentBuilds
      packageBuilds
      ;
    localDbAttr = compileLocalDbAttr;
  };
  flags = flagValues.flags ++ componentExtensionFlags component ++ stdDevGhcOptions ++ ghcOptions;
  hackageConfDirs = map (
    externalUnitId: "${externalContext.slices.${externalUnitId}}/lib/package.conf.d"
  ) flagValues.closureHackageUnitIds;
  localDeps = builtins.filter (
    name: name != pkg.name && builtins.hasAttr name packageBuilds
  ) dependencyNames;
  localIfaceConfDirs = map (
    package: "${packageBuilds.${package}.components.lib.dbIface}/lib/package.conf.d"
  ) localDeps;
  localFullConfDirs = map (
    package: "${packageBuilds.${package}.components.lib.dbFull}/lib/package.conf.d"
  ) localDeps;
  dependencyConfDirs = hackageConfDirs ++ localIfaceConfDirs;
  registrationDbFlags = lib.concatMap (confDir: [
    "--package-db"
    confDir
  ]) dependencyConfDirs;
  projectedSource = componentSourceProjection srcPath pkg component;
  hackageDependsShell = lib.concatMapStringsSep "\n" (externalUnitId: ''
    dependency_id="$(cat ${externalContext.slices.${externalUnitId}}/installed-id)"
    test -n "$dependency_id"
    depends+=("$dependency_id")
  '') flagValues.directHackageUnitIds;
  localDependsShell = lib.concatMapStringsSep "\n" (package: ''
    depends+=("$(ghc-pkg --package-db ${
      packageBuilds.${package}.components.lib.dbIface
    }/lib/package.conf.d field ${lib.escapeShellArg package} id --simple-output)")
  '') localDeps;
  packageName = "penance-${sanitizeName pkg.name}-${sanitizeName component.name}";
  canonicalizer =
    if ifaceCanonicalizer == null then
      throw "penanceProject: lock-backed libraries require ifaceCanonicalizer"
    else
      ifaceCanonicalizer;
  libDrv =
    pkgs.runCommand packageName
      (
        {
          outputs = [
            "out"
            "iface"
          ];
          nativeBuildInputs = [
            hpkgs.ghc
            canonicalizer
            pkgs.findutils
          ];
          passthru.localDependencyDb = compileLocalDbAttr;
        }
        // lib.optionalAttrs contentAddressed {
          __contentAddressed = true;
          outputHashMode = "recursive";
          outputHashAlgo = "sha256";
        }
      )
      ''
                mkdir -p "$out/lib" "$iface/lib/ghc/${unitId}" build
                cp -R ${projectedSource} source
                chmod -R u+w source
                cd source

                common_flags=(
        ${shellArrayLines (
          flags
          ++ [
            "-this-unit-id"
            unitId
            "-dynamic-too"
          ]
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
        ${lib.concatMapStringsSep "\n" (packageName: ''
          package_id="$(ghc-pkg --global field ${lib.escapeShellArg packageName} id --simple-output)"
          test "$(printf '%s\n' "$package_id" | wc -w | tr -d ' ')" = 1
          package_flags+=("-package-id" "$package_id")
        '') flagValues.directBootPackageNames}
        ${lib.concatMapStringsSep "\n" (externalUnitId: ''
          package_id="$(cat ${externalContext.slices.${externalUnitId}}/installed-id)"
          test -n "$package_id"
          package_flags+=("-package-id" "$package_id")
        '') flagValues.directHackageUnitIds}
                common_flags+=("''${package_flags[@]}")
                dynamic_library_path=${lib.escapeShellArg (lib.concatStringsSep ":" flagValues.localDynamicLibraryDirs)}
                export DYLD_LIBRARY_PATH="$dynamic_library_path''${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
                export LD_LIBRARY_PATH="$dynamic_library_path''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

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

                (cd ../build && find . \( -name '*.hi' -o -name '*.dyn_hi' \) -type f | sort | while IFS= read -r hi; do
                  mkdir -p "$iface/lib/ghc/${unitId}/$(dirname "$hi")"
                  penance-iface-canon \
                    --input "$PWD/''${hi#./}" \
                    --output "$iface/lib/ghc/${unitId}/$hi" \
                    --expect-version "$iface_version"
                done)
                find ../build -name '*.o' -type f | sort > "$TMPDIR/objects"
                object_args=()
                while IFS= read -r object; do
                  test -n "$object" || continue
                  object_args+=("$object")
                done < "$TMPDIR/objects"
                ${pkgs.stdenv.cc.bintools.bintools}/bin/ar rcs "$out/lib/libHS${unitId}.a" "''${object_args[@]}"

                find ../build -name '*.dyn_o' -type f | sort > "$TMPDIR/dynamic-objects"
                dynamic_object_args=()
                while IFS= read -r object; do
                  test -n "$object" || continue
                  dynamic_object_args+=("$object")
                done < "$TMPDIR/dynamic-objects"
                test "''${#dynamic_object_args[@]}" -gt 0
                case "$(uname -s)" in
                  Darwin) shared_suffix=dylib ;;
                  Linux) shared_suffix=so ;;
                  *) echo "penanceProject: unsupported shared-library platform $(uname -s)" >&2; exit 1 ;;
                esac
                ghc "''${common_flags[@]}" -shared -dynamic "''${dynamic_object_args[@]}" \
                  -o "$out/lib/libHS${unitId}-ghc''${compiler_version}.$shared_suffix"

                depends=()
        ${lib.concatMapStringsSep "\n" (packageName: ''
          package_id="$(ghc-pkg --global field ${lib.escapeShellArg packageName} id --simple-output)"
          test "$(printf '%s\n' "$package_id" | wc -w | tr -d ' ')" = 1
          depends+=("$package_id")
        '') flagValues.directBootPackageNames}
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
        dynamic-library-dirs: $out/lib
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

                metadata=${
                  lib.escapeShellArg (
                    builtins.toJSON {
                      schema = "penance/local-library/3";
                      package = pkg.name;
                      inherit (pkg) version;
                      component = component.name;
                      lockSchema = lock.schema;
                      outputs = [
                        "iface"
                        "out"
                      ];
                      interfaceCanonicalizer = "ghc-wasm";
                      localDependencyDb = compileLocalDbAttr;
                    }
                  )
                }
                printf '%s\n' "$metadata" > "$out/metadata.json"
                printf '%s\n' "$metadata" > "$iface/metadata.json"
      '';
  dbIface = composePackageDb hpkgs contentAddressed "${packageName}-dbIface" (
    hackageConfDirs ++ localIfaceConfDirs ++ [ "${libDrv.iface}/lib/package.conf.d" ]
  ) [ ];
  dbFull = composePackageDb hpkgs contentAddressed "${packageName}-dbFull" (
    hackageConfDirs ++ localFullConfDirs ++ [ "${libDrv}/lib/package.conf.d" ]
  ) [ dbIface ];
in
libDrv
// {
  inherit dbIface dbFull;
}
