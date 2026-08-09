#!/usr/bin/env bash
set -euo pipefail

compose=(docker compose)
psql=("${compose[@]}" exec -T postgres psql -X -U postgres -d postgres -v ON_ERROR_STOP=1)
"${compose[@]}" cp tests/m3.sql postgres:/tmp/m3.sql >/dev/null
output=$("${psql[@]}" -f /tmp/m3.sql)
grep -q 'M3 operational RC checks passed' <<<"$output"
