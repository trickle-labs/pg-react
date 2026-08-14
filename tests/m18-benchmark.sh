#!/usr/bin/env bash
set -euo pipefail
profile=${1:?usage: tests/m18-benchmark.sh fast|complete COMMAND}; shift
case "$profile" in fast|complete) ;; *) exit 2 ;; esac
runner=("$@")
test "${#runner[@]}" -gt 0
manifest=${M18_MANIFEST:-tests/fixtures/m18/manifest.json}; baseline=${M18_BASELINE:-tests/fixtures/m18/baseline.json}; out=${M18_BENCHMARK_OUTPUT:-m18-benchmark.json}
record=${M18_RECORD_BASELINE:-false}
case "$record" in true|false) ;; *) exit 2 ;; esac
mapfile -t cases < <(jq -r ".benchmarks.$profile[]" "$manifest")
tmp=$(mktemp); trap 'rm -f "$tmp" "$tmp.log"' EXIT
first=true; printf '{"profile":"%s","cases":[' "$profile" >"$tmp"
measure() {
  local name=$1 value values=()
  for _ in 1 2 3; do
    "${runner[@]}" "$name" >/dev/null 2>"$tmp.log" || { cat "$tmp.log" >&2; return 1; }
  done
  for _ in 1 2 3 4 5; do
    value=$("${runner[@]}" "$name" 2>"$tmp.log") || { cat "$tmp.log" >&2; return 1; }
    values+=("$value")
  done
  printf '%s\n' "${values[@]}" | jq -s '
    .[0] as $f | {
      name:$f.name,
      correctness:(map(.correctness) | all),
      correctness_checksum:(map(.correctness_checksum) | unique | if length == 1 then .[0] else null end),
      update_throughput:(map(.update_throughput) | sort | .[2]),
      worker_throughput:(map(.worker_throughput) | sort | .[2]),
      update_p50_ms:(map(.update_p50_ms) | sort | .[2]),
      update_p95_ms:(map(.update_p95_ms) | max),
      worker_p50_ms:(map(.worker_p50_ms) | sort | .[2]),
      worker_p95_ms:(map(.worker_p95_ms) | max),
      window_p50_ms:(map(.window_p50_ms) | sort | .[2]),
      window_p95_ms:(map(.window_p95_ms) | max),
      watermark_p50_ms:(map(.watermark_p50_ms) | sort | .[2]),
      watermark_p95_ms:(map(.watermark_p95_ms) | max),
      peak_memory_bytes:(map(.peak_memory_bytes) | max),
      database_bytes:(map(.database_bytes) | max)
    }'
}
check() {
  jq -e --argjson a "$actual" --argjson e "$expected" '
    ($a.correctness == true) and ($a.name == $e.name) and
    ($a.correctness_checksum == $e.correctness_checksum) and
    ($a.update_throughput >= $e.update_throughput * 0.9) and
    ($a.worker_throughput >= $e.worker_throughput * 0.9) and
    ($a.update_p95_ms <= $e.update_p95_ms * 1.2) and
    ($a.worker_p95_ms <= $e.worker_p95_ms * 1.2) and
    ($a.window_p95_ms <= $e.window_p95_ms * 1.2) and
    ($a.watermark_p95_ms <= $e.watermark_p95_ms * 1.2) and
    ($a.peak_memory_bytes <= $e.peak_memory_bytes * 1.15) and
    ($a.database_bytes <= $e.database_bytes * 1.15)' >/dev/null
}
for name in "${cases[@]}"; do
  actual=$(measure "$name")
  jq -e --arg name "$name" '
    .name == $name and .correctness == true and
    (.correctness_checksum | type == "string") and
    ([.update_throughput,.worker_throughput,.update_p50_ms,.update_p95_ms,
      .worker_p50_ms,.worker_p95_ms,.window_p50_ms,.window_p95_ms,
      .watermark_p50_ms,.watermark_p95_ms,
      .peak_memory_bytes,.database_bytes] | all(type == "number"))' <<<"$actual" >/dev/null
  if [[ $record = false ]]; then
    expected=$(jq -ce --arg n "$name" '.cases[] | select(.name == $n)' "$baseline")
    if ! check; then
      actual=$(measure "$name")
      if ! check; then
        jq -cn --argjson actual "$actual" --argjson expected "$expected" \
          '{error:"M18 benchmark budget breached after deterministic rerun",actual:$actual,expected:$expected}' >&2
        exit 1
      fi
    fi
  fi
  $first || printf ',' >>"$tmp"; first=false; printf '%s' "$actual" >>"$tmp"
done
printf ']}' >>"$tmp"; jq -S . "$tmp" >"$out"; cat "$out"
