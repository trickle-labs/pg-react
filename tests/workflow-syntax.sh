#!/usr/bin/env bash
set -euo pipefail

if rg -n 'run:\s*>-?' .github/workflows; then
  echo 'workflow uses a folded run scalar' >&2
  exit 1
fi
grep -Fq 'workflow_call:' .github/workflows/qualification.yml
grep -Fq 'qualification:' .github/workflows/ci.yml
grep -Fq 'qualification:' .github/workflows/release.yml
if rg -n 'placeholder|inherited qualification completed before packaging|synthetic qualification' .github/workflows; then
  echo 'workflow contains synthetic qualification evidence' >&2
  exit 1
fi
if rg -U -n 'docker build[^\n]*\n\s+bash tests' .github/workflows; then
  echo 'docker build and qualification command are accidentally concatenated' >&2
  exit 1
fi
grep -Fq 'bash tests/v0.43.3.sh complete' .github/workflows/qualification.yml
grep -Fq 'image: pg-react:m54-unreleased' .github/workflows/release.yml
grep -Fq -- '- v0.43.3' .github/workflows/release.yml
grep -Fq 'ref: v0.26.0' .github/workflows/m29-evidence.yml
grep -Fq 'ref: v0.27.0' .github/workflows/m30-evidence.yml
grep -Fq 'ref: v0.30.0' .github/workflows/m33-evidence.yml
if rg -n 'schedule:' .github/workflows/m29-evidence.yml .github/workflows/m30-evidence.yml .github/workflows/m33-evidence.yml; then
  echo 'historical workflows still have schedules' >&2
  exit 1
fi
echo '0.43.3 workflow syntax and identity audit passed'
