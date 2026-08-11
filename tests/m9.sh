#!/usr/bin/env bash
set -euo pipefail

image=${1:-pg-react:v0.6.0}
expected_version=${PG_REACT_EXPECTED_VERSION:-0.6.0}
platform=linux/amd64
project=${COMPOSE_PROJECT_NAME:-pgreact-m9-${GITHUB_RUN_ID:-$$}}
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

run_test "M0-M8 compatibility" env \
  COMPOSE_PROJECT_NAME="${project}-compatibility" \
  PG_REACT_EXPECTED_VERSION="$expected_version" \
  bash tests/m8.sh "$image"

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

docker compose exec -T postgres createdb -U postgres m9_slice2
docker compose exec -T postgres psql -X -U postgres -d m9_slice2 \
  -v ON_ERROR_STOP=1 -c 'CREATE EXTENSION pg_trickle; CREATE EXTENSION pg_react' >/dev/null
docker compose cp tests/m9-slice2.sql postgres:/tmp/m9-slice2.sql >/dev/null 2>&1
if docker compose exec -T postgres psql -XAt -U postgres -d m9_slice2 \
    -v ON_ERROR_STOP=1 -f /tmp/m9-slice2.sql >"$test_log_dir/m9-slice2.log" 2>&1; then
  grep -qx 'M9 slice 2 safe-negative deployment gate passed' "$test_log_dir/m9-slice2.log"
  echo 'M9 slice 2 safe-negative deployment gate passed'
else
  sed -n '1,$p' "$test_log_dir/m9-slice2.log"
  exit 1
fi

docker compose cp tests/m9-slice3.sql postgres:/tmp/m9-slice3.sql >/dev/null 2>&1
if docker compose exec -T postgres psql -XAt -U postgres -d m9_slice2 \
    -v ON_ERROR_STOP=1 -f /tmp/m9-slice3.sql >"$test_log_dir/m9-slice3.log" 2>&1; then
  grep -qx 'M9 slice 3 deletion-sensitive truth gate passed' "$test_log_dir/m9-slice3.log"
  echo 'M9 slice 3 deletion-sensitive truth gate passed'
else
  sed -n '1,$p' "$test_log_dir/m9-slice3.log"
  exit 1
fi

run_slice4() {
  local database=$1
  local reverse_schedule=$2
  local output=$3
  local errors=${output%.log}.errors
  docker compose exec -T postgres createdb -U postgres "$database"
  docker compose exec -T postgres psql -X -U postgres -d "$database" \
    -v ON_ERROR_STOP=1 -c \
    'CREATE EXTENSION pg_trickle; CREATE EXTENSION pg_react' >/dev/null
  docker compose exec -T postgres psql -XAt -U postgres -d "$database" \
    -v ON_ERROR_STOP=1 -v reverse_schedule="$reverse_schedule" \
    -f /tmp/m9-slice4.sql >"$output" 2>"$errors"
}

docker compose cp tests/m9-slice4.sql postgres:/tmp/m9-slice4.sql >/dev/null 2>&1
if run_slice4 m9_slice4_forward false "$test_log_dir/m9-slice4-forward.log" &&
   run_slice4 m9_slice4_reverse true "$test_log_dir/m9-slice4-reverse.log"; then
  grep -qx 'M9 slice 4 stratified fixed-point gate passed' \
    "$test_log_dir/m9-slice4-forward.log"
  cmp -s "$test_log_dir/m9-slice4-forward.log" \
    "$test_log_dir/m9-slice4-reverse.log"
  echo 'M9 slice 4 stratified fixed-point gate passed'
else
  for file in "$test_log_dir"/m9-slice4-*.log \
              "$test_log_dir"/m9-slice4-*.errors; do
    test ! -f "$file" || sed -n '1,$p' "$file"
  done
  exit 1
fi

for fixture in m9-slice5 m9-slice5-hold-refresh \
               m9-slice5-concurrency-result m9-slice5-remove m9-slice6; do
  docker compose cp "tests/$fixture.sql" "postgres:/tmp/$fixture.sql" \
    >/dev/null 2>&1
done

if docker compose exec -T postgres psql -XAt -U postgres \
    -d m9_slice4_forward -v ON_ERROR_STOP=1 \
    -f /tmp/m9-slice5.sql >"$test_log_dir/m9-slice5.log" 2>&1; then
  grep -qx 'M9 slice 5 atomic stratified-program change gate passed' \
    "$test_log_dir/m9-slice5.log"
  echo 'M9 slice 5 atomic stratified-program change gate passed'
else
  sed -n '1,$p' "$test_log_dir/m9-slice5.log"
  exit 1
fi

docker compose exec -T postgres psql -X -U postgres -d m9_slice4_forward \
  -v ON_ERROR_STOP=1 -f /tmp/m9-slice5-hold-refresh.sql \
  >"$test_log_dir/m9-slice5-held-refresh.log" 2>&1 &
held_pid=$!
held=false
for _ in {1..120}; do
  if docker compose exec -T postgres psql -XAt -U postgres \
      -d m9_slice4_forward -c \
      "SELECT EXISTS (SELECT 1 FROM pg_stat_activity WHERE datname='m9_slice4_forward' AND pid <> pg_backend_pid() AND state='active' AND query LIKE '%pg_sleep%')" \
      | grep -qx t; then
    held=true
    break
  fi
  sleep 0.1
done
test "$held" = true

concurrent_output=$(docker compose exec -T postgres psql -XqAt \
  -v ON_ERROR_STOP=1 -U postgres -d m9_slice4_forward -c \
  "SET lock_timeout='100ms'; SELECT COALESCE(pgreact.refresh_derivation_program(program_version_id)::text, 'NULL') FROM m9_slice5.concurrent_control")
