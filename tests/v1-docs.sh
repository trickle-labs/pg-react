#!/usr/bin/env bash
set -euo pipefail

profile=${1:-fast}
image=${2:-pg-react:1.0.0-rc.1}
expected_version=${V1_EXPECTED_VERSION:-1.0.0-rc.1}

if [[ $profile != fast && $profile != complete ]]; then
  echo "usage: $0 [fast|complete] [image]" >&2
  exit 1
fi

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

run_dir=$(mktemp -d "${TMPDIR:-/tmp}/pg-react-v1-docs.XXXXXX")
project="pgreact-v1docs-$$"

cleanup() {
  set +e
  COMPOSE_PROJECT_NAME="$project" docker compose down -v --remove-orphans >/dev/null 2>&1 || true
  rm -rf "$run_dir"
}
trap cleanup EXIT

run_test() {
  local name=$1
  shift
  echo "==> Running: $name"
  "$@"
}

echo "=== pg-react v1 Documentation Executable Validation ($profile) ==="

# 1. Static documentation, link, and stale-reference audit
run_test 'v1 documentation link and stale-reference audit' \
  python3 tests/v1-docs-audit.py

# 2. JSON machine inventory validation
run_test 'v1 JSON machine inventory format validation' \
  jq -e '
    .schema_version == 1 and .milestone == "1.0.0-rc.1" and .extension_version == "1.0.0-rc.1" and
    .contract_version == "1.0.0" and
    (.ordinary.functions | length >= 10) and
    (.ordinary.types | length >= 2) and
    (.ordinary.views | length >= 7)
  ' docs/v1-api-inventory.json >/dev/null

run_test 'v1 finding codes registry format validation' \
  jq -e '
    .schema_version == 1 and .milestone == "1.0.0-rc.1" and .extension_version == "1.0.0-rc.1" and
    .finding_shape == ["code","severity","blocking","target","field","message","hint","details"] and
    .severity == ["ERROR","WARNING","INFO"] and
    (.codes | length == 40)
  ' docs/v1-finding-codes.json >/dev/null

# 3. Bring up test environment
echo "Starting PostgreSQL container with image: $image"
export COMPOSE_PROJECT_NAME="$project"
export PG_REACT_IMAGE="$image"
export PG_REACT_INIT_VERSION="$expected_version"

docker compose up -d postgres

for _ in $(seq 1 30); do
  if [[ $(docker inspect --format '{{.State.Health.Status}}' "${project}-postgres-1" 2>/dev/null || true) = healthy ]] &&
     docker compose exec -T postgres psql -XAtq -U postgres -d postgres -c \
       "SELECT extversion='$expected_version' FROM pg_extension WHERE extname='pg_react'" 2>/dev/null | grep -qx t; then
    break
  fi
  sleep 1
done

if ! docker compose exec -T postgres psql -XAtq -U postgres -d postgres -c \
     "SELECT extversion='$expected_version' FROM pg_extension WHERE extname='pg_react'" 2>/dev/null | grep -qx t; then
  echo "PostgreSQL container failed to become healthy with pg_react $expected_version" >&2
  exit 1
fi

# 4. Extract live catalog inventories and verify consistency
docker compose exec -T postgres psql -XAtq -U postgres -d postgres -v ON_ERROR_STOP=1 -c \
  "SELECT pgreact_internal.m33_installed_inventory()" >"$run_dir/installed-inventory.json"

docker compose exec -T postgres psql -XAtq -U postgres -d postgres -v ON_ERROR_STOP=1 -c \
  "SELECT pgreact_internal.m33_finding_registry()" >"$run_dir/m33-findings.json"

docker compose exec -T postgres psql -XAtq -U postgres -d postgres -v ON_ERROR_STOP=1 -c \
  "SELECT pgreact_internal.m34_finding_registry()" >"$run_dir/m34-findings.json"

run_test 'v1 documentation and live installed inventory consistency' \
  jq -e --slurpfile installed "$run_dir/installed-inventory.json" '
    all(.ordinary.functions[]; . as $name | any($installed[0].functions[];
      (.schema_name + "." + .name) == $name)) and
    all(.ordinary.types[]; . as $name | any($installed[0].types[];
      (.schema_name + "." + .name) == $name)) and
    all(.ordinary.views[]; . as $name | any($installed[0].public_views[];
      (.schema_name + "." + .name) == $name))
  ' docs/v1-api-inventory.json

run_test 'v1 documentation and live installed finding codes consistency' \
  jq -e --slurpfile m33 "$run_dir/m33-findings.json" --slurpfile m34 "$run_dir/m34-findings.json" '
    . as $doc |
    (all($m33[0].codes[]; . as $c | any($doc.codes[]; .code == $c.code))) and
    (all($m34[0].codes[]; . as $c | any($doc.codes[]; .code == $c.code)))
  ' docs/v1-finding-codes.json

# 5. Execute documentation SQL fixtures in isolated test databases
setup_test_db() {
  local db=$1
  docker compose exec -T postgres psql -U postgres -d postgres -c "DROP DATABASE IF EXISTS $db WITH (FORCE);" >/dev/null
  docker compose exec -T postgres psql -U postgres -d postgres -c "CREATE DATABASE $db;" >/dev/null
  docker compose exec -T postgres psql -U postgres -d "$db" -v ON_ERROR_STOP=1 -c "CREATE EXTENSION pg_trickle; CREATE EXTENSION pg_react;" >/dev/null
}

setup_test_db "test_v1_api"
run_test 'v1 API and security fixture (tests/v1-docs-api.sql)' \
  docker compose exec -T postgres psql -XAtq -U postgres -d test_v1_api -v ON_ERROR_STOP=1 -f - < tests/v1-docs-api.sql

