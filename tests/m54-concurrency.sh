#!/usr/bin/env bash
set -euo pipefail

image=${1:?candidate image is required}
project=${2:?compose project is required}
: "$image"
export COMPOSE_PROJECT_NAME=$project

psql() {
  docker compose exec -T postgres psql -XAtq -U postgres -d postgres -v ON_ERROR_STOP=1 "$@"
}

run_sql() {
  printf '%s\n' "$1" | psql -f -
}

wait_for_lock() {
  local target=$1
  for _ in {1..100}; do
    if psql -c "SELECT EXISTS (SELECT 1 FROM pg_stat_activity WHERE wait_event_type = 'Lock' AND query LIKE '%$target%')" | grep -qx t; then
      return 0
    fi
    sleep 0.1
  done
  echo "waiter did not block for $target" >&2
  return 1
}

run_race() {
  local name=$1
  local declaration=$2
  local reviewed_token=$3
  local holder_operation=$4
  local run_dir
  local fifo
  local holder_log
  local waiter_log
  local holder_pid
  local waiter_pid
  local holder_fd
  local waiter_sql

  run_dir=$(mktemp -d "${TMPDIR:-/tmp}/m54-race.XXXXXX")
  fifo=$run_dir/input
  holder_log=$run_dir/holder.log
  waiter_log=$run_dir/waiter.log
  mkfifo "$fifo"

  docker compose exec -T postgres psql -XAtq -U postgres -d postgres -v ON_ERROR_STOP=1 \
    < "$fifo" >"$holder_log" 2>&1 &
  holder_pid=$!
  exec {holder_fd}>"$fifo"
  printf 'BEGIN;\nSELECT pg_advisory_xact_lock(hashtextextended(\x27rule:%s\x27, 5788046901200000));\nSELECT \x27LOCK_HELD\x27;\n' "$name" >&$holder_fd
  for _ in {1..100}; do
    if grep -qx LOCK_HELD "$holder_log"; then break; fi
    sleep 0.1
  done
  grep -qx LOCK_HELD "$holder_log"

  waiter_sql="DO \$m54\$ BEGIN PERFORM pgreact.deploy($declaration, '$reviewed_token'); RAISE EXCEPTION 'unexpected success'; EXCEPTION WHEN OTHERS THEN IF SQLERRM <> 'M54_REVIEW_TOKEN_STALE: reviewed preview is stale' THEN RAISE; END IF; END \$m54\$; SELECT 'M54_REVIEW_TOKEN_STALE: reviewed preview is stale';"
  printf '%s\n' "$waiter_sql" |
    psql -f - >"$waiter_log" 2>&1 &
  waiter_pid=$!
  wait_for_lock "$name"

  printf '%s\nCOMMIT;\n' "$holder_operation" >&$holder_fd
  exec {holder_fd}>&-
  wait "$holder_pid"
  set +e
  wait "$waiter_pid"
  set -e
  grep -Fxq 'M54_REVIEW_TOKEN_STALE: reviewed preview is stale' "$waiter_log"
  rm -rf -- "$run_dir"
  echo "$name concurrent $name race passed"
}

run_sql "CREATE OR REPLACE VIEW m54_reference.race_conditions AS SELECT account_id, result, state FROM m54_reference.conditions;"

keep_decl="pgreact.rule('m54-race-keep', 'm54_reference.race_conditions'::regclass, 'account_id', 'CONSTRAINT', NULL, NULL, NULL, 'SEED_CURRENT', ARRAY['state']::name[], 1, 'default', ARRAY['state']::name[], 1, 1, 2, 60)"
keep_replacement="pgreact.rule('m54-race-keep', 'm54_reference.race_conditions'::regclass, 'account_id', 'CONSTRAINT', NULL, NULL, NULL, 'SEED_CURRENT', ARRAY['result']::name[], 2, 'default', ARRAY['state']::name[], 1, 1, 2, 60)"
run_sql "SELECT pgreact.deploy($keep_decl, '{}'::jsonb);"
keep_token=$(psql -c "SELECT pgreact.review_token(pgreact.preview($keep_decl));")
run_race m54-race-keep "$keep_decl" "$keep_token" "SELECT pgreact.deploy($keep_replacement, '{}'::jsonb);"

remove_decl="pgreact.rule('m54-race-remove', 'm54_reference.race_conditions'::regclass, 'account_id', 'CONSTRAINT', NULL, NULL, NULL, 'SEED_CURRENT', ARRAY['state']::name[], 1, 'default', ARRAY['state']::name[], 1, 1, 2, 60)"
run_sql "SELECT pgreact.deploy($remove_decl, '{}'::jsonb);"
remove_token=$(psql -c "SELECT pgreact.review_token(pgreact.preview($remove_decl));")
run_race m54-race-remove "$remove_decl" "$remove_token" "SELECT pgreact.remove('m54-race-remove', '{}'::jsonb);"

replace_decl="pgreact.rule('m54-race-replace', 'm54_reference.race_conditions'::regclass, 'account_id', 'CONSTRAINT', NULL, NULL, NULL, 'SEED_CURRENT', ARRAY['state']::name[], 1, 'default', ARRAY['state']::name[], 1, 1, 2, 60)"
replace_next="pgreact.rule('m54-race-replace', 'm54_reference.race_conditions'::regclass, 'account_id', 'CONSTRAINT', NULL, NULL, NULL, 'SEED_CURRENT', ARRAY['result']::name[], 2, 'default', ARRAY['state']::name[], 1, 1, 2, 60)"
replace_other="pgreact.rule('m54-race-replace', 'm54_reference.race_conditions'::regclass, 'account_id', 'CONSTRAINT', NULL, NULL, NULL, 'SEED_CURRENT', ARRAY['state']::name[], 3, 'default', ARRAY['state']::name[], 1, 1, 2, 60)"
run_sql "SELECT pgreact.deploy($replace_decl, '{}'::jsonb);"
replace_token=$(psql -c "SELECT pgreact.review_token(pgreact.preview($replace_next));")
run_race m54-race-replace "$replace_next" "$replace_token" "SELECT pgreact.deploy($replace_other, jsonb_build_object('old_work', 'DRAIN_OLD'));"

ddl_decl="pgreact.rule('m54-race-ddl', 'm54_reference.race_conditions'::regclass, 'account_id', 'CONSTRAINT', NULL, NULL, NULL, 'SEED_CURRENT', ARRAY['state']::name[], 1, 'default', ARRAY['state']::name[], 1, 1, 2, 60)"
run_sql "SELECT pgreact.deploy($ddl_decl, '{}'::jsonb);"
ddl_token=$(psql -c "SELECT pgreact.review_token(pgreact.preview($ddl_decl));")
run_race m54-race-ddl "$ddl_decl" "$ddl_token" "CREATE OR REPLACE VIEW m54_reference.race_conditions AS SELECT account_id, result || '' AS result, state FROM m54_reference.conditions;"

echo "M54 exact two-session concurrency checks passed"
