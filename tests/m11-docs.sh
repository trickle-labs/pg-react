#!/usr/bin/env bash
set -euo pipefail

rg -q 'pgreact_api\.author_rule' README.md
rg -q 'pgreact_api\.rule_status' docs/m11-tasks.md
rg -q '0\.7\.0 -> 0\.8\.0' docs/m11-upgrade.md
rg -q 'v0\.7\.0' docs/m11-preentry.md
! rg -q 'pgreact_internal|pgreact_runtime|rule_version_id|episode_id|support_id|frontier' docs/m11-tasks.md
echo 'M11 task documentation gate passed'
