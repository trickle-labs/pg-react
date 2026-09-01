#!/usr/bin/env bash
set -euo pipefail

jq -e '
  .schema_version == 1 and .extension_version == "0.43.1" and
  .classification_order == ["ordinary", "compatibility", "advanced", "administrative"] and
  (.surfaces | keys | sort) == ["administrative", "advanced", "compatibility", "internal_not_public", "ordinary"] and
  (.surfaces.ordinary.functions | index("pgreact.review_token(preview_result jsonb)")) != null and
  (.surfaces.ordinary.functions | index("pgreact.deploy(declaration pgreact_api.declaration, review_token text, preconditions jsonb)")) != null and
  (.surfaces.ordinary.functions | any(. == "pgreact.policy_set(name text, version text, members pgreact_api.declaration[], applicability regclass, subject_keys name[], support pgreact_api.declaration[], dependencies jsonb, valid_from timestamp with time zone, valid_to timestamp with time zone, evidence_limit integer)")) and
  (.surfaces.ordinary.functions | index("pgreact.rule(name text, condition regclass, semantic_key name, kind text, on_activate regprocedure, on_deactivate regprocedure, on_change regprocedure, bootstrap_policy text, change_columns name[], salience integer, agenda_group text, conflict_key_columns name[], max_attempts integer, initial_backoff_seconds integer, backoff_multiplier numeric, max_backoff_seconds integer)")) != null and
  (.surfaces.ordinary.views | index("pgreact.rules")) != null and
  (.surfaces.advanced.views | index("pgreact.policy_set_contents")) != null and
  (.surfaces.administrative.views | index("pgreact.operational_status")) != null and
  ([.surfaces[].functions[]? | select(test("[*+?]"))] | length) == 0 and
  .actions == ["ADD", "KEEP", "REPLACE", "ADOPT", "REMOVE"] and
  .limits.review_token_bytes == 4096
' docs/api-inventory.json >/dev/null
cmp docs/api-inventory.json docs/m54-api-inventory.json
grep -Fq 'machine-readable API inventory' docs/api-reference.md
grep -Fq 'M54_REVIEW_TOKEN_INVALID' docs/m54-finding-codes.json

image=${1:-}
if [[ -z "$image" ]] || ! command -v docker >/dev/null 2>&1 || ! docker image inspect "$image" >/dev/null 2>&1; then
  echo 'M54 API inventory static audit passed; installed catalog audit not run'
  exit 0
fi

project=${COMPOSE_PROJECT_NAME:-pgreact-api-inventory-${GITHUB_RUN_ID:-$$}}
run_dir="tests/.api-inventory-${GITHUB_RUN_ID:-$$}"
artifact=${API_INVENTORY_ARTIFACT:-$run_dir/installed-catalog.json}
cleanup() {
  COMPOSE_PROJECT_NAME=$project docker compose down --volumes --remove-orphans >/dev/null 2>&1 || true
  rm -rf -- "$run_dir"
}
trap cleanup EXIT
mkdir -p -- "${artifact%/*}"
export COMPOSE_PROJECT_NAME=$project
export PG_REACT_IMAGE=$image
export PG_REACT_INIT_VERSION=0.43.1
docker compose up -d --no-build >/dev/null 2>&1
ready=
for _ in {1..120}; do
  if docker compose exec -T postgres psql -XAtq -U postgres -d postgres -c \
      "SELECT extversion = '0.43.1' FROM pg_extension WHERE extname = 'pg_react'" 2>/dev/null | grep -qx t; then
    ready=1
    break
  fi
  sleep 1
done
test -n "$ready"

docker compose exec -T postgres psql -XAtq -U postgres -d postgres -v ON_ERROR_STOP=1 -c \
  "SELECT jsonb_build_object(
     'functions', (SELECT COALESCE(jsonb_agg(jsonb_build_object(
       'identity', n.nspname || '.' || p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')',
       'return_type', pg_get_function_result(p.oid),
       'volatility', CASE p.provolatile WHEN 'i' THEN 'immutable' WHEN 's' THEN 'stable' ELSE 'volatile' END,
       'security_definer', p.prosecdef,
       'acl', COALESCE(p.proacl::text[], ARRAY[]::text[])
     ) ORDER BY n.nspname, p.proname, p.oid), '[]'::jsonb)
     FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname IN ('pgreact', 'pgreact_api')),
     'relations', (SELECT COALESCE(jsonb_agg(jsonb_build_object(
       'identity', n.nspname || '.' || c.relname,
       'kind', c.relkind,
       'acl', COALESCE(c.relacl::text[], ARRAY[]::text[])
     ) ORDER BY n.nspname, c.relname), '[]'::jsonb)
     FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname IN ('pgreact', 'pgreact_api') AND c.relkind IN ('r', 'p', 'v', 'm')));" > "$artifact"

jq -e '(.functions | all(has("identity", "return_type", "volatility", "security_definer", "acl"))) and
       (.relations | all(has("identity", "kind", "acl")))' "$artifact" >/dev/null
expected_functions=$(jq -c '[.surfaces[].functions[]? | split("(")[0]] | unique' docs/api-inventory.json)
expected_relations=$(jq -c '[.surfaces[].views[]?] | unique' docs/api-inventory.json)
expected_catalog_sha256=$(jq -r '.catalog.expected_catalog_sha256' docs/api-inventory.json)
jq -e --argjson expected_functions "$expected_functions" --argjson expected_relations "$expected_relations" '
  ([.functions[].identity | split("(")[0]] - $expected_functions | length) == 0 and
  ([.relations[].identity] - $expected_relations | length) == 0
' "$artifact" >/dev/null
actual_catalog_sha256=$(jq -S '{functions: .functions, relations: .relations}' "$artifact" | sha256sum | awk '{print $1}')
test "$actual_catalog_sha256" = "$expected_catalog_sha256"
echo "M54 installed API catalog audit passed: $artifact"
