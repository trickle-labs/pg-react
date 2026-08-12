#!/usr/bin/env bash
set -euo pipefail

grep -Eq 'direct finite non-null `timestamptz`' docs/m12-contract.md
grep -Eq 'pgreact_api\.author_deadline_rule' docs/m12-tasks.md
grep -Eq '0\.8\.0 -> 0\.9\.0' docs/m12-upgrade.md
grep -Eq '4ca2efe53f71572cbddaccbb771a9505d549ad2169718f793780501ca1418f07' docs/m12-entry.md
grep -Eq 'tests/m12\.sh pg-react:v0\.9\.0' docs/m12-evidence.md
! grep -Eq 'pgreact_internal|rule_version_id|timer_id' docs/m12-tasks.md
echo 'M12 task documentation gate passed'
