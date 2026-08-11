#!/usr/bin/env bash
set -euo pipefail

image=${1:-pg-react:v0.4.0}
platform=linux/amd64
project=${COMPOSE_PROJECT_NAME:-pgreact-m7-${GITHUB_RUN_ID:-$$}}
expected_version=${PG_REACT_EXPECTED_VERSION:-0.4.0}
test_log_dir=$(mktemp -d)

case "$expected_version" in
  0.4.0|0.5.0|0.6.0|0.7.0) ;;
  *) echo "unsupported M7 compatibility version: $expected_version" >&2; exit 1 ;;
esac

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

expect_failure() {
  local name=$1
  local expected=$2
  shift 2
  local log="$test_log_dir/${name// /-}.log"
  if "$@" >"$log" 2>&1; then
    echo "$name unexpectedly succeeded" >&2
    return 1
  fi
  if ! grep -Fq "$expected" "$log"; then
    sed -n '1,$p' "$log"
    return 1
  fi
  echo "$name rejected exactly"
}

expect_lock_timeout() {
  local name=$1
  shift
  local log="$test_log_dir/${name// /-}.log"
  if "$@" >"$log" 2>&1; then
    echo "$name unexpectedly crossed the refresh lock" >&2
    return 1
  fi
  if ! grep -Fq 'canceling statement due to lock timeout' "$log"; then
    sed -n '1,$p' "$log"
    return 1
  fi
  echo "$name serialized"
}

run_sql_fixture() {
  local name=$1
  local database=$2
  local fixture=$3
  docker compose exec -T postgres createdb -U postgres "$database"
  docker compose exec -T postgres psql -X -U postgres -d "$database" -v ON_ERROR_STOP=1 -c \
    'CREATE EXTENSION pg_trickle; CREATE EXTENSION pg_react' >/dev/null
  docker compose cp "tests/$fixture.sql" "postgres:/tmp/$fixture.sql" >/dev/null 2>&1
  run_test "$name" docker compose exec -T postgres psql -X -U postgres -d "$database" \
    -v ON_ERROR_STOP=1 -f "/tmp/$fixture.sql"
}

run_test "M0-M6 compatibility" env \
  COMPOSE_PROJECT_NAME="${project}-compatibility" \
  PG_REACT_EXPECTED_VERSION="$expected_version" \
  bash tests/m6.sh "$image"

export PG_REACT_IMAGE=$image
export PG_REACT_PLATFORM=$platform
export PG_REACT_PORT_BINDING=${PG_REACT_PORT_BINDING:-127.0.0.1::5432}
export COMPOSE_PROJECT_NAME=$project
docker compose up -d --no-build >/dev/null 2>&1
ready=false
for _ in {1..120}; do
  if docker compose exec -T postgres psql -X -U postgres -d postgres -Atc \
      "SELECT extversion = '$expected_version' FROM pg_extension WHERE extname = 'pg_react'" 2>/dev/null | grep -qx t; then
    ready=true
    break
  fi
  sleep 1
done
test "$ready" = true
test "$(docker image inspect "$image" --format '{{.Os}}/{{.Architecture}}')" = "$platform"

run_sql_fixture "M7 public API inventory" m7_api m6-api
run_sql_fixture "M7 lifecycle and reconciliation" m7_acceptance m7
run_sql_fixture "M7 ordering equivalence" m7_order m7-order
run_sql_fixture "M7 boundary and retention" m7_boundary m7-boundary
run_sql_fixture "M7 atomic pack lifecycle" m7_pack m7-pack

docker compose exec -T postgres createdb -U postgres m7_conflict
docker compose exec -T postgres psql -X -U postgres -d m7_conflict -v ON_ERROR_STOP=1 -c \
  'CREATE EXTENSION pg_trickle; CREATE EXTENSION pg_react' >/dev/null
for fixture in m7-conflict-setup m7-conflict-result; do
  docker compose cp "tests/$fixture.sql" "postgres:/tmp/$fixture.sql" >/dev/null 2>&1
done
run_test "M7 conflicting-payload setup" docker compose exec -T postgres psql -X -U postgres \
  -d m7_conflict -v ON_ERROR_STOP=1 -f /tmp/m7-conflict-setup.sql
expect_failure "M7 conflicting payload" "conflicting derived payloads" \
  docker compose exec -T postgres psql -X -U postgres -d m7_conflict -v ON_ERROR_STOP=1 -c \
  'SELECT pgreact.refresh_derived_relation((SELECT relation_version_id FROM conflict_fixture.identity))'
