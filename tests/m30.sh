#!/usr/bin/env bash
set -euo pipefail

profile=${1:-fast}
image=${2:-pg-react:v0.27.0}
case "$profile" in fast|complete) ;; *) echo 'usage: tests/m30.sh fast|complete [IMAGE]' >&2; exit 2 ;; esac

project=${COMPOSE_PROJECT_NAME:-pgreact-m30-${GITHUB_RUN_ID:-$$}}
upgrade_project=${project}-upgrade
test_log_dir=$(mktemp -d)
artifact_dir=${M30_ARTIFACT_DIR:-}
inherited_worktree="$test_log_dir/m26-source"

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
  grep -Fq 'pg-react M30 is the released `0.27.0`' README.md || return 1
  grep -Fq 'tests/m30.sh fast pg-react:v0.27.0' docs/m30-readiness.md || return 1
  grep -Fq '0.26.0 -> 0.27.0' docs/m30-upgrade.md || return 1
  grep -Fq 'M31 — Authoritative runtime' docs/m30-release-notes.md || return 1
  jq '.milestone == "M30" and .target_version == "0.27.0" and .contract_version == 18' \
    docs/m30-api-inventory.json >/dev/null || return 1
  return 0
}

release_audit() {
  test -s sql/pg_react--0.26.0.sql &&
    test -s sql/pg_react--0.26.0--0.27.0.sql &&
    test -s sql/pg_react--0.27.0.sql &&
    cmp sql/pg_react--0.27.0.sql <(cat sql/pg_react--0.26.0.sql sql/m30.sql) &&
    test -s sql/m30.sql &&
    test -s docs/m30-evidence.md &&
    test -s tests/m30.sql &&
    bash -n tests/m30.sh &&
    jq '.target_version == "0.27.0" and .direct_upgrade == "0.26.0 -> 0.27.0" and .contract_version == 18' \
      tests/fixtures/m30/release-state.json >/dev/null
}

run_test 'M30 documentation audit' docs_audit
run_test 'M30 release identity audit' release_audit

export PG_REACT_IMAGE=$image
export PG_REACT_INIT_VERSION=0.27.0
export PG_REACT_PLATFORM=linux/amd64
export PG_REACT_PORT_BINDING=${PG_REACT_PORT_BINDING:-127.0.0.1::5432}
export PG_REACT_POLL_INTERVAL_MS=60000
export PG_REACT_BATCH_SIZE=1000
export COMPOSE_PROJECT_NAME=$project
docker compose up -d --no-build >/dev/null 2>&1
wait_for_version "$project" 0.27.0
docker compose cp tests/m30.sql postgres:/tmp/m30.sql >/dev/null
run_test 'M30 applicability foundation' \
  docker compose exec -T postgres psql -XAtq -U postgres -d postgres -v ON_ERROR_STOP=1 -f /tmp/m30.sql

if [[ $profile = complete ]]; then
  git worktree add --detach "$inherited_worktree" v0.26.0 >/dev/null
  run_test 'M29 inherited complete gate' env \
    M29_INHERITED_IMAGE=${M29_INHERITED_IMAGE:-pg-react:v0.25.0} \
    COMPOSE_PROJECT_NAME="${project}-inherited" \
    bash -c "cd '$inherited_worktree' && bash tests/m29.sh complete 'pg-react:v0.26.0'"
  export COMPOSE_PROJECT_NAME=$upgrade_project
  export PG_REACT_IMAGE=${M30_UPGRADE_IMAGE:-pg-react:v0.26.0}
  export PG_REACT_INIT_VERSION=0.26.0
  docker compose up -d --no-build >/dev/null 2>&1
  wait_for_version "$upgrade_project" 0.26.0
  docker compose cp tests/m30-upgrade-before.sql postgres:/tmp/m30-upgrade-before.sql >/dev/null
  docker compose cp tests/m30-upgrade-after.sql postgres:/tmp/m30-upgrade-after.sql >/dev/null
  run_test 'M30 populated direct-upgrade setup' \
    docker compose exec -T postgres psql -XAtq -U postgres -d postgres -v ON_ERROR_STOP=1 -f /tmp/m30-upgrade-before.sql
  docker compose down --remove-orphans >/dev/null
  export PG_REACT_IMAGE=$image
  docker compose up -d --no-build >/dev/null 2>&1
  wait_for_version "$upgrade_project" 0.26.0
  docker compose cp tests/m30-upgrade-after.sql postgres:/tmp/m30-upgrade-after.sql >/dev/null
  run_test 'M30 direct 0.26.0 to 0.27.0 upgrade' \
    docker compose exec -T postgres psql -XAtq -U postgres -d postgres -v ON_ERROR_STOP=1 -c \
    "ALTER EXTENSION pg_react UPDATE TO '0.27.0';"
  run_test 'M30 populated upgrade preserved' \
    docker compose exec -T postgres psql -XAtq -U postgres -d postgres -v ON_ERROR_STOP=1 -f /tmp/m30-upgrade-after.sql
fi

echo "M30 $profile evidence gate passed for $image (linux/amd64)"
if [[ -n $artifact_dir ]]; then
  mkdir -p -- "$artifact_dir"
  cp -- "$test_log_dir"/*.log tests/fixtures/m30/release-state.json "$artifact_dir"/
fi
