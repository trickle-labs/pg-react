# v1 security

pg-react installs private-by-default. `PUBLIC` receives no access to the public API, private catalogs, or generated runtime schema. Installation requires a superuser; normal authoring and operation do not.

## Separate responsibilities

Use four connection classes:

- A rule author owns its condition view and typed consequence functions.
- An operator owns coordinated refresh, recovery, configuration, and rule administration.
- A worker may claim, heartbeat, and execute episodes but cannot read protected application schemas merely because it runs work.
- A reader can inspect selected public views and functions.

Apply the tested role and grant recipe in [M3 operations](m3-operations.md#roles-and-grants). In particular, run `pg-reactd` with a claim-only `DATABASE_URL` and a rule-owner or `pgreact_admin` `COORDINATOR_DATABASE_URL`. If the coordinator URL is omitted, the worker connection needs both privilege sets.

Authors need `USAGE` on `pgreact` plus only the validation, preview, creation, replacement, and inspection functions they use. Grant access to their own application schemas separately. Do not grant `pgreact_internal` or `pgreact_runtime`.

For M5 packs, grant the owner only the public pack functions it needs:

```sql
GRANT EXECUTE ON FUNCTION pgreact.validate_pack(jsonb, jsonb),
                          pgreact.preview_pack(jsonb, jsonb),
                          pgreact.deploy_pack(jsonb, text, jsonb),
                          pgreact.pack_history(text),
                          pgreact.explain_pack(text)
TO rule_author;
```

The logical owner may map to a different role name in each environment, but `deploy_pack` still requires that mapped role to equal `session_user`. Object mappings resolve names only and never grant access or bypass view/function ownership checks.

## Authoring checklist

- The author owns the condition view and every bound consequence function.
- The view does not depend on a table with enabled or forced RLS; v1 rejects RLS sources rather than guessing an evaluation role.
- Function identities are schema-qualified `regprocedure` values.
- Consequences accept the exact view row type, return `void`, and do not contain irreversible remote effects.
- Application writes are limited to the tables the consequence needs.
- Transactional outbox tables enforce uniqueness on `idempotency_key`.
- External consumers authenticate separately and deduplicate every delivery.

pg-react snapshots function identity and definition, generates an exact `SECURITY DEFINER` dispatcher owned by the rule owner, fixes its `search_path`, and revokes dispatcher access from `PUBLIC`. Execution rechecks the lease, current eligibility, source row signature, and function/dispatcher fingerprints before invocation. Do not replace this with dynamic SQL or direct calls into `pgreact_runtime`.

## Verify grants

Run these checks as an administrator, replacing role names as needed:

```sql
SELECT has_schema_privilege('pgreact_worker', 'pgreact', 'USAGE');
SELECT has_schema_privilege('pgreact_worker', 'pgreact_internal', 'USAGE');
SELECT has_table_privilege('pgreact_reader', 'pgreact.rules', 'SELECT');
SELECT has_function_privilege(
  'pgreact_worker',
  'pgreact.execute_claimed_episode(bigint,text,uuid)',
  'EXECUTE'
);
```

The first, third, and fourth results should be `true`; private-schema access should be `false`. Also verify that worker and reader roles are neither superusers nor members of application-owner roles.

## Unsupported security boundaries

v1 does not support RLS evaluation, custom run-as roles, dynamically supplied untrusted code, or remote calls from a database consequence. It does not make an external effect exactly once. Use a registered transactional outbox sink and an independently secured relay for work outside PostgreSQL.
