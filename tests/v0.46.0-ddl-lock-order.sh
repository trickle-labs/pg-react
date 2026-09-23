#!/usr/bin/env bash
set -euo pipefail

project=${1:?Compose project is required}
compose=(docker compose -p "$project")
psql=("${compose[@]}" exec -T postgres psql -XAtq -U postgres -d postgres -v ON_ERROR_STOP=1)
test_id=$$
schema="v046_lock_order_${test_id}"
app_a="v046-lock-a-${test_id}"
app_b="v046-lock-b-${test_id}"
run_dir=$(mktemp -d)
trap 'rm -rf -- "$run_dir"' EXIT

"${psql[@]}" -c "CREATE SCHEMA $schema" >/dev/null
mkfifo "$run_dir/holder.fifo"
"${psql[@]}" -f - <"$run_dir/holder.fifo" >"$run_dir/holder.log" 2>&1 &
holder_pid=$!
exec {holder_fd}>"$run_dir/holder.fifo"
printf '%s\n' \
  "SET application_name = '$app_a';" \
  'BEGIN;' \
  'SELECT pg_advisory_xact_lock(5788046901200000);' \
  "SELECT 'V046_DDL_LOCK_HOLDER_READY';" >&$holder_fd

for _ in {1..100}; do
  if grep -Fxq 'V046_DDL_LOCK_HOLDER_READY' "$run_dir/holder.log"; then break; fi
  sleep 0.1
done
grep -Fxq 'V046_DDL_LOCK_HOLDER_READY' "$run_dir/holder.log"

"${psql[@]}" -c "SET application_name = '$app_b'; BEGIN;
CREATE FUNCTION $schema.actor_b() RETURNS integer LANGUAGE sql AS 'SELECT 1';
SELECT pg_advisory_xact_lock(5788046901200000); COMMIT" >"$run_dir/waiter.log" 2>&1 &
waiter_pid=$!

blocked=false
for _ in {1..100}; do
  if [[ $("${psql[@]}" -c "SELECT EXISTS (
    SELECT 1 FROM pg_stat_activity
    WHERE application_name = '$app_b'
      AND wait_event_type = 'Lock'
      AND wait_event = 'advisory'
  )") = t ]]; then
    blocked=true
    break
  fi
  sleep 0.1
done
if [[ $blocked != true ]]; then
  sed -n '1,$p' "$run_dir/waiter.log"
  echo 'v0.46 DDL lock-order waiter did not block on the coordinator lock' >&2
  exit 1
fi

printf '%s\n' \
  "SET LOCAL lock_timeout = '300ms';" \
  'SELECT pg_advisory_xact_lock(5788046901200001);' \
  'COMMIT;' >&$holder_fd
exec {holder_fd}>&-

set +e
wait "$holder_pid"
holder_status=$?
wait "$waiter_pid"
waiter_status=$?
set -e
if (( holder_status != 0 || waiter_status != 0 )); then
  sed -n '1,$p' "$run_dir/holder.log" "$run_dir/waiter.log"
  echo 'v0.46 DDL lock-order concurrency regression failed' >&2
  exit 1
fi

"${psql[@]}" -c "DROP SCHEMA $schema CASCADE" >/dev/null
echo 'v0.46 DDL lock-order concurrency regression passed'
