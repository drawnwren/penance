#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: validate-hackage-package.sh [--index-state TIMESTAMP|HEAD] --compiler ID --compiler-nix-name NAME PACKAGE_OR_PACKAGE_VERSION

Examples:
  scripts/validate-hackage-package.sh StateVar-1.2.2
  scripts/validate-hackage-package.sh --index-state HEAD colour

The script downloads the Hackage source with cabal get, creates a temporary
single-package cabal.project, evaluates penance and real haskell.nix against it,
and runs surface parity validation.
EOF
}

index_state="${PENANCE_INDEX_STATE:-2026-02-01T00:00:00Z}"
compiler_nix_name="${PENANCE_COMPILER_NIX_NAME:-}"
penance_compiler="${PENANCE_COMPILER:-}"
keep_work="${PENANCE_KEEP_HACKAGE_WORK:-1}"
package_spec=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --index-state)
      index_state="${2:?--index-state requires a value}"
      shift 2
      ;;
    --compiler-nix-name)
      compiler_nix_name="${2:?--compiler-nix-name requires a value}"
      shift 2
      ;;
    --compiler)
      penance_compiler="${2:?--compiler requires a value}"
      shift 2
      ;;
    --cleanup)
      keep_work=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      echo "unknown option: $1" >&2
      usage
      exit 2
      ;;
    *)
      if [[ -n "$package_spec" ]]; then
        echo "only one package spec is supported" >&2
        usage
        exit 2
      fi
      package_spec="$1"
      shift
      ;;
  esac
done

if [[ -z "$package_spec" ]]; then
  usage
  exit 2
fi

if [[ -z "$penance_compiler" || -z "$compiler_nix_name" ]]; then
  echo "--compiler and --compiler-nix-name are required" >&2
  usage
  exit 2
fi

read_cabal_field() {
  local field="$1"
  local path="$2"
  perl -Mstrict -Mwarnings -e '
    my ($field, $path) = @ARGV;
    open my $fh, "<", $path or die "cannot open $path: $!";
    while (my $line = <$fh>) {
      $line =~ s/\r?\n\z//;
      $line =~ s/--.*\z//;
      if ($line =~ /^\s*\Q$field\E\s*:\s*(.*?)\s*\z/i) {
        print $1;
        exit 0;
      }
    }
    exit 1;
  ' "$field" "$path"
}

nix_string() {
  jq -Rn --arg value "$1" '$value'
}

