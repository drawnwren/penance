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
    }:
    let
      srcPath = cleanSource src;
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
      packages = packageAttrs rootPlanner skeleton;
      checks = {
        planner = rootPlanner;
      };
      devShells = {};
      apps = {};
      drvGraph = rootPlanner;
    };
}
