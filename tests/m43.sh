#!/usr/bin/env bash
set -euo pipefail

profile=${1:-fast}
image=${2:-pg-react:m43-unreleased}
expected_version=${M43_EXPECTED_VERSION:-0.40.0}
case "$profile" in fast|complete) ;; *) echo 'usage: tests/m43.sh fast|complete [IMAGE]' >&2; exit 2 ;; esac

run_dir="tests/.m43-run-${GITHUB_RUN_ID:-$$}"
project=${COMPOSE_PROJECT_NAME:-pgreact-m43-${GITHUB_RUN_ID:-$$}}
mkdir -p -- "$run_dir"
cleanup() {
  COMPOSE_PROJECT_NAME=$project docker compose down --volumes --remove-orphans >/dev/null 2>&1 || true
  if [[ -n ${M43_ARTIFACT_DIR:-} ]]; then
    mkdir -p -- "$M43_ARTIFACT_DIR"
    cp -a -- "$run_dir/." "$M43_ARTIFACT_DIR/"
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
  test -s sql/m43.sql
  test -s tests/m43.sql
  for file in \
    docs/m43-contract.md docs/m43-api-reference.md docs/m43-api-inventory.json \
    docs/m43-finding-codes.json docs/m43-evidence.md docs/m43-migration.md \
    docs/m43-release-notes.md docs/m43-examples.md docs/m43-known-limitations.md \
    docs/m43-benchmark.md docs/m43-compatibility.md docs/m43-reference-corpus.json \
    docs/m43-final-checklist.md; do
    test -s "$file"
  done
  bash -n tests/m43.sh
  grep -qx 'version = "0.40.0"' Cargo.toml
  grep -qx "default_version = '0.40.0'" pg_react.control
  grep -Fq '0.39.0` to `0.40.0' docs/m43-migration.md
  grep -Eiq 'ordinary|plain|operator' docs/m43-release-notes.md
  jq -e '.schema_version == 1 and .milestone == "M43" and .extension_version == "0.40.0" and (.ordinary.functions | index("pgreact_api.semantic_diff"))' docs/m43-api-inventory.json >/dev/null
  jq -e '.schema_version == 1 and .milestone == "M43" and (.codes | length >= 13)' docs/m43-finding-codes.json >/dev/null
  jq -e '.schema_version == 1 and (.reviews | length == 3)' docs/m43-reference-corpus.json >/dev/null
  cmp sql/pg_react--0.39.0--0.40.0.sql sql/m43.sql
  cmp sql/pg_react--0.40.0.sql <(cat sql/pg_react--0.39.0.sql sql/m43.sql)
  test "$(tail -c 1 sql/pg_react--0.40.0.sql | od -An -t x1 | tr -d ' \n')" = 0a
  ! grep -Eq '(^|[[:space:]])(ALTER|CREATE)[[:space:]]+EXTENSION' sql/m43.sql
  ! grep -Eq '(^|[[:space:]])(CREATE|ALTER)[[:space:]]+(SCHEMA|TABLE|TYPE|VIEW)[[:space:]]+pgreact\.' sql/m43.sql
}

run_test 'M43 static and concatenation audit' static_audit

if ! command -v docker >/dev/null 2>&1 || ! docker image inspect "$image" >/dev/null 2>&1; then
  echo "M43 external Docker evidence not run: candidate image '$image' is unavailable"
  echo 'M43 static lane passed; no external qualification claim made'
  exit 0
fi

export COMPOSE_PROJECT_NAME=$project
export PG_REACT_IMAGE=$image
export PG_REACT_INIT_VERSION=${M43_INIT_VERSION:-$expected_version}
export PG_REACT_PLATFORM=linux/amd64
export PG_REACT_PORT_BINDING=${PG_REACT_PORT_BINDING:-127.0.0.1::5432}
docker compose up -d --no-build >/dev/null 2>&1
ready=
for _ in {1..120}; do
  if [[ $(docker inspect --format '{{.State.Health.Status}}' "${project}-postgres-1" 2>/dev/null || true) = healthy ]] &&
     docker compose exec -T postgres psql -XAtq -U postgres -d postgres -c \
       "SELECT extversion='$expected_version' FROM pg_extension WHERE extname='pg_react'" 2>/dev/null | grep -qx t; then
    ready=1; break
  fi
  sleep 1
done
if [[ -z $ready ]]; then echo "M43 candidate image did not provide pg-react $expected_version" >&2; exit 1; fi
run_test 'M43 inherited M42 corpus' docker compose exec -T postgres psql -XAtq -U postgres -d postgres -v ON_ERROR_STOP=1 -f - < tests/m42.sql
run_test 'M43 conformance corpus' docker compose exec -T postgres psql -XAtq -U postgres -d postgres -v ON_ERROR_STOP=1 -f - < tests/m43.sql

if [[ $profile = complete ]]; then
  export PG_REACT_INIT_VERSION=0.39.0
  docker compose down --volumes --remove-orphans >/dev/null 2>&1
  docker compose up -d --no-build >/dev/null 2>&1
  ready=
  for _ in {1..120}; do
    if [[ $(docker inspect --format '{{.State.Health.Status}}' "${project}-postgres-1" 2>/dev/null || true) = healthy ]] &&
       docker compose exec -T postgres psql -XAtq -U postgres -d postgres -c \
       "SELECT extversion='0.39.0' FROM pg_extension WHERE extname='pg_react'" 2>/dev/null | grep -qx t; then
      ready=1; break
    fi
    sleep 1
  done
  if [[ -z $ready ]]; then echo 'M43 populated-upgrade source did not provide pg-react 0.39.0' >&2; exit 1; fi
  run_test 'M43 0.39.0 to 0.40.0 upgrade' docker compose exec -T postgres psql -XAtq -U postgres -d postgres -v ON_ERROR_STOP=1 -c "ALTER EXTENSION pg_react UPDATE TO '0.40.0';"
  run_test 'M43 upgraded version' docker compose exec -T postgres psql -XAtq -U postgres -d postgres -v ON_ERROR_STOP=1 -c "SELECT extversion = '0.40.0' FROM pg_extension WHERE extname = 'pg_react';"
fi
