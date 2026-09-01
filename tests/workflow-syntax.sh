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
echo 'M54 workflow syntax audit passed'
