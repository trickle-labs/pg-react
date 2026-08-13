#!/usr/bin/env bash
set -euo pipefail

grep -Fq 'pg-react M15 is extension `0.12.0`' README.md
grep -Fq "shared_preload_libraries = 'pg_trickle,pg_react'" docs/m15-tasks.md
grep -Fq "pg_react.databases = 'appdb'" docs/m15-tasks.md
grep -Fq 'ARRAY[' README.md
grep -Fq 'tests/m15.sh pg-react:v0.12.0' docs/m15-evidence.md
grep -Fq 'v0.12.0' docs/m15-readiness.md
grep -Fq '0.11.0 -> 0.12.0' docs/m15-contract.md
grep -Fq 'M16' docs/m15-readiness.md
test "$(grep -h '^# ' docs/m15-{contract,entry,evidence,readiness,release-notes,tasks,upgrade}.md | wc -l | tr -d ' ')" = 7

echo 'M15 documentation gate passed'
