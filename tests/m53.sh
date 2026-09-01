#!/usr/bin/env bash
set -euo pipefail

profile=${1:-fast}
image=${2:-pg-react:m53-unreleased}
expected_version=${M53_EXPECTED_VERSION:-0.42.0}
case "$profile" in fast|complete) ;; *) echo 'usage: tests/m53.sh fast|complete [IMAGE]' >&2; exit 2 ;; esac

run_dir="tests/.m53-run-${GITHUB_RUN_ID:-$$}"
project=${COMPOSE_PROJECT_NAME:-pgreact-m53-${GITHUB_RUN_ID:-$$}}
rollback_project=${project}-rollback
mkdir -p -- "$run_dir"
cleanup() {
  COMPOSE_PROJECT_NAME=$project docker compose down --volumes --remove-orphans >/dev/null 2>&1 || true
  COMPOSE_PROJECT_NAME=$rollback_project docker compose down --volumes --remove-orphans >/dev/null 2>&1 || true
  if [[ -n ${M53_ARTIFACT_DIR:-} ]]; then
    mkdir -p -- "$M53_ARTIFACT_DIR"
    cp -a -- "$run_dir/." "$M53_ARTIFACT_DIR/"
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
  test -s sql/m53.sql
  test -s tests/m53.sql
  for file in \
    docs/m53-contract.md docs/m53-api-reference.md docs/m53-api-inventory.json \
    docs/m53-finding-codes.json docs/m53-evidence.md docs/m53-migration.md \
    docs/m53-release-notes.md docs/m53-known-limitations.md docs/m53-final-checklist.md \
    docs/m53-ergonomics-contract.md docs/m53-ergonomics-api-inventory.json \
    docs/m53-ergonomics-finding-codes.json; do
    test -s "$file"
  done
  bash -n tests/m53.sh
  grep -qx 'version = "0.42.0"' Cargo.toml
  grep -qx "default_version = '0.42.0'" pg_react.control
  grep -Fq '0.41.0` to `0.42.0' docs/m53-migration.md
  grep -Fq 'ordinary people' docs/m53-release-notes.md || grep -Eiq 'you can|what you can|back up|roll back' docs/m53-release-notes.md
  jq -e '.extension_version == "0.42.0" and .contract_version == 53 and (.functions | index("pgreact.policy_set(text,text,pgreact_api.declaration[],regclass,name[],pgreact_api.declaration[],jsonb,timestamptz,timestamptz,integer)")) and (.views | index("pgreact.policy_set_contents")) and (.actions == ["ADD","KEEP","REPLACE","ADOPT","REMOVE"]) and .limits.canonical_bytes == 1048576' docs/m53-api-inventory.json >/dev/null
  jq -e '.contract_version == 53 and (.codes | index("M53_POLICY_DEPENDENCY_CYCLE")) and (.codes | index("M53_IMPORT_DIGEST"))' docs/m53-finding-codes.json >/dev/null
  grep -Fq "'ADD'" sql/m53.sql
  grep -Fq "'KEEP'" sql/m53.sql
  grep -Fq "'REPLACE'" sql/m53.sql
  grep -Fq "'ADOPT'" sql/m53.sql
  grep -Fq "'REMOVE'" sql/m53.sql
  cmp sql/pg_react--0.41.0--0.42.0.sql sql/m53.sql
  cmp sql/pg_react--0.42.0.sql <(cat sql/pg_react--0.41.0.sql sql/m53.sql)
  test "$(tail -c 1 sql/pg_react--0.42.0.sql | od -An -t x1 | tr -d ' \n')" = 0a
  ! grep -Eq '(^|[[:space:]])(ALTER|CREATE)[[:space:]]+EXTENSION' sql/m53.sql
  ! grep -Eq '(^|[[:space:]])(CREATE|ALTER)[[:space:]]+(SCHEMA|TABLE|TYPE)[[:space:]]+pgreact\.' sql/m53.sql
}

run_test 'M53 static and concatenation audit' static_audit

if ! command -v docker >/dev/null 2>&1 || ! docker image inspect "$image" >/dev/null 2>&1; then
  echo "M53 external Docker evidence not run: candidate image '$image' is unavailable"
  echo 'M53 static lane passed; no external qualification claim made'
  exit 0
fi

