#!/usr/bin/env bash
set -euo pipefail

name=${1:?usage: tests/m55-benchmark-case.sh CASE_NAME}
database=${M55_BENCHMARK_DB:?M55_BENCHMARK_DB must name the benchmark database}
project=${COMPOSE_PROJECT_NAME:?COMPOSE_PROJECT_NAME must identify the benchmark compose project}
if [[ ! $database =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ || $database =~ ^(postgres|template0|template1)$ ]]; then
  printf 'unsafe M55_BENCHMARK_DB: %s\n' "$database" >&2
  exit 2
fi
case "$name" in
  comparison.fixed_target.unrelated_history|comparison.shared_source.validation|runtime.empty_queue|runtime.sustained_backlog_hot_conflict|recovery.worker_loss_expired_leases|review.evidence_limit_1_and_100|packages.layered_dag_61_nodes) ;;
  *) printf 'unknown M55 benchmark case: %s\n' "$name" >&2; exit 2 ;;
esac

psql_cmd=(docker compose -p "$project" exec -T postgres psql -XAtq -v ON_ERROR_STOP=1 -U postgres -d "$database")
docker compose -p "$project" exec -T postgres dropdb --if-exists --force -U postgres "$database" >/dev/null
docker compose -p "$project" exec -T postgres createdb -U postgres "$database" >/dev/null
"${psql_cmd[@]}" -c 'CREATE EXTENSION pg_trickle; CREATE EXTENSION pg_react' >/dev/null
"${psql_cmd[@]}" -v "case_name=$name" \
  -v "matches=${M55_BENCHMARK_MATCHES:-1000}" \
  -v "history_rows=${M55_BENCHMARK_HISTORY_ROWS:-10000}" \
  -f - < tests/m55-benchmark-case.sql
