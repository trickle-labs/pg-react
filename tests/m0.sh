#!/usr/bin/env bash
set -euo pipefail

compose=(docker compose)
psql=("${compose[@]}" exec -T postgres psql -X -U postgres -d postgres -v ON_ERROR_STOP=1)

"${compose[@]}" cp tests/m0.sql postgres:/tmp/m0.sql >/dev/null
"${compose[@]}" cp tests/failed_refresh.sql postgres:/tmp/failed_refresh.sql >/dev/null
"${compose[@]}" cp tests/coordinated_refresh.sql postgres:/tmp/coordinated_refresh.sql >/dev/null
"${compose[@]}" cp tests/hold_barrier.sql postgres:/tmp/hold_barrier.sql >/dev/null
"${psql[@]}" -f /tmp/m0.sql

version_sql="(SELECT rule_version_id FROM pgreact_internal.rule_versions WHERE source_view_name = 'rule_def.high_value_risky_order')"

# A claim racing the committed barrier cannot enter the refresh window.
"${psql[@]}" -f /tmp/hold_barrier.sql >/tmp/pg-react-barrier.out &
barrier_pid=$!
sleep 0.2
if "${psql[@]}" -c "SET statement_timeout = '200ms'; SELECT pgreact_internal.execute_one(${version_sql}, 'claim-race')"; then
  echo "claim passed the coordinator's exclusive refresh lock" >&2
  exit 1
fi
wait "$barrier_pid"

# Transactions changing opposite sides of the join commit independently; the
# one coordinated refresh must observe their final joined state exactly once.
"${psql[@]}" -c "INSERT INTO app.customers VALUES (2, 'LOW'); INSERT INTO app.orders VALUES (6, 2002, 2, 9000)"
"${psql[@]}" -c "BEGIN; UPDATE app.customers SET risk_level = 'HIGH' WHERE id = 2; SELECT pg_sleep(0.5); COMMIT" >/tmp/pg-react-join-left.out &
join_pid=$!
sleep 0.1
"${psql[@]}" -c "BEGIN; UPDATE app.orders SET amount = 15000 WHERE id = 6; COMMIT"
wait "$join_pid"
"${psql[@]}" -v refresh_id=4 -f /tmp/coordinated_refresh.sql
test "$("${psql[@]}" -Atc "SELECT count(*) FROM pgreact_internal.activation_state WHERE rule_version_id = ${version_sql} AND semantic_key = 2002 AND active")" = 1
test "$("${psql[@]}" -Atc "SELECT count(*) FROM pgreact_internal.lifecycle_events e JOIN pgreact_internal.activation_state s USING (rule_version_id, activation_id) WHERE e.rule_version_id = ${version_sql} AND s.semantic_key = 2002 AND e.event_kind = 'ACTIVATE'")" = 1

# STATE_ONLY takes the same exclusive lock as refresh before inspecting state,
# so a claim cannot enter while reconciliation is blocked on its match table.
match_name=$("${psql[@]}" -Atc "SELECT match_name FROM pgreact_internal.rule_versions WHERE rule_version_id = ${version_sql}")
"${psql[@]}" -c "BEGIN; LOCK TABLE ${match_name} IN ACCESS EXCLUSIVE MODE; SELECT pg_sleep(1); COMMIT" >/tmp/pg-react-reconcile-blocker.out &
reconcile_blocker_pid=$!
sleep 0.2
"${psql[@]}" -c "SELECT pgreact_internal.reconcile_state_only(${version_sql})" >/tmp/pg-react-reconcile.out &
reconcile_pid=$!
sleep 0.2
if "${psql[@]}" -c "SET statement_timeout = '200ms'; SELECT pgreact_internal.execute_one(${version_sql}, 'reconcile-race')"; then
  echo "claim passed the reconciliation lock" >&2
  exit 1
fi
wait "$reconcile_blocker_pid"
wait "$reconcile_pid"

# A null runtime key aborts refresh. The coordinator disconnect releases its
# session lock while the previously committed durable barrier remains.
"${psql[@]}" -c "INSERT INTO app.orders VALUES (4, NULL, 1, 23000)"
if "${psql[@]}" -v refresh_id=5 -f /tmp/failed_refresh.sql; then
  echo "null-key refresh unexpectedly succeeded" >&2
  exit 1
fi
test "$("${psql[@]}" -Atc "SELECT count(*) FROM pgreact_internal.rule_barriers WHERE rule_version_id = ${version_sql}")" = 1
if "${psql[@]}" -c "SELECT pgreact_internal.execute_one(${version_sql}, 'barrier-test')"; then
  echo "claim unexpectedly passed a durable refresh barrier" >&2
  exit 1
