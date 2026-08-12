#!/usr/bin/env bash
set -euo pipefail

for file in docs/m14-contract.md docs/m14-evidence.md docs/m14-readiness.md \
  docs/m14-release-notes.md docs/m14-tasks.md docs/m14-upgrade.md; do
  test -s "$file"
done
grep -Fq 'pgreact_api.doctor' docs/m14-contract.md
grep -Fq 'Do not provide `inputs`' docs/m14-contract.md
grep -Fq 'tests/m14.sh pg-react:v0.11.0' docs/m14-evidence.md
grep -Fq 'v0.11.0' docs/m14-readiness.md
grep -Fq 'M15' docs/m14-readiness.md

echo 'M14 task documentation gate passed'
