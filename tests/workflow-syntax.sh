#!/usr/bin/env bash
set -euo pipefail

if grep -ERn 'run:[[:space:]]*>-?' .github/workflows; then
  echo 'workflow uses a folded run scalar' >&2
  exit 1
fi
grep -Fq 'workflow_call:' .github/workflows/qualification.yml
grep -Fq 'qualification:' .github/workflows/ci.yml
grep -Fq 'qualification:' .github/workflows/release.yml
if grep -ERn 'placeholder|inherited qualification completed before packaging|synthetic qualification' .github/workflows; then
  echo 'workflow contains synthetic qualification evidence' >&2
  exit 1
fi
grep -Fq 'bash tests/qualification.sh complete' .github/workflows/qualification.yml
grep -Fq 'image: pg-react:v0.46.0-qualification' .github/workflows/release.yml
grep -Fq -- '- v0.46.0' .github/workflows/release.yml
grep -Fq 'name: Release pg-react adapter v0.48.0' .github/workflows/v0.48.0-release.yml
grep -Fq 'image: pg-react:v0.48.0-qualification' .github/workflows/v0.48.0-release.yml
grep -Fq -- '- v0.48.0' .github/workflows/v0.48.0-release.yml
grep -Fq 'tests/integrations/pg-mdm/evidence/v0.48.0/manifest.json' .github/workflows/v0.48.0-release.yml
if grep -Eq '^[[:space:]]+pull_request:' .github/workflows/v0.49.0-release.yml; then
  echo 'immutable v0.49 release workflow must not run on feature pull requests' >&2
  exit 1
fi
grep -Fq '      mode:' .github/workflows/v0.50.0-qualification.yml
grep -Fq '        type: choice' .github/workflows/v0.50.0-qualification.yml
grep -Fq '        default: rehearsal' .github/workflows/v0.50.0-qualification.yml
grep -Fq '          - rehearsal' .github/workflows/v0.50.0-qualification.yml
grep -Fq '          - require-qualified' .github/workflows/v0.50.0-qualification.yml
grep -Fq "if: \${{ github.event_name == 'workflow_call' || (github.event_name == 'workflow_dispatch' && inputs.mode == 'require-qualified') }}" .github/workflows/v0.50.0-qualification.yml
grep -Fq 'ref: v0.26.0' .github/workflows/m29-evidence.yml
grep -Fq 'ref: v0.27.0' .github/workflows/m30-evidence.yml
grep -Fq 'ref: v0.30.0' .github/workflows/m33-evidence.yml
if grep -En 'schedule:' .github/workflows/m29-evidence.yml .github/workflows/m30-evidence.yml .github/workflows/m33-evidence.yml; then
  echo 'historical workflows still have schedules' >&2
  exit 1
fi
echo 'workflow identity and v0.50 rehearsal gate audit passed'
