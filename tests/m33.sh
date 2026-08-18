#!/usr/bin/env bash
set -euo pipefail

profile=${1:-fast}
image=${2:-pg-react:m33-unreleased}
expected_version=${M33_EXPECTED_VERSION:-0.30.0}
case "$profile" in fast|complete) ;; *) echo 'usage: tests/m33.sh fast|complete [IMAGE]' >&2; exit 2 ;; esac

project=${COMPOSE_PROJECT_NAME:-pgreact-m33-${GITHUB_RUN_ID:-$$}}
run_dir="tests/.m33-run-${GITHUB_RUN_ID:-$$}"
artifact_dir=${M33_ARTIFACT_DIR:-}
mkdir -p -- "$run_dir"

cleanup() {
  COMPOSE_PROJECT_NAME=$project docker compose down --volumes --remove-orphans >/dev/null 2>&1 || true
  rm -rf -- "$run_dir"
}
trap cleanup EXIT

run_test() {
  local name=$1; shift
  local log="$run_dir/${name// /-}.log"
  if "$@" >"$log" 2>&1; then
    echo "$name passed"
  else
    sed -n '1,$p' "$log"
    return 1
  fi
}

static_audit() {
  test -s sql/m33.sql
  test -s tests/m33.sql
  bash -n tests/m33.sh
  test -s sql/pg_react--0.29.0.sql
  test "$(tail -c 1 sql/pg_react--0.29.0.sql | od -An -t x1 | tr -d ' \n')" = 0a
  ! grep -Eq '(^|[[:space:]])(ALTER|CREATE)[[:space:]]+EXTENSION' sql/m33.sql
  ! grep -Eq '(^|[[:space:]])(CREATE|ALTER)[[:space:]]+(SCHEMA|TABLE|TYPE|VIEW|FUNCTION)[[:space:]]+pgreact\.' sql/m33.sql
}

docs_audit() {
  test -s docs/v1-contract.md
  test -s docs/v1-api-inventory.json
  test -s docs/v1-finding-codes.json
  test -s docs/v1-limits.md
  test -s docs/v1-security.md
  jq -e '
    .schema_version == 1 and (.milestone == "M33" or .milestone == "M34") and
    .contract_version == "1.0.0" and
    (.ordinary.functions | length > 0) and
    (.ordinary.types | length > 0) and
    (.ordinary.views | length > 0)
  ' docs/v1-api-inventory.json >/dev/null
  jq -e '
    .schema_version == 1 and (.milestone == "M33" or .milestone == "M34") and
    .finding_shape == ["code","severity","blocking","target","field","message","hint","details"] and
    .severity == ["ERROR","WARNING","INFO"] and
    (.codes | length >= 22)
  ' docs/v1-finding-codes.json >/dev/null
  grep -Fq 'generated from the installed pgreact.api_inventory view' docs/v1-api-inventory.json
  grep -Fq 'M33 freezes the security boundary' docs/v1-security.md
  grep -Eiq 'match|subject|retry|retention' docs/v1-limits.md
}

run_test 'M33 static and concatenation audit' static_audit
run_test 'M33 documentation audit' docs_audit

if ! command -v docker >/dev/null 2>&1 ||
   ! docker image inspect "$image" >/dev/null 2>&1; then
  echo "M33 external Docker evidence not run: candidate image '$image' is unavailable"
  echo "M33 static lane passed; no external qualification claim made"
  exit 0
fi

export COMPOSE_PROJECT_NAME=$project
export PG_REACT_IMAGE=$image
export PG_REACT_INIT_VERSION=${M33_INIT_VERSION:-$expected_version}
export PG_REACT_PLATFORM=linux/amd64
export PG_REACT_PORT_BINDING=${PG_REACT_PORT_BINDING:-127.0.0.1::5432}
docker compose up -d --no-build >/dev/null 2>&1

ready=
for _ in {1..120}; do
  if [[ $(docker inspect --format '{{.State.Health.Status}}' "${project}-postgres-1" 2>/dev/null || true) = healthy ]] &&
     docker compose exec -T postgres psql -XAtq -U postgres -d postgres -c \
       "SELECT extversion='$expected_version' FROM pg_extension WHERE extname='pg_react'" 2>/dev/null | grep -qx t; then
    ready=1
    break
  fi
  sleep 1
done
if [[ -z $ready ]]; then
  echo "M33 candidate image did not provide pg-react $expected_version" >&2
  exit 1
fi

run_test 'M33 installed additive SQL' \
  docker compose exec -T postgres psql -XAtq -U postgres -d postgres \
  -v ON_ERROR_STOP=1 -f - < sql/m33.sql
run_test 'M33 inventory finding security and limits checks' \
  docker compose exec -T postgres psql -XAtq -U postgres -d postgres \
  -v ON_ERROR_STOP=1 -f - < tests/m33.sql

docker compose exec -T postgres psql -XAtq -U postgres -d postgres \
  -v ON_ERROR_STOP=1 -c \
  "SELECT pgreact_internal.m33_installed_inventory()" >"$run_dir/inventory.json"
docker compose exec -T postgres psql -XAtq -U postgres -d postgres \
  -v ON_ERROR_STOP=1 -c \
  "SELECT pgreact_internal.m33_finding_registry()" >"$run_dir/finding-registry.json"

if [[ $expected_version = 0.30.0 ]]; then
  m33_inv="docs/history/v1-api-inventory-m33-0.30.0.json"
  m33_codes="docs/history/v1-finding-codes-m33-0.30.0.json"
  test -f "$m33_inv" || m33_inv="docs/v1-api-inventory.json"
  test -f "$m33_codes" || m33_codes="docs/v1-finding-codes.json"
  run_test 'M33 documentation and installed inventory consistency' \
    jq -e --slurpfile installed "$run_dir/inventory.json" '
      all(.ordinary.functions[]; . as $name | any($installed[0].functions[];
        (.schema_name + "." + .name) == $name)) and
      all(.ordinary.types[]; . as $name | any($installed[0].types[];
        (.schema_name + "." + .name) == $name)) and
      all(.ordinary.views[]; . as $name | any($installed[0].public_views[];
        (.schema_name + "." + .name) == $name))
    ' "$m33_inv"
  run_test 'M33 documentation and finding registry consistency' \
    jq -e --slurpfile installed "$run_dir/finding-registry.json" '
      ([.codes[].code] | sort) == ([$installed[0].codes[].code] | sort)
    ' "$m33_codes"
else
  echo "M33 documentation/inventory execution check skipped for non-v1 image $expected_version"
fi

if [[ $expected_version = 0.30.0 ]]; then
  echo "M33 $profile candidate Docker lane passed for $image; external qualification evidence was run"
else
  echo "M33 $profile compatibility Docker smoke passed for $image ($expected_version); no M33 qualification claim made"
fi

if [[ $profile = complete ]]; then
  inherited_image=${M33_INHERITED_IMAGE:-pg-react:v0.29.0}
  if docker image inspect "$inherited_image" >/dev/null 2>&1; then
    run_test 'M32 inherited qualification' \
      env M32_INHERITED_IMAGE="${M32_INHERITED_IMAGE:-pg-react:v0.28.0}" \
      bash tests/m32.sh complete "$inherited_image"
  else
    echo "M33 inherited M32 evidence not run: image '$inherited_image' is unavailable"
    echo "No inherited M32 qualification claim made"
  fi
fi

if [[ -n $artifact_dir ]]; then
  mkdir -p -- "$artifact_dir"
  cp -- "$run_dir"/*.log "$artifact_dir"/
fi
