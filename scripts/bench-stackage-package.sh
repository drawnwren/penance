#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: bench-stackage-package.sh [--resolver RESOLVER] [--package NAME] [--compiler-nix-name NAME] [--dry-run] [--cleanup]
       bench-stackage-package.sh RESOLVER PACKAGE

Examples:
  scripts/bench-stackage-package.sh lts-23.25 servant
  scripts/bench-stackage-package.sh --resolver lts-23.25 --package servant
  scripts/bench-stackage-package.sh --resolver nightly-2026-05-21 --package text

The script resolves PACKAGE in the Stackage snapshot, fetches that exact
Hackage source, generates a temporary Stack project, builds penance's planner
output, and builds a haskell.nix closure target for the package components and
their dependencies.
EOF
}

resolver="${PENANCE_STACKAGE_RESOLVER:-}"
package_name="${PENANCE_ST_PACKAGE:-}"
compiler_nix_name="${PENANCE_COMPILER_NIX_NAME:-}"
keep_work="${PENANCE_KEEP_STACKAGE_WORK:-1}"
build_mode="${PENANCE_STACKAGE_BUILD_MODE:-build}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --resolver)
      resolver="${2:?--resolver requires a value}"
      shift 2
      ;;
    --package)
      package_name="${2:?--package requires a value}"
      shift 2
      ;;
    --compiler-nix-name)
      compiler_nix_name="${2:?--compiler-nix-name requires a value}"
      shift 2
      ;;
    --dry-run)
      build_mode="dry-run"
      shift
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
      if [[ -z "$resolver" ]]; then
        resolver="$1"
      elif [[ -z "$package_name" ]]; then
        package_name="$1"
      else
        echo "too many positional arguments" >&2
        usage
        exit 2
      fi
      shift
      ;;
  esac
done

if [[ -z "$resolver" || -z "$package_name" ]]; then
  usage
  exit 2
fi

nix_string() {
  jq -Rn --arg value "$1" '$value'
}

resolver_snapshot_url() {
  local value="$1"
  if [[ "$value" =~ ^https?:// ]]; then
    printf '%s\n' "$value"
    return
  fi

  if [[ "$value" =~ ^lts-([0-9]+)\.([0-9]+)$ ]]; then
    printf 'https://raw.githubusercontent.com/commercialhaskell/stackage-snapshots/master/lts/%s/%s.yaml\n' \
      "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
    return
  fi

  if [[ "$value" =~ ^nightly-([0-9]{4})-([0-9]{2})-([0-9]{2})$ ]]; then
    local year="${BASH_REMATCH[1]}"
    local month="${BASH_REMATCH[2]#0}"
    local day="${BASH_REMATCH[3]#0}"
    printf 'https://raw.githubusercontent.com/commercialhaskell/stackage-snapshots/master/nightly/%s/%s/%s.yaml\n' \
      "$year" "$month" "$day"
    return
  fi

  echo "unsupported resolver '$value'; expected lts-X.Y, nightly-YYYY-MM-DD, or an http(s) snapshot URL" >&2
  exit 2
}

snapshot_package_version() {
  local package="$1"
  local snapshot="$2"
  perl -Mstrict -Mwarnings -e '
    my ($package, $snapshot) = @ARGV;
    open my $fh, "<", $snapshot or die "cannot open $snapshot: $!";
    while (my $line = <$fh>) {
      $line =~ s/\r?\n\z//;
      if ($line =~ /^\s*-\s+hackage:\s+\Q$package\E-([0-9][^@\s]*)\@/) {
        print $1;
        exit 0;
      }
    }
    exit 1;
  ' "$package" "$snapshot"
}

snapshot_field() {
  local field="$1"
  local snapshot="$2"
  perl -Mstrict -Mwarnings -e '
    my ($field, $snapshot) = @ARGV;
    open my $fh, "<", $snapshot or die "cannot open $snapshot: $!";
    while (my $line = <$fh>) {
      $line =~ s/\r?\n\z//;
      if ($line =~ /^\s*\Q$field\E:\s*(.*?)\s*\z/) {
        print $1;
        exit 0;
      }
    }
    exit 1;
  ' "$field" "$snapshot"
}

normalize_index_state() {
  local value="$1"
  if [[ "$value" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})\.[0-9]+Z$ ]]; then
    printf '%sZ\n' "${BASH_REMATCH[1]}"
  else
    printf '%s\n' "$value"
  fi
}