fi
"${psql[@]}" -c "DELETE FROM app.orders WHERE id = 4"
"${psql[@]}" -v refresh_id=6 -f /tmp/coordinated_refresh.sql

# A duplicate runtime key has the same atomic failure and barrier behavior.
"${psql[@]}" -c "INSERT INTO app.orders VALUES (5, 1001, 1, 24000)"
if "${psql[@]}" -v refresh_id=7 -f /tmp/failed_refresh.sql; then
  echo "duplicate-key refresh unexpectedly succeeded" >&2
  exit 1
fi
"${psql[@]}" -c "DELETE FROM app.orders WHERE id = 5"
"${psql[@]}" -v refresh_id=8 -f /tmp/coordinated_refresh.sql
test "$("${psql[@]}" -Atc "SELECT count(*) FROM pgreact_internal.lifecycle_events WHERE rule_version_id = ${version_sql}")" = 4
test "$("${psql[@]}" -Atc "SELECT count(*) FROM pgreact_internal.agenda WHERE rule_version_id = ${version_sql}")" = 3

# Raw consequence DDL must wait behind verification and invocation. The test
# consequence sleeps for two seconds while execute_one holds the shared lock.
"${psql[@]}" -c "SELECT pgreact_internal.execute_one(${version_sql}, 'ddl-race')" >/tmp/pg-react-execute.out &
executor_pid=$!
sleep 0.2
dispatcher_identity=$("${psql[@]}" -Atc "SELECT dispatcher_identity FROM pgreact_internal.rule_versions WHERE rule_version_id = ${version_sql}")
ddl_commands=(
  "ALTER FUNCTION rule_action.activate_high_value_risky_order(pgreact.activation_context, rule_def.high_value_risky_order) COST 101"
  "DROP FUNCTION rule_action.activate_high_value_risky_order(pgreact.activation_context, rule_def.high_value_risky_order)"
  "CREATE OR REPLACE FUNCTION rule_action.activate_high_value_risky_order(context pgreact.activation_context, match rule_def.high_value_risky_order) RETURNS void LANGUAGE plpgsql AS 'BEGIN NULL; END'"
  "ALTER FUNCTION ${dispatcher_identity} COST 101"
)
for ddl in "${ddl_commands[@]}"; do
  if "${psql[@]}" -c "SET lock_timeout = '100ms'; ${ddl}"; then
    echo "binding DDL passed the verification/invocation lock: ${ddl}" >&2
    exit 1
  fi
done
wait "$executor_pid"

# Restart preserves durable state and reproduces the identity fixture.
episodes_before=$("${psql[@]}" -Atc "SELECT count(*) FROM pgreact_internal.agenda")
"${compose[@]}" restart postgres >/dev/null
until "${compose[@]}" exec -T postgres pg_isready -U postgres >/dev/null 2>&1; do sleep 1; done
episodes_after=$("${psql[@]}" -Atc "SELECT count(*) FROM pgreact_internal.agenda")
test "$episodes_before" = "$episodes_after"
"${psql[@]}" -Atc "SELECT activation_id = pgreact_internal.activation_uuid(digest) FROM app.identity_fixture" | grep -qx t

# A logical dump/restore retains the portable fixture without local OIDs.
"${compose[@]}" exec -T postgres pg_dump -U postgres -d postgres -Fc -t app.identity_fixture -f /tmp/m0-app.dump
"${compose[@]}" exec -T postgres createdb -U postgres m0_restore
"${compose[@]}" exec -T postgres psql -X -U postgres -d m0_restore -v ON_ERROR_STOP=1 -c "CREATE EXTENSION pg_trickle; CREATE EXTENSION pg_react; CREATE SCHEMA app;"
"${compose[@]}" exec -T postgres pg_restore -U postgres -d m0_restore /tmp/m0-app.dump
"${compose[@]}" exec -T postgres psql -X -U postgres -d m0_restore -Atc "SELECT encode(canonical_key, 'hex') = '010100000008000000000000002a' AND encode(digest, 'hex') = '8307bd70b28711d35b356a1df7c9bb606b720b2be74025b0d2c7dab15f4fa23e' AND activation_id = '8307bd70-b287-81d3-9b35-6a1df7c9bb60'::uuid FROM app.identity_fixture" | grep -qx t

echo "M0 integration, failure, restart, DDL-lock, and restore checks passed"
