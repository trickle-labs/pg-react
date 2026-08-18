#!/usr/bin/env bash
set -euo pipefail

# Standalone hook: rtk run "bash tests/m31-race.sh pg-react:m31-unreleased"
# Existing M31 compose DB: M31_RACE_REUSE_COMPOSE=true COMPOSE_PROJECT_NAME=... rtk run "bash tests/m31-race.sh pg-react:m31-unreleased"
image=${1:-pg-react:m31-unreleased}
reuse=${M31_RACE_REUSE_COMPOSE:-false}
if [[ $reuse = true ]]; then
  project=${COMPOSE_PROJECT_NAME:?COMPOSE_PROJECT_NAME is required when reusing Compose}
else
  project=${COMPOSE_PROJECT_NAME:-pgreact-m31-race-${GITHUB_RUN_ID:-$$}}
  [[ -z ${COMPOSE_PROJECT_NAME:-} ]] || project="${project}-race"
fi
log_dir=$(mktemp -d)
if command -v rtk >/dev/null 2>&1; then
  compose=(rtk docker compose)
  docker_inspect=(rtk docker inspect)
else
  compose=(docker compose)
  docker_inspect=(docker inspect)
fi

cleanup() {
  if [[ $reuse != true ]]; then
    COMPOSE_PROJECT_NAME=$project "${compose[@]}" down --volumes --remove-orphans >/dev/null 2>&1 || true
  fi
  rm -r -- "$log_dir"
}
trap cleanup EXIT

export COMPOSE_PROJECT_NAME=$project
export PG_REACT_IMAGE=$image
export PG_REACT_INIT_VERSION=0.28.0
export PG_REACT_PLATFORM=linux/amd64
export PG_REACT_PORT_BINDING=${PG_REACT_PORT_BINDING:-127.0.0.1::5432}
export PG_REACT_POLL_INTERVAL_MS=60000
export PG_REACT_BATCH_SIZE=1000

run_phase() {
  local phase=$1
  "${compose[@]}" exec -T postgres psql -XAtq -U postgres -d postgres \
    -v ON_ERROR_STOP=1 -v "phase=$phase" -f /tmp/m31-race.sql
}

wait_for_marker() {
  local log=$1
  local marker=$2
  for _ in {1..150}; do
    if grep -Fq "$marker" "$log"; then
      return 0
    fi
    sleep 0.1
  done
  sed -n '1,$p' "$log"
  echo "M31 race marker timed out: $marker" >&2
  return 1
}

wait_for_actor() {
  local pid=$1
  local log=$2
  if wait "$pid"; then
    return 0
  fi
  sed -n '1,$p' "$log"
  return 1
}

if [[ $reuse != true ]]; then
  "${compose[@]}" up -d --no-build >/dev/null 2>&1
  ready=false
  for _ in {1..120}; do
    container_state=$("${docker_inspect[@]}" --format '{{.State.Status}}' "${project}-postgres-1" 2>/dev/null || true)
    if [[ $container_state = exited || $container_state = dead ]]; then
      "${compose[@]}" logs --no-color postgres >&2 || true
      exit 1
    fi
    if [[ $("${docker_inspect[@]}" --format '{{.State.Health.Status}}' "${project}-postgres-1" 2>/dev/null || true) = healthy ]] &&
       "${compose[@]}" exec -T postgres psql -XAtq -U postgres -d postgres -c \
         "SELECT extversion='0.28.0' FROM pg_extension WHERE extname='pg_react'" \
         2>/dev/null | grep -qx t; then
      ready=true
      break
    fi
    sleep 1
  done
  test "$ready" = true
fi
"${compose[@]}" cp tests/m31-race.sql postgres:/tmp/m31-race.sql >/dev/null

run_phase setup >"$log_dir/setup.log" 2>&1 || { sed -n '1,$p' "$log_dir/setup.log"; exit 1; }

run_phase withdraw-worker >"$log_dir/withdraw-worker.log" 2>&1 &
withdraw_worker_pid=$!
wait_for_marker "$log_dir/withdraw-worker.log" M31_RACE_WITHDRAW_CLAIMED
run_phase withdraw-mutator >"$log_dir/withdraw-mutator.log" 2>&1 || {
  sed -n '1,$p' "$log_dir/withdraw-mutator.log"
  exit 1
}
wait_for_actor "$withdraw_worker_pid" "$log_dir/withdraw-worker.log"

run_phase lease-worker >"$log_dir/lease-worker.log" 2>&1 &
lease_worker_pid=$!
wait_for_marker "$log_dir/lease-worker.log" M31_RACE_LEASE_CLAIMED
run_phase lease-mutator >"$log_dir/lease-mutator.log" 2>&1 || {
  sed -n '1,$p' "$log_dir/lease-mutator.log"
  exit 1
}
wait_for_actor "$lease_worker_pid" "$log_dir/lease-worker.log"

run_phase verify >"$log_dir/verify.log" 2>&1 || {
  sed -n '1,$p' "$log_dir/verify.log"
  exit 1
}

echo "M31 two-session race/lease qualification passed for $image (linux/amd64)"
