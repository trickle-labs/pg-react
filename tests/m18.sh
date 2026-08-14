#!/usr/bin/env bash
set -euo pipefail

profile=${1:-fast}
image=${2:-pg-react:v0.15.0}
case "$profile" in fast|complete) ;; *) echo 'usage: tests/m18.sh fast|complete [IMAGE]' >&2; exit 2 ;; esac

project=${COMPOSE_PROJECT_NAME:-pgreact-m18-${GITHUB_RUN_ID:-$$}}
upgrade_project=${project}-upgrade
test_log_dir=$(mktemp -d)
artifact_dir=${M18_ARTIFACT_DIR:-$test_log_dir/artifacts}
mkdir -p "$artifact_dir"
managed_pid=

cleanup() {
  if [[ -n $managed_pid ]]; then
    COMPOSE_PROJECT_NAME=$upgrade_project docker compose exec -T postgres \
      bash -c 'kill -CONT "$1"' bash "$managed_pid" >/dev/null 2>&1 || true
  fi
  COMPOSE_PROJECT_NAME=$project docker compose down --volumes --remove-orphans >/dev/null 2>&1 || true
  COMPOSE_PROJECT_NAME=$upgrade_project docker compose down --volumes --remove-orphans >/dev/null 2>&1 || true
  rm -r -- "$test_log_dir"
}
trap cleanup EXIT

run_test() {
  local name=$1
  shift
  local log="$test_log_dir/${name// /-}.log"
  if "$@" >"$log" 2>&1; then
    echo "$name passed"
  else
    sed -n '1,$p' "$log"
    return 1
  fi
}

wait_for_version() {
  local compose_project=$1 expected=$2
  for _ in {1..120}; do
    if COMPOSE_PROJECT_NAME=$compose_project docker compose exec -T postgres \
      psql -XAtq -U postgres -d postgres -c \
      "SELECT extversion='$expected' FROM pg_extension WHERE extname='pg_react'" \
      2>/dev/null | grep -qx t; then return; fi
    sleep 1
  done
  return 1
}

docs_audit() {
  python3 tests/m18-docs-audit.py
  grep -Fq 'pg-react M18 is extension `0.15.0`' README.md
  grep -Fq 'tests/m18.sh fast pg-react:v0.15.0' docs/m18-evidence.md
  grep -Fq '0.14.0 -> 0.15.0' docs/m18-upgrade.md
  ! grep -R -E 'M18 is (ready|complete)\.' README.md docs --include='*.md'
}

release_audit() {
  grep -qx 'version = "0.15.0"' Cargo.toml
  grep -qx "default_version = '0.15.0'" pg_react.control
  grep -Fq "extversion = '0.15.0'" src/managed.rs
  grep -Fq 'pg_react--0.14.0--0.15.0.sql' < <(find sql -maxdepth 1 -type f -print)
  test "$(grep -R -E '^\s*(- )?uses:' .github/workflows | wc -l | tr -d ' ')" = \
    "$(grep -R -E '^\s*(- )?uses: [^@]+@[0-9a-f]{40}$' .github/workflows | wc -l | tr -d ' ')"
  grep -R -Fq 'toolchain: 1.89.0' .github/workflows
  grep -Fq 'contents: read' .github/workflows/ci.yml
  grep -Fq 'cargo audit --locked' .github/workflows/release.yml
  grep -Fq 'pg-react-v0.15.0.spdx.json' .github/workflows/release.yml
  grep -Fq 'actions/attest@59d89421af93a897026c735860bf21b6eb4f7b26' .github/workflows/release.yml
  grep -Fq 'attestations: write' .github/workflows/release.yml
  grep -Fq 'artifact-metadata: write' .github/workflows/release.yml
  grep -Fq 'artifacts.provenance.json' .github/workflows/release.yml
  grep -Fq 'tests/m18-human-evidence.sh tests/fixtures/m18/human-usability.json' \
    .github/workflows/release.yml
  grep -Fq 'actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a' \
    .github/workflows/m18-evidence.yml
  grep -Fq 'runs-on: ubuntu-24.04' .github/workflows/m18-evidence.yml
  grep -Fq 'contents: read' .github/workflows/m18-evidence.yml
  grep -Fq "tar --sort=name --mtime='UTC 1970-01-01'" .github/workflows/m18-evidence.yml
  grep -Fq "tar --sort=name --mtime='UTC 1970-01-01'" .github/workflows/release.yml
  bash -n tests/m18.sh tests/m18-benchmark.sh tests/m18-benchmark-case.sh \
    tests/m18-human-evidence.sh tests/m18-recovery-benchmark.sh tests/m18-sbom.sh
  python3 tests/m18-lock-packages.py | jq -e \
    'length > 0 and all(.[]; (.name | length > 0) and (.version | length > 0))' >/dev/null
  jq -e '.target_version == "0.15.0"' tests/fixtures/m18/manifest.json >/dev/null
  jq -r '.fixture_checksums | to_entries[] | "\(.value)  \(.key)"' \
    tests/fixtures/m18/manifest.json | sha256sum -c - >/dev/null
  while IFS= read -r fixture; do test -e "$fixture"; done < <(
    jq -r '.. | strings | select(startswith("tests/")) | split("#")[0]' \
      tests/fixtures/m18/manifest.json | sort -u)
  jq -e '.required_artifacts == ["archive","sha256","oci_digest","sbom","provenance"]' \
    tests/fixtures/m18/release-state.json >/dev/null
}

