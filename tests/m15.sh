#!/usr/bin/env bash
set -euo pipefail

image=${1:-pg-react:v0.12.0}
platform=linux/amd64
project=${COMPOSE_PROJECT_NAME:-pgreact-m15-${GITHUB_RUN_ID:-$$}}
test_log_dir=$(mktemp -d)

cleanup() {
  if [[ -n ${managed_pid:-} ]]; then
    COMPOSE_PROJECT_NAME=$project docker compose exec -T postgres \
      bash -c 'kill -CONT "$1"' bash "$managed_pid" >/dev/null 2>&1 || true
  fi
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

run_test 'M15 task documentation' bash tests/m15-docs.sh
run_test 'M13 compatibility' env \
  PG_REACT_SKIP_INHERITED=true \
  PG_REACT_EXPECTED_VERSION=0.12.0 \
  COMPOSE_PROJECT_NAME="${project}-m13" \
  bash tests/m13.sh "$image"
run_test 'M14 compatibility' env \
  PG_REACT_EXPECTED_VERSION=0.12.0 \
  COMPOSE_PROJECT_NAME="${project}-m14" \
  bash tests/m14.sh "$image"

export PG_REACT_IMAGE=$image
export PG_REACT_PLATFORM=$platform
export PG_REACT_PORT_BINDING=${PG_REACT_PORT_BINDING:-127.0.0.1::5432}
export PG_REACT_POLL_INTERVAL_MS=60000
export PG_REACT_MAX_PENDING_JOBS=1
export COMPOSE_PROJECT_NAME=$project

docker compose up -d --no-build >/dev/null 2>&1
ready=false
ready_checks=0
for _ in {1..120}; do
  if docker compose exec -T postgres psql -XAtq -U postgres -d postgres -c \
      "SELECT extversion = '0.12.0' FROM pg_extension WHERE extname = 'pg_react'" \
      2>/dev/null | grep -qx t; then
    ready_checks=$((ready_checks + 1))
    if [[ $ready_checks -eq 2 ]]; then ready=true; break; fi
  else
    ready_checks=0
  fi
  sleep 1
done
test "$ready" = true
test "$(docker image inspect "$image" --format '{{.Os}}/{{.Architecture}}')" = "$platform"

managed_pid=
for _ in {1..120}; do
  managed_pid=$(docker compose exec -T postgres psql -XAtq -U postgres -d postgres -c \
    "SELECT pgreact_api.managed_status() #>> '{process,pid}'" 2>/dev/null || true)
  [[ -n $managed_pid ]] && break
  sleep 1
done
test -n "$managed_pid"
docker compose exec -T postgres bash -c 'kill -STOP "$1"' bash "$managed_pid"

docker compose cp tests/m15-api.sql postgres:/tmp/m15-api.sql >/dev/null
run_test 'M15 managed runtime, typed keys, derivation, and usability' \
  docker compose exec -T postgres psql -XAtq -U postgres -d postgres \
  -v ON_ERROR_STOP=1 -f /tmp/m15-api.sql

for fixture in m15-lifecycle m15-reasoning m15-coexist-setup m15-coexist-result \
               m15-logical-setup m15-logical-restore; do
  docker compose cp "tests/$fixture.sql" "postgres:/tmp/$fixture.sql" >/dev/null
done
run_test 'M15 typed lifecycle, retry, deadline, reconciliation, and replacement' \
  docker compose exec -T postgres psql -XAtq -U postgres -d postgres \
  -v ON_ERROR_STOP=1 -f /tmp/m15-lifecycle.sql
run_test 'M15 typed recursion, negation, aggregation, and program replacement' \
  docker compose exec -T postgres psql -XAtq -U postgres -d postgres \
  -v ON_ERROR_STOP=1 -f /tmp/m15-reasoning.sql

run_coexistence() {
  local external_log="$test_log_dir/m15-external-worker.log"
  local managed_log="$test_log_dir/m15-managed-worker.log"
  docker compose exec -T postgres psql -XAtq -U postgres -d postgres \
    -v ON_ERROR_STOP=1 -f /tmp/m15-coexist-setup.sql
  docker compose exec -T -e DATABASE_URL=postgresql://postgres@localhost/postgres \
    postgres pg-reactd all transition-worker >"$external_log" 2>&1 &
  local external_pid=$!
  docker compose exec -T postgres psql -XAtq -U postgres -d postgres \
    -v ON_ERROR_STOP=1 -c \
    'SET SESSION AUTHORIZATION m15_worker; SELECT pgreact_api.managed_cycle()' \
    >"$managed_log" 2>&1 &
  local managed_pid=$!
  if ! wait "$external_pid"; then sed -n '1,$p' "$external_log"; return 1; fi
  if ! wait "$managed_pid"; then sed -n '1,$p' "$managed_log"; return 1; fi
  docker compose exec -T postgres psql -XAtq -U postgres -d postgres \
    -v ON_ERROR_STOP=1 -f /tmp/m15-coexist-result.sql
}
run_test 'M15 managed and external single-lease transition' run_coexistence

run_test 'M15 logical source qualification' docker compose exec -T postgres \
  psql -XAtq -U postgres -d postgres -v ON_ERROR_STOP=1 \
  -f /tmp/m15-logical-setup.sql
docker compose exec -T postgres pg_dump -U postgres -d postgres -Fc \
  -t m15_portable.effects -t m15_portable.identity_snapshot \
  -f /tmp/m15-portable-schema.dump
docker compose exec -T postgres pg_dump -U postgres -d postgres -Fc \
  -n m15_portable --schema-only -f /tmp/m15-portable-all-schema.dump
docker compose exec -T postgres pg_restore -U postgres -d postgres -l \
  /tmp/m15-portable-all-schema.dump >"$test_log_dir/m15-portable.list"
awk '/FUNCTION m15_portable activate_portable\(jsonb\)/ || /ACL m15_portable FUNCTION activate_portable\(jsonb\)/' \
  "$test_log_dir/m15-portable.list" >"$test_log_dir/m15-portable-function.list"
docker compose cp "$test_log_dir/m15-portable-function.list" \
  postgres:/tmp/m15-portable-function.list >/dev/null
docker compose exec -T postgres pg_restore -U postgres \
  -L /tmp/m15-portable-function.list -f /tmp/m15-portable-function.sql \
  /tmp/m15-portable-all-schema.dump
docker compose exec -T postgres pg_dump -U postgres -d postgres -Fc \
  -t m15_portable.source --data-only --disable-triggers \
  -f /tmp/m15-portable-data.dump
docker compose exec -T postgres createdb -U postgres m15_logical
docker compose exec -T postgres psql -XAtq -U postgres -d m15_logical \
  -v ON_ERROR_STOP=1 -c 'CREATE EXTENSION pg_trickle; CREATE EXTENSION pg_react'
docker compose exec -T postgres psql -XAtq -U postgres -d m15_logical \
  -v ON_ERROR_STOP=1 -c 'CREATE SCHEMA m15_portable AUTHORIZATION m15_author;'
docker compose exec -T postgres pg_restore -U postgres -d m15_logical \
  /tmp/m15-portable-schema.dump
docker compose exec -T postgres psql -XAtq -U postgres -d m15_logical \
  -v ON_ERROR_STOP=1 -c 'CREATE TABLE m15_portable.source (
    tenant text COLLATE "C" NOT NULL, account_id bigint NOT NULL,
    payload text NOT NULL, PRIMARY KEY (tenant, account_id));
    CREATE VIEW m15_portable.condition AS SELECT * FROM m15_portable.source;
    CREATE FUNCTION m15_portable.activate(row_value m15_portable.condition)
    RETURNS void LANGUAGE SQL AS $$
      INSERT INTO m15_portable.effects VALUES (
        jsonb_build_array(row_value.tenant, row_value.account_id), row_value.payload)
    $$;
    ALTER TABLE m15_portable.source OWNER TO m15_author;
    ALTER VIEW m15_portable.condition OWNER TO m15_author;
    ALTER FUNCTION m15_portable.activate(m15_portable.condition) OWNER TO m15_author;'
