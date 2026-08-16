#!/usr/bin/env bash
set -euo pipefail

profile=${1:-fast}
image=${2:-pg-react:v0.25.0}
case "$profile" in fast|complete) ;; *) echo 'usage: tests/m28.sh fast|complete [IMAGE]' >&2; exit 2 ;; esac

project=${COMPOSE_PROJECT_NAME:-pgreact-m28-${GITHUB_RUN_ID:-$$}}
upgrade_project=${project}-upgrade
test_log_dir=$(mktemp -d)
artifact_dir=${M28_ARTIFACT_DIR:-}
inherited_worktree="$test_log_dir/m27-source"

cleanup() {
  COMPOSE_PROJECT_NAME=$project docker compose down --volumes --remove-orphans >/dev/null 2>&1 || true
  COMPOSE_PROJECT_NAME=$upgrade_project docker compose down --volumes --remove-orphans >/dev/null 2>&1 || true
  git worktree remove --force "$inherited_worktree" >/dev/null 2>&1 || true
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
  grep -Fq 'pg-react M28 is extension `0.25.0`' README.md &&
    grep -Fq 'tests/m28.sh fast pg-react:v0.25.0' docs/m28-readiness.md &&
    grep -Fq '0.24.0 -> 0.25.0' docs/m28-upgrade.md &&
    grep -Fq 'M29 — Policy-set gating' docs/m28-release-notes.md &&
    jq -e '.ordinary | length == 10 and .[2] == "pgreact_api.validate(declaration)"' docs/m28-api-inventory.json >/dev/null
}

release_audit() {
  grep -qx 'version = "0.25.0"' Cargo.toml &&
    grep -qx "default_version = '0.25.0'" pg_react.control &&
    grep -Fq "extversion = '0.25.0'" src/managed.rs &&
    test -s sql/pg_react--0.24.0.sql &&
    test -s sql/pg_react--0.24.0--0.25.0.sql &&
    test -s sql/pg_react--0.25.0.sql &&
    test -s sql/m28.sql &&
    test -s tests/m28.sql &&
    bash -n tests/m28.sh &&
    jq -e '.target_version == "0.25.0" and .direct_upgrade == "0.24.0 -> 0.25.0" and (.ordinary_verbs | length) == 8' \
      tests/fixtures/m28/release-state.json >/dev/null
}

run_test 'M28 documentation audit' docs_audit
run_test 'M28 release identity audit' release_audit

export PG_REACT_IMAGE=$image
export PG_REACT_INIT_VERSION=0.25.0
export PG_REACT_PLATFORM=linux/amd64
export PG_REACT_PORT_BINDING=${PG_REACT_PORT_BINDING:-127.0.0.1::5432}
export PG_REACT_POLL_INTERVAL_MS=60000
export PG_REACT_BATCH_SIZE=1000
export COMPOSE_PROJECT_NAME=$project
docker compose up -d --no-build >/dev/null 2>&1
wait_for_version "$project" 0.25.0
docker compose cp tests/m28.sql postgres:/tmp/m28.sql >/dev/null
run_test 'M28 canonical façade gate' \
  docker compose exec -T postgres psql -XAtq -U postgres -d postgres -v ON_ERROR_STOP=1 -f /tmp/m28.sql

if [[ $profile = complete ]]; then
  git worktree add --detach "$inherited_worktree" v0.24.0 >/dev/null
  run_test 'M27 inherited complete gate' env \
    M27_INHERITED_IMAGE=${M27_INHERITED_IMAGE:-pg-react:v0.23.0} \
    COMPOSE_PROJECT_NAME="${project}-inherited" \
    bash -c "cd '$inherited_worktree' && bash tests/m27.sh complete 'pg-react:v0.24.0'"
  export COMPOSE_PROJECT_NAME=$upgrade_project
  export PG_REACT_INIT_VERSION=0.24.0
  docker compose up -d --no-build >/dev/null 2>&1
  wait_for_version "$upgrade_project" 0.24.0
  docker compose cp tests/m28-upgrade-before.sql postgres:/tmp/m28-upgrade-before.sql >/dev/null
  docker compose cp tests/m28-upgrade-after.sql postgres:/tmp/m28-upgrade-after.sql >/dev/null
  run_test 'M28 populated direct-upgrade setup' \
    docker compose exec -T postgres psql -XAtq -U postgres -d postgres -v ON_ERROR_STOP=1 -f /tmp/m28-upgrade-before.sql
  run_test 'M28 direct 0.24.0 to 0.25.0 upgrade' \
    docker compose exec -T postgres psql -XAtq -U postgres -d postgres -v ON_ERROR_STOP=1 -c \
    "ALTER EXTENSION pg_react UPDATE TO '0.25.0';"
  run_test 'M28 populated upgrade preserved' \
    docker compose exec -T postgres psql -XAtq -U postgres -d postgres -v ON_ERROR_STOP=1 -f /tmp/m28-upgrade-after.sql
fi

echo "M28 $profile evidence gate passed for $image (linux/amd64)"
if [[ -n $artifact_dir ]]; then
  mkdir -p -- "$artifact_dir"
  cp -- "$test_log_dir"/*.log tests/fixtures/m28/release-state.json "$artifact_dir"/
fi
