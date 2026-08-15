#!/usr/bin/env bash
set -euo pipefail

profile=${1:-fast}
image=${2:-pg-react:v0.17.0}
case "$profile" in fast|complete) ;; *) echo 'usage: tests/m20.sh fast|complete [IMAGE]' >&2; exit 2 ;; esac

project=${COMPOSE_PROJECT_NAME:-pgreact-m20-${GITHUB_RUN_ID:-$$}}
upgrade_project=${project}-upgrade
test_log_dir=$(mktemp -d)
artifact_dir=${M20_ARTIFACT_DIR:-}

cleanup() {
  COMPOSE_PROJECT_NAME=$project docker compose down --volumes --remove-orphans >/dev/null 2>&1 || true
  COMPOSE_PROJECT_NAME=$upgrade_project docker compose down --volumes --remove-orphans >/dev/null 2>&1 || true
  rm -r -- "$test_log_dir"
}
trap cleanup EXIT

run_test() {
  local name=$1
  shift
  local log="$test_log_dir/${name// /-}.log"
  if "$@" >"$log" 2>&1; then
    echo "$name passed"
  else
    sed -n '1,$p' "$log"
    return 1
  fi
}

wait_for_version() {
  local compose_project=$1 expected=$2
  local container="${compose_project}-postgres-1"
  for _ in {1..120}; do
    if [[ $(docker inspect --format '{{.State.Health.Status}}' "$container" 2>/dev/null || true) = healthy ]] &&
       COMPOSE_PROJECT_NAME=$compose_project docker compose exec -T postgres \
       psql -XAtq -U postgres -d postgres -c \
       "SELECT extversion='$expected' FROM pg_extension WHERE extname='pg_react'" \
       2>/dev/null | grep -qx t; then return; fi
    sleep 1
  done
  return 1
}

docs_audit() {
  grep -Fq 'pg-react M20 is extension `0.17.0`' README.md
  grep -Fq 'tests/m20.sh fast pg-react:v0.17.0' docs/m20-evidence.md
  grep -Fq '0.16.0 -> 0.17.0' docs/m20-upgrade.md
  grep -Fq 'M21 — Retention and catalog scale' docs/m20-readiness.md
}

release_audit() {
  grep -qx 'version = "0.17.0"' Cargo.toml
  grep -qx "default_version = '0.17.0'" pg_react.control
  grep -Fq "extversion = '0.17.0'" src/managed.rs
  test -s sql/pg_react--0.16.0.sql
  test -s sql/pg_react--0.16.0--0.17.0.sql
  test -s sql/pg_react--0.17.0.sql
  bash -n tests/m20.sh
  jq -e '.target_version == "0.17.0" and .direct_upgrade == "0.16.0 -> 0.17.0"' \
    tests/fixtures/m20/release-state.json >/dev/null
}

run_test 'M20 documentation audit' docs_audit
run_test 'M20 release identity audit' release_audit

export PG_REACT_IMAGE=$image
export PG_REACT_PLATFORM=linux/amd64
export PG_REACT_PORT_BINDING=${PG_REACT_PORT_BINDING:-127.0.0.1::5432}
export PG_REACT_POLL_INTERVAL_MS=60000
export PG_REACT_BATCH_SIZE=1000
export COMPOSE_PROJECT_NAME=$project
docker compose up -d --no-build >/dev/null 2>&1
wait_for_version "$project" 0.17.0
docker compose cp tests/m20-shared.sql postgres:/tmp/m20-shared.sql >/dev/null
run_test 'M20 shared condition public gate' \
  docker compose exec -T postgres psql -XAtq -U postgres -d postgres \
  -v ON_ERROR_STOP=1 -f /tmp/m20-shared.sql

if [[ $profile = complete ]]; then
  export COMPOSE_PROJECT_NAME=$upgrade_project
  export PG_REACT_INIT_VERSION=0.16.0
  docker compose up -d --no-build >/dev/null 2>&1
  wait_for_version "$upgrade_project" 0.16.0
  docker compose cp tests/m20-upgrade-before.sql postgres:/tmp/m20-upgrade-before.sql >/dev/null
  docker compose cp tests/m20-upgrade-after.sql postgres:/tmp/m20-upgrade-after.sql >/dev/null
  run_test 'M20 populated direct-upgrade setup' \
    docker compose exec -T postgres psql -XAtq -U postgres -d postgres \
    -v ON_ERROR_STOP=1 -f /tmp/m20-upgrade-before.sql
  run_test 'M20 direct 0.16.0 to 0.17.0 upgrade' \
    docker compose exec -T postgres psql -XAtq -U postgres -d postgres \
    -v ON_ERROR_STOP=1 -c "ALTER EXTENSION pg_react UPDATE TO '0.17.0';"
  run_test 'M20 populated upgrade state preserved' \
    docker compose exec -T postgres psql -XAtq -U postgres -d postgres \
    -f /tmp/m20-upgrade-after.sql
fi

echo "M20 $profile evidence gate passed for $image (linux/amd64)"
if [[ -n $artifact_dir ]]; then
  mkdir -p -- "$artifact_dir"
  cp -- "$test_log_dir"/*.log tests/fixtures/m20/release-state.json "$artifact_dir"/
fi
