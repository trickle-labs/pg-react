#!/usr/bin/env bash
set -euo pipefail

evidence=${1:?usage: tests/m18-human-evidence.sh EVIDENCE_JSON}
expected=tests/fixtures/m18/expected-small-transcript.txt
actual=$(mktemp)
trap 'rm -f "$actual"' EXIT
if [[ ! -f $evidence ]]; then
  printf 'missing independent M18 human usability evidence: %s\n' "$evidence" >&2
  exit 1
fi
jq -e '
  .schema == 1 and .independent_observer == true and
  (.observer | type == "string" and length > 0) and
  (.observed_at | type == "string" and length > 0) and
  .role == "m18_author" and
  (.elapsed_seconds | type == "number" and . > 0 and . <= 900) and
  (.environment | type == "object" and
    .postgresql == "18.3" and .pg_react == "0.15.0" and
    .platform == "linux/amd64") and
  (.transcript | type == "string" and length > 0) and
  .final_state == {schemas:[], rules:[], programs:[]} and
  (.deviations | type == "array")
' "$evidence" >/dev/null
jq -j '.transcript' "$evidence" >"$actual"
cmp "$expected" "$actual"
echo 'M18 independent human usability evidence passed'
