#!/usr/bin/env bash
set -euo pipefail

expected_version=${PG_REACT_EXPECTED_VERSION:-0.13.0}
if [[ $expected_version = 0.13.0 ]]; then
  grep -Fq 'pg-react M16 is extension `0.13.0`' README.md
else
  grep -Fq "pg-react M17 is extension \`$expected_version\`" README.md
fi
grep -Fq 'tests/m16.sh pg-react:v0.13.0' docs/m16-evidence.md
grep -Fq 'v0.13.0' docs/m16-readiness.md
grep -Fq '0.12.0 -> 0.13.0' docs/m16-contract.md
grep -Fq 'COUNT(expression)' docs/m16-tasks.md
grep -Fq 'SUM' docs/m16-tasks.md
grep -Fq 'MIN' docs/m16-tasks.md
grep -Fq 'MAX' docs/m16-tasks.md

echo 'M16 documentation gate passed'
