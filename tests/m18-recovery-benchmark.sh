#!/usr/bin/env bash
set -euo pipefail

image=${1:?usage: tests/m18-recovery-benchmark.sh IMAGE}
output=${M18_RECOVERY_BENCHMARK_OUTPUT:-m18-recovery-benchmark.json}
test "${PG_REACT_IMAGE:?PG_REACT_IMAGE must name the release image}" = "$image"
test -n "${COMPOSE_PROJECT_NAME:?COMPOSE_PROJECT_NAME must identify the M18 project}"
scratch=$(mktemp -d)
trap 'rm -r -- "$scratch"' EXIT

run_sample() {
  local name=$1 log="$scratch/$1.log" artifact="$scratch/$1.json"
  if M18_RECOVERY_ARTIFACT="$artifact" RECOVERY_MILESTONE=m17 \
      bash tests/m6-recovery.sh >"$log" 2>&1; then
    test -s "$artifact"
  else
    sed -n '1,$p' "$log"
    return 1
  fi
}

for sample in warmup-1 warmup-2 warmup-3; do run_sample "$sample"; done
for sample in measured-1 measured-2 measured-3 measured-4 measured-5; do run_sample "$sample"; done
jq -s '{warmups:3,measured_runs:5,
         crash_restart_ms:(map(.crash_restart_ms)|max),
         logical_restore_ms:(map(.logical_restore_ms)|max),
         physical_restore_ms:(map(.physical_restore_ms)|max)}' \
  "$scratch"/measured-*.json >"$output"
jq -S . "$output"
