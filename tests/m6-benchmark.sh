#!/usr/bin/env bash
set -euo pipefail

image=${1:-pg-react:v0.3.0}
export PG_REACT_IMAGE=$image
export PG_REACT_PLATFORM=linux/amd64
export PG_REACT_PORT_BINDING=${PG_REACT_PORT_BINDING:-127.0.0.1::5432}
export COMPOSE_PROJECT_NAME=${M6_BENCHMARK_PROJECT_NAME:-pgreact-m6-benchmark-${GITHUB_RUN_ID:-$$}}
test_log_dir=$(mktemp -d)

cleanup() {
  docker compose down --volumes --remove-orphans >/dev/null 2>&1 || true
  rm -r -- "$test_log_dir"
}
trap cleanup EXIT

scalar() {
  docker compose exec -T postgres psql -X -A -t -U postgres -d "$1" -c "$2"
}

median() {
  printf '%s\n' "$@" | sort -n | sed -n '3p'
}

durable_sql="SELECT COALESCE(sum(pg_total_relation_size(c.oid)), 0)
FROM pg_catalog.pg_class c
JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname IN ('pgreact_internal', 'pgreact_runtime')
  AND c.relkind IN ('r', 'p', 'm')"
normalized_sql="SELECT jsonb_build_object(
  'activations', (SELECT jsonb_agg(
      to_jsonb(a) - ARRAY['rule_version_id','activation_id','first_seen_at','last_seen_at','deactivated_at']
      ORDER BY semantic_key) FROM pgreact.activations a),
  'lifecycle_events', (SELECT jsonb_agg(
      to_jsonb(e) - ARRAY[
        'rule_id','rule_version_id','activation_id','idempotency_key','transitioned_at','transition_xid'
      ]
      ORDER BY event_id) FROM pgreact_internal.lifecycle_events e),
  'episodes', (SELECT jsonb_agg(jsonb_build_object(
      'episode_id', episode_id, 'activation_generation', activation_generation,
      'activation_revision', activation_revision, 'event_kind', event_kind,
      'state', state, 'attempt_count', attempt_count
    ) ORDER BY episode_id) FROM pgreact.episodes),
  'attempts', (SELECT jsonb_agg(jsonb_build_object(
      'episode_id', episode_id, 'attempt_no', attempt_no, 'status', status,
      'error_code', error_code, 'error_message', error_message, 'event_kind', event_kind
    ) ORDER BY episode_id, attempt_no) FROM pgreact.attempts),
  'effects', (SELECT jsonb_agg(to_jsonb(e) ORDER BY episode_id) FROM m6_entry.effects e)
)"

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

docker compose exec -T postgres createdb -U postgres m6_baseline_template
docker compose exec -T postgres createdb -U postgres m6_candidate_template
docker compose cp tests/m6-entry.sql postgres:/tmp/m6-entry.sql >/dev/null 2>&1
docker compose cp tests/m6-benchmark.sql postgres:/tmp/m6-benchmark.sql >/dev/null 2>&1
docker compose cp tests/m6-entry-single.pgbench postgres:/tmp/m6-single.pgbench >/dev/null 2>&1
docker compose cp tests/m6-benchmark-batch.pgbench postgres:/tmp/m6-batch.pgbench >/dev/null 2>&1
if ! docker compose exec -T postgres psql -X -U postgres -d m6_baseline_template \
    -v ON_ERROR_STOP=1 -f /tmp/m6-entry.sql >"$test_log_dir/baseline-setup.log" 2>&1; then
  sed -n '1,$p' "$test_log_dir/baseline-setup.log"
  exit 1
fi
candidate_setup_before=$(scalar postgres 'SELECT pg_current_wal_lsn()')
if ! docker compose exec -T postgres psql -X -U postgres -d m6_candidate_template \
    -v ON_ERROR_STOP=1 -f /tmp/m6-benchmark.sql >"$test_log_dir/candidate-setup.log" 2>&1; then
  sed -n '1,$p' "$test_log_dir/candidate-setup.log"
  exit 1
fi
candidate_setup_after=$(scalar postgres 'SELECT pg_current_wal_lsn()')
candidate_setup_wal=$(scalar postgres "SELECT pg_wal_lsn_diff('$candidate_setup_after', '$candidate_setup_before')::bigint")
for template in m6_baseline_template m6_candidate_template; do
  docker compose exec -T postgres psql -X -U postgres -d postgres -v ON_ERROR_STOP=1 -c \
    "ALTER DATABASE $template ALLOW_CONNECTIONS false; SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$template'" >/dev/null
done

baseline_tps=()
single_tps=()
batch_tps=()
single_wal=()
batch_wal=()
single_durable=()
batch_durable=()
normalized_identical=true

