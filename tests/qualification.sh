#!/usr/bin/env bash
set -euo pipefail

profile=${1:-fast}
image=${2:-pg-react:m55-unreleased}
case "$profile" in fast|complete) ;; *) echo 'usage: tests/qualification.sh fast|complete [IMAGE]' >&2; exit 2 ;; esac

run_dir="tests/.m55-run-${GITHUB_RUN_ID:-$$}"
project=${COMPOSE_PROJECT_NAME:-pgreact-m55-${GITHUB_RUN_ID:-$$}}
upgrade_project=${project}-upgrade
mkdir -p -- "$run_dir"
cleanup() {
  COMPOSE_PROJECT_NAME=$project docker compose -p "$project" down --volumes --remove-orphans >/dev/null 2>&1 || true
  COMPOSE_PROJECT_NAME=$upgrade_project docker compose -p "$upgrade_project" down --volumes --remove-orphans >/dev/null 2>&1 || true
  if [[ -n ${M55_ARTIFACT_DIR:-} ]]; then
    mkdir -p -- "$M55_ARTIFACT_DIR"
    cp -a -- "$run_dir/." "$M55_ARTIFACT_DIR/"
  fi
  rm -rf -- "$run_dir"
}
trap cleanup EXIT

run_test() {
  local name=$1; shift
  local log="$run_dir/${name// /-}.log"
  local status
  set +e
  (set -e; "$@") >"$log" 2>&1
  status=$?
  set -e
  if (( status == 0 )); then
    printf '%s passed\n' "$name" >>"$log"
    echo "$name passed"
  else
    sed -n '1,$p' "$log"
    return "$status"
  fi
}

static_audit() {
  for file in \
    docs/current-release.json docs/api-inventory.json docs/benchmarks.md \
    docs/v0.44.0-release-notes.md docs/v0.44.0-migration.md \
    tests/fixtures/m55/workloads.json tests/v0.44.0.sql tests/v0.44.0-inherited.sql \
    tests/m55-comparison.sql tests/m55-m35.sql tests/m55-benchmark.sh \
    tests/m55-benchmark-case.sh tests/m55-benchmark-case.sql \
    sql/current/assembly.txt sql/current/README.md \
    sql/pg_react--0.43.3--0.44.0.sql sql/pg_react--0.44.0.sql \
    sql/v0.44.0.sql sql/m55.sql; do
    test -s "$file"
  done
  bash tests/current-docs.sh
  bash tests/api-inventory.sh
  bash tests/workflow-syntax.sh
  bash -n bin/assemble-sql tests/qualification.sh tests/current-docs.sh \
    tests/api-inventory.sh tests/workflow-syntax.sh tests/m55-benchmark.sh \
    tests/m55-benchmark-case.sh
  jq -e '.release == "0.44.0" and .milestone == "M55" and
    .warmups == 1 and .measured_repetitions == 5 and
    (.required_cases | length) == 7 and
    ([.profiles[].name] | sort) == ["backlog-10000", "baseline", "retained-history"] and
    (.acceptance.comparison_p95_ms | type) == "number" and
    (.acceptance.recovery_p95_ms | type) == "number"' tests/fixtures/m55/workloads.json >/dev/null
  bash bin/assemble-sql "$run_dir/fresh.sql"
  cmp "$run_dir/fresh.sql" sql/pg_react--0.44.0.sql
  bash bin/assemble-sql "$run_dir/upgrade.sql" \
    sql/current/upgrade-0.43.3-to-0.44.0.txt
  cmp "$run_dir/upgrade.sql" sql/pg_react--0.43.3--0.44.0.sql
  echo 'M55 static, assembly, and artifact audit passed'
}

run_test 'M55 static and artifact audit' static_audit

if ! command -v docker >/dev/null 2>&1 || ! docker image inspect "$image" >/dev/null 2>&1; then
  echo "M55 external Docker evidence not run: candidate image '$image' is unavailable"
  echo 'M55 static lane passed; no execution or scale claim made'
  exit 0
fi

export PG_REACT_IMAGE=$image
export PG_REACT_PLATFORM=linux/amd64
export PG_REACT_POLL_INTERVAL_MS=60000
export PG_REACT_PORT_BINDING=${PG_REACT_PORT_BINDING:-127.0.0.1::5432}
wait_for_version() {
  local version=$1
  local ready=
  for _ in {1..120}; do
    if docker compose -p "$COMPOSE_PROJECT_NAME" exec -T postgres psql -XAtq -U postgres -d postgres -c \
        "SELECT extversion = '$version' FROM pg_extension WHERE extname = 'pg_react'" 2>/dev/null | grep -qx t; then
      ready=1
      break
    fi
    sleep 1
  done
  test -n "$ready"
}

