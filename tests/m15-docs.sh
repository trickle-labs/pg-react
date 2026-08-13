#!/usr/bin/env bash
set -euo pipefail

expected_version=${PG_REACT_EXPECTED_VERSION:-0.12.0}
if [[ $expected_version = 0.12.0 ]]; then
  grep -Fq 'pg-react M15 is extension `0.12.0`' README.md
elif [[ $expected_version = 0.13.0 ]]; then
  grep -Fq "pg-react M16 is extension \`$expected_version\`" README.md
else
  grep -Fq "pg-react M17 is extension \`$expected_version\`" README.md
fi
grep -Fq "shared_preload_libraries = 'pg_trickle,pg_react'" docs/m15-tasks.md
grep -Fq "pg_react.databases = 'appdb'" docs/m15-tasks.md
grep -Fq 'ARRAY[' README.md
grep -Fq 'tests/m15.sh pg-react:v0.12.0' docs/m15-evidence.md
grep -Fq 'v0.12.0' docs/m15-readiness.md
grep -Fq '0.11.0 -> 0.12.0' docs/m15-contract.md
grep -Fq 'M16' docs/m15-readiness.md
test "$(grep -h '^# ' docs/m15-{contract,entry,evidence,readiness,release-notes,tasks,upgrade}.md | wc -l | tr -d ' ')" = 7

echo 'M15 documentation gate passed'
