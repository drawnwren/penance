#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: bench-architecture-phases.sh [options]

Runs the architecture phase benchmark matrix. Comparison phases time evaluation
and nix builds for equivalent penance and haskell.nix package attrs. Failing
phases record architecture failures.

Options:
  --flake REF          flake to benchmark (default: repo root)
  --matrix PATH       phase matrix JSON (default: tests/architecture/phase-matrix.json)
  --system SYSTEM     Nix system (default: builtins.currentSystem)
  --out-dir DIR       output directory (default: docs/bench-results/architecture)
  --phase ID          run only one phase; may be repeated
  --repeat N          repeat runnable measurements N times (default: 1)
  --rebuild           pass --rebuild to nix build for local rebuild timing
  --dry-run           use nix build --dry-run instead of real builds
  --keep-going        continue after a failed runnable measurement
  --list              print the phase matrix and exit
  -h, --help          show this help

Environment:
  PENANCE_NIX_BIN     nix executable to use
  PENANCE_PHASE_BENCH_OUT
  PENANCE_PHASE_BENCH_MATRIX
EOF
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
nix_bin="${PENANCE_NIX_BIN:-nix}"
flake_ref="$repo_root"
matrix_path="${PENANCE_PHASE_BENCH_MATRIX:-$repo_root/tests/architecture/phase-matrix.json}"
out_dir="${PENANCE_PHASE_BENCH_OUT:-$repo_root/docs/bench-results/architecture}"
system=""
repeat=1
rebuild=0
dry_run=0
keep_going=0
list_only=0
phase_filters=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --flake)
      flake_ref="${2:?--flake requires a value}"
      shift 2
      ;;
    --matrix)
      matrix_path="${2:?--matrix requires a value}"
      shift 2
      ;;
    --system)
      system="${2:?--system requires a value}"
      shift 2
      ;;
    --out-dir)
      out_dir="${2:?--out-dir requires a value}"
      shift 2
      ;;
    --phase)
      phase_filters+=("${2:?--phase requires a value}")
      shift 2
      ;;
    --repeat)
      repeat="${2:?--repeat requires a value}"
      if ! [[ "$repeat" =~ ^[1-9][0-9]*$ ]]; then
        echo "--repeat must be a positive integer" >&2
        exit 2
      fi
      shift 2
      ;;
    --rebuild)
      rebuild=1
      shift
      ;;
    --dry-run)
      dry_run=1
      shift
      ;;
    --keep-going)
      keep_going=1
      shift
      ;;
    --list)
      list_only=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown option: $1" >&2
      usage
      exit 2
      ;;
  esac
done

if ! command -v jq >/dev/null 2>&1; then
  echo "bench-architecture-phases.sh requires jq" >&2
  exit 2
fi

if [[ ! -f "$matrix_path" ]]; then
  echo "phase matrix not found: $matrix_path" >&2
  exit 2
fi

if [[ -z "$system" ]]; then
  system="$("$nix_bin" eval --raw --impure --expr builtins.currentSystem)"
fi

if [[ "$list_only" == "1" ]]; then
  printf '%-24s %-10s %-32s %-24s %-5s %s\n' \
    "PHASE" "STATE" "PENANCE TARGET" "HASKELL.NIX TARGET" "GATE" "TITLE"
  printf '%-24s %-10s %-32s %-24s %-5s %s\n' \
    "-----" "-----" "--------------" "------------------" "----" "-----"
  jq -r '
    .phases[]
    | [
        .id,
        .status,
        (.penanceAttr // "-"),
        (.haskellNixAttr // "-"),
        (if .required then "yes" else "no" end),
        .title
      ]
    | @tsv
  ' "$matrix_path" |
    while IFS=$'\t' read -r id status penance_attr haskell_attr required title; do
      printf '%-24s %-10s %-32s %-24s %-5s %s\n' \
        "$id" "$status" "$penance_attr" "$haskell_attr" "$required" "$title"
    done
  cat <<'EOF'

States:
  comparison  equivalent real penance build vs real haskell.nix build
  failing     required comparison is not implemented or not passing yet
EOF
  exit 0
fi

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
run_dir="$out_dir/$system-$stamp"
log_dir="$run_dir/logs"
link_dir="$run_dir/results"
metrics_tsv="$run_dir/metrics.tsv"
metrics_jsonl="$run_dir/metrics.jsonl"
summary_json="$run_dir/summary.json"

mkdir -p "$log_dir" "$link_dir"

cat >"$metrics_tsv" <<'EOF'
run_id	phase_id	milestone	phase_title	backend	attr	action	status	supported	wall_ms	drv_path	out_path	closure_nar_size	log	command
EOF
: >"$metrics_jsonl"

json_bool() {
  case "$1" in
    1|true) printf 'true' ;;
    *) printf 'false' ;;
  esac
}

