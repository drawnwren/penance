{
  ghcWasm,
  haskellNix,
  hackageStateVarVersion,
  pkgsFor,
  stackageResolver,
  system,
  ...
}:
let
  pkgs = pkgsFor.${system};
  haskellNixPkgs = import haskellNix.inputs.nixpkgs-unstable {
    inherit system;
    overlays = [ haskellNix.overlay ];
    inherit (haskellNix) config;
  };
  repentCabalIndexState = "2026-05-22T01:04:11Z";
  repentHackageIndex = pkgs.fetchurl {
    name = "penance-hackage-index-${
      builtins.replaceStrings [ ":" ] [ "" ] repentCabalIndexState
    }.tar.gz";
    url = "https://hackage.haskell.org/01-index.tar.gz";
    hash = "sha256-2w7hxEBCz+3e89B0ix6fc/RkZI50FfT7LSU8wbn3qrA=";
    downloadToTemp = true;
    nativeBuildInputs = [ pkgs.python3 ];
    postFetch = ''
      python - "$downloadedFile" "$out" <<'PY'
      import datetime
      import gzip
      import sys

      source_path, output_path = sys.argv[1:]
      cutoff = int(
          datetime.datetime.fromisoformat("${repentCabalIndexState}".replace("Z", "+00:00")).timestamp()
      )

      with gzip.open(source_path, "rb") as source:
          with open(output_path, "wb") as raw_output:
              with gzip.GzipFile(
                  fileobj=raw_output,
                  mode="wb",
                  filename="",
                  mtime=0,
                  compresslevel=6,
              ) as output:
                  while True:
                      header = source.read(512)
                      if not header or header == bytes(512):
                          output.write(bytes(1024))
                          break
                      if len(header) != 512:
                          raise RuntimeError("truncated Hackage tar header")
                      size = int(header[124:136].rstrip(b"\x00 ") or b"0", 8)
                      mtime = int(header[136:148].rstrip(b"\x00 ") or b"0", 8)
                      contents = source.read(((size + 511) // 512) * 512)
                      if mtime <= cutoff:
                          output.write(header)
                          output.write(contents)

      with open(output_path, "r+b") as output:
          output.seek(9)
          output.write(bytes([0xff]))
      PY
    '';
  };
  repentHackageRepo =
    pkgs.runCommand
      "penance-hackage-repo-${builtins.replaceStrings [ ":" ] [ "" ] repentCabalIndexState}"
      { }
      ''
        mkdir -p "$out"
        ln -s ${repentHackageIndex} "$out/01-index.tar.gz"

        expires=4000-01-01T00:00:00Z
        cat > "$out/root.json" <<EOF
        {"signatures":[],"signed":{"_type":"Root","expires":"$expires","keys":{},"roles":{"mirrors":{"keyids":[],"threshold":0},"root":{"keyids":[],"threshold":0},"snapshot":{"keyids":[],"threshold":0},"targets":{"keyids":[],"threshold":0},"timestamp":{"keyids":[],"threshold":0}},"version":1}}
        EOF
        cat > "$out/mirrors.json" <<EOF
        {"signatures":[],"signed":{"_type":"Mirrorlist","expires":"$expires","mirrors":[],"version":1}}
        EOF

        file_metadata() {
          local path="$1"
          printf '"hashes":{"md5":"%s","sha256":"%s"},"length":%s' \
            "$(md5sum "$path" | cut -d ' ' -f 1)" \
            "$(sha256sum "$path" | cut -d ' ' -f 1)" \
            "$(stat --dereference --printf='%s' "$path")"
        }

        cat > "$out/snapshot.json" <<EOF
        {"signatures":[],"signed":{"_type":"Snapshot","expires":"$expires","meta":{"<repo>/01-index.tar.gz":{$(file_metadata "$out/01-index.tar.gz")},"<repo>/root.json":{$(file_metadata "$out/root.json")},"<repo>/mirrors.json":{$(file_metadata "$out/mirrors.json")}},"version":1}}
        EOF
        cat > "$out/timestamp.json" <<EOF
        {"signatures":[],"signed":{"_type":"Timestamp","expires":"$expires","meta":{"<repo>/snapshot.json":{$(file_metadata "$out/snapshot.json")}},"version":1}}
        EOF
      '';
  repentCabalDir =
    pkgs.runCommand
      "penance-cabal-index-${builtins.replaceStrings [ ":" ] [ "" ] repentCabalIndexState}"
      {
        nativeBuildInputs = [ pkgs.cabal-install ];
      }
      ''
        export HOME="$TMPDIR/home"
        export CABAL_DIR="$TMPDIR/cabal"
        mkdir -p "$HOME" "$CABAL_DIR/packages/hackage.haskell.org"

        cat > "$CABAL_DIR/config" <<EOF
        repository hackage.haskell.org
          url: file:${repentHackageRepo}
          secure: True
          root-keys: aaa
          key-threshold: 0
        EOF
        cabal update hackage.haskell.org

        mkdir -p "$out"
        cp -R "$CABAL_DIR/packages" "$out/packages"
        cat > "$out/config" <<'EOF'
        repository hackage.haskell.org
          url: https://hackage.haskell.org/
          secure: True
        EOF
      '';
  hpkgs = pkgs.haskell.packages.ghc9102 or pkgs.haskellPackages;
  benchHpkgs = pkgs.haskell.packages.ghc9103 or hpkgs;
  benchGhc = pkgs.haskell.compiler.ghc9103 or benchHpkgs.ghc;
  stripBin = "${pkgs.stdenv.cc.bintools.bintools}/bin/strip";
  writeMetadataJson = metadata: ''
    cat > "$out/metadata.json" <<'JSON'
    ${builtins.toJSON metadata}
    JSON
  '';
  assertCrossHelloElf = ''
    file "$out/bin/cross-hello" > "$out/file.txt"
    grep -E 'ELF.*(aarch64|ARM aarch64)' "$out/file.txt"
  '';
  haskellNixCrossAarch64 = haskellNixPkgs.pkgsCross.aarch64-multiplatform;
  backpackSrc = ../../../../tests/fixtures/backpack-multi-instance;
  crossHelloSrc = ../../../../tests/fixtures/cross-hello;
  hsBootThSrc = ../../../../tests/fixtures/hs-boot-th;
  lockExternalSrc = ../../../../tests/fixtures/lock-external;
  localThDependencySrc = ../../../../tests/fixtures/local-th-dependency;
  moduleCutoff30Src = ../../../../tests/fixtures/module-cutoff-30;
  multiInstanceExternalSrc = ../../../../tests/fixtures/multi-instance-external;
  simpleLibSrc = ../../../../tests/fixtures/simple-lib;
  benchSrc = ../../../../tests/bench/vs-haskell-nix/project;
  benchLock = builtins.fromJSON (builtins.readFile (benchSrc + "/penance.lock"));
  # Arc B seed: the module-granular prototype still invokes raw GHC,
  # but its external package flags come from the committed lock.
  benchGhcPackageNames = map (unit: unit.name) (
    builtins.filter (unit: unit.source == "ghc-boot" && unit.name != "base") benchLock.externalUnits
  );
  benchGhcPackageFlags = pkgs.lib.concatMapStringsSep " " (
    name: "-package ${name}"
  ) benchGhcPackageNames;
  benchDyndrvGhcFlags = [
    "-hide-all-packages"
    "-no-user-package-db"
    "-package"
    "base"
  ]
  ++ pkgs.lib.concatMap (name: [
    "-package"
    name
  ]) benchGhcPackageNames
  ++ [
    "-O0"
    "-fomit-interface-pragmas"
    "-fignore-interface-pragmas"
    "-fhide-source-paths"
    "-fdiagnostics-color=never"
  ];
  benchDyndrvGhcFlagsText = pkgs.lib.concatStringsSep "\n" benchDyndrvGhcFlags;
  cutoff30DyndrvGhcFlags = [
    "-hide-all-packages"
    "-no-user-package-db"
    "-package"
    "base"
    "-O0"
    "-fomit-interface-pragmas"
    "-fignore-interface-pragmas"
    "-fhide-source-paths"
    "-fdiagnostics-color=never"
  ];
  cutoff30DyndrvGhcFlagsText = pkgs.lib.concatStringsSep "\n" cutoff30DyndrvGhcFlags;
  hsBootThDyndrvGhcFlags = [
    "-hide-all-packages"
    "-no-user-package-db"
    "-package"
    "base"
    "-package"
    "template-haskell"
    "-O0"
    "-fomit-interface-pragmas"
    "-fignore-interface-pragmas"
    "-fhide-source-paths"
    "-fdiagnostics-color=never"
  ];
  hsBootThDyndrvGhcFlagsText = pkgs.lib.concatStringsSep "\n" hsBootThDyndrvGhcFlags;
  crossHaskellCompilerName = "ghc910";
  crossHaskellCompilerAttr = haskellNixPkgs.haskell-nix.resolve-compiler-name crossHaskellCompilerName;
  crossHaskellTarget = "aarch64-unknown-linux-gnu";
  # The same Rts.hs fix must land in the hadrian input drv and in the
  # in-tree hadrian sources that GHC's build uses.
  patchHadrianRtsRules = dir: ''
    substituteInPlace ${dir}/Rules/Rts.hs \
      --replace-fail 'when osxHost $ cmd' 'when (osxHost && libSuf == ".dylib") $ cmd'
  '';
  crossHaskellHadrianFor =
    ghc:
    ghc.hadrian.overrideAttrs (old: {
      postPatch = (old.postPatch or "") + patchHadrianRtsRules "src";
    });
  crossHaskellGhcFor =
    ghc:
    (ghc.override {
      useLLVM = true;
      libffi = null;
      ghcFlavour = "quickest+llvm";
      hadrian = crossHaskellHadrianFor ghc;
      enableProfiledLibs = false;
      enableDocs = false;
    }).overrideAttrs
      (old: {
        postPatch = (old.postPatch or "") + patchHadrianRtsRules "hadrian/src";
        hadrianFlags = (old.hadrianFlags or [ ]) ++ [
          "*.*.ghc.*.opts += -I${haskellNixCrossAarch64.libffi.dev}/include"
        ];
      });
  haskellNixCompilerShapeFor =
    baseCompiler: ghc:
    haskellNixPkgs.haskell-nix.haskellLib.makeCompilerDeps (
      ghc.overrideAttrs (old: {
        passthru = (old.passthru or { }) // {
          raw-src = baseCompiler.raw-src or baseCompiler.buildGHC.raw-src;
          buildGHC = benchHpkgs.ghc;
          targetPrefix = ghc.targetPrefix or "${crossHaskellTarget}-";
          version = ghc.version or baseCompiler.version;
        };
      })
    );
  stackageStateVarSnapshot =
    ../../../../tests/fixtures/stackage + "/${stackageResolver}-StateVar.yaml";
  stackageStateVarSnapshotUrl = "https://raw.githubusercontent.com/commercialhaskell/stackage-snapshots/master/lts/24/41.yaml";
  stackageStateVarSnapshotHash = "0309c4253d979705ab59973fd0c67e263e863ed7158bb4507f13165e46f20842";
  stackageStateVarSnapshotLine =
    pkgs.lib.findFirst (line: pkgs.lib.hasPrefix "- hackage: StateVar-" line)
      (throw "StateVar is missing from ${stackageResolver} snapshot")
      (pkgs.lib.splitString "\n" (builtins.readFile stackageStateVarSnapshot));
  stackageStateVarVersion = builtins.head (
    pkgs.lib.splitString "@" (pkgs.lib.removePrefix "- hackage: StateVar-" stackageStateVarSnapshotLine)
  );
  penanceStateVarHackageGhc = benchHpkgs.ghcWithPackages (ps: [
    (ps.callHackage "StateVar" hackageStateVarVersion { })
  ]);
  penanceStateVarStackageGhc = benchHpkgs.ghcWithPackages (ps: [
    (ps.callHackage "StateVar" stackageStateVarVersion { })
  ]);
