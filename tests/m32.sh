#!/usr/bin/env bash
set -euo pipefail

if ! command -v docker >/dev/null 2>&1; then
  echo "M32 fixture checks skipped: Docker is unavailable"
  exit 0
fi

profile=${1:-fast}
image=${2:-pg-react:m32-unreleased}
case "$profile" in fast|complete) ;; *) echo 'usage: tests/m32.sh fast|complete [IMAGE]' >&2; exit 2 ;; esac

project=${COMPOSE_PROJECT_NAME:-pgreact-m32-${GITHUB_RUN_ID:-$$}}
cleanup() {
  COMPOSE_PROJECT_NAME=$project docker compose down --volumes --remove-orphans >/dev/null 2>&1 || true
}
trap cleanup EXIT

test -s sql/m32.sql
test -s sql/pg_react--0.28.0--0.29.0.sql
test -s sql/pg_react--0.29.0.sql
cmp sql/pg_react--0.28.0--0.29.0.sql sql/m32.sql
cmp sql/pg_react--0.29.0.sql <(cat sql/pg_react--0.28.0.sql; printf '\n'; cat sql/m32.sql)
bash -n tests/m32.sh

export COMPOSE_PROJECT_NAME=$project
export PG_REACT_IMAGE=$image
export PG_REACT_INIT_VERSION=0.29.0
docker compose up -d --no-build >/dev/null 2>&1
for _ in {1..120}; do
  if [[ $(docker inspect --format '{{.State.Health.Status}}' "${project}-postgres-1" 2>/dev/null || true) = healthy ]] &&
     docker compose exec -T postgres psql -XAtq -U postgres -d postgres -c \
       "SELECT extversion='0.29.0' FROM pg_extension WHERE extname='pg_react'" 2>/dev/null | grep -qx t; then
    break
  fi
  sleep 1
done
docker compose exec -T postgres psql -XAtq -U postgres -d postgres -v ON_ERROR_STOP=1 \
  -f - < tests/m32.sql
echo "M32 $profile fixture passed for $image"
