#!/usr/bin/env bash
set -euo pipefail

profile=${1:-fast}
image=${2:-pg-react:m40-unreleased}
expected_version=${M40_EXPECTED_VERSION:-0.37.0}
case "$profile" in fast|complete) ;; *) echo 'usage: tests/m40.sh fast|complete [IMAGE]' >&2; exit 2 ;; esac

run_dir="tests/.m40-run-${GITHUB_RUN_ID:-$$}"
project=${COMPOSE_PROJECT_NAME:-pgreact-m40-${GITHUB_RUN_ID:-$$}}
rollback_project=${project}-rollback
mkdir -p -- "$run_dir"
cleanup() {
  COMPOSE_PROJECT_NAME=$project docker compose down --volumes --remove-orphans >/dev/null 2>&1 || true
  COMPOSE_PROJECT_NAME=$rollback_project docker compose down --volumes --remove-orphans >/dev/null 2>&1 || true
  if [[ -n ${M40_ARTIFACT_DIR:-} ]]; then
    mkdir -p -- "$M40_ARTIFACT_DIR"
    cp -a -- "$run_dir/." "$M40_ARTIFACT_DIR/"
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
    echo "$name passed"
  else
    sed -n '1,$p' "$log"
    return "$status"
  fi
}

static_audit() {
  test -s sql/m40.sql
  test -s tests/m40.sql
  for file in \
    docs/m40-contract.md docs/m40-api-reference.md docs/m40-api-inventory.json \
    docs/m40-finding-codes.json docs/m40-evidence.md docs/m40-migration.md \
    docs/m40-release-notes.md docs/m40-examples.md docs/m40-known-limitations.md \
    docs/m40-benchmark.md docs/m40-compatibility.md docs/m40-final-checklist.md; do
    test -s "$file"
  done
  bash -n tests/m40.sh
  grep -qx 'version = "0.37.0"' Cargo.toml
  grep -qx "default_version = '0.37.0'" pg_react.control
  grep -Fq '0.36.0` to `0.37.0' docs/m40-migration.md
  grep -Eiq 'ordinary|plain|operator' docs/m40-release-notes.md
  jq -e '.schema_version == 1 and .milestone == "M40" and .extension_version == "0.37.0" and (.ordinary.functions | index("pgreact.explain")) and (.ordinary.states | index("already_present"))' docs/m40-api-inventory.json >/dev/null
  jq -e '.schema_version == 1 and .milestone == "M40" and (.codes | length == 16)' docs/m40-finding-codes.json >/dev/null
  cmp sql/pg_react--0.36.0--0.37.0.sql sql/m40.sql
  cmp sql/pg_react--0.37.0.sql <(cat sql/pg_react--0.36.0.sql sql/m40.sql)
  test "$(tail -c 1 sql/pg_react--0.37.0.sql | od -An -t x1 | tr -d ' \\n')" = 0a
  ! grep -Eq '(^|[[:space:]])(ALTER|CREATE)[[:space:]]+EXTENSION' sql/m40.sql
  ! grep -Eq '(^|[[:space:]])(CREATE|ALTER)[[:space:]]+(SCHEMA|TABLE|TYPE|VIEW)[[:space:]]+pgreact\\.' sql/m40.sql
  ! grep -Eq '^[[:space:]]*(INSERT|UPDATE|DELETE|TRUNCATE|CREATE[[:space:]]+TEMP)[[:space:]]' sql/m40.sql
}

run_test 'M40 static and concatenation audit' static_audit

if ! command -v docker >/dev/null 2>&1 || ! docker image inspect "$image" >/dev/null 2>&1; then
  echo "M40 external Docker evidence not run: candidate image '$image' is unavailable"
  echo "M40 static lane passed; no external qualification claim made"
  exit 0
fi

export COMPOSE_PROJECT_NAME=$project
export PG_REACT_IMAGE=$image
export PG_REACT_INIT_VERSION=${M40_INIT_VERSION:-$expected_version}
export PG_REACT_PLATFORM=linux/amd64
export PG_REACT_PORT_BINDING=${PG_REACT_PORT_BINDING:-127.0.0.1::5432}
docker compose up -d --no-build >/dev/null 2>&1
ready=
for _ in {1..120}; do
  if [[ $(docker inspect --format '{{.State.Health.Status}}' "${project}-postgres-1" 2>/dev/null || true) = healthy ]] &&
     docker compose exec -T postgres psql -XAtq -U postgres -d postgres -c \
       "SELECT extversion='$expected_version' FROM pg_extension WHERE extname='pg_react'" 2>/dev/null | grep -qx t; then
    ready=1
    break
  fi
  sleep 1
done
if [[ -z $ready ]]; then
  echo "M40 candidate image did not provide pg-react $expected_version" >&2
  exit 1
fi
run_test 'M40 inherited M34 corpus' \
  docker compose exec -T postgres psql -XAtq -U postgres -d postgres \
  -v ON_ERROR_STOP=1 -f - < tests/m34.sql
