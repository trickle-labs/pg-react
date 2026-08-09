#!/usr/bin/env bash
set -euo pipefail

image=${1:-pg-react:v0.2.0}
export PG_REACT_IMAGE=$image
export PG_REACT_PLATFORM=linux/amd64
export PG_REACT_PORT_BINDING=${PG_REACT_PORT_BINDING:-127.0.0.1::5432}
export COMPOSE_PROJECT_NAME=${COMPOSE_PROJECT_NAME:-pgreact-m6-entry-${GITHUB_RUN_ID:-$$}}
test_log_dir=$(mktemp -d)

cleanup() {
  docker compose down --volumes --remove-orphans >/dev/null 2>&1 || true
  rm -r -- "$test_log_dir"
}
trap cleanup EXIT

docker build --platform "$PG_REACT_PLATFORM" --tag "$image" . >/dev/null 2>&1
docker compose up -d --no-build >/dev/null 2>&1

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

docker compose exec -T postgres createdb -U postgres m6_entry_template
docker compose cp tests/m6-entry.sql postgres:/tmp/m6-entry.sql >/dev/null 2>&1
if ! docker compose exec -T postgres psql -X -U postgres -d m6_entry_template \
    -v ON_ERROR_STOP=1 -f /tmp/m6-entry.sql >"$test_log_dir/setup.log" 2>&1; then
  sed -n '1,$p' "$test_log_dir/setup.log"
  exit 1
fi
docker compose exec -T postgres psql -X -U postgres -d postgres -v ON_ERROR_STOP=1 -c \
  "ALTER DATABASE m6_entry_template ALLOW_CONNECTIONS false; SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = 'm6_entry_template'" >/dev/null
for database in m6_entry_single m6_entry_batch; do
  docker compose exec -T postgres createdb -U postgres -T m6_entry_template "$database"
done

docker compose cp tests/m6-entry-single.pgbench postgres:/tmp/m6-entry-single.pgbench >/dev/null 2>&1
docker compose cp tests/m6-entry-batch.pgbench postgres:/tmp/m6-entry-batch.pgbench >/dev/null 2>&1

docker compose exec -T postgres pgbench -n -U postgres -d m6_entry_single \
  -c 1 -j 1 -t 4096 -f /tmp/m6-entry-single.pgbench >"$test_log_dir/single.log" 2>&1
docker compose exec -T postgres pgbench -n -U postgres -d m6_entry_batch \
  -c 1 -j 1 -t 128 -f /tmp/m6-entry-batch.pgbench >"$test_log_dir/batch.log" 2>&1

single_tps=$(sed -n 's/^tps = \([0-9.]*\) (without initial connection time)$/\1/p' "$test_log_dir/single.log")
batch_tps=$(sed -n 's/^tps = \([0-9.]*\) (without initial connection time)$/\1/p' "$test_log_dir/batch.log")
test -n "$single_tps"
test -n "$batch_tps"

expected_effects=$(docker compose exec -T postgres psql -X -U postgres -d m6_entry_single -Atc \
  "SELECT jsonb_agg(jsonb_build_array(id, id) ORDER BY id) FROM generate_series(1, 4096) AS id")
single_effects=$(docker compose exec -T postgres psql -X -U postgres -d m6_entry_single -Atc \
  "SELECT jsonb_agg(jsonb_build_array(episode_id, fact_id) ORDER BY episode_id) FROM m6_entry.effects")
batch_effects=$(docker compose exec -T postgres psql -X -U postgres -d m6_entry_batch -Atc \
  "SELECT jsonb_agg(jsonb_build_array(episode_id, fact_id) ORDER BY episode_id) FROM m6_entry.effects")
test "$single_effects" = "$expected_effects"
test "$batch_effects" = "$expected_effects"

single_episode_tps=$single_tps
batch_episode_tps=$(awk -v tps="$batch_tps" 'BEGIN { printf "%.2f", tps * 32 }')
speedup=$(awk -v single="$single_episode_tps" -v batch="$batch_episode_tps" 'BEGIN { printf "%.2f", batch / single }')
refresh_milliseconds=$(docker compose exec -T postgres psql -X -U postgres -d m6_entry_single -Atc \
  "SELECT refresh_milliseconds FROM m6_entry.benchmark")
refresh_episode_milliseconds=$(awk -v elapsed="$refresh_milliseconds" 'BEGIN { printf "%.2f", elapsed / 8192 }')
single_episode_milliseconds=$(awk -v tps="$single_episode_tps" 'BEGIN { printf "%.2f", 1000 / tps }')
material=$(awk -v measured="$speedup" -v execution="$single_episode_milliseconds" -v refresh="$refresh_episode_milliseconds" \
  'BEGIN { print (measured >= 1.5 && execution > refresh ? "true" : "false") }')

printf 'single_episode_tps=%s\n' "$single_episode_tps"
printf 'prototype_batch_episode_tps=%s\n' "$batch_episode_tps"
printf 'prototype_speedup=%sx\n' "$speedup"
printf 'match_maintenance_ms_per_episode=%s\n' "$refresh_episode_milliseconds"
printf 'single_execution_ms_per_episode=%s\n' "$single_episode_milliseconds"
printf 'per_episode_overhead_is_material=%s\n' "$material"
test "$material" = true
