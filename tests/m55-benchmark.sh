#!/usr/bin/env bash
set -euo pipefail

image=${1:?usage: tests/m55-benchmark.sh IMAGE}
profile=${2:-complete}
case "$profile" in complete) ;; *) echo 'usage: tests/m55-benchmark.sh IMAGE' >&2; exit 2 ;; esac
manifest=${M55_MANIFEST:-tests/fixtures/m55/workloads.json}
output=${M55_BENCHMARK_OUTPUT:-m55-benchmark.json}
workload_profile=${M55_BENCHMARK_PROFILE:-baseline}
warmups=$(jq -er '.warmups' "$manifest")
repetitions=$(jq -er '.measured_repetitions' "$manifest")
matches=${M55_BENCHMARK_MATCHES:-1000}
history_rows=${M55_BENCHMARK_HISTORY_ROWS:-10000}
if [[ -n ${M55_BENCHMARK_CASES:-} ]]; then
  IFS=',' read -ra cases <<<"$M55_BENCHMARK_CASES"
else
  mapfile -t cases < <(jq -er '.required_cases[]' "$manifest")
fi
for name in "${cases[@]}"; do
  jq -e --arg name "$name" '.required_cases | index($name) != null' "$manifest" >/dev/null
done
project=${COMPOSE_PROJECT_NAME:-pgreact-m55-${GITHUB_RUN_ID:-$$}}-benchmark
database=${M55_BENCHMARK_DB:-m55_benchmark}
run_dir="tests/.m55-benchmark-run-${GITHUB_RUN_ID:-$$}"
mkdir -p -- "$run_dir"

cleanup() {
  COMPOSE_PROJECT_NAME=$project docker compose -p "$project" down --volumes --remove-orphans >/dev/null 2>&1 || true
  if [[ -n ${M55_ARTIFACT_DIR:-} ]]; then
    mkdir -p -- "$M55_ARTIFACT_DIR"
    cp -a -- "$run_dir/." "$M55_ARTIFACT_DIR/"
    if [[ -f $output ]]; then
      cp -f -- "$output" "$M55_ARTIFACT_DIR/m55-benchmark.json" 2>/dev/null || true
    fi
  fi
  rm -rf -- "$run_dir"
}
trap cleanup EXIT

export COMPOSE_PROJECT_NAME=$project
export PG_REACT_IMAGE=$image
export PG_REACT_PLATFORM=linux/amd64
export PG_REACT_INIT_VERSION=0.44.0
export PG_REACT_POLL_INTERVAL_MS=${PG_REACT_POLL_INTERVAL_MS:-1000}

docker compose -p "$project" up -d --no-build >/dev/null 2>&1
ready=
for _ in {1..120}; do
  if docker compose -p "$project" exec -T postgres psql -XAtq -U postgres -d postgres -c \
      "SELECT extversion = '0.44.0' FROM pg_extension WHERE extname = 'pg_react'" 2>/dev/null | grep -qx t; then
    ready=1
    break
  fi
  sleep 1
done
test -n "$ready"

