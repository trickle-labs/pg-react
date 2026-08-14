#!/usr/bin/env bash
set -euo pipefail

name=${1:?usage: tests/m18-benchmark-case.sh CASE_NAME}
database=${M18_BENCHMARK_DB:?M18_BENCHMARK_DB must name the running benchmark database}
project=${COMPOSE_PROJECT_NAME:?COMPOSE_PROJECT_NAME must identify the running M18 compose project}
if [[ ! $database =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ || $database =~ ^(postgres|template0|template1)$ ]]; then
  printf 'unsafe M18_BENCHMARK_DB: %s\n' "$database" >&2
  exit 2
fi
if [[ $name =~ ^rules-(1|10|100|1000)-facts-(1e3|1e5|1e6)-updates-(1|100|10000)-workers-(1|4)-windows-(1e3|1e5)-watermark-(0|1e3|1e5)$ ]]; then
  rules=${BASH_REMATCH[1]}; facts=${BASH_REMATCH[2]}; updates=${BASH_REMATCH[3]}
  workers=${BASH_REMATCH[4]}; windows=${BASH_REMATCH[5]}; watermark=${BASH_REMATCH[6]}
else
  printf 'unknown M18 benchmark case: %s\n' "$name" >&2
  exit 2
fi
case $facts in 1e3) facts=1000;; 1e5) facts=100000;; 1e6) facts=1000000;; esac
case $windows in 1e3) windows=1000;; 1e5) windows=100000;; esac
case $watermark in 0) watermark=0;; 1e3) watermark=1000;; 1e5) watermark=100000;; esac
worker_jobs=$((updates > 1000 ? 1000 : updates))
update_samples=$((rules == 1000 ? 1 : 20))

psql_cmd=(docker compose -p "$project" exec -T postgres psql -X -q -A -t -v ON_ERROR_STOP=1 -U postgres -d "$database")
docker compose -p "$project" exec -T postgres dropdb --if-exists --force -U postgres "$database"
docker compose -p "$project" exec -T postgres createdb -U postgres "$database"
"${psql_cmd[@]}" -c 'CREATE EXTENSION pg_trickle; CREATE EXTENSION pg_react' >/dev/null
docker compose -p "$project" cp tests/m18-benchmark-case.sql postgres:/tmp/m18-benchmark-case.sql >/dev/null
docker compose -p "$project" cp tests/m18-benchmark-window.sql postgres:/tmp/m18-benchmark-window.sql >/dev/null
"${psql_cmd[@]}" -v rules="$rules" -v facts="$facts" -v batch="$updates" \
  -v workers="$workers" -v windows="$windows" -v watermark="$watermark" \
  -f /tmp/m18-benchmark-case.sql >/dev/null

memory_bytes() {
  docker compose -p "$project" exec -T postgres sh -c \
    'if test -r /sys/fs/cgroup/memory.peak; then read -r value </sys/fs/cgroup/memory.peak; elif test -r /sys/fs/cgroup/memory.current; then read -r value </sys/fs/cgroup/memory.current; else read -r value </sys/fs/cgroup/memory/memory.max_usage_in_bytes; fi; printf "%s" "$value"'
}
"${psql_cmd[@]}" -c \
  "SET pg_trickle.differential_max_change_ratio=1; INSERT INTO m18_bench.worker_facts VALUES (1,1,1,'1999-01-01 UTC'); SELECT pgreact_api.run_rule('m18.benchmark.command')" >/dev/null
if (( worker_jobs > 1 )); then
  "${psql_cmd[@]}" -c \
    "SET pg_trickle.differential_max_change_ratio=1; INSERT INTO m18_bench.worker_facts SELECT id,1,1,'1999-01-01 UTC' FROM generate_series(2,$worker_jobs) id; SELECT pgreact_api.run_rule('m18.benchmark.command')" >/dev/null
fi
update_commands=()
for ((iteration=1; iteration<=update_samples; iteration++)); do
  update_commands+=(-c "SELECT m18_bench.update_batch($iteration)")
done
"${psql_cmd[@]}" "${update_commands[@]}" >/dev/null

worker_started=$("${psql_cmd[@]}" -c "SELECT extract(epoch FROM clock_timestamp())")
pids=()
for ((worker=1; worker<=workers; worker++)); do
  "${psql_cmd[@]}" -c "SELECT m18_bench.work('worker-$worker')" >/dev/null &
  pids+=("$!")