now_ms() {
  perl -MTime::HiRes=time -e 'printf "%.0f\n", time() * 1000'
}

contains_phase() {
  local phase="$1"
  if [[ "${#phase_filters[@]}" -eq 0 ]]; then
    return 0
  fi
  local wanted
  for wanted in "${phase_filters[@]}"; do
    [[ "$phase" == "$wanted" ]] && return 0
  done
  return 1
}

sanitize() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '-'
}

record_row() {
  local run_id="$1"
  local phase_id="$2"
  local milestone="$3"
  local phase_title="$4"
  local backend="$5"
  local attr="$6"
  local action="$7"
  local status="$8"
  local supported="$9"
  local wall_ms="${10}"
  local drv_path="${11}"
  local out_path="${12}"
  local closure_nar_size="${13}"
  local log_path="${14}"
  local command_text="${15}"

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$run_id" "$phase_id" "$milestone" "$phase_title" "$backend" "$attr" \
    "$action" "$status" "$supported" "$wall_ms" "$drv_path" "$out_path" \
    "$closure_nar_size" "$log_path" "$command_text" >>"$metrics_tsv"

  jq -cn \
    --arg runId "$run_id" \
    --arg phaseId "$phase_id" \
    --arg milestone "$milestone" \
    --arg phaseTitle "$phase_title" \
    --arg backend "$backend" \
    --arg attr "$attr" \
    --arg action "$action" \
    --arg status "$status" \
    --argjson supported "$(json_bool "$supported")" \
    --argjson wallMs "$wall_ms" \
    --arg drvPath "$drv_path" \
    --arg outPath "$out_path" \
    --argjson closureNarSize "$closure_nar_size" \
    --arg log "$log_path" \
    --arg command "$command_text" \
    '{
      runId: $runId,
      phaseId: $phaseId,
      milestone: $milestone,
      phaseTitle: $phaseTitle,
      backend: $backend,
      attr: (if $attr == "" then null else $attr end),
      action: $action,
      status: $status,
      supported: $supported,
      wallMs: $wallMs,
      drvPath: (if $drvPath == "" then null else $drvPath end),
      outPath: (if $outPath == "" then null else $outPath end),
      closureNarSize: $closureNarSize,
      log: (if $log == "" then null else $log end),
      command: (if $command == "" then null else $command end)
    }' >>"$metrics_jsonl"
}

run_timed() {
  local log_path="$1"
  shift

  local start end status
  start="$(now_ms)"
  set +e
  "$@" >"$log_path" 2>&1
  status=$?
  set -e
  end="$(now_ms)"

  RUN_TIMED_STATUS="$status"
  RUN_TIMED_WALL_MS="$((end - start))"
}

run_timed_split() {
  local stdout_path="$1"
  local log_path="$2"
  shift 2

  local start end status
  start="$(now_ms)"
  set +e
  "$@" >"$stdout_path" 2>"$log_path"
  status=$?
  set -e
  end="$(now_ms)"

  RUN_TIMED_STATUS="$status"
  RUN_TIMED_WALL_MS="$((end - start))"
}

path_nar_size() {
  local path="$1"
  if [[ -z "$path" || ! -e "$path" || "$dry_run" == "1" ]]; then
    printf '0\n'
    return
  fi

  if [[ -L "$path" ]]; then
    path="$(readlink "$path")"
  fi

  "$nix_bin" path-info --json -S "$path" 2>/dev/null \
    | jq -r '.[0].narSize // 0' 2>/dev/null \
    || printf '0\n'
}

