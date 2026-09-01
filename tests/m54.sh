#!/usr/bin/env bash
set -euo pipefail

profile=${1:-fast}
image=${2:-pg-react:m54-unreleased}
expected_version=${M54_EXPECTED_VERSION:-0.43.1}
case "$profile" in fast|complete) ;; *) echo 'usage: tests/m54.sh fast|complete [IMAGE]' >&2; exit 2 ;; esac

run_dir="tests/.m54-run-${GITHUB_RUN_ID:-$$}"
project=${COMPOSE_PROJECT_NAME:-pgreact-m54-${GITHUB_RUN_ID:-$$}}
rollback_project=${project}-rollback
managed_pid=
mkdir -p -- "$run_dir"
cleanup() {
  if [[ -n ${managed_pid:-} ]]; then
    COMPOSE_PROJECT_NAME=$project docker compose exec -T postgres \
      bash -c 'kill -CONT "$1"' bash "$managed_pid" >/dev/null 2>&1 || true
  fi
  COMPOSE_PROJECT_NAME=$project docker compose down --volumes --remove-orphans >/dev/null 2>&1 || true
  COMPOSE_PROJECT_NAME=$rollback_project docker compose down --volumes --remove-orphans >/dev/null 2>&1 || true
  if [[ -n ${M54_ARTIFACT_DIR:-} ]]; then
    mkdir -p -- "$M54_ARTIFACT_DIR"
    cp -a -- "$run_dir/." "$M54_ARTIFACT_DIR/"
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
    docs/m54-contract.md docs/m54-api-reference.md docs/m54-api-inventory.json \
    docs/m54-finding-codes.json docs/m54-evidence.md docs/m54-migration.md \
    docs/m54-known-limitations.md docs/m54-release-notes.md docs/m54-final-checklist.md \
    docs/current-release.json docs/api-inventory.json docs/product-contract.md \
    docs/versioning.md sql/m54.sql sql/pg_react--0.43.0--0.43.1.sql \
    sql/pg_react--0.43.1.sql tests/m54.sql tests/m54-concurrency.sh; do
    test -s "$file"
  done
  bash tests/current-docs.sh
  bash tests/api-inventory.sh
  bash tests/workflow-syntax.sh
  bash -n tests/m54.sh tests/current-docs.sh tests/api-inventory.sh tests/workflow-syntax.sh tests/m54-concurrency.sh
  jq -e --arg version "$expected_version" '.extension_version == $version and .contract_version == 54' docs/m54-api-inventory.json >/dev/null
  cmp sql/pg_react--0.43.0--0.43.1.sql sql/m54.sql
  cmp sql/pg_react--0.43.1.sql <(awk 'FNR==NR {if ($0 ~ /^-- M54 adoption hardening/) {seen=1} if (!seen) print; next} {print}' sql/pg_react--0.43.0.sql sql/m54.sql)
  ! rg -n 'pg_sleep' README.md docs/getting-started.md docs/order-review-tutorial.md showcase/order-review
  echo 'M54 static and artifact audit passed'
}

run_test 'M54 static and artifact audit' static_audit

if ! command -v docker >/dev/null 2>&1 || ! docker image inspect "$image" >/dev/null 2>&1; then
  echo "M54 external Docker evidence not run: candidate image '$image' is unavailable"
  echo 'M54 static lane passed; no external qualification claim made'
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
    if [[ $(docker inspect --format '{{.State.Health.Status}}' "${COMPOSE_PROJECT_NAME}-postgres-1" 2>/dev/null || true) = healthy ]] &&
       docker compose exec -T postgres psql -XAtq -U postgres -d postgres -c \
         "SELECT extversion='$version' FROM pg_extension WHERE extname='pg_react'" 2>/dev/null | grep -qx t; then
      ready=1
      break
    fi
    sleep 1
  done
  test -n "$ready"
}

