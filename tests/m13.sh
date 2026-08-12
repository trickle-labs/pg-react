#!/usr/bin/env bash
set -euo pipefail

version=${PG_REACT_EXPECTED_VERSION:-0.10.0}
image=${1:-pg-react:v$version}
platform=linux/amd64
project=${COMPOSE_PROJECT_NAME:-pgreact-m13-${GITHUB_RUN_ID:-$$}}
test_log_dir=$(mktemp -d)

cleanup() {
  COMPOSE_PROJECT_NAME=$project docker compose down --volumes --remove-orphans >/dev/null 2>&1 || true
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

create_db() {
  for _ in {1..3}; do
    if docker compose exec -T postgres createdb -U postgres "$1" >/dev/null 2>&1; then
      return
    fi
    sleep 1
  done
  docker compose exec -T postgres createdb -U postgres "$1"
}

run_sql_fixture() {
  local name=$1
  local database=$2
  local fixture=$3
  create_db "$database"
  docker compose exec -T postgres psql -X -U postgres -d "$database" \
    -v ON_ERROR_STOP=1 -c 'CREATE EXTENSION pg_trickle; CREATE EXTENSION pg_react' >/dev/null
  docker compose cp "tests/$fixture.sql" "postgres:/tmp/$fixture.sql" >/dev/null 2>&1
  run_test "$name" docker compose exec -T postgres psql -XAtq -U postgres \
    -d "$database" -v ON_ERROR_STOP=1 -f "/tmp/$fixture.sql"
}

run_test 'M13 task documentation' bash tests/m13-docs.sh
run_test 'M0-M12 compatibility' env \
  PG_REACT_EXPECTED_VERSION=0.10.0 \
  COMPOSE_PROJECT_NAME="${project}-compatibility" \
  bash tests/m12.sh "$image"

export PG_REACT_IMAGE=$image
export PG_REACT_PLATFORM=$platform
export PG_REACT_PORT_BINDING=${PG_REACT_PORT_BINDING:-127.0.0.1::5432}
export COMPOSE_PROJECT_NAME=$project

docker compose up -d --no-build >/dev/null 2>&1
ready=false
for _ in {1..120}; do
  if docker compose exec -T postgres psql -X -U postgres -d postgres -Atc \
      "SELECT extversion = '$version' FROM pg_extension WHERE extname = 'pg_react'" \
      2>/dev/null | grep -qx t; then
    ready=true
    break
  fi
  sleep 1
done
test "$ready" = true
test "$(docker image inspect "$image" --format '{{.Os}}/{{.Architecture}}')" = "$platform"
test "$(docker compose exec -T postgres sh -c 'test -x /usr/local/bin/pg-reactd && echo executable')" = executable

run_sql_fixture 'M13 ergonomic API and exact role matrix' m13_api m13-api
run_sql_fixture 'M13 immutable action drift' m13_drift m13-drift

create_db m13_program
docker compose exec -T postgres psql -X -U postgres -d m13_program \
  -v ON_ERROR_STOP=1 -c 'CREATE EXTENSION pg_trickle; CREATE EXTENSION pg_react' >/dev/null
for fixture in m8-setup m13-program; do
  docker compose cp "tests/$fixture.sql" "postgres:/tmp/$fixture.sql" >/dev/null 2>&1
done
run_test 'M13 dependency-ordered program coordination' docker compose exec -T postgres \
  psql -XAtq -U postgres -d m13_program -v ON_ERROR_STOP=1 \
  -f /tmp/m13-program.sql

create_db m13_concurrency
for fixture in m13-concurrency-setup m13-hold-run m13-concurrency-result; do
  docker compose cp "tests/$fixture.sql" "postgres:/tmp/$fixture.sql" >/dev/null 2>&1
done
docker compose exec -T postgres psql -XAtq -U postgres -d m13_concurrency \
  -v ON_ERROR_STOP=1 -c 'CREATE EXTENSION pg_trickle; CREATE EXTENSION pg_react' \
  -f /tmp/m13-concurrency-setup.sql >"$test_log_dir/m13-concurrency-setup.log" 2>&1
docker compose exec -T postgres psql -XAtq -U postgres -d m13_concurrency \
  -v ON_ERROR_STOP=1 -f /tmp/m13-hold-run.sql \
  >"$test_log_dir/m13-run-a.log" 2>&1 &
run_a_pid=$!
held=false
for _ in {1..120}; do
  if docker compose exec -T postgres psql -XAtq -U postgres -d m13_concurrency -c \
      "SELECT EXISTS (SELECT 1 FROM pg_stat_activity WHERE datname = 'm13_concurrency' AND pid <> pg_backend_pid() AND state = 'active' AND query LIKE '%pg_sleep%')" \
      | grep -qx t; then
    held=true
    break
  fi
  sleep 0.1
done
test "$held" = true
docker compose exec -T postgres psql -XAtq -U postgres -d m13_concurrency \
  -v ON_ERROR_STOP=1 -c "SELECT pgreact_api.run('2033-01-01 00:00:00+00')" \
  >"$test_log_dir/m13-run-b.log" 2>&1 &
run_b_pid=$!
blocked=false
for _ in {1..120}; do
  if docker compose exec -T postgres psql -XAtq -U postgres -d m13_concurrency -c \
      "SELECT EXISTS (SELECT 1 FROM pg_stat_activity WHERE datname = 'm13_concurrency' AND pid <> pg_backend_pid() AND wait_event_type = 'Lock' AND query LIKE '%pgreact_api.run%')" \
      | grep -qx t; then
    blocked=true
    break
  fi
  sleep 0.1
done
test "$blocked" = true
wait "$run_a_pid"
wait "$run_b_pid"
grep -Fq '"jobs_created": 1' "$test_log_dir/m13-run-a.log"
grep -Fq '"jobs_created": 0' "$test_log_dir/m13-run-b.log"
run_test 'M13 concurrent coordinator serialization' docker compose exec -T postgres \
  psql -XAtq -U postgres -d m13_concurrency -v ON_ERROR_STOP=1 \
  -f /tmp/m13-concurrency-result.sql

create_db m13_upgrade
docker compose cp tests/m13-upgrade.sql postgres:/tmp/m13-upgrade.sql >/dev/null 2>&1
run_test 'M13 direct populated upgrade' docker compose exec -T postgres \
  psql -XAtq -U postgres -d m13_upgrade -v ON_ERROR_STOP=1 \
  -c "CREATE EXTENSION pg_trickle; CREATE EXTENSION pg_react VERSION '0.9.0'" \
  -f /tmp/m13-upgrade.sql

create_db m13_worker
for fixture in m12-worker-setup m12-worker-result; do
  docker compose cp "tests/$fixture.sql" "postgres:/tmp/$fixture.sql" >/dev/null 2>&1
done
docker compose exec -T postgres psql -XAtq -U postgres -d m13_worker \
  -v ON_ERROR_STOP=1 -c 'CREATE EXTENSION pg_trickle; CREATE EXTENSION pg_react' \
  -f /tmp/m12-worker-setup.sql >"$test_log_dir/m13-worker-setup.log" 2>&1
worker_version=$(docker compose exec -T postgres psql -XAtq -U postgres -d m13_worker -c \
  "SELECT version.rule_version_id FROM pgreact_internal.rules rule JOIN pgreact_internal.rule_versions version USING (rule_id) WHERE rule.rule_name = 'worker-deadline' AND version.state = 'ACTIVE'")
run_test 'M13 bundled worker canonical run and execution' docker compose exec -T \
  -e DATABASE_URL=postgresql://postgres@localhost/m13_worker \
  postgres pg-reactd "$worker_version" m13-worker
run_test 'M13 bundled worker exact result' docker compose exec -T postgres \
  psql -XAtq -U postgres -d m13_worker -v ON_ERROR_STOP=1 \
  -f /tmp/m12-worker-result.sql

run_test 'M13 crash restart and physical recovery' env \
  RECOVERY_MILESTONE=m13 bash tests/m6-recovery.sh

echo "M13 core PostgreSQL ergonomics gate passed for $image ($platform)"
