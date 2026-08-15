#!/usr/bin/env bash
set -euo pipefail

profile=${1:-fast}
image=${2:-pg-react:v0.21.0}
case "$profile" in fast|complete) ;; *) echo 'usage: tests/m24.sh fast|complete [IMAGE]' >&2; exit 2 ;; esac

project=${COMPOSE_PROJECT_NAME:-pgreact-m24-${GITHUB_RUN_ID:-$$}}
upgrade_project=${project}-upgrade
test_log_dir=$(mktemp -d)
artifact_dir=${M24_ARTIFACT_DIR:-}

cleanup() {
  COMPOSE_PROJECT_NAME=$project docker compose down --volumes --remove-orphans >/dev/null 2>&1 || true
  COMPOSE_PROJECT_NAME=$upgrade_project docker compose down --volumes --remove-orphans >/dev/null 2>&1 || true
  rm -r -- "$test_log_dir"
}
trap cleanup EXIT

run_test() {
  local name=$1; shift
  local log="$test_log_dir/${name// /-}.log"
  if "$@" >"$log" 2>&1; then echo "$name passed"; else sed -n '1,$p' "$log"; return 1; fi
}

wait_for_version() {
  local compose_project=$1 expected=$2
  local container="${compose_project}-postgres-1"
  for _ in {1..120}; do
    if [[ $(docker inspect --format '{{.State.Health.Status}}' "$container" 2>/dev/null || true) = healthy ]] &&
       COMPOSE_PROJECT_NAME=$compose_project docker compose exec -T postgres psql -XAtq -U postgres -d postgres -c \
       "SELECT extversion='$expected' FROM pg_extension WHERE extname='pg_react'" 2>/dev/null | grep -qx t; then return; fi
    sleep 1
  done
  return 1
}

docs_audit() {
  grep -Fq 'pg-react M24 is extension `0.21.0`' README.md &&
    grep -Fq 'tests/m24.sh fast pg-react:v0.21.0' docs/m24-readiness.md &&
    grep -Fq 'tests/m24.sh complete pg-react:v0.21.0' docs/m24-evidence.md &&
    grep -Fq '0.20.0 -> 0.21.0' docs/m24-upgrade.md &&
    grep -Fq 'M25 — Parameterized policy families' docs/m24-release-notes.md
}

release_audit() {
  grep -qx 'version = "0.21.0"' Cargo.toml &&
    grep -qx "default_version = '0.21.0'" pg_react.control &&
    grep -Fq "extversion = '0.21.0'" src/managed.rs &&
    test -s sql/pg_react--0.20.0.sql &&
    test -s sql/pg_react--0.20.0--0.21.0.sql &&
    test -s sql/pg_react--0.21.0.sql &&
    test -s tests/m24.sql &&
    test -s tests/m24-program.sql &&
    bash -n tests/m24.sh &&
    jq -e '.target_version == "0.21.0" and .direct_upgrade == "0.20.0 -> 0.21.0"' \
      tests/fixtures/m24/release-state.json >/dev/null
}

run_test 'M24 documentation audit' docs_audit
run_test 'M24 release identity audit' release_audit

export PG_REACT_IMAGE=$image
export PG_REACT_INIT_VERSION=0.21.0
export PG_REACT_PLATFORM=linux/amd64
export PG_REACT_PORT_BINDING=${PG_REACT_PORT_BINDING:-127.0.0.1::5432}
export PG_REACT_POLL_INTERVAL_MS=60000
export PG_REACT_BATCH_SIZE=1000
export COMPOSE_PROJECT_NAME=$project
docker compose up -d --no-build >/dev/null 2>&1
wait_for_version "$project" 0.21.0
docker compose cp tests/m24.sql postgres:/tmp/m24.sql >/dev/null
docker compose cp tests/m24-program.sql postgres:/tmp/m24-program.sql >/dev/null
docker compose cp tests/m8-setup.sql postgres:/tmp/m8-setup.sql >/dev/null
run_test 'M24 effective policy gate' \
  docker compose exec -T postgres psql -XAtq -U postgres -d postgres -v ON_ERROR_STOP=1 -f /tmp/m24.sql
run_test 'M24 effective program gate' \
  docker compose exec -T postgres psql -XAtq -U postgres -d postgres -v ON_ERROR_STOP=1 -f /tmp/m24-program.sql

if [[ $profile = complete ]]; then
  run_test 'M23 inherited complete gate' env M23_SKIP_REPO_AUDIT=1 M22_SKIP_REPO_AUDIT=1 \
    COMPOSE_PROJECT_NAME="${project}-inherited" \
    bash tests/m23.sh complete "$image"
  export COMPOSE_PROJECT_NAME=$upgrade_project
  export PG_REACT_INIT_VERSION=0.20.0
  docker compose up -d --no-build >/dev/null 2>&1
  wait_for_version "$upgrade_project" 0.20.0
  docker compose cp tests/m24-upgrade-before.sql postgres:/tmp/m24-upgrade-before.sql >/dev/null
  docker compose cp tests/m24-upgrade-after.sql postgres:/tmp/m24-upgrade-after.sql >/dev/null
  run_test 'M24 populated direct-upgrade setup' \
    docker compose exec -T postgres psql -XAtq -U postgres -d postgres -v ON_ERROR_STOP=1 -f /tmp/m24-upgrade-before.sql
  run_test 'M24 direct 0.20.0 to 0.21.0 upgrade' \
    docker compose exec -T postgres psql -XAtq -U postgres -d postgres -v ON_ERROR_STOP=1 -c \
    "ALTER EXTENSION pg_react UPDATE TO '0.21.0';"
  run_test 'M24 populated upgrade preserved' \
    docker compose exec -T postgres psql -XAtq -U postgres -d postgres -v ON_ERROR_STOP=1 -f /tmp/m24-upgrade-after.sql
fi

echo "M24 $profile evidence gate passed for $image (linux/amd64)"
if [[ -n $artifact_dir ]]; then
  mkdir -p -- "$artifact_dir"
  cp -- "$test_log_dir"/*.log tests/fixtures/m24/release-state.json "$artifact_dir"/
fi
