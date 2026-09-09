#!/usr/bin/env bash
set -euo pipefail

expected=0.45.0
test -s docs/current-release.json
jq -e --arg version "$expected" --arg previous 0.44.0 \
   '.schema_version == 1 and .milestone == "M56" and .extension_version == $version and
    .previous_extension_version == $previous and .adjacent_upgrade == "0.44.0 -> 0.45.0" and
   .v1_status == "postponed_indefinitely"' docs/current-release.json >/dev/null
grep -qx "version = \"$expected\"" Cargo.toml
awk '/name = "pg_react"/{found=1; next} found && /^version =/{print; exit}' Cargo.lock |
  grep -qx "version = \"$expected\""
grep -qx "default_version = '$expected'" pg_react.control
grep -Fq "version == \"$expected\"" src/managed.rs
grep -Fq "PG_REACT_INIT_VERSION=$expected" Dockerfile
grep -Fq "pg-react:$expected" docker-compose.yml

current_files=(
  README.md ROADMAP.md docs/index.md docs/getting-started.md docs/installation.md
  docs/authoring.md docs/operations.md docs/api-reference.md docs/security.md
  docs/backup-restore.md docs/upgrade.md docs/troubleshooting.md
  docs/support-matrix.md docs/known-limitations.md docs/changing-policies.md
  docs/limits.md docs/compatibility.md docs/versioning.md docs/concepts.md
  docs/deprecations.md docs/product-contract.md docs/order-review-tutorial.md
  showcase/order-review/README.md
  docs/benchmarks.md docs/v0.45.0-release-notes.md docs/v0.45.0-migration.md
)
for file in "${current_files[@]}"; do
  test -s "$file"
  grep -Fq "$expected" "$file"
  if grep -Eiq '1\.0\.0-rc\.1|current[^[:cntrl:]]{0,40}v1|below v1|v1 amount|current artifact v0\.' "$file"; then
    echo "stale current-release assertion in $file" >&2
    exit 1
  fi
done

for file in README.md ROADMAP.md docs/index.md docs/getting-started.md docs/installation.md \
  docs/authoring.md docs/operations.md docs/api-reference.md docs/security.md \
  docs/backup-restore.md docs/upgrade.md docs/troubleshooting.md \
  docs/support-matrix.md docs/known-limitations.md docs/deprecations.md \
  docs/product-contract.md docs/benchmarks.md docs/v0.45.0-release-notes.md; do
  ! grep -Fq '1.0.0-rc.1' "$file"
done

grep -Fq 'v0.45.0-release-notes.md' docs/history.md
grep -Fq 'v0.45.0-migration.md' docs/history.md
echo 'v0.45.0 current-release audit passed'
