#!/usr/bin/env bash
set -euo pipefail

profile=${1:-fast}
image=${2:-pg-react:m36-unreleased}
expected_version=${M36_EXPECTED_VERSION:-0.33.0}
case "$profile" in fast|complete) ;; *) echo 'usage: tests/m36.sh fast|complete [IMAGE]' >&2; exit 2 ;; esac

run_dir="tests/.m36-run-${GITHUB_RUN_ID:-$$}"
project=${COMPOSE_PROJECT_NAME:-pgreact-m36-${GITHUB_RUN_ID:-$$}}
mkdir -p -- "$run_dir"
cleanup() {
  COMPOSE_PROJECT_NAME=$project docker compose down --volumes --remove-orphans >/dev/null 2>&1 || true
  if [[ -n ${M36_ARTIFACT_DIR:-} ]]; then
    mkdir -p -- "$M36_ARTIFACT_DIR"
    cp -a -- "$run_dir/." "$M36_ARTIFACT_DIR/"
  fi
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
  test -s sql/m36.sql
  test -s tests/m36.sql
  test -s docs/m36-contract.md
  test -s docs/m36-api-reference.md
  test -s docs/m36-api-inventory.json
  test -s docs/m36-finding-codes.json
  test -s docs/m36-evidence.md
  test -s docs/m36-migration.md
  test -s docs/m36-release-notes.md
  bash -n tests/m36.sh
  grep -qx 'version = "0.33.0"' Cargo.toml
  grep -qx "default_version = '0.33.0'" pg_react.control
  jq -e '.schema_version == 1 and .milestone == "M36" and .extension_version == "0.33.0" and (.ordinary.functions | index("pgreact.replay"))' docs/m36-api-inventory.json >/dev/null
  jq -e '.schema_version == 1 and .milestone == "M36" and (.codes | length == 28)' docs/m36-finding-codes.json >/dev/null
  cmp sql/pg_react--0.32.0--0.33.0.sql sql/m36.sql
  cmp sql/pg_react--0.33.0.sql <(cat sql/pg_react--0.32.0.sql; printf '\n'; cat sql/m36.sql)
  test "$(tail -c 1 sql/pg_react--0.33.0.sql | od -An -t x1 | tr -d ' \n')" = 0a
  ! grep -Eq '(^|[[:space:]])(ALTER|CREATE)[[:space:]]+EXTENSION' sql/m36.sql
  ! grep -Eq '(^|[[:space:]])(CREATE|ALTER)[[:space:]]+(SCHEMA|TABLE|TYPE|VIEW)[[:space:]]+pgreact\.' sql/m36.sql
  ! grep -Eq '^[[:space:]]*(INSERT|UPDATE|DELETE|TRUNCATE|CREATE[[:space:]]+TEMP)[[:space:]]' sql/m36.sql
}

run_test 'M36 static and concatenation audit' static_audit

if ! command -v docker >/dev/null 2>&1 || ! docker image inspect "$image" >/dev/null 2>&1; then
  echo "M36 external Docker evidence not run: candidate image '$image' is unavailable"
  echo "M36 static lane passed; no external qualification claim made"
  exit 0
fi

export COMPOSE_PROJECT_NAME=$project
export PG_REACT_IMAGE=$image
export PG_REACT_INIT_VERSION=${M36_INIT_VERSION:-$expected_version}
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
  echo "M36 candidate image did not provide pg-react $expected_version" >&2
  exit 1
fi
run_test 'M36 historical replay checks' \
  docker compose exec -T postgres psql -XAtq -U postgres -d postgres \
  -v ON_ERROR_STOP=1 -f - < tests/m36.sql

if [[ $profile = complete ]]; then
  export PG_REACT_INIT_VERSION=0.32.0
  docker compose down --volumes --remove-orphans >/dev/null 2>&1
  docker compose up -d --no-build >/dev/null 2>&1
  ready=
  for _ in {1..120}; do
    if [[ $(docker inspect --format '{{.State.Health.Status}}' "${project}-postgres-1" 2>/dev/null || true) = healthy ]] &&
       docker compose exec -T postgres psql -XAtq -U postgres -d postgres -c \
       "SELECT extversion='0.32.0' FROM pg_extension WHERE extname='pg_react'" 2>/dev/null | grep -qx t; then
      ready=1
      break
    fi
    sleep 1
  done
  if [[ -z $ready ]]; then
    echo 'M36 populated-upgrade source did not provide pg-react 0.32.0' >&2
    exit 1
  fi
  run_test 'M36 0.32.0 to 0.33.0 upgrade' \
    docker compose exec -T postgres psql -XAtq -U postgres -d postgres \
    -v ON_ERROR_STOP=1 -c "ALTER EXTENSION pg_react UPDATE TO '0.33.0';"
  run_test 'M36 upgraded replay surface' \
    docker compose exec -T postgres psql -XAtq -U postgres -d postgres \
    -v ON_ERROR_STOP=1 -c "SELECT extversion = '0.33.0' AND to_regprocedure('pgreact.replay(pgreact_api.declaration,pgreact_api.target,jsonb,jsonb,jsonb)') IS NOT NULL FROM pg_extension WHERE extname = 'pg_react';"
fi

echo "M36 $profile candidate Docker lane passed for $image"