run_authoring() {
  local actual="$artifact_dir/small-profile-transcript.txt"
  local started=$SECONDS
  COMPOSE_PROJECT_NAME=$project docker compose exec -T postgres \
    dropdb --if-exists --force -U postgres m18_authoring
  COMPOSE_PROJECT_NAME=$project docker compose exec -T postgres \
    createdb -U postgres m18_authoring
  COMPOSE_PROJECT_NAME=$project docker compose exec -T postgres \
    psql -XAtq -U postgres -d m18_authoring -v ON_ERROR_STOP=1 \
    -c 'CREATE EXTENSION pg_trickle; CREATE EXTENSION pg_react' >/dev/null
  COMPOSE_PROJECT_NAME=$project docker compose exec -T postgres \
    psql -XAtq -U postgres -d m18_authoring -v ON_ERROR_STOP=1 \
    -f /tmp/m18-authoring.sql >"$actual"
  cmp tests/fixtures/m18/expected-small-transcript.txt "$actual"
  COMPOSE_PROJECT_NAME=$project docker compose exec -T postgres \
    dropdb --if-exists --force -U postgres m18_authoring
  local elapsed=$((SECONDS - started))
  test "$elapsed" -le 900
  printf '{"profile":"small","role":"m18_author","elapsed_seconds":%s,"automated":true}\n' \
    "$elapsed" >"$artifact_dir/small-profile.json"
}

recovery_budget() {
  local actual_file=${1:-$artifact_dir/recovery.json}
  jq -e \
    --slurpfile actual_values "$actual_file" \
    '.recovery as $expected | $actual_values[0] as $actual |
     ($actual.crash_restart_ms <= $expected.crash_restart_ms * 1.2) and
     ($actual.physical_restore_ms <= $expected.physical_restore_ms * 1.2) and
     ($actual.logical_restore_ms <= $expected.logical_restore_ms * 1.2)' \
    tests/fixtures/m18/baseline.json >/dev/null
}

run_recovery_benchmark() {
  bash tests/m18-recovery-benchmark.sh "$image"
  if [[ ${M18_RECORD_BASELINE:-false} = false ]] &&
      ! recovery_budget "$M18_RECOVERY_BENCHMARK_OUTPUT"; then
    bash tests/m18-recovery-benchmark.sh "$image"
    recovery_budget "$M18_RECOVERY_BENCHMARK_OUTPUT"
  fi
}

run_test 'M18 documentation and release claims' docs_audit
run_test 'M18 release security and artifact audit' release_audit
run_test 'M0-M17 inherited compatibility' env \
  M18_RECOVERY_ARTIFACT="$artifact_dir/recovery.json" \
  PG_REACT_EXPECTED_VERSION=0.15.0 \
  COMPOSE_PROJECT_NAME="${project}-m17" \
  bash tests/m17.sh "$image"

export PG_REACT_IMAGE=$image
export PG_REACT_PLATFORM=linux/amd64
export PG_REACT_PORT_BINDING=${PG_REACT_PORT_BINDING:-127.0.0.1::5432}
export PG_REACT_POLL_INTERVAL_MS=60000
export PG_REACT_BATCH_SIZE=1000
export COMPOSE_PROJECT_NAME=$project
docker compose up -d --no-build >/dev/null 2>&1
wait_for_version "$project" 0.15.0
for fixture in m18-authoring m17-smoke m18-public-matrix; do
  docker compose cp "tests/$fixture.sql" "postgres:/tmp/$fixture.sql" >/dev/null
