#!/usr/bin/env bash
set -euo pipefail

for file in \
  docs/m13-contract.md docs/m13-entry.md docs/m13-evidence.md \
  docs/m13-readiness.md docs/m13-release-notes.md docs/m13-tasks.md \
  docs/m13-upgrade.md; do
  test -s "$file"
done
grep -Fq 'pgreact_api.run' docs/m13-contract.md
grep -Fq 'action_schema' docs/m13-tasks.md
grep -Fq 'configure_roles' docs/m13-upgrade.md
grep -Fq 'tests/m13.sh pg-react:v0.10.0' docs/m13-evidence.md
grep -Fq 'v0.10.0' docs/m13-readiness.md
grep -Fq 'Explainability and reasoning UX' docs/m13-readiness.md

echo 'M13 task documentation gate passed'
