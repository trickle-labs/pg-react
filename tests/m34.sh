#!/usr/bin/env bash
set -euo pipefail

profile=${1:-fast}
image=${2:-pg-react:m34-unreleased}
expected_version=${M34_EXPECTED_VERSION:-0.31.0}
case "$profile" in fast|complete) ;; *) echo 'usage: tests/m34.sh fast|complete [IMAGE]' >&2; exit 2 ;; esac

project=${COMPOSE_PROJECT_NAME:-pgreact-m34-${GITHUB_RUN_ID:-$$}}
upgrade_project=${project}-upgrade
rollback_project=${project}-rollback
run_dir="tests/.m34-run-${GITHUB_RUN_ID:-$$}"
artifact_dir=${M34_ARTIFACT_DIR:-}
mkdir -p -- "$run_dir"

cleanup() {
  COMPOSE_PROJECT_NAME=$project docker compose down --volumes --remove-orphans >/dev/null 2>&1 || true
  COMPOSE_PROJECT_NAME=$upgrade_project docker compose down --volumes --remove-orphans >/dev/null 2>&1 || true
  COMPOSE_PROJECT_NAME=$rollback_project docker compose down --volumes --remove-orphans >/dev/null 2>&1 || true
  rm -rf -- "$run_dir"
}
trap cleanup EXIT

run_test() {
  local name=$1; shift
  local log="$run_dir/${name// /-}.log"
  if "$@" >"$log" 2>&1; then
    echo "$name passed"
  else
    sed -n '1,$p' "$log"
    return 1
  fi
}

static_audit() {
  test -s sql/m34.sql
  test -s tests/m34.sql
  test -s tests/m34-upgrade-before.sql
  test -s tests/m34-upgrade-after.sql
  bash -n tests/m34.sh
  test -s sql/pg_react--0.30.0.sql
  test -s sql/pg_react--0.30.0--0.31.0.sql
  test -s sql/pg_react--0.31.0.sql
  cmp sql/pg_react--0.30.0--0.31.0.sql sql/m34.sql
  cmp sql/pg_react--0.31.0.sql <(cat sql/pg_react--0.30.0.sql; printf '\n'; cat sql/m34.sql)
  test "$(tail -c 1 sql/pg_react--0.31.0.sql | od -An -t x1 | tr -d ' \n')" = 0a
  ! grep -Eq '(^|[[:space:]])(ALTER|CREATE)[[:space:]]+EXTENSION' sql/m34.sql
  ! grep -Eq '(^|[[:space:]])(CREATE|ALTER)[[:space:]]+(SCHEMA|TABLE|TYPE|VIEW)[[:space:]]+pgreact\.' sql/m34.sql
  ! grep -Eq '(^|[[:space:]])(INSERT|UPDATE|DELETE|TRUNCATE|CREATE[[:space:]]+TEMP)' sql/m34.sql
}

docs_audit() {
  test -s docs/m34-contract.md
  test -s docs/m34-api-reference.md
  test -s docs/m34-api-inventory.json
  test -s docs/m34-finding-codes.json
  test -s docs/m34-evidence.md
  test -s docs/m34-migration.md
  test -s docs/m34-release-notes.md
  jq -e '
    .schema_version == 1 and .milestone == "M34" and
    .extension_version == "0.31.0" and
    (.ordinary.functions | index("pgreact.compare")) and
    (.ordinary.functions | index("pgreact.compare_results"))
  ' docs/m34-api-inventory.json >/dev/null
  jq -e '
    .schema_version == 1 and .milestone == "M34" and
    .finding_shape == ["code","severity","blocking","target","field","message","hint","details"] and
    (.codes | length == 18)
  ' docs/m34-finding-codes.json >/dev/null
  grep -Eiq 'ordinary people|read-only|no change|next' docs/m34-release-notes.md
}

run_test 'M34 static and concatenation audit' static_audit
run_test 'M34 documentation audit' docs_audit

if ! command -v docker >/dev/null 2>&1 ||
   ! docker image inspect "$image" >/dev/null 2>&1; then
  echo "M34 external Docker evidence not run: candidate image '$image' is unavailable"
  echo "M34 static lane passed; no external qualification claim made"
  exit 0
fi

export COMPOSE_PROJECT_NAME=$project
export PG_REACT_IMAGE=$image
export PG_REACT_INIT_VERSION=${M34_INIT_VERSION:-$expected_version}
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
  echo "M34 candidate image did not provide pg-react $expected_version" >&2
  exit 1
fi

run_test 'M34 installed additive SQL' \
  docker compose exec -T postgres psql -XAtq -U postgres -d postgres \
  -v ON_ERROR_STOP=1 -f - < sql/m34.sql
run_test 'M34 comparison, no-effect, limit, and security checks' \
  docker compose exec -T postgres psql -XAtq -U postgres -d postgres \
  -v ON_ERROR_STOP=1 -f - < tests/m34.sql

