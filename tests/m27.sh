#!/usr/bin/env bash
set -euo pipefail

profile=${1:-fast}
image=${2:-pg-react:v0.24.0}
inherited_image=${M27_INHERITED_IMAGE:-pg-react:v0.23.0}
case "$profile" in fast|complete) ;; *) echo 'usage: tests/m27.sh fast|complete [IMAGE]' >&2; exit 2 ;; esac

project=${COMPOSE_PROJECT_NAME:-pgreact-m27-${GITHUB_RUN_ID:-$$}}
upgrade_project=${project}-upgrade
test_log_dir=$(mktemp -d)
artifact_dir=${M27_ARTIFACT_DIR:-}
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

release_audit() {
  bash -n tests/m27.sh &&
    test -s sql/m27.sql && test -s tests/m27.sql &&
    test -s tests/m27-upgrade-before.sql && test -s tests/m27-upgrade-after.sql &&
    jq -e '.target_version == "0.24.0" and .direct_upgrade == "0.23.0 -> 0.24.0" and (.finding_codes | length) == 6' \
      tests/fixtures/m27/release-state.json >/dev/null
}

run_test 'M27 release evidence audit' release_audit

export PG_REACT_IMAGE=$image
export PG_REACT_INIT_VERSION=0.24.0
export PG_REACT_PLATFORM=linux/amd64
export PG_REACT_PORT_BINDING=${PG_REACT_PORT_BINDING:-127.0.0.1::5432}
export PG_REACT_POLL_INTERVAL_MS=60000
export PG_REACT_BATCH_SIZE=1000
export COMPOSE_PROJECT_NAME=$project
docker compose up -d --no-build >/dev/null 2>&1
wait_for_version "$project" 0.24.0
docker compose cp tests/m27.sql postgres:/tmp/m27.sql >/dev/null
run_test 'M27 decision-analysis gate' \
  docker compose exec -T postgres psql -XAtq -U postgres -d postgres -v ON_ERROR_STOP=1 -f /tmp/m27.sql

if [[ $profile = complete ]]; then
  git worktree add --detach "$inherited_worktree" v0.23.0 >/dev/null
  run_test 'M26 inherited complete gate' env M26_SKIP_REPO_AUDIT=1 \
    COMPOSE_PROJECT_NAME="${project}-inherited" \
    bash -c "cd '$inherited_worktree' && bash tests/m26.sh complete '$inherited_image'"
  export COMPOSE_PROJECT_NAME=$upgrade_project
  export PG_REACT_INIT_VERSION=0.23.0
  docker compose up -d --no-build >/dev/null 2>&1
  wait_for_version "$upgrade_project" 0.23.0
  docker compose cp tests/m27-upgrade-before.sql postgres:/tmp/m27-upgrade-before.sql >/dev/null
  docker compose cp tests/m27-upgrade-after.sql postgres:/tmp/m27-upgrade-after.sql >/dev/null
  run_test 'M27 populated direct-upgrade setup' \
    docker compose exec -T postgres psql -XAtq -U postgres -d postgres -v ON_ERROR_STOP=1 -f /tmp/m27-upgrade-before.sql
  run_test 'M27 direct 0.23.0 to 0.24.0 upgrade' \
    docker compose exec -T postgres psql -XAtq -U postgres -d postgres -v ON_ERROR_STOP=1 -c \
    "ALTER EXTENSION pg_react UPDATE TO '0.24.0';"
  run_test 'M27 populated upgrade preserved' \
    docker compose exec -T postgres psql -XAtq -U postgres -d postgres -v ON_ERROR_STOP=1 -f /tmp/m27-upgrade-after.sql
fi

echo "M27 $profile evidence gate passed for $image (linux/amd64)"
if [[ -n $artifact_dir ]]; then
  mkdir -p -- "$artifact_dir"
  cp -- "$test_log_dir"/*.log tests/fixtures/m27/release-state.json "$artifact_dir"/
fi