setup_test_db "test_v1_getting_started"
run_test 'v1 Getting Started fixture (tests/v1-docs-getting-started.sql)' \
  docker compose exec -T postgres psql -XAtq -U postgres -d test_v1_getting_started -v ON_ERROR_STOP=1 -f - < tests/v1-docs-getting-started.sql

setup_test_db "test_v1_authoring"
run_test 'v1 Authoring fixture (tests/v1-docs-authoring.sql)' \
  docker compose exec -T postgres psql -XAtq -U postgres -d test_v1_authoring -v ON_ERROR_STOP=1 -f - < tests/v1-docs-authoring.sql

setup_test_db "test_v1_comparison"
run_test 'v1 Comparison and No-Effect fixture (tests/v1-docs-comparison.sql)' \
  docker compose exec -T postgres psql -XAtq -U postgres -d test_v1_comparison -v ON_ERROR_STOP=1 -f - < tests/v1-docs-comparison.sql

setup_test_db "test_v1_operations"
run_test 'v1 Operations and Troubleshooting fixture (tests/v1-docs-operations.sql)' \
  docker compose exec -T postgres psql -XAtq -U postgres -d test_v1_operations -v ON_ERROR_STOP=1 -f - < tests/v1-docs-operations.sql

if [[ $profile = complete ]]; then
  echo "==> Running complete profile extended validations..."
  docker compose exec -T postgres psql -XAtq -U postgres -d postgres -v ON_ERROR_STOP=1 -c "
    DO \$\$
    DECLARE
        doc jsonb;
    BEGIN
        doc := pgreact.doctor();
        IF doc ->> 'state' <> 'ready' THEN
            RAISE EXCEPTION 'Complete profile doctor check failed: %', doc;
        END IF;
    END \$\$;
  "

  # Upgrade qualification & inventory equality check
  docker compose exec -T postgres psql -U postgres -d postgres -c "DROP DATABASE IF EXISTS test_v1_fresh_inv WITH (FORCE);" >/dev/null
  docker compose exec -T postgres psql -U postgres -d postgres -c "CREATE DATABASE test_v1_fresh_inv;" >/dev/null
  docker compose exec -T postgres psql -U postgres -d test_v1_fresh_inv -v ON_ERROR_STOP=1 -c "
    CREATE EXTENSION pg_trickle;
    CREATE EXTENSION pg_react;
    DO \$\$
    BEGIN
      IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'inv_test_author') THEN CREATE ROLE inv_test_author; END IF;
      IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'inv_test_operator') THEN CREATE ROLE inv_test_operator; END IF;
      IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'inv_test_worker') THEN CREATE ROLE inv_test_worker; END IF;
      IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'inv_test_reader') THEN CREATE ROLE inv_test_reader; END IF;
      IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'inv_test_adv_reader') THEN CREATE ROLE inv_test_adv_reader; END IF;
    END \$\$;
    SELECT pgreact_api.configure_roles('inv_test_author', 'inv_test_operator', 'inv_test_worker', 'inv_test_reader', 'inv_test_adv_reader');
  "

  docker compose exec -T postgres psql -XAtq -U postgres -d test_v1_fresh_inv -v ON_ERROR_STOP=1 -c \
    "SELECT pgreact_internal.m33_installed_inventory()" >"$run_dir/fresh-inventory.json"

  docker compose exec -T postgres psql -U postgres -d postgres -c "DROP DATABASE IF EXISTS test_v1_upgrade WITH (FORCE);" >/dev/null
  docker compose exec -T postgres psql -U postgres -d postgres -c "CREATE DATABASE test_v1_upgrade;" >/dev/null

  run_test 'v1 populated 0.31.0 to 1.0.0-rc.1 upgrade qualification' \
    docker compose exec -T postgres psql -U postgres -d test_v1_upgrade -v ON_ERROR_STOP=1 -c "
      CREATE EXTENSION pg_trickle;
      CREATE EXTENSION pg_react VERSION '0.31.0';
      DO \$\$
      BEGIN
        IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'inv_test_author') THEN CREATE ROLE inv_test_author; END IF;
        IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'inv_test_operator') THEN CREATE ROLE inv_test_operator; END IF;
        IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'inv_test_worker') THEN CREATE ROLE inv_test_worker; END IF;
        IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'inv_test_reader') THEN CREATE ROLE inv_test_reader; END IF;
        IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'inv_test_adv_reader') THEN CREATE ROLE inv_test_adv_reader; END IF;
      END \$\$;
      SELECT pgreact_api.configure_roles('inv_test_author', 'inv_test_operator', 'inv_test_worker', 'inv_test_reader', 'inv_test_adv_reader');
      ALTER EXTENSION pg_react UPDATE TO '1.0.0-rc.1';
      DO \$\$
      BEGIN
        IF NOT has_function_privilege('inv_test_author', 'pgreact.compare(pgreact_api.declaration,pgreact_api.target,jsonb)', 'EXECUTE') THEN
          RAISE EXCEPTION 'inv_test_author lacks EXECUTE on pgreact.compare after upgrade';
        END IF;
      END \$\$;
    "

  docker compose exec -T postgres psql -XAtq -U postgres -d test_v1_upgrade -v ON_ERROR_STOP=1 -c \
    "SELECT pgreact_internal.m33_installed_inventory()" >"$run_dir/upgraded-inventory.json"

  run_test 'v1 fresh install vs upgraded inventory exact equality' \
    diff -u "$run_dir/fresh-inventory.json" "$run_dir/upgraded-inventory.json"
fi

echo "=== pg-react v1 documentation validation SUCCEEDED ($profile profile, image: $image) ==="
