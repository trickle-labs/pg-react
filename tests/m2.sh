#!/usr/bin/env bash
set -euo pipefail

compose=(docker compose)
psql=("${compose[@]}" exec -T postgres psql -X -U postgres -d postgres -v ON_ERROR_STOP=1)
"${compose[@]}" cp tests/m2.sql postgres:/tmp/m2.sql >/dev/null
output=$("${psql[@]}" -f /tmp/m2.sql)
grep -q 'M2 lifecycle, retry, and outbox checks passed' <<<"$output"
