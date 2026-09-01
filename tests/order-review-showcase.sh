#!/usr/bin/env bash
set -euo pipefail

image=${1:-pg-react:0.43.0}
project=${COMPOSE_PROJECT_NAME:-pgreact-order-review-${GITHUB_RUN_ID:-$$}}
database=order_review_showcase
log_dir=$(mktemp -d)
transcript="$log_dir/transcript.txt"

cleanup() {
    COMPOSE_PROJECT_NAME=$project docker compose down --volumes --remove-orphans \
        >/dev/null 2>&1 || true
    rm -rf "$log_dir"
}
trap cleanup EXIT

run_test() {
    local name=$1
    shift
    local log="$log_dir/${name// /-}.log"
    if "$@" >"$log" 2>&1; then
        echo "$name passed"
    else
        cat "$log"
        return 1
    fi
}

export COMPOSE_PROJECT_NAME=$project
export PG_REACT_IMAGE=$image
docker compose up -d --wait --no-build >/dev/null

psql_base=(
    docker compose exec -T
    -e PGOPTIONS=-c\ client_min_messages=error
    postgres psql -XAtq -U postgres -v ON_ERROR_STOP=1
)

"${psql_base[@]}" -d postgres \
    -c "DROP DATABASE IF EXISTS $database WITH (FORCE)" \
    -c "CREATE DATABASE $database" >/dev/null
"${psql_base[@]}" -d "$database" \
    -c "CREATE EXTENSION pg_trickle; CREATE EXTENSION pg_react" >/dev/null

for script in 01-schema.sql 02-seed.sql; do
    "${psql_base[@]}" -d "$database" -f - \
        < "showcase/order-review/$script" >/dev/null
done

for script in \
    03-core-rules.sql \
    04-decisions-and-policy-set.sql \
    05-scenarios.sql
do
    "${psql_base[@]}" -d "$database" -f - \
        < "showcase/order-review/$script" >>"$transcript"
done

run_test 'order-review SQL assertions' \
    "${psql_base[@]}" -d "$database" -f - < tests/order-review-showcase.sql

run_test 'order-review transcript' \
    diff -u tests/fixtures/order-review-showcase/expected-transcript.txt "$transcript"

"${psql_base[@]}" -d "$database" -f - \
    < showcase/order-review/99-cleanup.sql >/dev/null

cleanup_state=$("${psql_base[@]}" -d "$database" -c "
    SELECT jsonb_build_object(
        'schemas_removed',
            to_regnamespace('app') IS NULL
            AND to_regnamespace('rule_def') IS NULL
            AND to_regnamespace('rule_action') IS NULL,
        'deployed_objects', (
            SELECT count(*)
            FROM pgreact.api_declarations
            WHERE name IN (
                'order-review-required', 'order-review-work',
                'order-review-route', 'order-review-policy'
            ) AND state = 'DEPLOYED'
        )
    )")

if [[ $cleanup_state != '{"schemas_removed": true, "deployed_objects": 0}' ]]; then
    echo "cleanup state changed: $cleanup_state"
    exit 1
fi

echo 'order-review cleanup passed'
echo 'order-review showcase passed'