docker compose exec -T postgres psql -XAtq -U postgres -d m15_logical \
  -v ON_ERROR_STOP=1 -f /tmp/m15-portable-function.sql
docker compose exec -T postgres pg_restore -U postgres -d m15_logical \
  /tmp/m15-portable-data.dump
run_test 'M15 logical dump and declaration replay' docker compose exec -T postgres \
  psql -XAtq -U postgres -d m15_logical -v ON_ERROR_STOP=1 \
  -f /tmp/m15-logical-restore.sql

docker compose exec -T postgres bash -c 'kill -CONT "$1"' bash "$managed_pid"
for _ in {1..120}; do
  old_pid=$(docker compose exec -T postgres psql -XAtq -U postgres -d postgres -c \
    "SELECT pgreact_api.managed_status() #>> '{process,pid}'" 2>/dev/null || true)
  [[ $old_pid == "$managed_pid" ]] && break
  sleep 1
done
test "$old_pid" = "$managed_pid"
docker compose restart postgres >/dev/null
for _ in {1..120}; do
  new_pid=$(docker compose exec -T postgres psql -XAtq -U postgres -d postgres -c \
    "SELECT pgreact_api.managed_status() #>> '{process,pid}'" 2>/dev/null || true)
  [[ -n $new_pid && $new_pid != "$old_pid" ]] && break
  sleep 1
done
test -n "$new_pid"
test "$new_pid" != "$old_pid"
run_test 'M15 PostgreSQL-managed crash restart' docker compose exec -T postgres \
  psql -XAtq -U postgres -d postgres -v ON_ERROR_STOP=1 -c \
  "SELECT pgreact_api.managed_status() -> 'process' ->> 'state' = 'ready'"

docker compose exec -T postgres createdb -U postgres m15_upgrade
docker compose cp tests/m15-upgrade.sql postgres:/tmp/m15-upgrade.sql >/dev/null
run_test 'M15 direct populated upgrade' docker compose exec -T postgres \
  psql -XAtq -U postgres -d m15_upgrade -v ON_ERROR_STOP=1 \
  -c "CREATE EXTENSION pg_trickle; CREATE EXTENSION pg_react VERSION '0.11.0'" \
  -f /tmp/m15-upgrade.sql

run_test 'M15 standby, promotion, crash restart, and physical restore' env \
  RECOVERY_MILESTONE=m15 bash tests/m6-recovery.sh

echo "M15 runtime and usability completion gate passed for $image ($platform)"
