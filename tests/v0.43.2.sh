#!/usr/bin/env bash
set -euo pipefail

profile=${1:-fast}
image=${2:-pg-react:0.43.2}
case "$profile" in fast|complete) ;; *) echo 'usage: tests/v0.43.2.sh fast|complete [IMAGE]' >&2; exit 2 ;; esac

run_dir="tests/.v0.43.2-run-${GITHUB_RUN_ID:-$$}"
project=${COMPOSE_PROJECT_NAME:-pgreact-v0432-${GITHUB_RUN_ID:-$$}}
upgrade_project=${project}-upgrade
mkdir -p -- "$run_dir"
cleanup() {
  COMPOSE_PROJECT_NAME=$project docker compose -p "$project" down --volumes --remove-orphans >/dev/null 2>&1 || true
  COMPOSE_PROJECT_NAME=$upgrade_project docker compose -p "$upgrade_project" down --volumes --remove-orphans >/dev/null 2>&1 || true
  if [[ -n ${V0432_ARTIFACT_DIR:-} ]]; then
    mkdir -p -- "$V0432_ARTIFACT_DIR"
    cp -a -- "$run_dir/." "$V0432_ARTIFACT_DIR/"
  fi
  rm -rf -- "$run_dir"
}
trap cleanup EXIT

run_test() {
  local name=$1; shift
  local log="$run_dir/${name// /-}.log"
  local rc
  set +e
  (set -e; "$@") >"$log" 2>&1
  rc=$?
  set -e
  if (( rc == 0 )); then
    printf '%s passed\n' "$name" >>"$log"
    echo "$name passed"
  else
    sed -n '1,$p' "$log"
    return "$rc"
  fi
}

static_audit() {
  for file in \
    docs/current-release.json docs/api-inventory.json docs/v0.43.2-release-notes.md \
    docs/v0.43.2-migration.md sql/v0.43.2.sql \
    sql/pg_react--0.43.1--0.43.2.sql sql/pg_react--0.43.2.sql \
    tests/v0.43.2.sql tests/v0.43.2.sh; do
    test -s "$file"
  done
  bash tests/current-docs.sh
  bash tests/api-inventory.sh
  bash tests/workflow-syntax.sh
  bash -n tests/v0.43.2.sh tests/current-docs.sh tests/api-inventory.sh tests/workflow-syntax.sh
  cmp sql/pg_react--0.43.1--0.43.2.sql sql/v0.43.2.sql
  echo '0.43.2 static and artifact audit passed'
}

run_test '0.43.2 static and artifact audit' static_audit

if ! command -v docker >/dev/null 2>&1 || ! docker image inspect "$image" >/dev/null 2>&1; then
  echo "0.43.2 external Docker evidence not run: candidate image '$image' is unavailable"
  echo '0.43.2 static lane passed; no external qualification claim made'
  exit 0
fi

export PG_REACT_IMAGE=$image
export PG_REACT_PLATFORM=linux/amd64
export PG_REACT_POLL_INTERVAL_MS=60000
export PG_REACT_PORT_BINDING=${PG_REACT_PORT_BINDING:-127.0.0.1::5432}

wait_for_version() {
  local target=$1
  local ready=
  for _ in {1..120}; do
    if docker compose -p "$COMPOSE_PROJECT_NAME" exec -T postgres psql -XAtq -U postgres -d postgres -c \
        "SELECT extversion = '$target' FROM pg_extension WHERE extname = 'pg_react'" 2>/dev/null | grep -qx t; then
      ready=1
      break
    fi
    sleep 1
  done
  test -n "$ready"
}

export COMPOSE_PROJECT_NAME=$project
export PG_REACT_INIT_VERSION=0.43.2
docker compose -p "$project" up -d --no-build >/dev/null 2>&1
wait_for_version 0.43.2
run_test '0.43.2 SQL corpus' docker compose -p "$project" exec -T postgres \
  psql -XAtq -U postgres -d postgres -v ON_ERROR_STOP=1 -f - < tests/v0.43.2.sql
run_test 'M54 compatibility corpus on 0.43.2' docker compose -p "$project" exec -T postgres \
  psql -XAtq -U postgres -d postgres -v ON_ERROR_STOP=1 -f - < tests/m54.sql

if [[ $profile = complete ]]; then
  export COMPOSE_PROJECT_NAME=$upgrade_project
  export PG_REACT_INIT_VERSION=0.43.1
  docker compose -p "$upgrade_project" up -d --no-build >/dev/null 2>&1
  wait_for_version 0.43.1
  run_test '0.43.1 to 0.43.2 adjacent upgrade' docker compose -p "$upgrade_project" exec -T postgres \
    psql -XAtq -U postgres -d postgres -v ON_ERROR_STOP=1 -c \
    "ALTER EXTENSION pg_react UPDATE TO '0.43.2';"
  run_test '0.43.2 upgraded SQL corpus' docker compose -p "$upgrade_project" exec -T postgres \
    psql -XAtq -U postgres -d postgres -v ON_ERROR_STOP=1 -f - < tests/v0.43.2.sql
fi

echo "0.43.2 $profile candidate Docker lane passed for $image"