done
run_test 'M18 public-only five-workload authoring and cleanup' run_authoring
for _ in {1..120}; do
  managed_pid=$(docker compose exec -T postgres psql -XAtq -U postgres -d postgres \
    -c "WITH status AS (SELECT pgreact_api.managed_status() value)
        SELECT value #>> '{process,pid}' FROM status
        WHERE (value #>> '{process,heartbeat_at}')::timestamptz >
              clock_timestamp() - interval '5 seconds'" 2>/dev/null || true)
  [[ -n $managed_pid ]] && break
  sleep 1
done
test -n "$managed_pid"
docker compose exec -T postgres bash -c 'kill -STOP "$1"' bash "$managed_pid"
run_test 'M18 frozen M17 reference fixture' \
  docker compose exec -T postgres psql -XAtq -U postgres -d postgres \
  -v ON_ERROR_STOP=1 -f /tmp/m17-smoke.sql
run_test 'M18 exact public diagnostic and remediation matrix' \
  docker compose exec -T postgres psql -XAtq -U postgres -d postgres \
  -v ON_ERROR_STOP=1 -f /tmp/m18-public-matrix.sql
docker compose exec -T postgres bash -c 'kill -CONT "$1"' bash "$managed_pid"
managed_pid=
export M18_BENCHMARK_DB=m18_benchmark
run_test 'M18 fast benchmark correctness sentinel' \
  tests/m18-benchmark-case.sh \
  rules-1-facts-1e3-updates-1-workers-1-windows-1e3-watermark-0

export COMPOSE_PROJECT_NAME=$upgrade_project
export PG_REACT_INIT_VERSION=0.14.0
export PG_REACT_POLL_INTERVAL_MS=1000
docker compose up -d --no-build >/dev/null 2>&1
wait_for_version "$upgrade_project" 0.14.0
for fixture in m17-smoke m18-upgrade m18-day2-queue m18-day2; do
  docker compose cp "tests/$fixture.sql" "postgres:/tmp/$fixture.sql" >/dev/null
done
run_test 'M18 populated direct 0.14.0 to 0.15.0 upgrade' \
  docker compose exec -T postgres psql -XAtq -U postgres -d postgres \
  -v ON_ERROR_STOP=1 -f /tmp/m17-smoke.sql -f /tmp/m18-upgrade.sql

for _ in {1..120}; do
  managed_pid=$(docker compose exec -T postgres psql -XAtq -U postgres -d postgres \
    -c "SELECT pgreact_api.managed_status() #>> '{process,pid}'" 2>/dev/null || true)
  [[ -n $managed_pid ]] && break
  sleep 1
done
test -n "$managed_pid"
run_test 'M18 day-2 queued command setup' \
  docker compose exec -T postgres psql -XAtq -U postgres -d postgres \
  -v ON_ERROR_STOP=1 -f /tmp/m18-day2-queue.sql
worker_executing=false
for _ in {1..120}; do
  if docker compose exec -T postgres psql -XAtq -U postgres -d postgres -c \
    "SELECT wait_event='PgSleep' FROM pg_stat_activity WHERE pid=$managed_pid" \
    2>/dev/null | grep -qx t; then worker_executing=true; break; fi
  sleep 0.1
done
test "$worker_executing" = true
docker compose exec -T postgres bash -c 'kill -STOP "$1"' bash "$managed_pid"
sleep 11
run_test 'M18 day-2 in-lease worker-loss diagnosis' \
  docker compose exec -T postgres psql -XAtq -U postgres -d postgres \
  -v ON_ERROR_STOP=1 -v worker_loss=true -f /tmp/m18-day2.sql
docker compose exec -T postgres bash -c 'kill -CONT "$1"' bash "$managed_pid"
managed_pid=
for _ in {1..120}; do
  if docker compose exec -T postgres psql -XAtq -U postgres -d postgres \
    -c "SELECT pgreact_api.doctor() ->> 'status'" 2>/dev/null | grep -qx ready; then break; fi
  sleep 1
done
run_test 'M18 day-2 reconciliation and continued execution' \
  docker compose exec -T postgres psql -XAtq -U postgres -d postgres \
  -v ON_ERROR_STOP=1 -v worker_loss=false -f /tmp/m18-day2.sql

if [[ $profile = complete ]]; then
  export COMPOSE_PROJECT_NAME=$project
  export M18_RECOVERY_BENCHMARK_OUTPUT="$artifact_dir/recovery-benchmark.json"
  run_test 'M18 complete recovery benchmark and regression budget' \
    run_recovery_benchmark
  export M18_BENCHMARK_OUTPUT="$artifact_dir/benchmark.json"
  run_test 'M18 complete benchmark and regression budget' \
    bash tests/m18-benchmark.sh complete tests/m18-benchmark-case.sh
fi

uname -a >"$artifact_dir/host.txt"
docker image inspect "$image" >"$artifact_dir/image.json"
if command -v sha256sum >/dev/null; then
  (cd "$artifact_dir" && find . -type f ! -name SHA256SUMS -print | LC_ALL=C sort | xargs sha256sum) \
    >"$artifact_dir/SHA256SUMS"
else
  (cd "$artifact_dir" && find . -type f ! -name SHA256SUMS -print | LC_ALL=C sort | xargs shasum -a 256) \
    >"$artifact_dir/SHA256SUMS"
fi
echo "M18 $profile repository evidence gate passed for $image (linux/amd64)"
