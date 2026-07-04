#!/usr/bin/env bash
set -euo pipefail

nix_bin="${PENANCE_NIX_BIN:-nix}"
system="${1:-$("$nix_bin" eval --raw --impure --expr builtins.currentSystem)}"
out_dir="${PENANCE_BENCH_OUT:-docs/bench-results}"
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
result="$out_dir/vs-haskell-nix-$system-$stamp.tsv"

mkdir -p "$out_dir"

time_bin=""
if [[ "$(uname -s)" == "Darwin" ]]; then
  time_bin="${PENANCE_TIME_BIN:-/usr/bin/time}"
  time_args=(-l)
else
  time_bin="${PENANCE_TIME_BIN:-$(command -v gtime || command -v time || printf /usr/bin/time)}"
  time_args=(-v)
fi

run_metric() {
  local name="$1"
  shift

  local log="$out_dir/$name-$system-$stamp.log"
  printf 'running %s\n' "$name" >&2

  local start end status
  start="$(date +%s)"
  set +e
  "$time_bin" "${time_args[@]}" "$@" >"$log" 2>&1
  status=$?
  set -e
  end="$(date +%s)"

  printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$status" "$((end - start))" "$log" "$*" >>"$result"
}

cat >"$result" <<EOF
scenario	status	wall_seconds	log	command
EOF

run_metric penance_eval_module \
  "$nix_bin" eval --raw ".#packages.$system.penanceBenchModule.drvPath"

run_metric penance_eval_component \
  "$nix_bin" eval --raw ".#packages.$system.penanceBenchComponent.drvPath"

run_metric penance_build_dry_run \
  "$nix_bin" build --dry-run ".#packages.$system.penanceBenchModule"

run_metric haskell_nix_eval_exe \
  "$nix_bin" eval --raw ".#packages.$system.haskellNixBenchExe.drvPath"

run_metric haskell_nix_build_dry_run \
  "$nix_bin" build --dry-run ".#packages.$system.haskellNixBenchExe"

printf 'wrote %s\n' "$result"
