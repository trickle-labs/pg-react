#!/usr/bin/env bash
set -euo pipefail

profile=${1:-fast}
image=${2:-pg-react:v0.16.0}
case "$profile" in fast|complete) ;; *) echo 'usage: tests/m19.sh fast|complete [IMAGE]' >&2; exit 2 ;; esac

project=${COMPOSE_PROJECT_NAME:-pgreact-m19-${GITHUB_RUN_ID:-$$}}
upgrade_project=${project}-upgrade
test_log_dir=$(mktemp -d)

cleanup() {
  COMPOSE_PROJECT_NAME=$project docker compose down --volumes --remove-orphans >/dev/null 2>&1 || true
  COMPOSE_PROJECT_NAME=$upgrade_project docker compose down --volumes --remove-orphans >/dev/null 2>&1 || true
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

wait_for_version() {
  local compose_project=$1 expected=$2
  local container="${compose_project}-postgres-1"
  for _ in {1..120}; do
    if [[ $(docker inspect --format '{{.State.Health.Status}}' "$container" 2>/dev/null || true) = healthy ]] &&
       COMPOSE_PROJECT_NAME=$compose_project docker compose exec -T postgres \
      psql -XAtq -U postgres -d postgres -c \
      "SELECT extversion='$expected' FROM pg_extension WHERE extname='pg_react'" \
      2>/dev/null | grep -qx t; then return; fi
    sleep 1
  done
  return 1
}

docs_audit() {
  grep -Fq 'pg-react M19 is extension `0.16.0`' README.md
  grep -Fq 'tests/m19.sh fast pg-react:v0.16.0' docs/m19-evidence.md
  grep -Fq '0.15.0 -> 0.16.0' docs/m19-upgrade.md
  grep -Fq 'M20 — Shared conditions' docs/m19-readiness.md
  ! grep -R -E 'M19 is (ready|complete)\.' README.md docs --include='*.md'
}

release_audit() {
  grep -qx 'version = "0.16.0"' Cargo.toml
  grep -qx "default_version = '0.16.0'" pg_react.control
  grep -Fq "extversion = '0.16.0'" src/managed.rs
  test -s sql/pg_react--0.15.0.sql
  test -s sql/pg_react--0.15.0--0.16.0.sql
  test -s sql/pg_react--0.16.0.sql
  test "$(grep -R -E '^\s*(- )?uses:' .github/workflows | wc -l | tr -d ' ')" = \
    "$(grep -R -E '^\s*(- )?uses: [^@]+@[0-9a-f]{40}$' .github/workflows | wc -l | tr -d ' ')"
  grep -R -Fq 'toolchain: 1.89.0' .github/workflows
  grep -Fq 'contents: read' .github/workflows/ci.yml
  bash -n tests/m19.sh
  jq -e '.target_version == "0.16.0" and .direct_upgrade == "0.15.0 -> 0.16.0"' \
    tests/fixtures/m19/release-state.json >/dev/null
}

run_test 'M19 documentation audit' docs_audit
run_test 'M19 release identity audit' release_audit

export PG_REACT_IMAGE=$image
export PG_REACT_PLATFORM=linux/amd64
export PG_REACT_PORT_BINDING=${PG_REACT_PORT_BINDING:-127.0.0.1::5432}
export PG_REACT_POLL_INTERVAL_MS=60000
export PG_REACT_BATCH_SIZE=1000
export COMPOSE_PROJECT_NAME=$project
docker compose up -d --no-build >/dev/null 2>&1
wait_for_version "$project" 0.16.0
docker compose cp tests/m19-immediate.sql postgres:/tmp/m19-immediate.sql >/dev/null
run_test 'M19 immediate public correctness and rollback' \
  docker compose exec -T postgres psql -XAtq -U postgres -d postgres \
  -v ON_ERROR_STOP=1 -f /tmp/m19-immediate.sql

if [[ $profile = complete ]]; then
  export COMPOSE_PROJECT_NAME=$upgrade_project
  export PG_REACT_INIT_VERSION=0.15.0
  docker compose up -d --no-build >/dev/null 2>&1
  wait_for_version "$upgrade_project" 0.15.0
  docker compose cp tests/m19-upgrade-before.sql postgres:/tmp/m19-upgrade-before.sql >/dev/null
  docker compose cp tests/m19-upgrade-after.sql postgres:/tmp/m19-upgrade-after.sql >/dev/null
  run_test 'M19 populated direct-upgrade setup' \
    docker compose exec -T postgres psql -XAtq -U postgres -d postgres \
    -v ON_ERROR_STOP=1 -f /tmp/m19-upgrade-before.sql
  run_test 'M19 direct 0.15.0 to 0.16.0 upgrade' \
    docker compose exec -T postgres psql -XAtq -U postgres -d postgres \
    -v ON_ERROR_STOP=1 -c "ALTER EXTENSION pg_react UPDATE TO '0.16.0';" \
    -f /tmp/m19-upgrade-after.sql
fi

echo "M19 $profile evidence gate passed for $image (linux/amd64)"