test "$concurrent_output" = 'NULL'

expect_lock_timeout() {
  local label=$1
  shift
  local output="$test_log_dir/m9-slice5-lock-timeout.log"
  if "$@" >"$output" 2>&1; then
    echo "$label unexpectedly succeeded" >&2
    exit 1
  fi
  if ! grep -Fq 'canceling statement due to lock timeout' "$output"; then
    sed -n '1,$p' "$output"
    exit 1
  fi
}

expect_lock_timeout "M9 slice 5 source DDL" \
  docker compose exec -T postgres psql -X -v ON_ERROR_STOP=1 \
  -U postgres -d m9_slice4_forward -c \
  "SET lock_timeout='100ms'; ALTER VIEW m9_slice4.blocked_source SET (security_barrier=false)"
expect_lock_timeout "M9 slice 5 negative relation DDL" \
  docker compose exec -T postgres psql -X -v ON_ERROR_STOP=1 \
  -U postgres -d m9_slice4_forward -c \
  "SET lock_timeout='100ms'; ALTER VIEW m9_slice4.a_denied RENAME TO a_denied_locked"
expect_lock_timeout "M9 slice 5 target relation DDL" \
  docker compose exec -T postgres psql -X -v ON_ERROR_STOP=1 \
  -U postgres -d m9_slice4_forward -c \
  "SET lock_timeout='100ms'; ALTER VIEW m9_slice4.e_alert SET (security_barrier=true)"
expect_lock_timeout "M9 slice 5 concurrent deployment" \
  docker compose exec -T postgres psql -X -v ON_ERROR_STOP=1 \
  -U postgres -d m9_slice4_forward -c \
  "SET lock_timeout='100ms'; SELECT pgreact.deploy_pack(definition, plan_digest, mappings) FROM m9_slice5.concurrent_control"

docker compose exec -T postgres psql -XAt -U postgres \
  -d m9_slice4_forward -c \
  "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='m9_slice4_forward' AND pid <> pg_backend_pid() AND state='active' AND query LIKE '%pg_sleep%'" \
  | grep -qx t
if wait "$held_pid"; then
  echo 'terminated M9 slice 5 refresh unexpectedly committed' >&2
  exit 1
fi
grep -Fq 'terminating connection due to administrator command' \
  "$test_log_dir/m9-slice5-held-refresh.log"

if docker compose exec -T postgres psql -XAt -U postgres \
    -d m9_slice4_forward -v ON_ERROR_STOP=1 \
    -f /tmp/m9-slice5-concurrency-result.sql \
    >"$test_log_dir/m9-slice5-concurrency-result.log" 2>&1; then
  grep -qx 'M9 slice 5 concurrent refresh and DDL gate passed' \
    "$test_log_dir/m9-slice5-concurrency-result.log"
  echo 'M9 slice 5 concurrent refresh and DDL gate passed'
else
  sed -n '1,$p' "$test_log_dir/m9-slice5-concurrency-result.log"
  exit 1
fi

if docker compose exec -T postgres psql -XAt -U postgres \
    -d m9_slice4_forward -v ON_ERROR_STOP=1 \
    -f /tmp/m9-slice5-remove.sql \
    >"$test_log_dir/m9-slice5-remove.log" 2>&1; then
  grep -qx 'M9 slice 5 complete stratified-program removal gate passed' \
    "$test_log_dir/m9-slice5-remove.log"
  echo 'M9 slice 5 complete stratified-program removal gate passed'
else
  sed -n '1,$p' "$test_log_dir/m9-slice5-remove.log"
  exit 1
fi

if docker compose exec -T postgres psql -XAt -U postgres \
    -d m9_slice4_reverse -v ON_ERROR_STOP=1 \
    -f /tmp/m9-slice6.sql >"$test_log_dir/m9-slice6.log" 2>&1; then
  grep -qx 'M9 slice 6 explanation and repair gate passed' \
    "$test_log_dir/m9-slice6.log"
  echo 'M9 slice 6 explanation and repair gate passed'
else
  sed -n '1,$p' "$test_log_dir/m9-slice6.log"
  exit 1
fi

docker compose exec -T postgres createdb -U postgres m9_author
docker compose exec -T postgres psql -X -U postgres -d m9_author \
  -v ON_ERROR_STOP=1 -c \
  'CREATE EXTENSION pg_trickle; CREATE EXTENSION pg_react' >/dev/null
docker compose cp tests/m9-author.sql postgres:/tmp/m9-author.sql >/dev/null 2>&1
run_test "M9 public author workflow" docker compose exec -T postgres psql -X \
  -U postgres -d m9_author -v ON_ERROR_STOP=1 -f /tmp/m9-author.sql

docker compose exec -T postgres createdb -U postgres m9_upgrade
docker compose cp tests/m8-setup.sql postgres:/tmp/m8-setup.sql >/dev/null 2>&1
docker compose cp tests/m9-upgrade.sql postgres:/tmp/m9-upgrade.sql >/dev/null 2>&1
run_test "M9 direct upgrade" docker compose exec -T postgres psql -X \
  -U postgres -d m9_upgrade -v ON_ERROR_STOP=1 -f /tmp/m9-upgrade.sql

run_test "M9 crash restart and physical recovery" env \
  RECOVERY_MILESTONE=m9 bash tests/m6-recovery.sh

run_test "M9 fresh-install SQL composition" cmp sql/pg_react--0.6.0.sql \
  <(cat sql/pg_react--0.5.0.sql sql/pg_react--0.5.0--0.6.0.sql)

echo "M9 stratified negation gate passed for $image ($platform)"
