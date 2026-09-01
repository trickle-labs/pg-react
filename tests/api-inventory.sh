#!/usr/bin/env bash
set -euo pipefail

jq -e '
  .schema_version == 1 and .extension_version == "0.43.0" and
  .classification_order == ["ordinary", "compatibility", "advanced", "administrative"] and
  (.surfaces | keys | sort) == ["administrative", "advanced", "compatibility", "internal_not_public", "ordinary"] and
  (.surfaces.ordinary.functions | index("pgreact.review_token(preview_result jsonb)")) != null and
  (.surfaces.ordinary.functions | index("pgreact.deploy(declaration pgreact_api.declaration, review_token text, preconditions jsonb)")) != null and
  (.surfaces.ordinary.functions | index("pgreact.rule(name text, condition regclass, semantic_key name, kind text, on_activate regprocedure, on_deactivate regprocedure, on_change regprocedure, bootstrap_policy text, change_columns name[], salience integer, agenda_group text, conflict_key_columns name[], max_attempts integer, initial_backoff_seconds integer, backoff_multiplier numeric, max_backoff_seconds integer)")) != null and
  (.surfaces.ordinary.views | index("pgreact.rules")) != null and
  (.surfaces.advanced.views | index("pgreact.policy_set_contents")) != null and
  (.surfaces.administrative.views | index("pgreact.operational_status")) != null and
  .actions == ["ADD", "KEEP", "REPLACE", "ADOPT", "REMOVE"] and
  .limits.review_token_bytes == 4096
' docs/api-inventory.json >/dev/null
cmp docs/api-inventory.json docs/m54-api-inventory.json
grep -Fq 'machine-readable API inventory' docs/api-reference.md
grep -Fq 'M54_REVIEW_TOKEN_INVALID' docs/m54-finding-codes.json
echo 'M54 API inventory audit passed'
