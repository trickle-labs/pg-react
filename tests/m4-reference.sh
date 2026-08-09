#!/usr/bin/env bash
set -euo pipefail

compose=(docker compose)
psql=("${compose[@]}" exec -T postgres psql -X -U postgres -d m4_reference -v ON_ERROR_STOP=1)

"${compose[@]}" exec -T postgres createdb -U postgres m4_reference
"${compose[@]}" cp tests/m4-reference.sql postgres:/tmp/m4-reference.sql >/dev/null
"${psql[@]}" -f /tmp/m4-reference.sql
version_id=$("${psql[@]}" -Atc "SELECT rule_version_id FROM pgreact.rules WHERE rule_name = 'manual_review_required'")
"${compose[@]}" exec -T -e DATABASE_URL=postgresql://postgres:pgreact@localhost/m4_reference \
  postgres pg-reactd "$version_id" m4-reference
"${psql[@]}" -Atc \
  "SELECT count(*) = 1 AND bool_and(order_id = 42 AND customer_id = 7 AND amount = 15000 AND condition_active) FROM app.manual_review_tasks" \
  | grep -qx t

echo "M4 README reference workflow passed"
