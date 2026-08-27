#!/usr/bin/env bash
set -euo pipefail

profile=${1:-fast}
image=${2:-pg-react:m38-unreleased}
expected_version=${M38_EXPECTED_VERSION:-0.35.0}
case "$profile" in fast|complete) ;; *) echo 'usage: tests/m38.sh fast|complete [IMAGE]' >&2; exit 2 ;; esac

run_dir="tests/.m38-run-${GITHUB_RUN_ID:-$$}"
project=${COMPOSE_PROJECT_NAME:-pgreact-m38-${GITHUB_RUN_ID:-$$}}
mkdir -p -- "$run_dir"
cleanup() {
  COMPOSE_PROJECT_NAME=$project docker compose down --volumes --remove-orphans >/dev/null 2>&1 || true
  if [[ -n ${M38_ARTIFACT_DIR:-} ]]; then
    mkdir -p -- "$M38_ARTIFACT_DIR"
    cp -a -- "$run_dir/." "$M38_ARTIFACT_DIR/"
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
  test -s sql/m38.sql
  test -s tests/m38.sql
  for file in \
    docs/m38-contract.md docs/m38-api-reference.md docs/m38-api-inventory.json \
    docs/m38-finding-codes.json docs/m38-evidence.md docs/m38-migration.md \
    docs/m38-release-notes.md docs/m38-examples.md docs/m38-known-limitations.md \
    docs/m38-benchmark.md docs/m38-compatibility.md docs/m38-final-checklist.md; do
    test -s "$file"
  done
  bash -n tests/m38.sh
  grep -qx 'version = "0.35.0"' Cargo.toml
  grep -qx "default_version = '0.35.0'" pg_react.control
  jq -e '.schema_version == 1 and .milestone == "M38" and .extension_version == "0.35.0" and (.ordinary.functions | index("pgreact.backtest"))' docs/m38-api-inventory.json >/dev/null
  jq -e '.schema_version == 1 and .milestone == "M38" and (.codes | length == 9)' docs/m38-finding-codes.json >/dev/null
  cmp sql/pg_react--0.34.0--0.35.0.sql sql/m38.sql
  cmp sql/pg_react--0.35.0.sql <(cat sql/pg_react--0.34.0.sql; printf '\n'; cat sql/m38.sql)
  test "$(tail -c 1 sql/pg_react--0.35.0.sql | od -An -t x1 | tr -d ' \n')" = 0a
  ! grep -Eq '(^|[[:space:]])(ALTER|CREATE)[[:space:]]+EXTENSION' sql/m38.sql
  ! grep -Eq '(^|[[:space:]])(CREATE|ALTER)[[:space:]]+(SCHEMA|TABLE|TYPE|VIEW)[[:space:]]+pgreact\.' sql/m38.sql
  ! grep -Eq '^[[:space:]]*(INSERT|UPDATE|DELETE|TRUNCATE|CREATE[[:space:]]+TEMP)[[:space:]]' sql/m38.sql
}

run_test 'M38 static and concatenation audit' static_audit

if ! command -v docker >/dev/null 2>&1 || ! docker image inspect "$image" >/dev/null 2>&1; then
  echo "M38 external Docker evidence not run: candidate image '$image' is unavailable"
  echo "M38 static lane passed; no external qualification claim made"
  exit 0
fi

export COMPOSE_PROJECT_NAME=$project
export PG_REACT_IMAGE=$image
export PG_REACT_INIT_VERSION=${M38_INIT_VERSION:-$expected_version}
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
  echo "M38 candidate image did not provide pg-react $expected_version" >&2
  exit 1
fi
run_test 'M38 why-changed checks' \
  docker compose exec -T postgres psql -XAtq -U postgres -d postgres \
  -v ON_ERROR_STOP=1 -f - < tests/m38.sql

if [[ $profile = complete ]]; then
  export PG_REACT_INIT_VERSION=0.34.0
  docker compose down --volumes --remove-orphans >/dev/null 2>&1
  docker compose up -d --no-build >/dev/null 2>&1
  ready=
  for _ in {1..120}; do
    if [[ $(docker inspect --format '{{.State.Health.Status}}' "${project}-postgres-1" 2>/dev/null || true) = healthy ]] &&
       docker compose exec -T postgres psql -XAtq -U postgres -d postgres -c \
       "SELECT extversion='0.34.0' FROM pg_extension WHERE extname='pg_react'" 2>/dev/null | grep -qx t; then
      ready=1
      break
    fi
    sleep 1
  done
  if [[ -z $ready ]]; then
    echo 'M38 populated-upgrade source did not provide pg-react 0.34.0' >&2
    exit 1
  fi
  run_test 'M38 0.34.0 to 0.35.0 upgrade' \
    docker compose exec -T postgres psql -XAtq -U postgres -d postgres \
    -v ON_ERROR_STOP=1 -c "ALTER EXTENSION pg_react UPDATE TO '0.35.0';"
  run_test 'M38 upgraded why-changed surface' \
    docker compose exec -T postgres psql -XAtq -U postgres -d postgres \
    -v ON_ERROR_STOP=1 -c "SELECT extversion = '0.35.0' AND to_regprocedure('pgreact.backtest(pgreact_api.declaration,pgreact_api.target,jsonb,jsonb,jsonb)') IS NOT NULL FROM pg_extension WHERE extname = 'pg_react';"
fi

echo "M38 $profile candidate Docker lane passed for $image"
