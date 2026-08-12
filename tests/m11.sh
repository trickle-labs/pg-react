#!/usr/bin/env bash
set -euo pipefail

image=${1:-pg-react:v0.8.0}
platform=linux/amd64
project=${COMPOSE_PROJECT_NAME:-pgreact-m11-${GITHUB_RUN_ID:-$$}}
test_log_dir=$(mktemp -d)

cleanup() {
  COMPOSE_PROJECT_NAME=$project docker compose down --volumes --remove-orphans >/dev/null 2>&1 || true
  rm -r -- "$test_log_dir"
}
trap cleanup EXIT

bash tests/m11-docs.sh

PG_REACT_EXPECTED_VERSION=0.8.0 \
  COMPOSE_PROJECT_NAME="${project}-compatibility" \
  bash tests/m10.sh "$image"

export PG_REACT_IMAGE=$image
export PG_REACT_PLATFORM=$platform
export PG_REACT_PORT_BINDING=${PG_REACT_PORT_BINDING:-127.0.0.1::5432}
export COMPOSE_PROJECT_NAME=$project

docker compose up -d --no-build >/dev/null 2>&1
ready=false
for _ in {1..120}; do
  if docker compose exec -T postgres psql -X -U postgres -d postgres -Atc \
      "SELECT extversion = '0.8.0' FROM pg_extension WHERE extname = 'pg_react'" 2>/dev/null | grep -qx t; then
    ready=true
    break
  fi
  sleep 1
done
test "$ready" = true
test "$(docker image inspect "$image" --format '{{.Os}}/{{.Architecture}}')" = "$platform"

docker compose exec -T postgres createdb -U postgres m11_api
docker compose exec -T postgres psql -X -U postgres -d m11_api \
  -v ON_ERROR_STOP=1 -c 'CREATE EXTENSION pg_trickle; CREATE EXTENSION pg_react' >/dev/null
docker compose cp tests/m11-api.sql postgres:/tmp/m11-api.sql >/dev/null 2>&1
if docker compose exec -T postgres psql -XAt -U postgres -d m11_api \
    -v ON_ERROR_STOP=1 -f /tmp/m11-api.sql >"$test_log_dir/m11-api.log" 2>&1; then
  grep -qx 'M11 replacement facade API gate passed' "$test_log_dir/m11-api.log"
  echo 'M11 replacement facade API gate passed'
else
  sed -n '1,$p' "$test_log_dir/m11-api.log"
  exit 1
fi

docker compose exec -T postgres createdb -U postgres m11_upgrade
for fixture in m8-setup m9-upgrade m10-upgrade m11-upgrade; do
  docker compose cp "tests/$fixture.sql" "postgres:/tmp/$fixture.sql" >/dev/null 2>&1
done
if docker compose exec -T postgres psql -XAt -U postgres -d m11_upgrade \
    -v ON_ERROR_STOP=1 -f /tmp/m9-upgrade.sql -f /tmp/m10-upgrade.sql \
    -f /tmp/m11-upgrade.sql >"$test_log_dir/m11-upgrade.log" 2>&1; then
  grep -qx 'M11 direct 0.7.0 to 0.8.0 upgrade preserved exact M10 state' \
    "$test_log_dir/m11-upgrade.log"
  echo 'M11 direct upgrade preserved exact M10 state'
else
  sed -n '1,$p' "$test_log_dir/m11-upgrade.log"
  exit 1
fi

echo "M11 replacement facade gate passed for $image ($platform)"