snapshot_compiler() {
  local snapshot="$1"
  perl -Mstrict -Mwarnings -e '
    my ($snapshot) = @ARGV;
    open my $fh, "<", $snapshot or die "cannot open $snapshot: $!";
    while (my $line = <$fh>) {
      $line =~ s/\r?\n\z//;
      if ($line =~ /^\s*compiler:\s*(ghc-[0-9][0-9.]*)\s*\z/) {
        print $1;
        exit 0;
      }
    }
    exit 1;
  ' "$snapshot"
}

compiler_to_nix_name() {
  local compiler="$1"
  local version="${compiler#ghc-}"
  printf 'ghc%s\n' "${version//./}"
}

repo_root="${PENANCE_REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
nix_bin="${PENANCE_NIX_BIN:-nix}"
system="${PENANCE_SYSTEM:-$("$nix_bin" eval --raw --impure --expr builtins.currentSystem)}"
default_out_dir="${PENANCE_STACKAGE_OUT_DIR:-$(pwd -P)}"
case "$default_out_dir" in
  /nix/store/*)
    default_out_dir="${TMPDIR:-/tmp}"
    ;;
esac

snapshot_url="$(resolver_snapshot_url "$resolver")"
safe_resolver="$(printf '%s' "$resolver" | tr -c 'A-Za-z0-9._-' '-')"
safe_package="$(printf '%s' "$package_name" | tr -c 'A-Za-z0-9._-' '-')"
timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
work_dir="${PENANCE_STACKAGE_WORKDIR:-/tmp/penance-stackage-${safe_resolver}-${safe_package}-${timestamp}}"
project_dir="$work_dir/project"
out_link="${PENANCE_STACKAGE_OUT_LINK:-$default_out_dir/result-stackage-${safe_resolver}-${safe_package}}"
metrics_dir="${PENANCE_STACKAGE_BENCH_OUT:-docs/bench-results}"
metrics="$metrics_dir/stackage-${safe_resolver}-${safe_package}-${system}-${timestamp}.tsv"

rm -rf "$work_dir"
mkdir -p "$project_dir" "$metrics_dir"
mkdir -p "$(dirname "$out_link")"

printf 'fetching Stackage snapshot: %s\n' "$snapshot_url" >&2
curl -L --fail --silent "$snapshot_url" -o "$work_dir/snapshot.yaml"

package_version="$(snapshot_package_version "$package_name" "$work_dir/snapshot.yaml" || true)"
if [[ -z "$package_version" ]]; then
  printf 'package %s was not found in Stackage resolver %s\n' "$package_name" "$resolver" >&2
  exit 1
fi

snapshot_publish_time="$(snapshot_field publish-time "$work_dir/snapshot.yaml" || true)"
snapshot_index_state="$(normalize_index_state "$snapshot_publish_time")"
snapshot_compiler_name="$(snapshot_compiler "$work_dir/snapshot.yaml" || true)"
if [[ -z "$snapshot_compiler_name" ]]; then
  echo "could not find compiler in snapshot $resolver" >&2
  exit 1
fi
if [[ -z "$compiler_nix_name" ]]; then
  compiler_nix_name="$(compiler_to_nix_name "$snapshot_compiler_name")"
fi

printf 'resolved %s in %s: %s-%s (%s, %s)\n' \
  "$package_name" "$resolver" "$package_name" "$package_version" "$snapshot_compiler_name" "$compiler_nix_name" >&2

printf 'fetching Hackage source: %s-%s\n' "$package_name" "$package_version" >&2
if [[ "${PENANCE_CABAL_UPDATE:-1}" != "0" ]]; then
  printf 'updating Cabal package index\n' >&2
  cabal update >/dev/null
fi
cabal_get_args=("$package_name-$package_version" "--destdir=$project_dir")
if [[ -n "$snapshot_index_state" ]]; then
  cabal_get_args+=("--index-state=$snapshot_index_state")
fi
cabal get "${cabal_get_args[@]}" >/dev/null

package_dir_name="$package_name-$package_version"
if [[ ! -d "$project_dir/$package_dir_name" ]]; then
  package_dir_name="$(find "$project_dir" -mindepth 1 -maxdepth 1 -type d | sed 's|.*/||' | sort | head -1)"
