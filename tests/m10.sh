#!/usr/bin/env bash
set -euo pipefail

image=${1:-pg-react:v0.7.0}
expected_version=${PG_REACT_EXPECTED_VERSION:-0.7.0}
platform=linux/amd64
project=${COMPOSE_PROJECT_NAME:-pgreact-m10-${GITHUB_RUN_ID:-$$}}
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

if [[ ${PG_REACT_SKIP_INHERITED:-false} != true ]]; then
  run_test "M0-M9 compatibility" env \
    COMPOSE_PROJECT_NAME="${project}-compatibility" \
    PG_REACT_EXPECTED_VERSION="$expected_version" \
    bash tests/m9.sh "$image"
fi

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

docker compose exec -T postgres createdb -U postgres m10_slice1
docker compose exec -T postgres psql -X -U postgres -d m10_slice1 \
  -v ON_ERROR_STOP=1 -c 'CREATE EXTENSION pg_trickle; CREATE EXTENSION pg_react' \
  >/dev/null
for fixture in m10-slice1 m10-boundary; do
  docker compose cp "tests/$fixture.sql" "postgres:/tmp/$fixture.sql" >/dev/null 2>&1
done
if docker compose exec -T postgres psql -XAt -U postgres -d m10_slice1 \
    -v ON_ERROR_STOP=1 -f /tmp/m10-slice1.sql >"$test_log_dir/m10-slice1.log" 2>&1; then
  grep -qx 'M10 slice 1 aggregate threshold gate passed' "$test_log_dir/m10-slice1.log"
  echo 'M10 slice 1 aggregate threshold gate passed'
else
  sed -n '1,$p' "$test_log_dir/m10-slice1.log"
  exit 1
fi

if docker compose exec -T postgres psql -XAt -U postgres -d m10_slice1 \
    -v ON_ERROR_STOP=1 -f /tmp/m10-boundary.sql >"$test_log_dir/m10-boundary.log" 2>&1; then
  grep -qx 'M10 aggregate boundary gate passed' "$test_log_dir/m10-boundary.log"
  echo 'M10 aggregate boundary gate passed'
else
  sed -n '1,$p' "$test_log_dir/m10-boundary.log"
  exit 1
fi

docker compose exec -T postgres createdb -U postgres m10_upgrade
for fixture in m8-setup m9-upgrade m10-upgrade; do
  docker compose cp "tests/$fixture.sql" "postgres:/tmp/$fixture.sql" >/dev/null 2>&1
done
run_test "M10 direct upgrade" docker compose exec -T postgres psql -X \
  -U postgres -d m10_upgrade -v ON_ERROR_STOP=1 \
  -f /tmp/m9-upgrade.sql -f /tmp/m10-upgrade.sql

run_test "M10 crash restart and physical recovery" env \
  RECOVERY_MILESTONE=m10 bash tests/m6-recovery.sh

run_test "M10 fresh-install SQL composition" cmp sql/pg_react--0.7.0.sql \
  <(cat sql/pg_react--0.6.0.sql sql/pg_react--0.6.0--0.7.0.sql)

echo "M10 stratified aggregation gate passed for $image ($platform, extension $expected_version)"
