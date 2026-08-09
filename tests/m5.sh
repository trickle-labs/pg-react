#!/usr/bin/env bash
set -euo pipefail

image=${1:-pg-react:v0.2.0}
expected_version=${PG_REACT_EXPECTED_VERSION:-0.2.0}
export PG_REACT_IMAGE=$image
export PG_REACT_PLATFORM=linux/amd64
export PG_REACT_INIT_VERSION=${PG_REACT_INIT_VERSION:-0.2.0}
export PG_REACT_PORT_BINDING=${PG_REACT_PORT_BINDING:-127.0.0.1::5432}
export COMPOSE_PROJECT_NAME=${COMPOSE_PROJECT_NAME:-pgreact-m5-${GITHUB_RUN_ID:-$$}}
test_log_dir=$(mktemp -d)

cleanup() {
  docker compose down --volumes --remove-orphans >/dev/null 2>&1 || true
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

expect_lock_timeout() {
  local name=$1
  shift
  local log="$test_log_dir/${name// /-}.log"
  if "$@" >"$log" 2>&1; then
    echo "$name unexpectedly passed the deployment lock" >&2
    return 1
  fi
  if ! grep -q 'canceling statement due to lock timeout' "$log"; then
    sed -n '1,$p' "$log"
    return 1
  fi
  echo "$name serialized"
}

docker build --platform "$PG_REACT_PLATFORM" --tag "$image" . >/dev/null 2>&1
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
test "$(docker image inspect "$image" --format '{{.Os}}/{{.Architecture}}')" = "$PG_REACT_PLATFORM"
docker compose exec -T postgres psql -X -U postgres -d postgres -Atc \
  "SELECT extversion = '$expected_version' FROM pg_extension WHERE extname = 'pg_react'" | grep -qx t

for suite in m0 m1 m1-scale m2 m3; do
  run_test "$suite compatibility" bash "tests/$suite.sh"
done

docker compose exec -T postgres createdb -U postgres m5_api
docker compose exec -T postgres psql -X -U postgres -d m5_api -v ON_ERROR_STOP=1 \
  -c "CREATE EXTENSION pg_trickle; CREATE EXTENSION pg_react VERSION '0.2.0'" >/dev/null
docker compose cp tests/m5-api.sql postgres:/tmp/m5-api.sql >/dev/null 2>&1
run_test "M5 API inventory" docker compose exec -T postgres psql -X -U postgres -d m5_api \
  -v ON_ERROR_STOP=1 -f /tmp/m5-api.sql

run_test "v1 reference workflow" bash tests/m4-reference.sh
run_test "v1 physical recovery pilot" bash tests/m4-pilot.sh

docker compose exec -T postgres createdb -U postgres m5_upgrade
docker compose cp tests/m5-upgrade.sql postgres:/tmp/m5-upgrade.sql >/dev/null 2>&1
run_test "M5 direct upgrade" docker compose exec -T postgres psql -X -U postgres -d m5_upgrade \
  -v ON_ERROR_STOP=1 -f /tmp/m5-upgrade.sql

docker compose exec -T postgres createdb -U postgres m5_dev
for fixture in m5-setup m5-promotion m5 m5-hold-deploy m5-racing-deploy m5-concurrency-result; do
  docker compose cp "tests/$fixture.sql" "postgres:/tmp/$fixture.sql" >/dev/null 2>&1
done
run_test "M5 development setup" docker compose exec -T postgres psql -X -U postgres -d m5_dev \
  -v ON_ERROR_STOP=1 -v actual_schema=m5_dev -f /tmp/m5-setup.sql
run_test "M5 portable development deployment" docker compose exec -T postgres psql -X -U postgres -d m5_dev \
  -v ON_ERROR_STOP=1 -f /tmp/m5-promotion.sql
run_test "M5 atomic acceptance" docker compose exec -T postgres psql -X -U postgres -d m5_dev \
  -v ON_ERROR_STOP=1 -v actual_schema=m5_dev -f /tmp/m5.sql

docker compose exec -T postgres psql -X -U postgres -d m5_dev -v ON_ERROR_STOP=1 \
  -f /tmp/m5-hold-deploy.sql >"$test_log_dir/held-deployment.log" 2>&1 &
held_pid=$!
sleep 0.5
expect_lock_timeout "source DDL" docker compose exec -T postgres psql -X -U postgres -d m5_dev \
  -v ON_ERROR_STOP=1 -c "SET lock_timeout = '100ms'; ALTER VIEW m5_dev.command_v2 SET (security_barrier = false)"
expect_lock_timeout "consequence DDL" docker compose exec -T postgres psql -X -U postgres -d m5_dev \
  -v ON_ERROR_STOP=1 -c "SET lock_timeout = '100ms'; ALTER FUNCTION m5_dev.act_v2(pgreact.activation_context,m5_dev.command_v2) COST 101"
expect_lock_timeout "concurrent deployment" docker compose exec -T postgres psql -X -U postgres -d m5_dev \
  -v ON_ERROR_STOP=1 -f /tmp/m5-racing-deploy.sql
if ! wait "$held_pid"; then
  sed -n '1,$p' "$test_log_dir/held-deployment.log"
  exit 1
fi
run_test "M5 concurrency result" docker compose exec -T postgres psql -X -U postgres -d m5_dev \
  -v ON_ERROR_STOP=1 -f /tmp/m5-concurrency-result.sql

docker compose exec -T postgres createdb -U postgres m5_prod
docker compose cp tests/m5-setup.sql postgres:/tmp/m5-prod-setup.sql >/dev/null 2>&1
docker compose cp tests/m5-promotion.sql postgres:/tmp/m5-prod-promotion.sql >/dev/null 2>&1
run_test "M5 production setup" docker compose exec -T postgres psql -X -U postgres -d m5_prod \
  -v ON_ERROR_STOP=1 -v actual_schema=m5_prod -f /tmp/m5-prod-setup.sql
run_test "M5 portable production deployment" docker compose exec -T postgres psql -X -U postgres -d m5_prod \
  -v ON_ERROR_STOP=1 -f /tmp/m5-prod-promotion.sql

dev_definition=$(docker compose exec -T postgres psql -X -U postgres -d m5_dev -Atc \
  "SELECT definition_digest FROM pgreact.pack_history('risk-pack') WHERE version = '1'")
prod_definition=$(docker compose exec -T postgres psql -X -U postgres -d m5_prod -Atc \
  "SELECT definition_digest FROM pgreact.pack_history('risk-pack') WHERE version = '1'")
test "$dev_definition" = "$prod_definition"

echo "M5 safe rule-set deployment gate passed for $image ($PG_REACT_PLATFORM)"