fi
if [[ -z "$package_dir_name" || ! -d "$project_dir/$package_dir_name" ]]; then
  echo "could not locate unpacked package directory" >&2
  exit 1
fi

cat >"$project_dir/stack.yaml" <<EOF
resolver: $resolver
packages:
- ./$package_dir_name
EOF

cat >"$project_dir/cabal.project" <<EOF
packages: ./$package_dir_name
EOF

nix_repo_url="$(nix_string "path:$repo_root")"
nix_system="$(nix_string "$system")"
nix_package_name="$(nix_string "$package_name")"
nix_package_version="$(nix_string "$package_version")"
nix_resolver="$(nix_string "$resolver")"
nix_snapshot_url="$(nix_string "$snapshot_url")"
nix_snapshot_compiler="$(nix_string "$snapshot_compiler_name")"
nix_compiler_nix_name="$(nix_string "$compiler_nix_name")"
nix_index_state="$(nix_string "${snapshot_index_state:-$resolver}")"

cat >"$work_dir/flake.nix" <<EOF
{
  inputs.penance.url = $nix_repo_url;

  outputs = { self, penance }:
    let
      system = $nix_system;
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
      packageName = $nix_package_name;
      packageVersion = $nix_package_version;
      resolver = $nix_resolver;
      snapshotUrl = $nix_snapshot_url;
      snapshotCompiler = $nix_snapshot_compiler;
      compilerNixName = $nix_compiler_nix_name;
      penanceModule = (penanceLib.penanceProject {
        inherit src;
        compiler = snapshotCompiler;
        index-state = $nix_index_state;
        mode = "module";
      }).drvGraph;
      stackageProject = haskellNixPkgs.haskell-nix.stackProject' {
        src = haskellNixPkgs.haskell-nix.cleanSourceHaskell {
          name = packageName + "-stackage-src";
          inherit src;
        };
        stackYaml = "stack.yaml";
        compiler-nix-name = compilerNixName;
      };
      targetPackage = stackageProject.hsPkgs.\${packageName};
      lib = pkgs.lib;
      componentId = component:
        let
          ident = component.identifier or {};
          componentIdValue = ident.component-id or null;
          unitIdValue = ident.unit-id or null;
          name = ident.name or "unknown";
          version = ident.version or "unknown";
        in
          if componentIdValue != null then componentIdValue
          else if unitIdValue != null then unitIdValue
          else name + ":" + version;
      componentJson = component:
        let ident = component.identifier or {};
        in {
          key = componentId component;
          package = ident.name or null;
          version = ident.version or null;
          unitId = ident.unit-id or null;
          componentId = ident.component-id or null;
          drvPath = component.drvPath or null;
        };
      presentComponents = attrs:
        builtins.filter (component: component != null) (builtins.attrValues attrs);
      libraryComponentDrvs =
        lib.optional (targetPackage.components ? library && targetPackage.components.library != null) targetPackage.components.library;
      sublibraryComponentDrvs =
        presentComponents (targetPackage.components.sublibs or {});
      executableComponentDrvs =
        presentComponents (targetPackage.components.exes or {});
      testComponentDrvs =
        presentComponents (targetPackage.components.tests or {});
      benchmarkComponentDrvs =
        presentComponents (targetPackage.components.benchmarks or {});
      targetComponentDrvs =
        libraryComponentDrvs
        ++ sublibraryComponentDrvs
        ++ executableComponentDrvs
        ++ testComponentDrvs
        ++ benchmarkComponentDrvs;
      dependencyClosureNodes = builtins.genericClosure {
        startSet = map (component: {
          key = componentId component;
          inherit component;
        }) targetComponentDrvs;
        operator = node:
          map (component: {
            key = componentId component;
            inherit component;
          }) (node.component.config.depends or []);
      };
      dependencyClosure = map (node: componentJson node.component) dependencyClosureNodes;
      targetComponents = map componentJson targetComponentDrvs;
      dependencyClosureJson = pkgs.writeText (packageName + "-stackage-dependency-closure.json") (builtins.toJSON {
        source = "haskell.nix";
        resolver = resolver;
        snapshotUrl = snapshotUrl;
        compiler = snapshotCompiler;
        compilerNixName = compilerNixName;
        package = {
          name = packageName;
          version = packageVersion;
        };
        counts = {
          targetComponents = builtins.length targetComponents;
          dependencyClosure = builtins.length dependencyClosure;
        };
        targetComponents = targetComponents;
        dependencyClosure = dependencyClosure;
      });
      haskellNixBuildClosure = pkgs.runCommand (packageName + "-stackage-build-closure") {
        buildInputs = targetComponentDrvs;
      } ''
        mkdir -p "\$out"
        cp \${dependencyClosureJson} "\$out/dependency-closure.json"
        printf '%s\n' \${lib.escapeShellArgs (map toString targetComponentDrvs)} > "\$out/target-component-store-paths.txt"
      '';
    in
    {
      packages.\${system} = {
        inherit dependencyClosureJson haskellNixBuildClosure penanceModule;
      };
      checks.\${system}.build-closure = haskellNixBuildClosure;
    };
}
EOF

