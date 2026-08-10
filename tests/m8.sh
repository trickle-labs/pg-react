#!/usr/bin/env bash
set -euo pipefail

image=${1:-pg-react:v0.5.0}
platform=linux/amd64
project=${COMPOSE_PROJECT_NAME:-pgreact-m8-${GITHUB_RUN_ID:-$$}}
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

expect_exact_output() {
  local name=$1
  local expected=$2
  shift 2
  local log="$test_log_dir/${name// /-}.log"
  if ! "$@" >"$log" 2>&1; then
    sed -n '1,$p' "$log"
    return 1
  fi
  if ! printf '%s\n' "$expected" | cmp -s - "$log"; then
    sed -n '1,$p' "$log"
    return 1
  fi
  echo "$name passed"
}

expect_lock_timeout() {
  local name=$1
  shift
  local log="$test_log_dir/${name// /-}.log"
  if "$@" >"$log" 2>&1; then
    echo "$name unexpectedly crossed the program lock" >&2
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
  docker compose cp tests/m8-setup.sql postgres:/tmp/m8-setup.sql >/dev/null 2>&1
  docker compose cp "tests/$fixture.sql" "postgres:/tmp/$fixture.sql" >/dev/null 2>&1
  run_test "$name" docker compose exec -T postgres psql -X -U postgres -d "$database" \
    -v ON_ERROR_STOP=1 -f "/tmp/$fixture.sql"
}

run_order_fixture() {
  local database=$1
  local left_first=$2
  local output=$3
  docker compose exec -T postgres createdb -U postgres "$database"
  docker compose exec -T postgres psql -X -U postgres -d "$database" -v ON_ERROR_STOP=1 -c \
    'CREATE EXTENSION pg_trickle; CREATE EXTENSION pg_react' >/dev/null
  docker compose cp tests/m8-setup.sql postgres:/tmp/m8-setup.sql >/dev/null 2>&1
  docker compose cp tests/m8-order.sql postgres:/tmp/m8-order.sql >/dev/null 2>&1
  docker compose exec -T postgres psql -XAt -U postgres -d "$database" \
    -v ON_ERROR_STOP=1 -v left_first="$left_first" -f /tmp/m8-order.sql >"$output"
}

run_test "M0-M7 compatibility" env \
  COMPOSE_PROJECT_NAME="${project}-compatibility" \
  PG_REACT_EXPECTED_VERSION=0.5.0 \
  bash tests/m7.sh "$image"

export PG_REACT_IMAGE=$image
export PG_REACT_PLATFORM=$platform
export PG_REACT_PORT_BINDING=${PG_REACT_PORT_BINDING:-127.0.0.1::5432}
export COMPOSE_PROJECT_NAME=$project
docker compose up -d --no-build >/dev/null 2>&1
ready=false
for _ in {1..120}; do
  if docker compose exec -T postgres psql -X -U postgres -d postgres -Atc \
      "SELECT extversion = '0.5.0' FROM pg_extension WHERE extname = 'pg_react'" 2>/dev/null | grep -qx t; then
    ready=true
    break
  fi
  sleep 1
done
test "$ready" = true
test "$(docker image inspect "$image" --format '{{.Os}}/{{.Architecture}}')" = "$platform"

run_sql_fixture "M8 recursive lifecycle" m8_acceptance m8
run_order_fixture m8_order_left true "$test_log_dir/order-left.log"
run_order_fixture m8_order_right false "$test_log_dir/order-right.log"
run_test "M8 ordering and clean-history equivalence" \
  cmp -s "$test_log_dir/order-left.log" "$test_log_dir/order-right.log"
run_sql_fixture "M8 validator boundary" m8_boundary m8-boundary
run_sql_fixture "M8 non-superuser author workflow" m8_author m8-author
run_sql_fixture "M8 independently optional program arrays" m8_optionals m8-optionals
run_sql_fixture "M8 resource failure record" m8_resource_failure m8-resource-failure
run_sql_fixture "M8 atomic pack lifecycle" m8_pack m8-pack