in
{
  inherit
    ghcWasm
    haskellNix
    hackageStateVarVersion
    stackageResolver
    system
    pkgs
    haskellNixPkgs
    repentCabalIndexState
    repentHackageIndex
    repentHackageRepo
    repentCabalDir
    hpkgs
    benchHpkgs
    benchGhc
    stripBin
    writeMetadataJson
    assertCrossHelloElf
    haskellNixCrossAarch64
    backpackSrc
    crossHelloSrc
    hsBootThSrc
    lockExternalSrc
    localThDependencySrc
    moduleCutoff30Src
    multiInstanceExternalSrc
    simpleLibSrc
    benchSrc
    benchLock
    benchGhcPackageNames
    benchGhcPackageFlags
    benchDyndrvGhcFlags
    benchDyndrvGhcFlagsText
    cutoff30DyndrvGhcFlags
    cutoff30DyndrvGhcFlagsText
    hsBootThDyndrvGhcFlags
    hsBootThDyndrvGhcFlagsText
    crossHaskellCompilerName
    crossHaskellCompilerAttr
    crossHaskellTarget
    patchHadrianRtsRules
    crossHaskellHadrianFor
    crossHaskellGhcFor
    haskellNixCompilerShapeFor
    stackageStateVarSnapshot
    stackageStateVarSnapshotUrl
    stackageStateVarSnapshotHash
    stackageStateVarSnapshotLine
    stackageStateVarVersion
    penanceStateVarHackageGhc
    penanceStateVarStackageGhc
    ;
}
