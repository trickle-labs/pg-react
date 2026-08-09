#!/usr/bin/env bash
set -euo pipefail

compose=(docker compose)
psql=("${compose[@]}" exec -T postgres psql -X -U postgres -d postgres -v ON_ERROR_STOP=1)
"${compose[@]}" cp tests/m1.sql postgres:/tmp/m1.sql >/dev/null
output=$("${psql[@]}" -f /tmp/m1.sql)
grep -q 'M1 public API and worker checks passed' <<<"$output"
