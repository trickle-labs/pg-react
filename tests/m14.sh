#!/usr/bin/env bash
set -euo pipefail

image=${1:-pg-react:v0.11.0}
expected_version=${PG_REACT_EXPECTED_VERSION:-0.11.0}
platform=linux/amd64
project=${COMPOSE_PROJECT_NAME:-pgreact-m14-${GITHUB_RUN_ID:-$$}}
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
    if docker compose exec -T postgres createdb -U postgres "$1" >/dev/null 2>&1; then return; fi
    sleep 1
  done
  docker compose exec -T postgres createdb -U postgres "$1"
}

run_test 'M14 task documentation' bash tests/m14-docs.sh
run_test 'M13 task documentation compatibility' bash tests/m13-docs.sh
if [[ ${PG_REACT_SKIP_INHERITED:-false} != true ]]; then
  run_test 'M0-M12 compatibility' env \
    PG_REACT_EXPECTED_VERSION="$expected_version" \
    COMPOSE_PROJECT_NAME="${project}-compatibility" \
    bash tests/m12.sh "$image"
fi

export PG_REACT_IMAGE=$image
export PG_REACT_PLATFORM=$platform
export PG_REACT_PORT_BINDING=${PG_REACT_PORT_BINDING:-127.0.0.1::5432}
export COMPOSE_PROJECT_NAME=$project

docker compose up -d --no-build >/dev/null
ready_checks=0
for _ in {1..120}; do
  if docker compose exec -T postgres psql -XAtq -U postgres -d postgres -c \
      "SELECT extversion = '$expected_version' FROM pg_extension WHERE extname = 'pg_react'" \
      2>/dev/null | grep -qx t; then
    ready_checks=$((ready_checks + 1))
    [[ $ready_checks -eq 2 ]] && break
  else
    ready_checks=0
  fi
  sleep 1
done
test "$ready_checks" -eq 2
test "$(docker compose exec -T postgres psql -XAtq -U postgres -d postgres -c \
  "SELECT extversion = '$expected_version' FROM pg_extension WHERE extname = 'pg_react'")" = t
test "$(docker image inspect "$image" --format '{{.Os}}/{{.Architecture}}')" = "$platform"

create_db m14_api
docker compose cp tests/m14-api.sql postgres:/tmp/m14-api.sql >/dev/null
run_test 'M14 diagnosis, inference, and explanation' docker compose exec -T postgres \
  psql -XAtq -U postgres -d m14_api -v ON_ERROR_STOP=1 \
  -c 'CREATE EXTENSION pg_trickle; CREATE EXTENSION pg_react' -f /tmp/m14-api.sql

create_db m14_upgrade
docker compose cp tests/m14-upgrade.sql postgres:/tmp/m14-upgrade.sql >/dev/null
if [[ $expected_version == 0.11.0 ]]; then
  run_test 'M14 direct populated upgrade' docker compose exec -T postgres \
    psql -XAtq -U postgres -d m14_upgrade -v ON_ERROR_STOP=1 \
    -c "CREATE EXTENSION pg_trickle; CREATE EXTENSION pg_react VERSION '0.10.0'" \
    -f /tmp/m14-upgrade.sql
fi

echo "M14 explainability and reasoning UX gate passed for $image ($platform)"
