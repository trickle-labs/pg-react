#!/usr/bin/env bash
set -euo pipefail

compose=(docker compose)
psql=("${compose[@]}" exec -T postgres psql -X -U postgres -d postgres -v ON_ERROR_STOP=1)
"${compose[@]}" cp tests/m1-scale.sql postgres:/tmp/m1-scale.sql >/dev/null
output=$("${psql[@]}" -f /tmp/m1-scale.sql)
grep -q 'M1 scale smoke checks passed' <<<"$output"
