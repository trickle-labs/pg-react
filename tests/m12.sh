#!/usr/bin/env bash
set -euo pipefail

image=${1:-pg-react:v0.9.0}
expected_version=${PG_REACT_EXPECTED_VERSION:-0.9.0}
platform=linux/amd64
project=${COMPOSE_PROJECT_NAME:-pgreact-m12-${GITHUB_RUN_ID:-$$}}
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

run_sql_fixture() {
  local name=$1
  local database=$2
  local fixture=$3
  docker compose exec -T postgres createdb -U postgres "$database"
  docker compose exec -T postgres psql -X -U postgres -d "$database" \
    -v ON_ERROR_STOP=1 -c 'CREATE EXTENSION pg_trickle; CREATE EXTENSION pg_react' >/dev/null
  docker compose cp "tests/$fixture.sql" "postgres:/tmp/$fixture.sql" >/dev/null 2>&1
  run_test "$name" docker compose exec -T postgres psql -XAtq -U postgres \
    -d "$database" -v ON_ERROR_STOP=1 -f "/tmp/$fixture.sql"
}

run_test 'M12 task documentation' bash tests/m12-docs.sh
run_test 'M0-M11 compatibility' env \
  PG_REACT_EXPECTED_VERSION="$expected_version" \
  COMPOSE_PROJECT_NAME="${project}-compatibility" \
  bash tests/m11.sh "$image"

export PG_REACT_IMAGE=$image
export PG_REACT_PLATFORM=$platform
export PG_REACT_PORT_BINDING=${PG_REACT_PORT_BINDING:-127.0.0.1::5432}
export COMPOSE_PROJECT_NAME=$project

docker compose up -d --no-build >/dev/null 2>&1
ready=false
for _ in {1..120}; do
  if docker compose exec -T postgres psql -X -U postgres -d postgres -Atc \
      "SELECT extversion = '$expected_version' FROM pg_extension WHERE extname = 'pg_react'" \
      2>/dev/null | grep -qx t; then
    ready=true
    break
  fi
  sleep 1
done
test "$ready" = true
test "$(docker image inspect "$image" --format '{{.Os}}/{{.Architecture}}')" = "$platform"
test "$(docker compose exec -T postgres sh -c 'test -x /usr/local/bin/pg-reactd && echo executable')" = executable

run_sql_fixture 'M12 exact reference workload' m12_reference m12-reference
run_sql_fixture 'M12 boundary and atomic failure' m12_boundary m12-boundary
run_sql_fixture 'M12 ordering and lifecycle operations' m12_order m12-order
run_sql_fixture 'M12 indexed performance smoke' m12_performance m12-performance

docker compose cp tests/m12-hold-clock.sql postgres:/tmp/m12-hold-clock.sql >/dev/null 2>&1
docker compose exec -T postgres psql -XAtq -U postgres -d m12_reference \
  -v ON_ERROR_STOP=1 -f /tmp/m12-hold-clock.sql >"$test_log_dir/held-clock.log" 2>&1 &
held_pid=$!
held=false
for _ in {1..120}; do
  if docker compose exec -T postgres psql -XAtq -U postgres -d m12_reference -c \
      "SELECT EXISTS (SELECT 1 FROM pg_stat_activity WHERE datname = 'm12_reference' AND pid <> pg_backend_pid() AND state = 'active' AND query LIKE '%pg_sleep%')" \
      | grep -qx t; then
    held=true
    break
  fi
  sleep 0.1
done
test "$held" = true
if docker compose exec -T postgres psql -XAtq -U postgres -d m12_reference \
    -v ON_ERROR_STOP=1 -c "SET lock_timeout = '200ms'; SELECT * FROM pgreact_api.claim('blocked-worker', 1)" \
    >"$test_log_dir/blocked-claim.log" 2>&1; then
  echo 'M12 claim unexpectedly crossed clock barrier' >&2
  exit 1
fi
grep -Fq 'canceling statement due to lock timeout' "$test_log_dir/blocked-claim.log"
wait "$held_pid"
echo 'M12 clock claim barrier passed'

docker compose exec -T postgres createdb -U postgres m12_worker
for fixture in m12-worker-setup m12-worker-result; do
  docker compose cp "tests/$fixture.sql" "postgres:/tmp/$fixture.sql" >/dev/null 2>&1
done
docker compose exec -T postgres psql -XAtq -U postgres -d m12_worker \
  -v ON_ERROR_STOP=1 -c 'CREATE EXTENSION pg_trickle; CREATE EXTENSION pg_react' \
  -f /tmp/m12-worker-setup.sql >"$test_log_dir/m12-worker-setup.log" 2>&1
worker_version=$(docker compose exec -T postgres psql -XAtq -U postgres -d m12_worker -c \
  "SELECT version.rule_version_id FROM pgreact_internal.rules rule JOIN pgreact_internal.rule_versions version USING (rule_id) WHERE rule.rule_name = 'worker-deadline' AND version.state = 'ACTIVE'")
run_test 'M12 bundled worker coordinator and execution' docker compose exec -T \
  -e DATABASE_URL=postgresql://postgres@localhost/m12_worker \
  postgres pg-reactd "$worker_version" m12-worker
run_test 'M12 bundled worker exact result' docker compose exec -T postgres \
  psql -XAtq -U postgres -d m12_worker -v ON_ERROR_STOP=1 \
  -f /tmp/m12-worker-result.sql

docker compose exec -T postgres createdb -U postgres m12_upgrade
docker compose cp tests/m12-upgrade.sql postgres:/tmp/m12-upgrade.sql >/dev/null 2>&1
run_test 'M12 direct populated upgrade' docker compose exec -T postgres \
  psql -XAtq -U postgres -d m12_upgrade -v ON_ERROR_STOP=1 \
  -c "CREATE EXTENSION pg_trickle; CREATE EXTENSION pg_react VERSION '0.8.0'" \
  -f /tmp/m12-upgrade.sql

run_test 'M12 crash restart and physical recovery' env \
  RECOVERY_MILESTONE=m12 bash tests/m6-recovery.sh

echo "M12 database-time deadline gate passed for $image ($platform)"