run_test 'M40 inherited M35 corpus' \
  docker compose exec -T postgres psql -XAtq -U postgres -d postgres \
  -v ON_ERROR_STOP=1 -f - < tests/m35.sql
run_test 'M40 inherited M36 corpus' \
  docker compose exec -T postgres psql -XAtq -U postgres -d postgres \
  -v ON_ERROR_STOP=1 -f - < tests/m36.sql
run_test 'M40 inherited M37 corpus' \
  docker compose exec -T postgres psql -XAtq -U postgres -d postgres \
  -v ON_ERROR_STOP=1 -f - < tests/m37.sql
run_test 'M40 inherited M38 corpus' \
  docker compose exec -T postgres psql -XAtq -U postgres -d postgres \
  -v ON_ERROR_STOP=1 -f - < tests/m38.sql
run_test 'M40 inherited M39 corpus' \
  docker compose exec -T postgres psql -XAtq -U postgres -d postgres \
  -v ON_ERROR_STOP=1 -f - < tests/m39.sql
run_test 'M40 conformance corpus' \
  docker compose exec -T postgres psql -XAtq -U postgres -d postgres \
  -v ON_ERROR_STOP=1 -f - < tests/m40.sql

if [[ $profile = complete ]]; then
  export PG_REACT_INIT_VERSION=0.36.0
  docker compose down --volumes --remove-orphans >/dev/null 2>&1
  docker compose up -d --no-build >/dev/null 2>&1
  ready=
  for _ in {1..120}; do
    if [[ $(docker inspect --format '{{.State.Health.Status}}' "${project}-postgres-1" 2>/dev/null || true) = healthy ]] &&
       docker compose exec -T postgres psql -XAtq -U postgres -d postgres -c \
       "SELECT extversion='0.36.0' FROM pg_extension WHERE extname='pg_react'" 2>/dev/null | grep -qx t; then
      ready=1
      break
    fi
    sleep 1
  done
  if [[ -z $ready ]]; then
    echo 'M40 populated-upgrade source did not provide pg-react 0.36.0' >&2
    exit 1
  fi
  upgrade_volume=$(docker volume ls \
    --filter "label=com.docker.compose.project=$project" \
    --filter 'label=com.docker.compose.volume=postgres-data' \
    --format '{{.Name}}')
  if [[ -z $upgrade_volume ]]; then
    echo 'M40 populated-upgrade volume was not created' >&2
    exit 1
  fi
  run_test 'M40 rollback backup' \
    docker run --rm \
    -v "$upgrade_volume:/source:ro" \
    -v "$PWD/$run_dir:/backup" \
    --entrypoint tar "$image" \
    -cf /backup/m40-upgrade.tar -C /source .
  run_test 'M40 0.36.0 to 0.37.0 upgrade' \
    docker compose exec -T postgres psql -XAtq -U postgres -d postgres \
    -v ON_ERROR_STOP=1 -c "ALTER EXTENSION pg_react UPDATE TO '0.37.0';"
  run_test 'M40 upgraded why-not surface' \
    docker compose exec -T postgres psql -XAtq -U postgres -d postgres \
    -v ON_ERROR_STOP=1 -c "SELECT extversion = '0.37.0' AND to_regprocedure('pgreact.explain(text,jsonb,jsonb)') IS NOT NULL FROM pg_extension WHERE extname='pg_react';"

  rollback_volume="${rollback_project}_postgres-data"
  docker volume create \
    --label "com.docker.compose.project=$rollback_project" \
    --label 'com.docker.compose.volume=postgres-data' \
    "$rollback_volume" >/dev/null
  run_test 'M40 rollback restore' \
    docker run --rm \
    -v "$rollback_volume:/target" \
    -v "$PWD/$run_dir:/backup" \
    --entrypoint tar "$image" \
    -xf /backup/m40-upgrade.tar -C /target
  export COMPOSE_PROJECT_NAME=$rollback_project
  export PG_REACT_INIT_VERSION=0.36.0
  docker compose up -d --no-build >/dev/null 2>&1
  ready=
  for _ in {1..120}; do
    if [[ $(docker inspect --format '{{.State.Health.Status}}' "${rollback_project}-postgres-1" 2>/dev/null || true) = healthy ]] &&
       docker compose exec -T postgres psql -XAtq -U postgres -d postgres -c \
       "SELECT extversion='0.36.0' FROM pg_extension WHERE extname='pg_react'" 2>/dev/null | grep -qx t; then
      ready=1
      break
    fi
    sleep 1
  done
  if [[ -z $ready ]]; then
    echo 'M40 rollback restore did not provide pg-react 0.36.0' >&2
    exit 1
  fi
  run_test 'M40 rollback version' \
    docker compose exec -T postgres psql -XAtq -U postgres -d postgres \
    -v ON_ERROR_STOP=1 -c "SELECT extversion = '0.36.0' FROM pg_extension WHERE extname = 'pg_react';"
fi

echo "M40 $profile candidate Docker lane passed for $image"
