#!/usr/bin/env bash
set -euo pipefail

profile=${1:-fast}
image=${2:-pg-react:m44-unreleased}
expected_version=${M44_EXPECTED_VERSION:-0.41.0}
case "$profile" in fast|complete) ;; *) echo 'usage: tests/m44.sh fast|complete [IMAGE]' >&2; exit 2 ;; esac

run_dir="tests/.m44-run-${GITHUB_RUN_ID:-$$}"
project=${COMPOSE_PROJECT_NAME:-pgreact-m44-${GITHUB_RUN_ID:-$$}}
rollback_project=${project}-rollback
mkdir -p -- "$run_dir"
cleanup() {
  COMPOSE_PROJECT_NAME=$project docker compose down --volumes --remove-orphans >/dev/null 2>&1 || true
  COMPOSE_PROJECT_NAME=$rollback_project docker compose down --volumes --remove-orphans >/dev/null 2>&1 || true
  if [[ -n ${M44_ARTIFACT_DIR:-} ]]; then
    mkdir -p -- "$M44_ARTIFACT_DIR"
    cp -a -- "$run_dir/." "$M44_ARTIFACT_DIR/"
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
  test -s sql/m44.sql
  test -s tests/m44.sql
  for file in \
    docs/m44-contract.md docs/m44-api-reference.md docs/m44-api-inventory.json \
    docs/m44-finding-codes.json docs/m44-evidence.md docs/m44-migration.md \
    docs/m44-release-notes.md docs/m44-examples.md docs/m44-known-limitations.md \
    docs/m44-benchmark.md docs/m44-compatibility.md docs/m44-reference-corpus.json \
    docs/m44-final-checklist.md; do
    test -s "$file"
  done
  bash -n tests/m44.sh
  grep -qx 'version = "0.41.0"' Cargo.toml
  grep -qx "default_version = '0.41.0'" pg_react.control
  grep -Fq '0.40.0` to `0.41.0' docs/m44-migration.md
  grep -Eiq 'ordinary|plain|operator' docs/m44-release-notes.md
  jq -e '.schema_version == 1 and .milestone == "M44" and .extension_version == "0.41.0" and (.qualified_origins | length == 5) and (.no_effect_boundary | index("no new explanation function"))' docs/m44-api-inventory.json >/dev/null
  jq -e '.schema_version == 1 and .milestone == "M44" and (.codes | length >= 20) and .codes_are_inherited' docs/m44-finding-codes.json >/dev/null
  jq -e '.schema_version == 1 and .milestone == "M44" and (.workflows | length == 3) and .external_review.status == "pending"' docs/m44-reference-corpus.json >/dev/null
  cmp sql/pg_react--0.40.0--0.41.0.sql sql/m44.sql
  cmp sql/pg_react--0.41.0.sql <(cat sql/pg_react--0.40.0.sql sql/m44.sql)
  test "$(tail -c 1 sql/pg_react--0.41.0.sql | od -An -t x1 | tr -d ' \\n')" = 0a
  ! grep -Eq '(^|[[:space:]])(ALTER|CREATE)[[:space:]]+EXTENSION' sql/m44.sql
  ! grep -Eq '(^|[[:space:]])(CREATE|ALTER)[[:space:]]+(SCHEMA|TABLE|TYPE|VIEW)[[:space:]]+pgreact\\.' sql/m44.sql
  ! grep -Eq '^[[:space:]]*(INSERT|UPDATE|DELETE|TRUNCATE|CREATE[[:space:]]+TEMP)[[:space:]]' sql/m44.sql
}

run_test 'M44 static and concatenation audit' static_audit

if ! command -v docker >/dev/null 2>&1 || ! docker image inspect "$image" >/dev/null 2>&1; then
  echo "M44 external Docker evidence not run: candidate image '$image' is unavailable"
  echo 'M44 static lane passed; no external qualification claim made'
  exit 0
fi

