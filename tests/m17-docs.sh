#!/usr/bin/env bash
set -euo pipefail

expected_version=${PG_REACT_EXPECTED_VERSION:-0.14.0}
if [[ $expected_version = 0.14.0 ]]; then
  grep -Fq 'pg-react M17 is extension `0.14.0`' README.md
else
  grep -Fq "pg-react M18 is extension \`$expected_version\`" README.md
fi
grep -Fq 'tests/m17.sh pg-react:v0.14.0' docs/m17-evidence.md
grep -Fq '0.13.0 -> 0.14.0' docs/m17-contract.md
grep -Fq 'request_watermark' docs/m17-tasks.md
grep -Fq 'restore_window_state' docs/m17-contract.md
test "$(grep -h '^# ' docs/m17-{contract,entry,evidence,readiness,release-notes,tasks,upgrade}.md | wc -l | tr -d ' ')" = 7

echo 'M17 documentation gate passed'