export COMPOSE_PROJECT_NAME=$project
export PG_REACT_IMAGE=$image
export PG_REACT_INIT_VERSION=${M53_INIT_VERSION:-$expected_version}
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
if [[ -z $ready ]]; then echo "M53 candidate image did not provide pg-react $expected_version" >&2; exit 1; fi
run_test 'M53 inherited M38 corpus' docker compose exec -T postgres psql -XAtq -U postgres -d postgres -v ON_ERROR_STOP=1 -f - < tests/m38.sql
run_test 'M53 inherited M39 corpus' docker compose exec -T postgres psql -XAtq -U postgres -d postgres -v ON_ERROR_STOP=1 -f - < tests/m39.sql
run_test 'M53 inherited M40 corpus' docker compose exec -T postgres psql -XAtq -U postgres -d postgres -v ON_ERROR_STOP=1 -f - < tests/m40.sql
run_test 'M53 inherited M41 corpus' docker compose exec -T postgres psql -XAtq -U postgres -d postgres -v ON_ERROR_STOP=1 -f - < tests/m41.sql
run_test 'M53 inherited M42 corpus' docker compose exec -T postgres psql -XAtq -U postgres -d postgres -v ON_ERROR_STOP=1 -f - < tests/m42.sql
run_test 'M53 inherited M43 corpus' docker compose exec -T postgres psql -XAtq -U postgres -d postgres -v ON_ERROR_STOP=1 -f - < tests/m43.sql
run_test 'M53 inherited M44 corpus' docker compose exec -T postgres psql -XAtq -U postgres -d postgres -v ON_ERROR_STOP=1 -f - < tests/m44.sql
run_test 'M53 ergonomics corpus' docker compose exec -T postgres psql -XAtq -U postgres -d postgres -v ON_ERROR_STOP=1 -f - < tests/m53-ergonomics.sql
run_test 'M53 package corpus' docker compose exec -T postgres psql -XAtq -U postgres -d postgres -v ON_ERROR_STOP=1 -f - < tests/m53.sql

if [[ $profile = complete ]]; then
  export PG_REACT_INIT_VERSION=0.41.0
  docker compose down --volumes --remove-orphans >/dev/null 2>&1
  docker compose up -d --no-build >/dev/null 2>&1
  ready=
  for _ in {1..120}; do
    if [[ $(docker inspect --format '{{.State.Health.Status}}' "${project}-postgres-1" 2>/dev/null || true) = healthy ]] &&
       docker compose exec -T postgres psql -XAtq -U postgres -d postgres -c \
         "SELECT extversion='0.41.0' FROM pg_extension WHERE extname='pg_react'" 2>/dev/null | grep -qx t; then
      ready=1
      break
    fi
    sleep 1
  done
  if [[ -z $ready ]]; then echo 'M53 populated-upgrade source did not provide pg-react 0.41.0' >&2; exit 1; fi
  upgrade_volume=$(docker volume ls --filter "label=com.docker.compose.project=$project" --filter 'label=com.docker.compose.volume=postgres-data' --format '{{.Name}}')
  if [[ -z $upgrade_volume ]]; then echo 'M53 populated-upgrade volume was not created' >&2; exit 1; fi
  run_test 'M53 rollback backup' docker run --rm -v "$upgrade_volume:/source:ro" -v "$PWD/$run_dir:/backup" --entrypoint tar "$image" -cf /backup/m53-upgrade.tar -C /source .
  run_test 'M53 0.41.0 to 0.42.0 upgrade' docker compose exec -T postgres psql -XAtq -U postgres -d postgres -v ON_ERROR_STOP=1 -c "ALTER EXTENSION pg_react UPDATE TO '0.42.0';"
  run_test 'M53 upgraded version' docker compose exec -T postgres psql -XAtq -U postgres -d postgres -v ON_ERROR_STOP=1 -c "SELECT extversion = '0.42.0' FROM pg_extension WHERE extname = 'pg_react';"
  rollback_volume="${rollback_project}_postgres-data"
  docker volume create --label "com.docker.compose.project=$rollback_project" --label 'com.docker.compose.volume=postgres-data' "$rollback_volume" >/dev/null
  run_test 'M53 rollback restore' docker run --rm -v "$rollback_volume:/target" -v "$PWD/$run_dir:/backup" --entrypoint tar "$image" -xf /backup/m53-upgrade.tar -C /target
  export COMPOSE_PROJECT_NAME=$rollback_project
  export PG_REACT_INIT_VERSION=0.41.0
  docker compose up -d --no-build >/dev/null 2>&1
  ready=
  for _ in {1..120}; do
    if [[ $(docker inspect --format '{{.State.Health.Status}}' "${rollback_project}-postgres-1" 2>/dev/null || true) = healthy ]] &&
       docker compose exec -T postgres psql -XAtq -U postgres -d postgres -c \
         "SELECT extversion='0.41.0' FROM pg_extension WHERE extname='pg_react'" 2>/dev/null | grep -qx t; then
      ready=1
      break
    fi
    sleep 1
  done
  if [[ -z $ready ]]; then echo 'M53 rollback restore did not provide pg-react 0.41.0' >&2; exit 1; fi
  run_test 'M53 rollback version' docker compose exec -T postgres psql -XAtq -U postgres -d postgres -v ON_ERROR_STOP=1 -c "SELECT extversion = '0.41.0' FROM pg_extension WHERE extname = 'pg_react';"
fi

echo "M53 $profile candidate Docker lane passed for $image"