run_case() {
  local name=$1 phase=$2 number=$3 slug=${1//./-}
  local stem="$run_dir/${slug}-${phase}-${number}"
  local log="$stem.log" json="$stem.json" result
  if ! result=$(M55_BENCHMARK_DB="$database" COMPOSE_PROJECT_NAME="$project" \
      M55_BENCHMARK_MATCHES="$matches" \
      M55_BENCHMARK_HISTORY_ROWS="$history_rows" \
      bash tests/m55-benchmark-case.sh "$name" 2>"$log"); then
    sed -n '1,$p' "$log"
    return 1
  fi
  printf '%s\n' "$result" | jq --arg profile "$workload_profile" \
    --argjson matches "$matches" --argjson history_rows "$history_rows" \
    '. + {profile: $profile, parameters: {matches: $matches, history_rows: $history_rows}}' >"$json"
  jq -e --arg name "$name" '
    type == "object" and .name == $name and
    (.correctness | type == "boolean") and
    (.state_hash | type == "string") and
    (.elapsed_ms | type == "number") and
    (.wal_bytes | type == "number") and
    (.database_bytes | type == "number")' "$json" >/dev/null
}

case_results=()
for name in "${cases[@]}"; do
  slug=${name//./-}
  for ((i=1; i<=warmups; i++)); do
    run_case "$name" warmup "$i"
  done
  for ((i=1; i<=repetitions; i++)); do
    run_case "$name" measured "$i"
  done
  case_json="$run_dir/${slug}.json"
  jq -S -s --arg name "$name" '
    def percentile($p):
      . as $values
      | ($values | sort) as $sorted
      | $sorted[((($sorted | length) * $p | ceil) - 1)];
    {
      name: $name,
      profile: .[0].profile,
      parameters: .[0].parameters,
      correctness: (map(.correctness) | all),
      state_consistent: (map(.state_hash) | unique | length == 1),
      failures: (map(select(.correctness != true)) | length),
      elapsed_ms: {
        sample_count: length,
        p50: ([.[] | .elapsed_ms] | percentile(0.50)),
        p95: ([.[] | .elapsed_ms] | percentile(0.95)),
        p99: ([.[] | .elapsed_ms] | percentile(0.99))
      },
      wal_bytes: {
        sample_count: length,
        p50: ([.[] | .wal_bytes] | percentile(0.50)),
        p95: ([.[] | .wal_bytes] | percentile(0.95)),
        p99: ([.[] | .wal_bytes] | percentile(0.99))
      },
      database_bytes: {
        sample_count: length,
        max: ([.[] | .database_bytes] | max)
      },
      peak_memory_bytes: null,
      peak_memory_status: "unavailable",
      runs: .
    }' "$run_dir/${slug}-measured-"*.json >"$case_json"
  if ! jq -e '.correctness and .state_consistent and .failures == 0' "$case_json" >/dev/null; then
    jq -S . "$case_json"
    exit 1
  fi
  case_results+=("$case_json")
done

cases_json="$run_dir/cases.json"
jq -S -s . "${case_results[@]}" >"$cases_json"
image_id=$(docker image inspect --format '{{.Id}}' "$image")
revision=$(git rev-parse HEAD)
acceptance=$(jq -c '.acceptance' "$manifest")
docker_server_version=$(docker info --format '{{.ServerVersion}}')
docker_architecture=$(docker info --format '{{.Architecture}}')
if [[ ${M55_ALLOW_NON_AMD64:-0} != 1 && $docker_architecture != amd64 && $docker_architecture != x86_64 ]]; then
  printf 'M59 benchmark requires an amd64 Docker host, found %s\n' "$docker_architecture" >&2
  exit 1
fi
docker_cpu_count=$(docker info --format '{{.NCPU}}')
docker_memory_bytes=$(docker info --format '{{.MemTotal}}')
disk_free_bytes=$(df -Pk . | awk 'NR == 2 { print $4 * 1024 }')
postgres_settings=$(docker compose -p "$project" exec -T postgres psql -XAtq -U postgres -d postgres -c \
  "SELECT jsonb_object_agg(name, setting ORDER BY name) FROM pg_settings WHERE name IN ('default_transaction_isolation', 'max_connections', 'shared_buffers', 'work_mem')")
mkdir -p -- "$(dirname -- "$output")"
jq -S -n \
  --arg image "$image" \
  --arg image_id "$image_id" \
  --arg revision "$revision" \
  --arg profile "$profile" \
  --arg workload_profile "$workload_profile" \
  --arg docker_server_version "$docker_server_version" \
  --arg docker_architecture "$docker_architecture" \
  --argjson docker_cpu_count "$docker_cpu_count" \
  --argjson docker_memory_bytes "$docker_memory_bytes" \
  --argjson disk_free_bytes "$disk_free_bytes" \
  --argjson postgres_settings "$postgres_settings" \
  --argjson warmups "$warmups" \
  --argjson repetitions "$repetitions" \
  --argjson acceptance "$acceptance" \
  --slurpfile cases "$cases_json" \
  '{schema_version: 1, milestone: "M55", release: "0.44.0",
    profile: $profile, workload_profile: $workload_profile,
    image: $image, image_id: $image_id,
    git_revision: $revision, platform: "linux/amd64", postgresql: "18.3",
    pg_trickle: "0.81.0", warmups: $warmups,
    measured_repetitions: $repetitions, acceptance: $acceptance,
    environment: {
      docker_server_version: $docker_server_version,
      docker_architecture: $docker_architecture,
      docker_cpu_count: $docker_cpu_count,
      docker_memory_bytes: $docker_memory_bytes,
      disk_free_bytes: $disk_free_bytes,
      postgres_settings: $postgres_settings
    }, cases: $cases[0]}' >"$output"
jq -e --argjson acceptance "$acceptance" '
  (if $acceptance.comparison_p95_ms == null then true else
    ([.cases[] | select((.name | startswith("comparison.")) or
                         (.name | startswith("review."))) | .elapsed_ms.p95]
     | if length == 0 then true else max <= $acceptance.comparison_p95_ms end)
  end) and
  (if $acceptance.recovery_p95_ms == null then true else
    ([.cases[] | select(.name | startswith("recovery.")) | .elapsed_ms.p95]
     | if length == 0 then true else max <= $acceptance.recovery_p95_ms end)
  end)' "$output" >/dev/null
jq -r '.cases[] | "\(.name) passed: p50=\(.elapsed_ms.p50)ms p95=\(.elapsed_ms.p95)ms p99=\(.elapsed_ms.p99)ms"' "$output"