repo_root="${PENANCE_REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
nix_bin="${PENANCE_NIX_BIN:-nix}"
current_system="$("$nix_bin" eval --raw --impure --expr builtins.currentSystem)"
default_out_dir="${PENANCE_HACKAGE_OUT_DIR:-$(pwd -P)}"
case "$default_out_dir" in
  /nix/store/*)
    default_out_dir="${TMPDIR:-/tmp}"
    ;;
esac

safe_spec="$(printf '%s' "$package_spec" | tr -c 'A-Za-z0-9._-' '-')"
timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
work_dir="${PENANCE_HACKAGE_WORKDIR:-/tmp/penance-hackage-${safe_spec}-${timestamp}}"
project_dir="$work_dir/project"
out_link="${PENANCE_HACKAGE_OUT_LINK:-$default_out_dir/result-hackage-${safe_spec}}"

rm -rf "$work_dir"
mkdir -p "$project_dir"
mkdir -p "$(dirname "$out_link")"

printf 'fetching Hackage source: %s\n' "$package_spec" >&2
cabal get "$package_spec" --index-state="$index_state" --destdir="$project_dir" >/dev/null

mapfile -t cabal_files < <(find "$project_dir" -mindepth 2 -maxdepth 2 -name '*.cabal' | sort)
if [[ "${#cabal_files[@]}" -ne 1 ]]; then
  printf 'expected exactly one unpacked .cabal file, found %s\n' "${#cabal_files[@]}" >&2
  printf '%s\n' "${cabal_files[@]}" >&2
  exit 1
fi

cabal_file="${cabal_files[0]}"
package_dir="$(dirname "$cabal_file")"
package_dir_name="$(basename "$package_dir")"
package_name="$(read_cabal_field name "$cabal_file")"
package_version="$(read_cabal_field version "$cabal_file")"

if [[ -z "$package_name" || -z "$package_version" ]]; then
  echo "could not read package name/version from $cabal_file" >&2
  exit 1
fi

nix_repo_url="$(nix_string "path:$repo_root")"
nix_current_system="$(nix_string "$current_system")"
nix_penance_compiler="$(nix_string "$penance_compiler")"
nix_index_state="$(nix_string "$index_state")"
nix_package_name="$(nix_string "$package_name")"
nix_package_src_name="$(nix_string "$package_name-src")"
nix_compiler_nix_name="$(nix_string "$compiler_nix_name")"

cat >"$project_dir/cabal.project" <<EOF
packages: ./$package_dir_name
index-state: $index_state
EOF

cat >"$work_dir/flake.nix" <<EOF
{
  inputs.penance.url = $nix_repo_url;

  outputs = { self, penance }:
    let
      system = $nix_current_system;
      pkgs = import penance.inputs.nixpkgs {
        inherit system;
      };
      haskellNix = penance.inputs.haskellNix;
      haskellNixPkgs = import haskellNix.inputs.nixpkgs-unstable {
        inherit system;
        overlays = [ haskellNix.overlay ];
        inherit (haskellNix) config;
      };
      penanceLib = import (penance.outPath + "/nix/lib.nix") {
        inherit pkgs;
        inherit (pkgs) lib;
        plannerWasm = penance.outPath + "/nix/planner.wasm";
        penancePlanner = penance.packages.\${system}.plannerBin;
      };
      src = ./project;
      penanceModule = (penanceLib.penanceProject {
        inherit src;
        compiler = $nix_penance_compiler;
        index-state = $nix_index_state;
        mode = "module";
      }).drvGraph;
      hackageProject = haskellNixPkgs.haskell-nix.cabalProject' {
        name = $nix_package_name;
        src = haskellNixPkgs.haskell-nix.cleanSourceHaskell {
          name = $nix_package_src_name;
          inherit src;
        };
        compiler-nix-name = $nix_compiler_nix_name;
        index-state = $nix_index_state;
        cabalProject = builtins.readFile (src + "/cabal.project");
        cabalProjectLocal = "";
        cabalProjectFreeze = "";
        configureArgs = "";
      };
      hackagePackage = hackageProject.hsPkgs.${nix_package_name};
      packageName = hackagePackage.identifier.name;
      packageVersion = hackagePackage.identifier.version;
      libraryComponents =
        pkgs.lib.optional (hackagePackage.components ? library) {
          package = packageName;
          component = "lib";
          kind = "library";
          unitId = hackagePackage.components.library.identifier.unit-id;
        };
      sublibraryComponents =
        map
          (name: {
            package = packageName;
            component = "lib:\${name}";
            kind = "library";
            unitId = hackagePackage.components.sublibs.\${name}.identifier.unit-id;
          })
          (builtins.attrNames (hackagePackage.components.sublibs or {}));
      executableComponents =
        map
          (name: {
            package = packageName;
            component = "exe:\${name}";
            kind = "executable";
            unitId = hackagePackage.components.exes.\${name}.identifier.unit-id;
          })
          (builtins.attrNames (hackagePackage.components.exes or {}));
      testComponents =
        map
          (name: {
            package = packageName;
            component = "test:\${name}";
            kind = "test-suite";
            unitId = hackagePackage.components.tests.\${name}.identifier.unit-id;
          })
          (builtins.attrNames (hackagePackage.components.tests or {}));
      benchmarkComponents =
        map
          (name: {
            package = packageName;
            component = "bench:\${name}";
            kind = "benchmark";
            unitId = hackagePackage.components.benchmarks.\${name}.identifier.unit-id;
          })
          (builtins.attrNames (hackagePackage.components.benchmarks or {}));
      haskellNixSurface = pkgs.writeText ("haskell-nix-" + packageName + "-surface.json") (builtins.toJSON {
        source = "haskell.nix";
        packages = [{
          name = packageName;
          version = packageVersion;
        }];
        components =
          libraryComponents
          ++ sublibraryComponents
          ++ executableComponents
          ++ testComponents
          ++ benchmarkComponents;
      });
    in
    {
      packages.\${system} = {
        inherit haskellNixSurface penanceModule;
      };
      checks.\${system}.surface-parity = pkgs.runCommand (packageName + "-surface-parity") {
        nativeBuildInputs = [
          pkgs.diffutils
          pkgs.jq
          pkgs.perl
        ];
      } ''
        mkdir -p "\$out"
        \${penance.outPath}/scripts/validate-surface-parity.sh \\
          \${penanceModule} \\
          \${haskellNixSurface} \\
          \${./project/$package_dir_name/$(basename "$cabal_file")} \\
          "\$out"
      '';
    };
}
EOF

printf 'validating %s-%s in %s\n' "$package_name" "$package_version" "$work_dir" >&2
"$nix_bin" build "$work_dir#checks.$current_system.surface-parity" \
  --out-link "$out_link" \
  -L

jq '{status, counts, compared, filter}' "$out_link/surface-parity.json"

cat >&2 <<EOF

Surface parity output:
  $out_link/surface-parity.json

Temporary project:
  $work_dir
EOF

if [[ "$keep_work" == "0" ]]; then
  rm -rf "$work_dir"
fi