export COMPOSE_PROJECT_NAME=$project
export PG_REACT_INIT_VERSION=${M54_INIT_VERSION:-$expected_version}
docker compose up -d --no-build >/dev/null 2>&1
wait_for_version "$expected_version"
for inherited in tests/m38.sql tests/m39.sql tests/m40.sql tests/m41.sql tests/m42.sql tests/m43.sql tests/m44.sql tests/m53-ergonomics.sql tests/m53.sql; do
  run_test "M54 inherited $(basename "$inherited" .sql)" docker compose exec -T postgres psql -XAtq -U postgres -d postgres -v ON_ERROR_STOP=1 -f - < "$inherited"
done
for _ in {1..120}; do
  managed_pid=$(docker compose exec -T postgres psql -XAtq -U postgres -d postgres -c \
    "SELECT pgreact_api.managed_status() #>> '{process,pid}'" 2>/dev/null || true)
  [[ -n $managed_pid ]] && break
  sleep 1
done
test -n "$managed_pid"
docker compose exec -T postgres bash -c 'kill -STOP "$1"' bash "$managed_pid"
run_test 'M54 fresh install and SQL corpus' docker compose exec -T postgres psql -XAtq -U postgres -d postgres -v ON_ERROR_STOP=1 -f - < tests/m54.sql
docker compose exec -T postgres bash -c 'kill -CONT "$1"' bash "$managed_pid"
managed_pid=
run_test 'M54 concurrency and failure corpus' bash tests/m54-concurrency.sh "$image" "$COMPOSE_PROJECT_NAME"

if [[ $profile = complete ]]; then
  docker compose down --volumes --remove-orphans >/dev/null 2>&1
  export PG_REACT_INIT_VERSION=0.43.0
  docker compose up -d --no-build >/dev/null 2>&1
  wait_for_version 0.43.0
  run_test 'M54 populated upgrade fixture' docker compose exec -T postgres psql -XAtq -U postgres -d postgres -v ON_ERROR_STOP=1 -c "CREATE TABLE m54_upgrade_fixture (id integer PRIMARY KEY); INSERT INTO m54_upgrade_fixture VALUES (1);"
  upgrade_volume=$(docker volume ls --filter "label=com.docker.compose.project=$project" --filter 'label=com.docker.compose.volume=postgres-data' --format '{{.Name}}')
  test -n "$upgrade_volume"
  run_test 'M54 populated backup' docker run --rm -v "$upgrade_volume:/source:ro" -v "$PWD/$run_dir:/backup" --entrypoint tar "$image" -cf /backup/m54-upgrade.tar -C /source .
  run_test 'M54 adjacent upgrade' docker compose exec -T postgres psql -XAtq -U postgres -d postgres -v ON_ERROR_STOP=1 -c "ALTER EXTENSION pg_react UPDATE TO '0.43.1';"
  run_test 'M54 upgraded version' docker compose exec -T postgres psql -XAtq -U postgres -d postgres -v ON_ERROR_STOP=1 -c "SELECT extversion = '0.43.1' FROM pg_extension WHERE extname = 'pg_react';"
  run_test 'M54 upgraded fixture' docker compose exec -T postgres psql -XAtq -U postgres -d postgres -v ON_ERROR_STOP=1 -c "SELECT * FROM m54_upgrade_fixture;"
  rollback_volume="${rollback_project}_postgres-data"
  docker volume create --label "com.docker.compose.project=$rollback_project" --label 'com.docker.compose.volume=postgres-data' "$rollback_volume" >/dev/null
  run_test 'M54 rollback restore' docker run --rm -v "$rollback_volume:/target" -v "$PWD/$run_dir:/backup" --entrypoint tar "$image" -xf /backup/m54-upgrade.tar -C /target
  export COMPOSE_PROJECT_NAME=$rollback_project
  export PG_REACT_INIT_VERSION=0.43.0
  docker compose up -d --no-build >/dev/null 2>&1
  wait_for_version 0.43.0
  run_test 'M54 rollback version' docker compose exec -T postgres psql -XAtq -U postgres -d postgres -v ON_ERROR_STOP=1 -c "SELECT extversion = '0.43.0' FROM pg_extension WHERE extname = 'pg_react';"
  run_test 'M54 rollback fixture' docker compose exec -T postgres psql -XAtq -U postgres -d postgres -v ON_ERROR_STOP=1 -c "SELECT * FROM m54_upgrade_fixture;"
fi

echo "M54 $profile candidate Docker lane passed for $image"
