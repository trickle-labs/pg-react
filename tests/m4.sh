#!/usr/bin/env bash
set -euo pipefail

image=${1:-pg-react:v0.1.1}
export PG_REACT_IMAGE=$image
export PG_REACT_PLATFORM=linux/amd64
export PG_REACT_PORT_BINDING=${PG_REACT_PORT_BINDING:-127.0.0.1::5432}
export COMPOSE_PROJECT_NAME=${COMPOSE_PROJECT_NAME:-pgreact-m4-${GITHUB_RUN_ID:-$$}}

cleanup() {
  docker compose down --volumes --remove-orphans >/dev/null 2>&1 || true
}
trap cleanup EXIT

docker build --platform "$PG_REACT_PLATFORM" --tag "$image" .
test "$(docker image inspect "$image" --format '{{.Os}}/{{.Architecture}}')" = "$PG_REACT_PLATFORM"
docker compose up -d --no-build

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
built_id=$(docker image inspect "$image" --format '{{.Id}}')
test "$(docker compose images -q postgres)" = "${built_id#sha256:}"
docker compose exec -T postgres test -x /usr/local/bin/pg-reactd
docker compose exec -T postgres psql -X -U postgres -d postgres -v ON_ERROR_STOP=1 -Atc \
  "SELECT extversion = '0.1.1' FROM pg_extension WHERE extname = 'pg_react'" | grep -qx t

for suite in m0 m1 m1-scale m2 m3; do
  bash "tests/$suite.sh"
done

docker compose exec -T postgres createdb -U postgres m4_api
docker compose exec -T postgres psql -X -U postgres -d m4_api -v ON_ERROR_STOP=1 \
  -c "CREATE EXTENSION pg_trickle; CREATE EXTENSION pg_react"
docker compose cp tests/m4-api.sql postgres:/tmp/m4-api.sql >/dev/null
docker compose exec -T postgres psql -X -U postgres -d m4_api -v ON_ERROR_STOP=1 -f /tmp/m4-api.sql

bash tests/m4-reference.sh
bash tests/m4-pilot.sh

echo "M4 release-artifact gate passed for $image ($PG_REACT_PLATFORM)"
