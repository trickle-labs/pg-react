#!/usr/bin/env bash
set -euo pipefail

image=${1:-pg-react:v0.3.0}
platform=linux/amd64
project=${COMPOSE_PROJECT_NAME:-pgreact-m6-${GITHUB_RUN_ID:-$$}}
expected_version=${PG_REACT_EXPECTED_VERSION:-0.3.0}
test_log_dir=$(mktemp -d)

case "$expected_version" in
  0.3.0|0.4.0|0.5.0|0.6.0|0.7.0|0.8.0|0.9.0|0.10.0) ;;
  *) echo "unsupported M6 compatibility version: $expected_version" >&2; exit 1 ;;
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

run_benchmark() {
  local log
  # ponytail: one retry absorbs hosted-runner timing noise; isolate benchmark CPUs if it persists.
  for attempt in 1 2; do
    log="$test_log_dir/m6-benchmark-$attempt.log"
    if M6_BENCHMARK_PROJECT_NAME="${project}-benchmark" bash tests/m6-benchmark.sh "$image" >"$log" 2>&1; then
      grep -E '^(baseline_|candidate_|audited_|protocol_|single_|batch_|normalized_|connections_)' "$log"
      echo "M6 frozen benchmark passed"
      return 0
    fi
  done
  sed -n '1,$p' "$log"
  return 1
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
    echo "$name unexpectedly crossed the execution lock" >&2
    return 1
  fi
  if ! grep -Fq 'canceling statement due to lock timeout' "$log"; then
    sed -n '1,$p' "$log"
    return 1
  fi
  echo "$name serialized"
}

run_test "M0-M5 compatibility" env \
  COMPOSE_PROJECT_NAME="${project}-compatibility" \
  PG_REACT_PORT_BINDING=127.0.0.1::5432 \
  PG_REACT_INIT_VERSION=0.2.0 \
  PG_REACT_EXPECTED_VERSION=0.2.0 \
  bash tests/m5.sh "$image"

export PG_REACT_IMAGE=$image
export PG_REACT_PLATFORM=$platform
export PG_REACT_PORT_BINDING=${PG_REACT_PORT_BINDING:-127.0.0.1::5432}
export COMPOSE_PROJECT_NAME=$project
docker build --platform "$platform" --tag "$image" . >/dev/null 2>&1
docker compose up -d --no-build >/dev/null 2>&1
ready=false
for _ in {1..120}; do
  if docker compose exec -T postgres psql -X -U postgres -d postgres -Atc \
      "SELECT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'pgreact')" 2>/dev/null | grep -qx t; then
    ready=true
    break
  fi
  sleep 1
done
test "$ready" = true
test "$(docker image inspect "$image" --format '{{.Os}}/{{.Architecture}}')" = "$platform"
docker compose exec -T postgres psql -X -A -t -U postgres -d postgres -c \
  "SELECT extversion = '$expected_version' FROM pg_extension WHERE extname = 'pg_react'" | grep -qx t

docker compose exec -T postgres createdb -U postgres m6_api
docker compose exec -T postgres psql -X -U postgres -d m6_api -v ON_ERROR_STOP=1 -c \
  "CREATE EXTENSION pg_trickle; CREATE EXTENSION pg_react" >/dev/null
docker compose cp tests/m6-api.sql postgres:/tmp/m6-api.sql >/dev/null 2>&1
run_test "M6 public API inventory" docker compose exec -T postgres psql -X -U postgres -d m6_api \
  -v ON_ERROR_STOP=1 -f /tmp/m6-api.sql

for fixture in m6 m6-upgrade m6-worker-setup m6-worker-result \
  m6-concurrency-setup m6-hold-execution m6-dispatcher-ddl m6-concurrency-result \
  m6-ambiguous-result; do
  docker compose cp "tests/$fixture.sql" "postgres:/tmp/$fixture.sql" >/dev/null 2>&1
done
docker compose exec -T postgres createdb -U postgres m6_acceptance
run_test "M6 audited batch acceptance" docker compose exec -T postgres psql -X -U postgres -d m6_acceptance \
  -v ON_ERROR_STOP=1 -f /tmp/m6.sql
docker compose exec -T postgres createdb -U postgres m6_upgrade
run_test "M6 direct upgrade" docker compose exec -T postgres psql -X -U postgres -d m6_upgrade \
  -v ON_ERROR_STOP=1 -f /tmp/m6-upgrade.sql