print_human_summary() {
  local summary_path="$1"

  jq -r '
    def seconds:
      if . == null or . == 0 then "-"
      else ((. / 1000 * 100 | round / 100) | tostring) + "s"
      end;

    def row_status:
      (.status | tostring) as $status
      | if $status == "0" then "ok" else $status end;

    def measurement_rows:
      [ .rows[]
        | select(.action == "eval_drv_path" or .action == "build" or .action == "build_dry_run")
      ];

    def failure_rows:
      [ .rows[]
        | select(
            .action == "architecture_failure"
            or (.action != "skipped" and (.status | tostring) != "0")
          )
      ];

    def skipped_rows:
      [ .rows[] | select(.action == "skipped") ];

    "Architecture benchmark summary",
    "  system: " + .system,
    "  result: " + (if .failures == 0 then "PASS" else "FAIL (" + (.failures | tostring) + " failure(s))" end),
    "  rows: " + (.rows | length | tostring),
    "",
    "Failures:",
    (failure_rows as $failures
      | if ($failures | length) == 0 then
          "  none"
        else
          ($failures[]
            | "  - " + .phaseId + " [" + .status + "]: "
              + (if .command != null and .command != "" then .command else (.log // "see log") end))
        end),
    "",
    "Measurements:",
    (measurement_rows as $measurements
      | if ($measurements | length) == 0 then
          "  none"
        else
          "  PHASE                    BACKEND      ACTION          STATUS  WALL",
          "  -----                    -------      ------          ------  ----",
          ($measurements[]
            | "  "
              + (.phaseId + "                        ")[0:24] + " "
              + (.backend + "            ")[0:12] + " "
              + (.action + "               ")[0:15] + " "
              + ((row_status) + "        ")[0:6] + " "
              + (.wallMs | seconds))
        end),
    "",
    "Skipped:",
    (skipped_rows as $skipped
      | if ($skipped | length) == 0 then
          "  none"
        else
          ($skipped[]
            | "  - " + .phaseId + " [" + .status + "]")
        end)
  ' "$summary_path"
}

measure_backend() {
  local run_id="$1"
  local phase_id="$2"
  local milestone="$3"
  local phase_title="$4"
  local backend="$5"
  local attr="$6"
  local repeat_index="$7"

  if [[ -z "$attr" || "$attr" == "null" ]]; then
    record_row "$run_id" "$phase_id" "$milestone" "$phase_title" "$backend" "" \
      "skipped" "unsupported" 0 0 "" "" 0 "" ""
    return 0
  fi

  local safe_phase safe_backend safe_attr eval_log build_log eval_ref drv_path
  safe_phase="$(sanitize "$phase_id")"
  safe_backend="$(sanitize "$backend")"
  safe_attr="$(sanitize "$attr")"
  eval_ref="$flake_ref#packages.$system.$attr.drvPath"
  eval_log="$log_dir/${safe_phase}-${safe_backend}-${safe_attr}-r${repeat_index}-eval.log"
  eval_out="$log_dir/${safe_phase}-${safe_backend}-${safe_attr}-r${repeat_index}-eval.out"

  run_timed_split "$eval_out" "$eval_log" "$nix_bin" eval --raw "$eval_ref"
  drv_path=""
  if [[ "$RUN_TIMED_STATUS" -eq 0 ]]; then
    drv_path="$(tr -d '\n' <"$eval_out")"
  fi

  record_row "$run_id" "$phase_id" "$milestone" "$phase_title" "$backend" "$attr" \
    "eval_drv_path" "$RUN_TIMED_STATUS" 1 "$RUN_TIMED_WALL_MS" "$drv_path" "" 0 \
    "$eval_log" "$nix_bin eval --raw $eval_ref"

  if [[ "$RUN_TIMED_STATUS" -ne 0 ]]; then
    return "$RUN_TIMED_STATUS"
  fi

  local build_ref build_action out_link closure_size build_status build_args=()
  build_ref="$flake_ref#packages.$system.$attr"
  out_link="$link_dir/${safe_phase}-${safe_backend}-${safe_attr}-r${repeat_index}"
  build_log="$log_dir/${safe_phase}-${safe_backend}-${safe_attr}-r${repeat_index}-build.log"

  if [[ "$dry_run" == "1" ]]; then
    build_action="build_dry_run"
    build_args=(build --dry-run "$build_ref" -L)
  else
    build_action="build"
    build_args=(build "$build_ref" --out-link "$out_link" -L)
    if [[ "$rebuild" == "1" ]]; then
      build_args+=(--rebuild)
    fi
  fi

  run_timed "$build_log" "$nix_bin" "${build_args[@]}"
  build_status="$RUN_TIMED_STATUS"
  if [[ "$build_status" -ne 0 || "$dry_run" == "1" ]]; then
    out_link=""
  fi
  closure_size="$(path_nar_size "$out_link")"

  record_row "$run_id" "$phase_id" "$milestone" "$phase_title" "$backend" "$attr" \
    "$build_action" "$build_status" 1 "$RUN_TIMED_WALL_MS" "$drv_path" "$out_link" \
    "$closure_size" "$build_log" "$nix_bin ${build_args[*]}"

  return "$build_status"
}

phase_count="$(jq '.phases | length' "$matrix_path")"
failures=0
selected=0
for ((i = 0; i < phase_count; i++)); do
  phase_id="$(jq -r ".phases[$i].id" "$matrix_path")"
  contains_phase "$phase_id" || continue
  selected=$((selected + 1))

  milestone="$(jq -r ".phases[$i].milestone" "$matrix_path")"
  phase_title="$(jq -r ".phases[$i].title" "$matrix_path")"
  phase_status="$(jq -r ".phases[$i].status" "$matrix_path")"
  failure_reason="$(jq -r ".phases[$i].failure // \"Required real-build comparison is not implemented\"" "$matrix_path")"
  penance_attr="$(jq -r ".phases[$i].penanceAttr // \"\"" "$matrix_path")"
  haskell_attr="$(jq -r ".phases[$i].haskellNixAttr // \"\"" "$matrix_path")"

  case "$phase_status" in
    comparison)
      :
      ;;
    failing)
      record_row "failing" "$phase_id" "$milestone" "$phase_title" "phase" "" \
        "architecture_failure" "not_implemented" 0 0 "" "" 0 "" "$failure_reason"
      failures=$((failures + 1))
      continue
      ;;
    *)
      echo "unknown phase status '$phase_status' for $phase_id" >&2
      exit 2
      ;;
  esac

  for ((r = 1; r <= repeat; r++)); do
    printf 'phase %s [%s] (%s), repeat %s/%s\n' "$phase_id" "$phase_status" "$phase_title" "$r" "$repeat" >&2

    if ! measure_backend "r$r" "$phase_id" "$milestone" "$phase_title" "penance" "$penance_attr" "$r"; then
      failures=$((failures + 1))
      [[ "$keep_going" == "1" ]] || break 2
    fi

    if ! measure_backend "r$r" "$phase_id" "$milestone" "$phase_title" "haskell.nix" "$haskell_attr" "$r"; then
      failures=$((failures + 1))
      [[ "$keep_going" == "1" ]] || break 2
    fi
  done
done

if [[ "$selected" -eq 0 ]]; then
  echo "no phases selected" >&2
  exit 2
fi

jq -s \
  --arg schema "penance/architecture-phase-bench/1" \
  --arg created "$stamp" \
  --arg system "$system" \
  --arg flake "$flake_ref" \
  --arg matrix "$matrix_path" \
  --argjson repeat "$repeat" \
  --argjson rebuild "$(json_bool "$rebuild")" \
  --argjson dryRun "$(json_bool "$dry_run")" \
  --argjson failures "$failures" \
  '{
    schema: $schema,
    created: $created,
    system: $system,
    flake: $flake,
    matrix: $matrix,
    options: {
      repeat: $repeat,
      rebuild: $rebuild,
      dryRun: $dryRun
    },
    failures: $failures,
    rows: .
  }' "$metrics_jsonl" >"$summary_json"

printf 'wrote architecture benchmark metrics:\n  %s\n  %s\n  %s\n' \
  "$metrics_tsv" "$metrics_jsonl" "$summary_json" >&2

print_human_summary "$summary_json" >&2

if [[ "$failures" -ne 0 ]]; then
  exit 1
fi