run_test "M7 conflicting-payload rollback" docker compose exec -T postgres psql -X -U postgres \
  -d m7_conflict -v ON_ERROR_STOP=1 -f /tmp/m7-conflict-result.sql

docker compose exec -T postgres createdb -U postgres m7_upgrade
docker compose cp tests/m7-upgrade.sql postgres:/tmp/m7-upgrade.sql >/dev/null 2>&1
run_test "M7 direct upgrade" docker compose exec -T postgres psql -X -U postgres -d m7_upgrade \
  -v ON_ERROR_STOP=1 -f /tmp/m7-upgrade.sql

docker compose exec -T postgres createdb -U postgres m7_concurrency
docker compose exec -T postgres psql -X -U postgres -d m7_concurrency -v ON_ERROR_STOP=1 -c \
  'CREATE EXTENSION pg_trickle; CREATE EXTENSION pg_react' >/dev/null
for fixture in m7-concurrency-setup m7-hold-refresh m7-concurrency-result; do
  docker compose cp "tests/$fixture.sql" "postgres:/tmp/$fixture.sql" >/dev/null 2>&1
done
run_test "M7 concurrency setup" docker compose exec -T postgres psql -X -U postgres \
  -d m7_concurrency -v ON_ERROR_STOP=1 -f /tmp/m7-concurrency-setup.sql
docker compose exec -T postgres psql -X -U postgres -d m7_concurrency \
  -v ON_ERROR_STOP=1 -f /tmp/m7-hold-refresh.sql >"$test_log_dir/held-refresh.log" 2>&1 &
held_pid=$!
held=false
for _ in {1..120}; do
  if docker compose exec -T postgres psql -X -A -t -U postgres -d m7_concurrency -c \
      "SELECT EXISTS (SELECT 1 FROM pg_stat_activity WHERE datname='m7_concurrency' AND pid <> pg_backend_pid() AND state='active' AND query LIKE '%pg_sleep%')" | grep -qx t; then
    held=true
    break
  fi
  sleep 0.1
done
test "$held" = true
expect_lock_timeout "M7 concurrent refresh" docker compose exec -T postgres psql -X -v ON_ERROR_STOP=1 \
  -U postgres -d m7_concurrency -c \
  "SET lock_timeout='100ms'; SELECT pgreact.refresh_derived_relation(relation_version_id) FROM m7_concurrency.control"
expect_lock_timeout "M7 derivation replacement" docker compose exec -T postgres psql -X -v ON_ERROR_STOP=1 \
  -U postgres -d m7_concurrency -c \
  "SET lock_timeout='100ms'; SELECT pgreact.replace_derivation_rule(derivation_version_id, 'm7_concurrency.source_active'::regclass, ARRAY['id'], 2) FROM m7_concurrency.control"
expect_lock_timeout "M7 source DDL" docker compose exec -T postgres psql -X -v ON_ERROR_STOP=1 \
  -U postgres -d m7_concurrency -c \
  "SET lock_timeout='100ms'; ALTER VIEW m7_concurrency.source_active SET (security_barrier=false)"
expect_failure "M7 relation DDL" "cannot drop view m7_concurrency.current_fact because other objects depend on it" \
  docker compose exec -T postgres psql -X -v ON_ERROR_STOP=1 -U postgres -d m7_concurrency -c \
  "DROP VIEW m7_concurrency.current_fact"
expect_lock_timeout "M7 downstream DDL" docker compose exec -T postgres psql -X -v ON_ERROR_STOP=1 \
  -U postgres -d m7_concurrency -c \
  "SET lock_timeout='100ms'; ALTER VIEW m7_concurrency.observe_fact SET (security_barrier=false)"
docker compose exec -T postgres psql -X -A -t -U postgres -d m7_concurrency -c \
  "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='m7_concurrency' AND pid <> pg_backend_pid() AND state='active' AND query LIKE '%pg_sleep%'" | grep -qx t
if wait "$held_pid"; then
  echo 'terminated refresh unexpectedly committed' >&2
  exit 1
fi
grep -Fq 'terminating connection due to administrator command' "$test_log_dir/held-refresh.log"
run_test "M7 concurrent graph remains exact" docker compose exec -T postgres psql -X -U postgres \
  -d m7_concurrency -v ON_ERROR_STOP=1 -f /tmp/m7-concurrency-result.sql

run_test "M7 crash restart and physical recovery" env RECOVERY_MILESTONE=m7 bash tests/m6-recovery.sh

echo "M7 maintained derived knowledge gate passed for $image ($platform)"
