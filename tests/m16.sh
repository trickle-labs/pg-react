#!/usr/bin/env bash
set -euo pipefail

image=${1:-pg-react:v0.13.0}
project=${COMPOSE_PROJECT_NAME:-pgreact-m16-${GITHUB_RUN_ID:-$$}}
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

run_test 'M16 documentation' bash tests/m16-docs.sh
run_test 'M15 compatibility' env \
  PG_REACT_EXPECTED_VERSION=0.13.0 \
  COMPOSE_PROJECT_NAME="${project}-m15" \
  bash tests/m15.sh "$image"

export PG_REACT_IMAGE=$image
export PG_REACT_PLATFORM=linux/amd64
export PG_REACT_PORT_BINDING=${PG_REACT_PORT_BINDING:-127.0.0.1::5432}
export PG_REACT_POLL_INTERVAL_MS=60000
export COMPOSE_PROJECT_NAME=$project
docker compose up -d --no-build >/dev/null 2>&1

ready=false
for _ in {1..120}; do
  if docker compose exec -T postgres psql -XAtq -U postgres -d postgres -c \
      "SELECT extversion = '0.13.0' FROM pg_extension WHERE extname = 'pg_react'" \
      2>/dev/null | grep -qx t; then ready=true; break; fi
  sleep 1
done
test "$ready" = true

for fixture in m16-aggregate m16-matrix m16-replacement; do
  docker compose cp "tests/$fixture.sql" "postgres:/tmp/$fixture.sql" >/dev/null
done
run_test 'M16 typed aggregate semantics and failures' \
  docker compose exec -T postgres psql -XAtq -U postgres -d postgres \
  -v ON_ERROR_STOP=1 -f /tmp/m16-aggregate.sql
run_test 'M16 complete aggregate type and value matrix' \
  docker compose exec -T postgres psql -XAtq -U postgres -d postgres \
  -v ON_ERROR_STOP=1 -f /tmp/m16-matrix.sql
run_test 'M16 typed aggregate replacement and removal' \
  docker compose exec -T postgres psql -XAtq -U postgres -d postgres \
  -v ON_ERROR_STOP=1 -f /tmp/m16-replacement.sql

docker compose exec -T postgres pg_dump -U postgres -d postgres -Fc \
  -t m16.groups -t m16.items --data-only -f /tmp/m16-data.dump
docker compose exec -T postgres createdb -U postgres m16_logical
docker compose exec -T postgres psql -XAtq -U postgres -d m16_logical \
  -v ON_ERROR_STOP=1 -c 'CREATE EXTENSION pg_trickle; CREATE EXTENSION pg_react'
for fixture in m16-logical-schema m16-logical-restore; do
  docker compose cp "tests/$fixture.sql" "postgres:/tmp/$fixture.sql" >/dev/null
done
docker compose exec -T postgres psql -XAtq -U postgres -d m16_logical \
  -v ON_ERROR_STOP=1 -f /tmp/m16-logical-schema.sql
docker compose exec -T postgres pg_restore -U postgres -d m16_logical /tmp/m16-data.dump
run_test 'M16 logical data restore and declaration replay' \
  docker compose exec -T postgres psql -XAtq -U postgres -d m16_logical \
  -v ON_ERROR_STOP=1 -f /tmp/m16-logical-restore.sql

docker compose exec -T postgres createdb -U postgres m16_upgrade
docker compose cp tests/m16-upgrade.sql postgres:/tmp/m16-upgrade.sql >/dev/null
run_test 'M16 populated direct upgrade' \
  docker compose exec -T postgres psql -XAtq -U postgres -d m16_upgrade \
  -v ON_ERROR_STOP=1 \
  -c "CREATE EXTENSION pg_trickle; CREATE EXTENSION pg_react VERSION '0.12.0'" \
  -f /tmp/m16-upgrade.sql

run_test 'M16 crash restart and physical recovery' env \
  RECOVERY_MILESTONE=m16 bash tests/m6-recovery.sh

echo "M16 richer stratified aggregation gate passed for $image (linux/amd64)"
