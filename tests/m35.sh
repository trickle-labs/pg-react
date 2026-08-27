#!/usr/bin/env bash
set -euo pipefail

profile=${1:-fast}
image=${2:-pg-react:m35-unreleased}
expected_version=${M35_EXPECTED_VERSION:-0.32.0}
case "$profile" in fast|complete) ;; *) echo 'usage: tests/m35.sh fast|complete [IMAGE]' >&2; exit 2 ;; esac

run_dir="tests/.m35-run-${GITHUB_RUN_ID:-$$}"
project=${COMPOSE_PROJECT_NAME:-pgreact-m35-${GITHUB_RUN_ID:-$$}}
mkdir -p -- "$run_dir"
cleanup() {
  COMPOSE_PROJECT_NAME=$project docker compose down --volumes --remove-orphans >/dev/null 2>&1 || true
  if [[ -n ${M35_ARTIFACT_DIR:-} ]]; then
    mkdir -p -- "$M35_ARTIFACT_DIR"
    cp -a -- "$run_dir/." "$M35_ARTIFACT_DIR/"
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
  test -s sql/m35.sql
  test -s tests/m35.sql
  test -s docs/m35-contract.md
  test -s docs/m35-api-reference.md
  test -s docs/m35-api-inventory.json
  test -s docs/m35-finding-codes.json
  test -s docs/m35-evidence.md
  test -s docs/m35-migration.md
  test -s docs/m35-release-notes.md
  bash -n tests/m35.sh
  grep -qx 'version = "0.32.0"' Cargo.toml
  grep -qx "default_version = '0.32.0'" pg_react.control
  jq -e '.schema_version == 1 and .milestone == "M35" and .extension_version == "0.32.0" and (.ordinary.functions | index("pgreact.compare"))' docs/m35-api-inventory.json >/dev/null
  jq -e '.schema_version == 1 and .milestone == "M35" and (.codes | length == 18)' docs/m35-finding-codes.json >/dev/null
  cmp sql/pg_react--0.31.0--0.32.0.sql sql/m35.sql
  cmp sql/pg_react--0.32.0.sql <(cat sql/pg_react--0.31.0.sql; printf '\n'; cat sql/m35.sql)
  test "$(tail -c 1 sql/pg_react--0.32.0.sql | od -An -t x1 | tr -d ' \n')" = 0a
  ! grep -Eq '(^|[[:space:]])(ALTER|CREATE)[[:space:]]+EXTENSION' sql/m35.sql
  ! grep -Eq '(^|[[:space:]])(CREATE|ALTER)[[:space:]]+(SCHEMA|TABLE|TYPE|VIEW)[[:space:]]+pgreact\.' sql/m35.sql
  ! grep -Eq '^[[:space:]]*(INSERT|UPDATE|DELETE|TRUNCATE|CREATE[[:space:]]+TEMP)[[:space:]]' sql/m35.sql
}

run_test 'M35 static and concatenation audit' static_audit

if ! command -v docker >/dev/null 2>&1 || ! docker image inspect "$image" >/dev/null 2>&1; then
  echo "M35 external Docker evidence not run: candidate image '$image' is unavailable"
  echo "M35 static lane passed; no external qualification claim made"
  exit 0
fi

export COMPOSE_PROJECT_NAME=$project
export PG_REACT_IMAGE=$image
export PG_REACT_INIT_VERSION=${M35_INIT_VERSION:-$expected_version}
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
  echo "M35 candidate image did not provide pg-react $expected_version" >&2
  exit 1
fi
run_test 'M35 hypothetical comparison checks' \
  docker compose exec -T postgres psql -XAtq -U postgres -d postgres \
  -v ON_ERROR_STOP=1 -f - < tests/m35.sql

if [[ $profile = complete ]]; then
  export PG_REACT_INIT_VERSION=0.31.0
  docker compose down --volumes --remove-orphans >/dev/null 2>&1
  docker compose up -d --no-build >/dev/null 2>&1
  ready=
  for _ in {1..120}; do
    if [[ $(docker inspect --format '{{.State.Health.Status}}' "${project}-postgres-1" 2>/dev/null || true) = healthy ]] &&
       docker compose exec -T postgres psql -XAtq -U postgres -d postgres -c \
       "SELECT extversion='0.31.0' FROM pg_extension WHERE extname='pg_react'" 2>/dev/null | grep -qx t; then
      ready=1
      break
    fi
    sleep 1
  done
  if [[ -z $ready ]]; then
    echo 'M35 populated-upgrade source did not provide pg-react 0.31.0' >&2
    exit 1
  fi
  run_test 'M35 0.31.0 to 0.32.0 upgrade' \
    docker compose exec -T postgres psql -XAtq -U postgres -d postgres \
    -v ON_ERROR_STOP=1 -c "ALTER EXTENSION pg_react UPDATE TO '0.32.0';"
  run_test 'M35 upgraded comparison surface' \
    docker compose exec -T postgres psql -XAtq -U postgres -d postgres \
    -v ON_ERROR_STOP=1 -c "SELECT extversion = '0.32.0' AND to_regprocedure('pgreact.compare(pgreact_api.declaration,pgreact_api.target,jsonb,jsonb)') IS NOT NULL FROM pg_extension WHERE extname = 'pg_react';"
fi

echo "M35 $profile candidate Docker lane passed for $image"