docker compose exec -T postgres createdb -U postgres m6_worker
run_test "M6 worker setup" docker compose exec -T postgres psql -X -U postgres -d m6_worker \
  -v ON_ERROR_STOP=1 -f /tmp/m6-worker-setup.sql
worker_version=$(docker compose exec -T postgres psql -X -A -t -U postgres -d m6_worker -c \
  'SELECT rule_version_id FROM m6_worker.control')
worker=(docker compose exec -T -e DATABASE_URL=postgresql://postgres@localhost/m6_worker \
  -e BATCH_MAX_ITEMS=2 postgres pg-reactd "$worker_version" m6-worker)
run_test "M6 worker ACTIVATE batch" "${worker[@]}"
docker compose exec -T postgres psql -X -U postgres -d m6_worker -c \
  "UPDATE m6_worker.facts SET value = value || value" >/dev/null
run_test "M6 worker CHANGE batch" "${worker[@]}"
docker compose exec -T postgres psql -X -U postgres -d m6_worker -c \
  'DELETE FROM m6_worker.facts' >/dev/null
run_test "M6 worker DEACTIVATE batch" "${worker[@]}"
docker compose exec -T postgres psql -X -U postgres -d m6_worker -c \
  "INSERT INTO m6_worker.facts VALUES (3, 'c')" >/dev/null
run_test "M6 worker singleton fallback" "${worker[@]}"
run_test "M6 worker exact result" docker compose exec -T postgres psql -X -U postgres -d m6_worker \
  -v ON_ERROR_STOP=1 -f /tmp/m6-worker-result.sql
expect_failure "M6 worker opt-in bound" 'pg-reactd: BATCH_MAX_ITEMS must be between 1 and 32' \
  docker compose exec -T -e DATABASE_URL=postgresql://postgres@localhost/m6_worker \
  -e BATCH_MAX_ITEMS=33 postgres pg-reactd "$worker_version" m6-worker
docker compose exec -T postgres createdb -U postgres m6_protocol1
docker compose exec -T postgres psql -X -U postgres -d m6_protocol1 -v ON_ERROR_STOP=1 -c \
  "CREATE EXTENSION pg_trickle; CREATE EXTENSION pg_react VERSION '0.2.0'" >/dev/null
expect_failure "M6 worker protocol handshake" 'pg-reactd: database does not support worker protocol 2' \
  docker compose exec -T -e DATABASE_URL=postgresql://postgres@localhost/m6_protocol1 \
  -e BATCH_MAX_ITEMS=2 postgres pg-reactd 00000000-0000-0000-0000-000000000000 m6-worker

docker compose exec -T postgres createdb -U postgres m6_concurrency
run_test "M6 concurrency setup" docker compose exec -T postgres psql -X -U postgres -d m6_concurrency \
  -v ON_ERROR_STOP=1 -f /tmp/m6-concurrency-setup.sql
docker compose exec -T postgres psql -X -U postgres -d m6_concurrency \
  -v ON_ERROR_STOP=1 -f /tmp/m6-hold-execution.sql >"$test_log_dir/held-execution.log" 2>&1 &
held_pid=$!
held=false
for _ in {1..120}; do
  if docker compose exec -T postgres psql -X -A -t -U postgres -d m6_concurrency -c \
      "SELECT EXISTS (SELECT 1 FROM pg_stat_activity WHERE datname='m6_concurrency' AND pid <> pg_backend_pid() AND state='active' AND query LIKE ANY (ARRAY['%execute_claimed_batch%', '%execute_batch%']))" | grep -qx t; then
    held=true
    break
  fi
  sleep 0.1
done
test "$held" = true
expect_lock_timeout "M6 pause" docker compose exec -T postgres psql -X -v ON_ERROR_STOP=1 -U postgres -d m6_concurrency -c \
  "SET lock_timeout='100ms'; SELECT pgreact.pause_rule((SELECT rule_version_id FROM m6_concurrency.control))"
expect_lock_timeout "M6 source DDL" docker compose exec -T postgres psql -X -v ON_ERROR_STOP=1 -U postgres -d m6_concurrency -c \
  "SET lock_timeout='100ms'; ALTER VIEW m6_concurrency.active_fact SET (security_barrier=false)"