export COMPOSE_PROJECT_NAME=$project
export PG_REACT_IMAGE=$image
export PG_REACT_INIT_VERSION=${M44_INIT_VERSION:-$expected_version}
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
if [[ -z $ready ]]; then echo "M44 candidate image did not provide pg-react $expected_version" >&2; exit 1; fi
run_test 'M44 inherited M38 corpus' docker compose exec -T postgres psql -XAtq -U postgres -d postgres -v ON_ERROR_STOP=1 -f - < tests/m38.sql
run_test 'M44 inherited M39 corpus' docker compose exec -T postgres psql -XAtq -U postgres -d postgres -v ON_ERROR_STOP=1 -f - < tests/m39.sql
run_test 'M44 inherited M40 corpus' docker compose exec -T postgres psql -XAtq -U postgres -d postgres -v ON_ERROR_STOP=1 -f - < tests/m40.sql
run_test 'M44 inherited M41 corpus' docker compose exec -T postgres psql -XAtq -U postgres -d postgres -v ON_ERROR_STOP=1 -f - < tests/m41.sql
run_test 'M44 inherited M42 corpus' docker compose exec -T postgres psql -XAtq -U postgres -d postgres -v ON_ERROR_STOP=1 -f - < tests/m42.sql
run_test 'M44 inherited M43 corpus' docker compose exec -T postgres psql -XAtq -U postgres -d postgres -v ON_ERROR_STOP=1 -f - < tests/m43.sql
run_test 'M44 conformance corpus' docker compose exec -T postgres psql -XAtq -U postgres -d postgres -v ON_ERROR_STOP=1 -f - < tests/m44.sql

if [[ $profile = complete ]]; then
  export PG_REACT_INIT_VERSION=0.40.0
  docker compose down --volumes --remove-orphans >/dev/null 2>&1
  docker compose up -d --no-build >/dev/null 2>&1
  ready=
  for _ in {1..120}; do
    if [[ $(docker inspect --format '{{.State.Health.Status}}' "${project}-postgres-1" 2>/dev/null || true) = healthy ]] &&
       docker compose exec -T postgres psql -XAtq -U postgres -d postgres -c \
       "SELECT extversion='0.40.0' FROM pg_extension WHERE extname='pg_react'" 2>/dev/null | grep -qx t; then
      ready=1
      break
    fi
    sleep 1
  done
  if [[ -z $ready ]]; then echo 'M44 populated-upgrade source did not provide pg-react 0.40.0' >&2; exit 1; fi
  upgrade_volume=$(docker volume ls --filter "label=com.docker.compose.project=$project" --filter 'label=com.docker.compose.volume=postgres-data' --format '{{.Name}}')
  if [[ -z $upgrade_volume ]]; then echo 'M44 populated-upgrade volume was not created' >&2; exit 1; fi
  run_test 'M44 rollback backup' docker run --rm -v "$upgrade_volume:/source:ro" -v "$PWD/$run_dir:/backup" --entrypoint tar "$image" -cf /backup/m44-upgrade.tar -C /source .
  run_test 'M44 0.40.0 to 0.41.0 upgrade' docker compose exec -T postgres psql -XAtq -U postgres -d postgres -v ON_ERROR_STOP=1 -c "ALTER EXTENSION pg_react UPDATE TO '0.41.0';"
  run_test 'M44 upgraded version' docker compose exec -T postgres psql -XAtq -U postgres -d postgres -v ON_ERROR_STOP=1 -c "SELECT extversion = '0.41.0' FROM pg_extension WHERE extname = 'pg_react';"
  rollback_volume="${rollback_project}_postgres-data"
  docker volume create --label "com.docker.compose.project=$rollback_project" --label 'com.docker.compose.volume=postgres-data' "$rollback_volume" >/dev/null
  run_test 'M44 rollback restore' docker run --rm -v "$rollback_volume:/target" -v "$PWD/$run_dir:/backup" --entrypoint tar "$image" -xf /backup/m44-upgrade.tar -C /target
  export COMPOSE_PROJECT_NAME=$rollback_project
  export PG_REACT_INIT_VERSION=0.40.0
  docker compose up -d --no-build >/dev/null 2>&1
  ready=
  for _ in {1..120}; do
    if [[ $(docker inspect --format '{{.State.Health.Status}}' "${rollback_project}-postgres-1" 2>/dev/null || true) = healthy ]] &&
       docker compose exec -T postgres psql -XAtq -U postgres -d postgres -c \
       "SELECT extversion='0.40.0' FROM pg_extension WHERE extname='pg_react'" 2>/dev/null | grep -qx t; then
      ready=1
      break
    fi
    sleep 1
  done
  if [[ -z $ready ]]; then echo 'M44 rollback restore did not provide pg-react 0.40.0' >&2; exit 1; fi
  run_test 'M44 rollback version' docker compose exec -T postgres psql -XAtq -U postgres -d postgres -v ON_ERROR_STOP=1 -c "SELECT extversion = '0.40.0' FROM pg_extension WHERE extname = 'pg_react';"
fi

echo "M44 $profile candidate Docker lane passed for $image"
