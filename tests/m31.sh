#!/usr/bin/env bash
set -euo pipefail

profile=${1:-fast}
image=${2:-pg-react:m31-unreleased}
case "$profile" in fast|complete) ;; *) echo 'usage: tests/m31.sh fast|complete [IMAGE]' >&2; exit 2 ;; esac

project=${COMPOSE_PROJECT_NAME:-pgreact-m31-${GITHUB_RUN_ID:-$$}}
upgrade_project=${project}-upgrade
m30_image=${M30_INHERITED_IMAGE:-pg-react:v0.27.0}
artifact_dir=${M31_ARTIFACT_DIR:-}
log_dir=$(mktemp -d)
cleanup() {
  COMPOSE_PROJECT_NAME=$project docker compose down --volumes --remove-orphans >/dev/null 2>&1 || true
  COMPOSE_PROJECT_NAME=$upgrade_project docker compose down --volumes --remove-orphans >/dev/null 2>&1 || true
  rm -r -- "$log_dir"
}
trap cleanup EXIT

run_test() {
  local name=$1; shift
  local log="$log_dir/${name// /-}.log"
  if "$@" >"$log" 2>&1; then echo "$name passed"; else sed -n '1,$p' "$log"; return 1; fi
}

docs_audit() {
  test -s docs/m31-contract.md &&
    test -s docs/m31-api-reference.md &&
    test -s docs/m31-migration.md &&
    grep -Fq 'M31 — Authoritative runtime' docs/m31-release-notes.md &&
    grep -Fq 'M32' docs/m31-readiness.md &&
    jq -e '.milestone == "M31" and .extension_version == "0.28.0"' docs/m31-api-inventory.json >/dev/null
}

release_audit() {
  grep -qx 'version = "0.28.0"' Cargo.toml &&
    sed -n '/name = "pg_react"/,+1p' Cargo.lock | grep -qx 'version = "0.28.0"' &&
    grep -qx "default_version = '0.28.0'" pg_react.control &&
    grep -Fq "extversion = '0.28.0'" src/managed.rs &&
    grep -Fq 'PG_REACT_INIT_VERSION=0.28.0' Dockerfile &&
    grep -Fq 'PG_REACT_INIT_VERSION:-0.28.0' docker-compose.yml &&
    test -s sql/pg_react--0.27.0.sql &&
    test -s sql/pg_react--0.27.0--0.28.0.sql &&
    test -s sql/pg_react--0.28.0.sql &&
    cmp sql/pg_react--0.27.0--0.28.0.sql sql/m31.sql &&
    cmp sql/pg_react--0.28.0.sql <(cat sql/pg_react--0.27.0.sql; printf '\n'; cat sql/m31.sql) &&
    test -s sql/m31.sql && test -s tests/m31.sql && test -s tests/m31-work.sql &&
    test -s tests/m31-security.sql &&
    test -s tests/m31-authorization.sql &&
    test -s tests/m31-performance.sql &&
    test -s tests/m31-retention.sql &&
    test -s tests/m31-race.sql &&
    test -s tests/m31-logical-schema.sql &&
    test -s tests/m31-logical-restore.sql &&
    test -s tests/m31-upgrade-after.sql &&
    test -s tests/m31-recovery-setup.sql &&
    test -s tests/m31-recovery-restart.sql &&
    test -s tests/m31-recovery-restore.sql &&
    bash -n tests/m31.sh &&
    grep -Fq 'M31 authoritative runtime' sql/pg_react--0.27.0--0.28.0.sql &&
    grep -Fq 'M31 authoritative runtime' sql/pg_react--0.28.0.sql &&
    ! grep -Fq 'M31 authoritative runtime' sql/pg_react--0.27.0.sql &&
    ! grep -Fq 'M31 authoritative runtime' sql/pg_react--0.26.0--0.27.0.sql &&
    git diff --quiet HEAD -- sql/pg_react--0.26.0--0.27.0.sql sql/pg_react--0.27.0.sql
}

run_test 'M31 documentation audit' docs_audit
run_test 'M31 release identity audit' release_audit

export PG_REACT_IMAGE=$image
export PG_REACT_INIT_VERSION=0.28.0
export PG_REACT_PLATFORM=linux/amd64
export PG_REACT_PORT_BINDING=${PG_REACT_PORT_BINDING:-127.0.0.1::5432}
export PG_REACT_POLL_INTERVAL_MS=60000
export PG_REACT_BATCH_SIZE=1000
export COMPOSE_PROJECT_NAME=$project
docker compose up -d --no-build >/dev/null 2>&1
for _ in {1..120}; do
  if [[ $(docker inspect --format '{{.State.Health.Status}}' "${project}-postgres-1" 2>/dev/null || true) = healthy ]] &&
     docker compose exec -T postgres psql -XAtq -U postgres -d postgres -c \
       "SELECT extversion='0.28.0' FROM pg_extension WHERE extname='pg_react'" 2>/dev/null | grep -qx t; then break; fi
  sleep 1