export COMPOSE_PROJECT_NAME=$project
export PG_REACT_INIT_VERSION=0.44.0
docker compose -p "$project" up -d --no-build >/dev/null 2>&1
wait_for_version 0.44.0
run_test '0.44.0 runtime contract' docker compose -p "$project" exec -T postgres \
  psql -XAtq -U postgres -d postgres -v ON_ERROR_STOP=1 -f - < tests/v0.44.0.sql
run_test 'M54 correctness corpus on 0.44.0' docker compose -p "$project" exec -T postgres \
  psql -XAtq -U postgres -d postgres -v ON_ERROR_STOP=1 -f - < tests/m54.sql
run_test '0.43.3 inherited correctness corpus on 0.44.0' docker compose -p "$project" exec -T postgres \
  psql -XAtq -U postgres -d postgres -v ON_ERROR_STOP=1 -f - < tests/v0.44.0-inherited.sql
run_test 'M34 scoped comparison corpus on 0.44.0' docker compose -p "$project" exec -T postgres \
  psql -XAtq -U postgres -d postgres -v ON_ERROR_STOP=1 -f - < tests/m55-comparison.sql
run_test 'M55 four-argument comparison on 0.44.0' docker compose -p "$project" exec -T postgres \
  psql -XAtq -U postgres -d postgres -v ON_ERROR_STOP=1 -f - < tests/m55-m35.sql

if [[ $profile = complete ]]; then
  mapfile -t benchmark_profiles < <(jq -er '.profiles[] | [.name, (.matches | tostring), (.history_rows | tostring), (.cases | join(","))] | @tsv' tests/fixtures/m55/workloads.json)
  for profile_row in "${benchmark_profiles[@]}"; do
    IFS=$'\t' read -r workload_profile profile_matches profile_history profile_cases <<<"$profile_row"
    profile_matches=${M55_BENCHMARK_MATCHES:-$profile_matches}
    profile_history=${M55_BENCHMARK_HISTORY_ROWS:-$profile_history}
    artifact_dir="$run_dir/m55-$workload_profile"
    run_test "M55 benchmark $workload_profile" env \
      M55_ARTIFACT_DIR="$artifact_dir" \
      M55_BENCHMARK_OUTPUT="$artifact_dir/m55-benchmark.json" \
      M55_BENCHMARK_PROFILE="$workload_profile" \
      M55_BENCHMARK_MATCHES="$profile_matches" \
      M55_BENCHMARK_HISTORY_ROWS="$profile_history" \
      M55_BENCHMARK_CASES="$profile_cases" \
      bash tests/m55-benchmark.sh "$image" complete
  done
fi

if [[ $profile = complete ]]; then
  export COMPOSE_PROJECT_NAME=$upgrade_project
  export PG_REACT_INIT_VERSION=0.43.3
  docker compose -p "$upgrade_project" up -d --no-build >/dev/null 2>&1
  wait_for_version 0.43.3
  run_test '0.43.3 to 0.44.0 adjacent upgrade' docker compose -p "$upgrade_project" exec -T postgres \
    psql -XAtq -U postgres -d postgres -v ON_ERROR_STOP=1 -c \
    "ALTER EXTENSION pg_react UPDATE TO '0.44.0';"
  run_test '0.44.0 upgraded runtime contract' docker compose -p "$upgrade_project" exec -T postgres \
    psql -XAtq -U postgres -d postgres -v ON_ERROR_STOP=1 -f - < tests/v0.44.0.sql
  run_test '0.44.0 upgraded M54 correctness corpus' docker compose -p "$upgrade_project" exec -T postgres \
    psql -XAtq -U postgres -d postgres -v ON_ERROR_STOP=1 -f - < tests/m54.sql
  run_test '0.44.0 upgraded inherited correctness corpus' docker compose -p "$upgrade_project" exec -T postgres \
    psql -XAtq -U postgres -d postgres -v ON_ERROR_STOP=1 -f - < tests/v0.44.0-inherited.sql
  run_test '0.44.0 upgraded M34 scoped comparison corpus' docker compose -p "$upgrade_project" exec -T postgres \
    psql -XAtq -U postgres -d postgres -v ON_ERROR_STOP=1 -f - < tests/m55-comparison.sql
  run_test '0.44.0 upgraded four-argument comparison' docker compose -p "$upgrade_project" exec -T postgres \
    psql -XAtq -U postgres -d postgres -v ON_ERROR_STOP=1 -f - < tests/m55-m35.sql
fi

echo "M55 $profile candidate Docker lane passed for $image"