done
for pid in "${pids[@]}"; do wait "$pid"; done
worker_finished=$("${psql_cmd[@]}" -c "SELECT extract(epoch FROM clock_timestamp())")

window_started=$("${psql_cmd[@]}" -c "SELECT extract(epoch FROM clock_timestamp())")
"${psql_cmd[@]}" -f /tmp/m18-benchmark-window.sql >/dev/null
window_finished=$("${psql_cmd[@]}" -c "SELECT extract(epoch FROM clock_timestamp())")
if (( watermark > 1000 )); then
  "${psql_cmd[@]}" -c "UPDATE m18_bench.window_control SET enabled=false; SELECT pgreact_api.run('2030-01-01 00:02:01 UTC')" >/dev/null
fi
watermark_started=$("${psql_cmd[@]}" -c "SELECT extract(epoch FROM clock_timestamp())")
target=$("${psql_cmd[@]}" -c "SELECT ('2000-01-01 UTC'::timestamptz + $watermark * interval '1 hour' + interval '15 minutes')::text")
passes=$((watermark == 0 ? 1 : (watermark + 999) / 1000 + 1))
"${psql_cmd[@]}" -c "SELECT pgreact_api.request_watermark('m18.benchmark.windows','m18_bench.item_source','occurred_at','$target'); DO \$body\$ BEGIN FOR iteration IN 1..$passes LOOP PERFORM pgreact_api.run('2030-02-01 UTC'::timestamptz + iteration * interval '1 second'); END LOOP; END \$body\$" >/dev/null
watermark_finished=$("${psql_cmd[@]}" -c "SELECT extract(epoch FROM clock_timestamp())")
peak=$(memory_bytes)