done
docker compose cp tests/m31.sql postgres:/tmp/m31.sql >/dev/null
run_test 'M31 authoritative runtime' \
  docker compose exec -T postgres psql -XAtq -U postgres -d postgres -v ON_ERROR_STOP=1 -f /tmp/m31.sql
docker compose cp tests/m31-work.sql postgres:/tmp/m31-work.sql >/dev/null
run_test 'M31 claimed-work revalidation' \
  docker compose exec -T postgres psql -XAtq -U postgres -d postgres -v ON_ERROR_STOP=1 -f /tmp/m31-work.sql
docker compose cp tests/m31-security.sql postgres:/tmp/m31-security.sql >/dev/null
run_test 'M31 security role isolation' \
  docker compose exec -T postgres psql -XAtq -U postgres -d postgres -v ON_ERROR_STOP=1 -f /tmp/m31-security.sql

for fixture in m31-authorization m31-performance m31-retention; do
  docker compose cp "tests/${fixture}.sql" "postgres:/tmp/${fixture}.sql" >/dev/null
done
run_test 'M31 authorization and protected-source matrix' \
  docker compose exec -T postgres psql -XAtq -U postgres -d postgres -v ON_ERROR_STOP=1 -f /tmp/m31-authorization.sql
run_test 'M31 bounded performance workload' \
  docker compose exec -T postgres psql -XAtq -U postgres -d postgres -v ON_ERROR_STOP=1 -f /tmp/m31-performance.sql
run_test 'M31 retention interaction' \
  docker compose exec -T postgres psql -XAtq -U postgres -d postgres -v ON_ERROR_STOP=1 -f /tmp/m31-retention.sql

if [[ $profile = complete ]]; then
  run_test 'M31 two-session race and lease qualification' \
    bash tests/m31-race.sh "$image"
  COMPOSE_PROJECT_NAME="${project}-m30" M30_INHERITED_IMAGE="$m30_image" \
    bash tests/m30.sh complete "$m30_image"
  export COMPOSE_PROJECT_NAME=$upgrade_project
  export PG_REACT_IMAGE=$image
  export PG_REACT_INIT_VERSION=0.26.0
  docker compose up -d --no-build >/dev/null 2>&1
  for _ in {1..120}; do
    if [[ $(docker inspect --format '{{.State.Health.Status}}' "${upgrade_project}-postgres-1" 2>/dev/null || true) = healthy ]] &&
       docker compose exec -T postgres psql -XAtq -U postgres -d postgres -c \
         "SELECT extversion='0.26.0' FROM pg_extension WHERE extname='pg_react'" 2>/dev/null | grep -qx t; then break; fi
    sleep 1
  done
  docker compose cp tests/m30-upgrade-before.sql postgres:/tmp/m30-upgrade-before.sql >/dev/null
  docker compose cp tests/m30-upgrade-after.sql postgres:/tmp/m30-upgrade-after.sql >/dev/null
  docker compose cp tests/m31-upgrade-after.sql postgres:/tmp/m31-upgrade-after.sql >/dev/null
  run_test 'M31 populated staged-upgrade setup' \
    docker compose exec -T postgres psql -XAtq -U postgres -d postgres -v ON_ERROR_STOP=1 -f /tmp/m30-upgrade-before.sql
  run_test 'M31 direct 0.26.0 to 0.27.0 upgrade' \
    docker compose exec -T postgres psql -XAtq -U postgres -d postgres -v ON_ERROR_STOP=1 -c \
    "ALTER EXTENSION pg_react UPDATE TO '0.27.0';"
  run_test 'M31 M30 state preserved' \
    docker compose exec -T postgres psql -XAtq -U postgres -d postgres -v ON_ERROR_STOP=1 -f /tmp/m30-upgrade-after.sql
  run_test 'M31 direct 0.27.0 to 0.28.0 upgrade' \
    docker compose exec -T postgres psql -XAtq -U postgres -d postgres -v ON_ERROR_STOP=1 -c \
    "ALTER EXTENSION pg_react UPDATE TO '0.28.0';"
  run_test 'M31 populated upgrade preserved' \
    docker compose exec -T postgres psql -XAtq -U postgres -d postgres -v ON_ERROR_STOP=1 -f /tmp/m31-upgrade-after.sql
  run_test 'M31 crash restart and physical recovery' env \
    RECOVERY_MILESTONE=m31 M31_RECOVERY_ARTIFACT="$log_dir/m31-recovery.json" \
    bash tests/m6-recovery.sh
  test -s "$log_dir/m31-recovery.json"
  jq -e '.logical_restore_ms >= 0 and .physical_restore_ms >= 0' \
    "$log_dir/m31-recovery.json" >/dev/null
fi

if [[ -n $artifact_dir ]]; then
  mkdir -p -- "$artifact_dir"
  cp -- "$log_dir"/*.log docs/m31-evidence.md docs/m31-readiness.md \
    docs/m31-release-notes.md "$artifact_dir"/
fi

echo "M31 $profile evidence gate passed for $image (linux/amd64)"