if [[ $profile = complete ]]; then
  export COMPOSE_PROJECT_NAME=$upgrade_project
  export PG_REACT_IMAGE=$image
  export PG_REACT_INIT_VERSION=0.30.0
  export PG_REACT_PORT_BINDING=${PG_REACT_PORT_BINDING:-127.0.0.1::5432}
  docker compose up -d --no-build >/dev/null 2>&1
  ready=
  for _ in {1..120}; do
    if [[ $(docker inspect --format '{{.State.Health.Status}}' "${upgrade_project}-postgres-1" 2>/dev/null || true) = healthy ]] &&
       docker compose exec -T postgres psql -XAtq -U postgres -d postgres -c \
         "SELECT extversion='0.30.0' FROM pg_extension WHERE extname='pg_react'" 2>/dev/null | grep -qx t; then
      ready=1
      break
    fi
    sleep 1
  done
  if [[ -z $ready ]]; then
    echo "M34 populated-upgrade source did not provide pg-react 0.30.0" >&2
    exit 1
  fi
  run_test 'M34 populated upgrade setup' \
    docker compose exec -T postgres psql -XAtq -U postgres -d postgres \
    -v ON_ERROR_STOP=1 -f - < tests/m34-upgrade-before.sql
  docker compose down --remove-orphans >/dev/null 2>&1
  upgrade_volume=$(docker volume ls \
    --filter "label=com.docker.compose.project=$upgrade_project" \
    --filter 'label=com.docker.compose.volume=postgres-data' \
    --format '{{.Name}}')
  if [[ -z $upgrade_volume ]]; then
    echo "M34 populated-upgrade volume was not created" >&2
    exit 1
  fi
  run_test 'M34 rollback backup' \
    docker run --rm \
    -v "$upgrade_volume:/source:ro" \
    -v "$PWD/$run_dir:/backup" \
    --entrypoint tar "$image" \
    -cf /backup/m34-upgrade.tar -C /source .
  docker compose up -d --no-build >/dev/null 2>&1
  ready=
  for _ in {1..120}; do
    if [[ $(docker inspect --format '{{.State.Health.Status}}' "${upgrade_project}-postgres-1" 2>/dev/null || true) = healthy ]] &&
       docker compose exec -T postgres psql -XAtq -U postgres -d postgres -c \
         "SELECT extversion='0.30.0' FROM pg_extension WHERE extname='pg_react'" 2>/dev/null | grep -qx t; then
      ready=1
      break
    fi
    sleep 1
  done
  if [[ -z $ready ]]; then
    echo "M34 populated-upgrade source did not restart after backup" >&2
    exit 1
  fi
  run_test 'M34 populated 0.30.0 to 0.31.0 upgrade' \
    docker compose exec -T postgres psql -XAtq -U postgres -d postgres \
    -v ON_ERROR_STOP=1 -c "ALTER EXTENSION pg_react UPDATE TO '0.31.0';"
  run_test 'M34 populated upgrade preserved' \
    docker compose exec -T postgres psql -XAtq -U postgres -d postgres \
    -v ON_ERROR_STOP=1 -f - < tests/m34-upgrade-after.sql
  run_test 'M34 upgraded comparison surface' \
    docker compose exec -T postgres psql -XAtq -U postgres -d postgres \
    -v ON_ERROR_STOP=1 -c \
    "SELECT extversion = '0.31.0'
       AND to_regprocedure('pgreact.compare(pgreact_api.declaration,pgreact_api.target,jsonb)') IS NOT NULL
       AND to_regprocedure('pgreact.compare_results(pgreact_api.declaration,pgreact_api.target,jsonb)') IS NOT NULL
     FROM pg_extension WHERE extname = 'pg_react';"
  export COMPOSE_PROJECT_NAME=$project
  export PG_REACT_INIT_VERSION=$expected_version

  rollback_image=${M34_INHERITED_IMAGE:-pg-react:v0.30.0}
  if ! docker image inspect "$rollback_image" >/dev/null 2>&1; then
    rollback_image=$image
  fi
  rollback_volume="${rollback_project}_postgres-data"
  docker volume create \
    --label "com.docker.compose.project=$rollback_project" \
    --label 'com.docker.compose.volume=postgres-data' \
    "$rollback_volume" >/dev/null
  run_test 'M34 rollback restore' \
    docker run --rm \
    -v "$rollback_volume:/target" \
    -v "$PWD/$run_dir:/backup" \
    --entrypoint tar "$rollback_image" \
    -xf /backup/m34-upgrade.tar -C /target
  export COMPOSE_PROJECT_NAME=$rollback_project
  export PG_REACT_IMAGE=$rollback_image
  export PG_REACT_INIT_VERSION=0.30.0
  docker compose up -d --no-build >/dev/null 2>&1
  ready=
  for _ in {1..120}; do
    if [[ $(docker inspect --format '{{.State.Health.Status}}' "${rollback_project}-postgres-1" 2>/dev/null || true) = healthy ]] &&
       docker compose exec -T postgres psql -XAtq -U postgres -d postgres -c \
         "SELECT extversion='0.30.0' FROM pg_extension WHERE extname='pg_react'" 2>/dev/null | grep -qx t; then
      ready=1
      break
    fi
    sleep 1
  done
  if [[ -z $ready ]]; then
    echo "M34 rollback restore did not provide pg-react 0.30.0" >&2
    exit 1
  fi
  run_test 'M34 rollback state preserved' \
    docker compose exec -T postgres psql -XAtq -U postgres -d postgres \
    -v ON_ERROR_STOP=1 -f - < tests/m34-upgrade-after.sql
  export COMPOSE_PROJECT_NAME=$project
  export PG_REACT_IMAGE=$image
  export PG_REACT_INIT_VERSION=$expected_version

  inherited_image=${M34_INHERITED_IMAGE:-pg-react:v0.30.0}
  if docker image inspect "$inherited_image" >/dev/null 2>&1; then
    run_test 'M33 inherited qualification' \
      env M33_EXPECTED_VERSION=0.30.0 \
      COMPOSE_PROJECT_NAME="${project}-inherited" \
      bash tests/m33.sh complete "$inherited_image"
  else
    echo "M34 inherited M33 evidence not run: image '$inherited_image' is unavailable"
    echo "No inherited M33 qualification claim made"
  fi
fi

if [[ -n $artifact_dir ]]; then
  mkdir -p -- "$artifact_dir"
  cp -- "$run_dir"/*.log "$artifact_dir"/
fi

echo "M34 $profile candidate Docker lane passed for $image"