for fixture in m8-hold-refresh m8-concurrency-result m8-pack-remove; do
  docker compose cp "tests/$fixture.sql" "postgres:/tmp/$fixture.sql" >/dev/null 2>&1
done
docker compose exec -T postgres psql -X -U postgres -d m8_pack \
  -v ON_ERROR_STOP=1 -f /tmp/m8-hold-refresh.sql >"$test_log_dir/held-refresh.log" 2>&1 &
held_pid=$!
held=false
for _ in {1..120}; do
  if docker compose exec -T postgres psql -X -A -t -U postgres -d m8_pack -c \
      "SELECT EXISTS (SELECT 1 FROM pg_stat_activity WHERE datname='m8_pack' AND pid <> pg_backend_pid() AND state='active' AND query LIKE '%pg_sleep%')" | grep -qx t; then
    held=true
    break
  fi
  sleep 0.1
done
test "$held" = true
expect_exact_output "M8 concurrent refresh serialized" NULL \
  docker compose exec -T postgres psql -X -qAt \
  -v ON_ERROR_STOP=1 -U postgres -d m8_pack -c \
  "SET lock_timeout='100ms'; SELECT COALESCE(pgreact.refresh_derivation_program(program_version_id)::text, 'NULL') FROM m8_ref.pack_control"
expect_lock_timeout "M8 source DDL" docker compose exec -T postgres psql -X \
  -v ON_ERROR_STOP=1 -U postgres -d m8_pack -c \
  "SET lock_timeout='100ms'; ALTER VIEW m8_ref.right_to_a SET (security_barrier=false)"
expect_lock_timeout "M8 relation DDL" docker compose exec -T postgres psql -X \
  -v ON_ERROR_STOP=1 -U postgres -d m8_pack -c \
  "SET lock_timeout='100ms'; ALTER VIEW m8_ref.c SET (security_barrier=true)"
expect_lock_timeout "M8 program removal" docker compose exec -T postgres psql -X \
  -v ON_ERROR_STOP=1 -U postgres -d m8_pack -c \
  "SET lock_timeout='100ms'; SELECT pgreact.remove_derivation_program(program_version_id) FROM m8_ref.pack_control"
docker compose exec -T postgres psql -X -A -t -U postgres -d m8_pack -c \
  "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='m8_pack' AND pid <> pg_backend_pid() AND state='active' AND query LIKE '%pg_sleep%'" | grep -qx t
if wait "$held_pid"; then
  echo 'terminated M8 refresh unexpectedly committed' >&2
  exit 1
fi
grep -Fq 'terminating connection due to administrator command' "$test_log_dir/held-refresh.log"
run_test "M8 concurrent graph remains exact" docker compose exec -T postgres psql -X \
  -U postgres -d m8_pack -v ON_ERROR_STOP=1 -f /tmp/m8-concurrency-result.sql
run_test "M8 pack removal" docker compose exec -T postgres psql -X \
  -U postgres -d m8_pack -v ON_ERROR_STOP=1 -f /tmp/m8-pack-remove.sql

docker compose exec -T postgres createdb -U postgres m8_upgrade
docker compose cp tests/m8-setup.sql postgres:/tmp/m8-setup.sql >/dev/null 2>&1
docker compose cp tests/m7-upgrade.sql postgres:/tmp/m7-upgrade.sql >/dev/null 2>&1
docker compose cp tests/m8-upgrade.sql postgres:/tmp/m8-upgrade.sql >/dev/null 2>&1
run_test "M8 direct upgrade" docker compose exec -T postgres psql -X -U postgres -d m8_upgrade \
  -v ON_ERROR_STOP=1 -f /tmp/m8-upgrade.sql

run_test "M8 crash restart and physical recovery" env RECOVERY_MILESTONE=m8 bash tests/m6-recovery.sh

echo "M8 monotone recursive derivation gate passed for $image ($platform)"
