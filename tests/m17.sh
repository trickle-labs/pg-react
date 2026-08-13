#!/usr/bin/env bash
set -euo pipefail

image=${1:-pg-react:v0.14.0}
project=${COMPOSE_PROJECT_NAME:-pgreact-m17-${GITHUB_RUN_ID:-$$}}
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
    if docker compose exec -T postgres createdb -U postgres "$1" >/dev/null 2>&1; then break; fi
    sleep 1
  done
  docker compose exec -T postgres psql -XAtq -U postgres -d "$1" \
    -v ON_ERROR_STOP=1 -c 'CREATE EXTENSION pg_trickle; CREATE EXTENSION pg_react' || return
}

run_test 'M17 documentation' bash tests/m17-docs.sh
run_test 'M0-M16 inherited compatibility' env \
  PG_REACT_EXPECTED_VERSION=0.14.0 \
  COMPOSE_PROJECT_NAME="${project}-m16" \
  bash tests/m16.sh "$image"

export PG_REACT_IMAGE=$image
export PG_REACT_PLATFORM=linux/amd64
export PG_REACT_PORT_BINDING=${PG_REACT_PORT_BINDING:-127.0.0.1::5432}
export PG_REACT_POLL_INTERVAL_MS=60000
export PG_REACT_BATCH_SIZE=1
export COMPOSE_PROJECT_NAME=$project
docker compose up -d --no-build >/dev/null 2>&1

ready=false
for _ in {1..120}; do
  if docker compose exec -T postgres psql -XAtq -U postgres -d postgres -c \
      "SELECT extversion='0.14.0' FROM pg_extension WHERE extname='pg_react'" \
      2>/dev/null | grep -qx t; then ready=true; break; fi
  sleep 1
done
test "$ready" = true
test "$(docker image inspect "$image" --format '{{.Os}}/{{.Architecture}}')" = linux/amd64

for fixture in m17-smoke m17-api m17-continue m17-late m17-resource \
               m17-logical-schema m17-logical-restore m17-hold-watermark \
               m17-concurrency-result m16-upgrade m17-upgrade; do
  docker compose cp "tests/$fixture.sql" "postgres:/tmp/$fixture.sql" >/dev/null
done

create_db m17_reference
run_test 'M17 exact boundaries and initial aggregates' \
  docker compose exec -T postgres psql -XAtq -U postgres -d m17_reference \
  -v ON_ERROR_STOP=1 -f /tmp/m17-smoke.sql
run_test 'M17 public API, permissions, and validation' \
  docker compose exec -T postgres psql -XAtq -U postgres -d m17_reference \
  -v ON_ERROR_STOP=1 -f /tmp/m17-api.sql
run_test 'M17 corrections, replay, batching, finalization, and failure rollback' \
  docker compose exec -T postgres psql -XAtq -U postgres -d m17_reference \
  -v ON_ERROR_STOP=1 -f /tmp/m17-continue.sql

docker compose exec -T postgres psql -XAtq -U postgres -d m17_reference \
  -v ON_ERROR_STOP=1 -c \
  "CREATE TABLE m17_reference.logical_export AS SELECT pgreact_api.export_window_state('m17.reference') AS state" \
  >/dev/null
docker compose exec -T postgres pg_dump -U postgres -d m17_reference -Fc --data-only \
  -t m17_reference.groups -t m17_reference.items \
  -t m17_reference.definition -t m17_reference.logical_export \
  -f /tmp/m17-logical.dump
create_db m17_logical
docker compose exec -T postgres psql -XAtq -U postgres -d m17_logical \
  -v ON_ERROR_STOP=1 -f /tmp/m17-logical-schema.sql >/dev/null
docker compose exec -T postgres pg_restore -U postgres -d m17_logical /tmp/m17-logical.dump
run_test 'M17 logical dump restore and continued execution' \
  docker compose exec -T postgres psql -XAtq -U postgres -d m17_logical \
  -v ON_ERROR_STOP=1 -f /tmp/m17-logical-restore.sql

run_test 'M17 late-input diagnostics, reconciliation, and retention' \
  docker compose exec -T postgres psql -XAtq -U postgres -d m17_reference \
  -v ON_ERROR_STOP=1 -f /tmp/m17-late.sql
run_test 'M17 resource, event-time, batch, and indexed-plan limits' \
  docker compose exec -T postgres psql -XAtq -U postgres -d m17_reference \
  -v ON_ERROR_STOP=1 -f /tmp/m17-resource.sql

create_db m17_concurrency
docker compose exec -T postgres psql -XAtq -U postgres -d m17_concurrency \
  -v ON_ERROR_STOP=1 -f /tmp/m17-smoke.sql >"$test_log_dir/m17-concurrency-setup.log" 2>&1

run_concurrent_request() {
  local held_target=$1
  local waiting_target=$2
  local expected=$3
  docker compose exec -T postgres psql -XAtq -U postgres -d m17_concurrency \
    -v ON_ERROR_STOP=1 -v target="$held_target" -f /tmp/m17-hold-watermark.sql \
    >"$test_log_dir/m17-held-$held_target.log" 2>&1 &
  local held_pid=$!
  local held=false
  for _ in {1..120}; do
    if docker compose exec -T postgres psql -XAtq -U postgres -d m17_concurrency -c \
      "SELECT EXISTS (SELECT 1 FROM pg_stat_activity WHERE datname='m17_concurrency' AND pid<>pg_backend_pid() AND state='active' AND query LIKE '%pg_sleep%')" \
      | grep -qx t; then held=true; break; fi
    sleep 0.05
  done
  test "$held" = true
  local result=0
  docker compose exec -T postgres psql -XAtq -U postgres -d m17_concurrency \
    -v ON_ERROR_STOP=1 -c \
    "SET SESSION AUTHORIZATION m17_operator; SELECT pgreact_api.request_watermark('m17.reference','m17_reference.item_source','occurred_at','$waiting_target')" \
    >"$test_log_dir/m17-waiting-$waiting_target.log" 2>&1 || result=$?
  wait "$held_pid"
  if [[ $expected = success ]]; then
    test "$result" -eq 0
  else
    test "$result" -ne 0
    grep -Fq 'M17_WATERMARK_BACKWARD' "$test_log_dir/m17-waiting-$waiting_target.log"
  fi
}

run_concurrent_request '1970-01-01T01:15:00Z' '1970-01-01T03:15:00Z' success
run_concurrent_request '1970-01-01T04:15:00Z' '1970-01-01T04:15:00Z' success
run_concurrent_request '1970-01-01T05:15:00Z' '1970-01-01T04:30:00Z' backward
run_test 'M17 concurrent watermark serialization' \
  docker compose exec -T postgres psql -XAtq -U postgres -d m17_concurrency \
  -v ON_ERROR_STOP=1 -f /tmp/m17-concurrency-result.sql

for _ in {1..3}; do
  if docker compose exec -T postgres createdb -U postgres m17_upgrade >/dev/null 2>&1; then break; fi
  sleep 1
done
run_test 'M17 populated direct upgrade' \
  docker compose exec -T postgres psql -XAtq -U postgres -d m17_upgrade \
  -v ON_ERROR_STOP=1 \
  -c "CREATE EXTENSION pg_trickle; CREATE EXTENSION pg_react VERSION '0.12.0'" \
  -f /tmp/m16-upgrade.sql -f /tmp/m17-upgrade.sql

run_test 'M17 crash restart, standby, promotion, and physical recovery' env \
  RECOVERY_MILESTONE=m17 bash tests/m6-recovery.sh

echo "M17 event-time windows evidence gate passed for $image (linux/amd64)"