expect_lock_timeout "M6 consequence DDL" docker compose exec -T postgres psql -X -v ON_ERROR_STOP=1 -U postgres -d m6_concurrency -c \
  "SET lock_timeout='100ms'; ALTER FUNCTION m6_concurrency.apply_fact(pgreact.activation_context,m6_concurrency.active_fact) COST 101"
expect_lock_timeout "M6 dispatcher DDL" docker compose exec -T postgres psql -X -v ON_ERROR_STOP=1 -U postgres -d m6_concurrency \
  -f /tmp/m6-dispatcher-ddl.sql
expect_lock_timeout "M6 recovery barrier" docker compose exec -T postgres psql -X -v ON_ERROR_STOP=1 -U postgres -d m6_concurrency -c \
  "SET lock_timeout='100ms'; SELECT pgreact.prepare_recovery()"
expect_lock_timeout "M6 replacement" docker compose exec -T postgres psql -X -v ON_ERROR_STOP=1 -U postgres -d m6_concurrency -c \
  "SET lock_timeout='100ms'; SELECT pgreact.replace_rule(target_version_id => (SELECT rule_version_id FROM m6_concurrency.control), definition => 'm6_concurrency.active_fact'::regclass, key_columns => ARRAY['id'], on_activate => 'm6_concurrency.apply_fact(pgreact.activation_context,m6_concurrency.active_fact)'::regprocedure)"
docker compose exec -T postgres psql -X -A -t -U postgres -d m6_concurrency -c \
  "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='m6_concurrency' AND pid <> pg_backend_pid() AND state='active' AND query LIKE ANY (ARRAY['%execute_claimed_batch%', '%execute_batch%'])" | grep -qx t
if wait "$held_pid"; then
  echo 'terminated execution unexpectedly committed' >&2
  exit 1
fi
grep -Fq 'terminating connection due to administrator command' "$test_log_dir/held-execution.log"
run_test "M6 concurrency and disconnect recovery" docker compose exec -T postgres psql -X -U postgres -d m6_concurrency \
  -v ON_ERROR_STOP=1 -f /tmp/m6-concurrency-result.sql

docker compose exec -T postgres psql -X -v ON_ERROR_STOP=1 -U postgres -d m6_concurrency -c \
  "UPDATE m6_concurrency.control SET sleep_enabled=true; INSERT INTO m6_concurrency.facts VALUES (3), (4)" >/dev/null
concurrency_version=$(docker compose exec -T postgres psql -X -A -t -U postgres -d m6_concurrency -c \
  'SELECT rule_version_id FROM m6_concurrency.control')
docker compose exec -T -e DATABASE_URL=postgresql://postgres@localhost/m6_concurrency \
  -e BATCH_MAX_ITEMS=2 postgres pg-reactd "$concurrency_version" m6-ambiguous \
  >"$test_log_dir/ambiguous-worker.log" 2>&1 &
ambiguous_pid=$!
ambiguous_active=false
for _ in {1..120}; do
  if docker compose exec -T postgres psql -X -A -t -U postgres -d m6_concurrency -c \
      "SELECT EXISTS (SELECT 1 FROM pg_stat_activity WHERE datname='m6_concurrency' AND pid <> pg_backend_pid() AND state='active' AND query LIKE ANY (ARRAY['%execute_claimed_batch%', '%execute_batch%']))" | grep -qx t; then
    ambiguous_active=true
    break
  fi
  sleep 0.1
done
test "$ambiguous_active" = true
docker compose exec -T postgres psql -X -A -t -U postgres -d m6_concurrency -c \
  "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='m6_concurrency' AND pid <> pg_backend_pid() AND state='active' AND query LIKE ANY (ARRAY['%execute_claimed_batch%', '%execute_batch%'])" | grep -qx t
docker compose exec -T postgres psql -X -v ON_ERROR_STOP=1 -U postgres -d m6_concurrency -c \
  'UPDATE m6_concurrency.control SET sleep_enabled=false' >/dev/null
if ! wait "$ambiguous_pid"; then
  sed -n '1,$p' "$test_log_dir/ambiguous-worker.log"
  exit 1
fi
run_test "M6 ambiguous worker recovery" docker compose exec -T postgres psql -X -U postgres -d m6_concurrency \
  -v ON_ERROR_STOP=1 -f /tmp/m6-ambiguous-result.sql

run_test "M6 crash restart and physical recovery" bash tests/m6-recovery.sh
run_benchmark

echo "M6 execution maturity gate passed for $image ($platform)"