for sample in {1..5}; do
  baseline_db="m6_baseline_$sample"
  single_db="m6_single_$sample"
  batch_db="m6_batch_$sample"
  docker compose exec -T postgres createdb -U postgres -T m6_baseline_template "$baseline_db"
  docker compose exec -T postgres createdb -U postgres -T m6_candidate_template "$single_db"
  docker compose exec -T postgres createdb -U postgres -T m6_candidate_template "$batch_db"

  baseline_before=$(scalar "$baseline_db" 'SELECT pg_current_wal_lsn()')
  docker compose exec -T postgres pgbench -n -U postgres -d "$baseline_db" \
    -c 1 -j 1 -t 4096 -f /tmp/m6-single.pgbench >"$test_log_dir/baseline-$sample.log" 2>&1
  baseline_after=$(scalar "$baseline_db" 'SELECT pg_current_wal_lsn()')
  test "$(scalar "$baseline_db" "SELECT pg_wal_lsn_diff('$baseline_after', '$baseline_before') > 0")" = t

  single_before_lsn=$(scalar "$single_db" 'SELECT pg_current_wal_lsn()')
  single_before_bytes=$(scalar "$single_db" "$durable_sql")
  docker compose exec -T postgres pgbench -n -U postgres -d "$single_db" \
    -c 1 -j 1 -t 4096 -f /tmp/m6-single.pgbench >"$test_log_dir/single-$sample.log" 2>&1
  single_after_lsn=$(scalar "$single_db" 'SELECT pg_current_wal_lsn()')
  single_after_bytes=$(scalar "$single_db" "$durable_sql")

  batch_before_lsn=$(scalar "$batch_db" 'SELECT pg_current_wal_lsn()')
  batch_before_bytes=$(scalar "$batch_db" "$durable_sql")
  docker compose exec -T postgres pgbench -n -U postgres -d "$batch_db" \
    -c 1 -j 1 -t 128 -f /tmp/m6-batch.pgbench >"$test_log_dir/batch-$sample.log" 2>&1
  batch_after_lsn=$(scalar "$batch_db" 'SELECT pg_current_wal_lsn()')
  batch_after_bytes=$(scalar "$batch_db" "$durable_sql")

  baseline_tps+=("$(sed -n 's/^tps = \([0-9.]*\) (without initial connection time)$/\1/p' "$test_log_dir/baseline-$sample.log")")
  single_tps+=("$(sed -n 's/^tps = \([0-9.]*\) (without initial connection time)$/\1/p' "$test_log_dir/single-$sample.log")")
  batch_tps+=("$(awk -v tps="$(sed -n 's/^tps = \([0-9.]*\) (without initial connection time)$/\1/p' "$test_log_dir/batch-$sample.log")" 'BEGIN { printf "%.6f", tps * 32 }')")
  single_wal+=("$(scalar "$single_db" "SELECT pg_wal_lsn_diff('$single_after_lsn', '$single_before_lsn')::bigint")")
  batch_wal+=("$(scalar "$batch_db" "SELECT pg_wal_lsn_diff('$batch_after_lsn', '$batch_before_lsn')::bigint")")
  test "$single_after_bytes" -gt "$single_before_bytes"
  test "$batch_after_bytes" -gt "$batch_before_bytes"
  single_durable+=("$single_after_bytes")
  batch_durable+=("$batch_after_bytes")

  baseline_state=$(scalar "$baseline_db" "$normalized_sql")
  single_state=$(scalar "$single_db" "$normalized_sql")
  batch_state=$(scalar "$batch_db" "$normalized_sql")
  if test "$baseline_state" != "$single_state" || test "$single_state" != "$batch_state"; then
    normalized_identical=false
  fi
done

baseline_median=$(median "${baseline_tps[@]}")
single_median=$(median "${single_tps[@]}")
batch_median=$(median "${batch_tps[@]}")
single_wal_median=$(median "${single_wal[@]}")
batch_wal_median=$(median "${batch_wal[@]}")
single_durable_median=$(median "${single_durable[@]}")
batch_durable_median=$(median "${batch_durable[@]}")
speedup=$(awk -v batch="$batch_median" -v single="$single_median" 'BEGIN { printf "%.2f", batch / single }')
regression=$(awk -v candidate="$single_median" -v baseline="$baseline_median" 'BEGIN { printf "%.3f", candidate / baseline }')
single_wal_total=$((candidate_setup_wal + single_wal_median))
batch_wal_total=$((candidate_setup_wal + batch_wal_median))
wal_ratio=$(awk -v batch="$batch_wal_total" -v single="$single_wal_total" 'BEGIN { printf "%.3f", batch / single }')
durable_ratio=$(awk -v batch="$batch_durable_median" -v single="$single_durable_median" 'BEGIN { printf "%.3f", batch / single }')
single_wal_per_episode=$(awk -v bytes="$single_wal_total" 'BEGIN { printf "%.2f", bytes / 4096 }')
batch_wal_per_episode=$(awk -v bytes="$batch_wal_total" 'BEGIN { printf "%.2f", bytes / 4096 }')
single_durable_per_episode=$(awk -v bytes="$single_durable_median" 'BEGIN { printf "%.2f", bytes / 4096 }')
batch_durable_per_episode=$(awk -v bytes="$batch_durable_median" 'BEGIN { printf "%.2f", bytes / 4096 }')

printf 'baseline_0_2_single_episode_tps_median=%s\n' "$baseline_median"
printf 'candidate_0_3_single_episode_tps_median=%s\n' "$single_median"
printf 'audited_batch_episode_tps_median=%s\n' "$batch_median"
printf 'audited_batch_speedup=%sx\n' "$speedup"
printf 'protocol_1_regression_ratio=%s\n' "$regression"
printf 'single_wal_bytes_per_episode=%s\n' "$single_wal_per_episode"
printf 'batch_wal_bytes_per_episode=%s\n' "$batch_wal_per_episode"
printf 'batch_to_single_wal_ratio=%s\n' "$wal_ratio"
printf 'single_durable_bytes_per_episode=%s\n' "$single_durable_per_episode"
printf 'batch_durable_bytes_per_episode=%s\n' "$batch_durable_per_episode"
printf 'batch_to_single_durable_ratio=%s\n' "$durable_ratio"
printf 'normalized_state_identical=%s\n' "$normalized_identical"
printf 'connections_per_benchmark_worker=1\n'

awk -v measured="$speedup" 'BEGIN { exit !(measured >= 1.5) }'
awk -v measured="$regression" 'BEGIN { exit !(measured >= 0.95) }'
awk -v measured="$wal_ratio" 'BEGIN { exit !(measured <= 1.25) }'
awk -v measured="$durable_ratio" 'BEGIN { exit !(measured <= 1.25) }'
test "$normalized_identical" = true