time_bin=""
if [[ "$(uname -s)" == "Darwin" ]]; then
  time_bin="${PENANCE_TIME_BIN:-/usr/bin/time}"
  time_args=(-l)
else
  time_bin="${PENANCE_TIME_BIN:-$(command -v gtime || command -v time || printf /usr/bin/time)}"
  time_args=(-v)
fi

cat >"$metrics" <<EOF
scenario	status	wall_seconds	log	command
EOF

run_metric() {
  local name="$1"
  shift

  local log="$metrics_dir/$name-${safe_resolver}-${safe_package}-${system}-${timestamp}.log"
  printf 'running %s\n' "$name" >&2

  local start end status
  start="$(date +%s)"
  set +e
  "$time_bin" "${time_args[@]}" "$@" >"$log" 2>&1
  status=$?
  set -e
  end="$(date +%s)"

  printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$status" "$((end - start))" "$log" "$*" >>"$metrics"
  if [[ "$status" -ne 0 ]]; then
    printf '%s failed; see %s\n' "$name" "$log" >&2
    return "$status"
  fi
}

run_metric penance_plan_build \
  "$nix_bin" build "$work_dir#packages.$system.penanceModule" \
    --out-link "$work_dir/result-penance-plan" \
    -L

run_metric haskell_nix_eval_closure \
  "$nix_bin" eval --raw "$work_dir#packages.$system.haskellNixBuildClosure.drvPath"

if [[ "$build_mode" == "dry-run" ]]; then
  run_metric haskell_nix_build_closure_dry_run \
    "$nix_bin" build --dry-run "$work_dir#packages.$system.haskellNixBuildClosure" \
      -L
  closure_json_path=""
  build_output="(dry-run; no build output link)"
else
  run_metric haskell_nix_build_closure \
    "$nix_bin" build "$work_dir#packages.$system.haskellNixBuildClosure" \
      --out-link "$out_link" \
      -L
  closure_json_path="$out_link/dependency-closure.json"
  build_output="$out_link"
fi

if [[ -n "$closure_json_path" ]]; then
  jq '{source, resolver, compiler, compilerNixName, package, counts}' "$closure_json_path"
else
  jq -n \
    --arg resolver "$resolver" \
    --arg compiler "$snapshot_compiler_name" \
    --arg compilerNixName "$compiler_nix_name" \
    --arg name "$package_name" \
    --arg version "$package_version" \
    '{
      source: "haskell.nix",
      resolver: $resolver,
      compiler: $compiler,
      compilerNixName: $compilerNixName,
      package: {name: $name, version: $version},
      mode: "dry-run"
    }'
fi

cat >&2 <<EOF

Stackage build closure output:
  $build_output

Dependency closure:
  ${closure_json_path:-dry-run; not realized}

Benchmark metrics:
  $metrics

Temporary project:
  $work_dir
EOF

if [[ "$keep_work" == "0" ]]; then
  rm -rf "$work_dir"
fi