metrics=$("${psql_cmd[@]}" -c "WITH s AS (SELECT kind,milliseconds,items FROM m18_bench.samples), w AS (SELECT GREATEST($worker_finished-$worker_started,0.000001) seconds), y AS (SELECT GREATEST(($window_finished-$window_started)*1000,0.001) ms), z AS (SELECT GREATEST(($watermark_finished-$watermark_started)*1000,0.001) ms) SELECT json_build_object('update_throughput',(SELECT sum(items)/(sum(milliseconds)/1000) FROM s WHERE kind='update'),'worker_throughput',(SELECT sum(items)/(SELECT seconds FROM w) FROM s WHERE kind='worker'),'update_p50_ms',(SELECT percentile_cont(.5) WITHIN GROUP (ORDER BY milliseconds) FROM s WHERE kind='update'),'update_p95_ms',(SELECT percentile_cont(.95) WITHIN GROUP (ORDER BY milliseconds) FROM s WHERE kind='update'),'worker_p50_ms',(SELECT percentile_cont(.5) WITHIN GROUP (ORDER BY milliseconds/items) FROM s WHERE kind='worker'),'worker_p95_ms',(SELECT percentile_cont(.95) WITHIN GROUP (ORDER BY milliseconds/items) FROM s WHERE kind='worker'),'window_p50_ms',(SELECT ms FROM y),'window_p95_ms',(SELECT ms FROM y),'watermark_p50_ms',(SELECT ms FROM z),'watermark_p95_ms',(SELECT ms FROM z))")
state=$("${psql_cmd[@]}" -c "
  SET TIME ZONE 'UTC';
  WITH command_jobs AS (
      SELECT count(*) AS n
      FROM pgreact_internal.agenda agenda
      JOIN pgreact_internal.rule_versions version USING (rule_version_id)
      JOIN pgreact_internal.rules rule ON rule.rule_id=agenda.rule_id
      WHERE rule.rule_name='m18.benchmark.command' AND agenda.state='COMPLETED'
  ), wm AS (
      SELECT status,
             (extract(epoch FROM requested_watermark-'2000-01-01 00:15 UTC'::timestamptz)/3600)::bigint requested_hours,
             (extract(epoch FROM complete_watermark-'2000-01-01 00:15 UTC'::timestamptz)/3600)::bigint complete_hours
      FROM pgreact_api.watermark_status('m18.benchmark.windows')
  ), normalized AS (
      SELECT jsonb_build_object(
          'config',(SELECT md5(to_jsonb(config)::text) FROM m18_bench.config),
          'facts',(SELECT md5(COALESCE(jsonb_agg(to_jsonb(fact) ORDER BY id)::text,'[]')) FROM m18_bench.facts fact),
          'rule_facts',(SELECT md5(COALESCE(jsonb_agg(to_jsonb(fact) ORDER BY id)::text,'[]')) FROM m18_bench.rule_facts fact),
          'worker_facts',(SELECT md5(COALESCE(jsonb_agg(to_jsonb(fact) ORDER BY id)::text,'[]')) FROM m18_bench.worker_facts fact),
          'effects',(SELECT md5(COALESCE(jsonb_agg(fact_id ORDER BY fact_id)::text,'[]')) FROM m18_bench.effects),
          'jobs',(SELECT md5(COALESCE(jsonb_agg(jsonb_build_object(
              'rule',rule.rule_name,'state',agenda.state,'new_bindings',agenda.new_bindings,
              'old_bindings',agenda.old_bindings,'event_kind',agenda.event_kind,
              'activation_generation',agenda.activation_generation,
              'activation_revision',agenda.activation_revision,
              'consequence_kind',agenda.consequence_kind,'agenda_group',agenda.agenda_group,
              'salience',agenda.salience,'conflict_key',agenda.conflict_key,
              'attempt_count',agenda.attempt_count,'max_attempts',agenda.max_attempts,
              'last_error',agenda.last_error)
              ORDER BY agenda.new_bindings::text,agenda.event_kind)::text,'[]'))
              FROM pgreact_internal.agenda agenda
              JOIN pgreact_internal.rule_versions version USING (rule_version_id)
              JOIN pgreact_internal.rules rule ON rule.rule_id=agenda.rule_id
              WHERE rule.rule_name='m18.benchmark.command'),
          'windows',(SELECT md5(COALESCE(jsonb_agg(to_jsonb(identity)-'program_version_id'
              ORDER BY window_ordinal)::text,'[]'))
              FROM pgreact_internal.window_identities identity
              WHERE program_version_id=(SELECT program_version_id
                  FROM pgreact_internal.window_programs
                  WHERE program_name='m18.benchmark.windows' AND active)),
          'rules',pgreact_api.status(),
          'program',pgreact_api.status('m18.benchmark.windows'),
          'watermark',(SELECT to_jsonb(row_value)
              FROM pgreact_api.watermark_status('m18.benchmark.windows') row_value)) AS value
  )
  SELECT json_build_object(
      'rules',(SELECT count(*) FROM pgreact.rules WHERE rule_name LIKE 'm18.benchmark.%'),
      'facts',(SELECT count(*) FROM m18_bench.facts),
      'windows',(SELECT count(*) FROM pgreact_internal.window_identities
          WHERE program_version_id=(SELECT program_version_id FROM pgreact_internal.window_programs
              WHERE program_name='m18.benchmark.windows' AND active)),
      'finalized',(SELECT count(*) FROM pgreact_internal.window_identities
          WHERE program_version_id=(SELECT program_version_id FROM pgreact_internal.window_programs
              WHERE program_name='m18.benchmark.windows' AND active) AND final),
      'jobs',(SELECT n FROM command_jobs),
      'watermark_status',(SELECT status FROM wm),
      'requested_hours',(SELECT requested_hours FROM wm),
      'complete_hours',(SELECT complete_hours FROM wm),
      'checksum',(SELECT md5(value::text) FROM normalized))")
database_bytes=$("${psql_cmd[@]}" -c "SELECT pg_database_size(current_database())")
correctness=$(jq -n --argjson s "$state" --argjson r "$rules" --argjson f "$facts" --argjson w "$windows" --argjson m "$watermark" --argjson j "$worker_jobs" '$s.rules == ($r + 1) and $s.facts == $f and $s.windows == $w and $s.finalized == $m and $s.jobs == $j and $s.requested_hours == $m and $s.complete_hours == $m and $s.watermark_status == "complete"')
test "$correctness" = true
jq -cn --arg name "$name" --argjson m "$metrics" --argjson s "$state" \
  --argjson correctness "$correctness" --argjson memory "$peak" --argjson db "$database_bytes" \
  '{name:$name,correctness:$correctness,peak_memory_bytes:$memory,database_bytes:$db,update_throughput:$m.update_throughput,worker_throughput:$m.worker_throughput,update_p50_ms:$m.update_p50_ms,update_p95_ms:$m.update_p95_ms,worker_p50_ms:$m.worker_p50_ms,worker_p95_ms:$m.worker_p95_ms,window_p50_ms:$m.window_p50_ms,window_p95_ms:$m.window_p95_ms,watermark_p50_ms:$m.watermark_p50_ms,watermark_p95_ms:$m.watermark_p95_ms,correctness_checksum:$s.checksum}'
