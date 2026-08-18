# v1 security

pg-react uses PostgreSQL ownership, role membership, schema privileges, and
fixed-identity function calls. `PUBLIC` is not an application role, private
schemas are not an API, and protected sources fail closed.

## Installed role model

Configure exactly four application roles plus the advanced reader:

```sql
SELECT pgreact_api.configure_roles(
  'pgreact_author',
  'pgreact_operator',
  'pgreact_worker',
  'pgreact_reader',
  'pgreact_advanced_reader'
);
```

There is no separate deployer role.

| Role | Installed responsibility |
| --- | --- |
| Author | Validate, preview, deploy, replace, remove, and run targets it is authorized to own; compare proposed changes. |
| Reader | Read ordinary status, diagnostics, explanations, and comparisons. |
| Worker | Run managed cycles or claim and execute already-authorized durable work; no deploy or comparison authority. |
| Operator | Coordinate runs, inspect health and work, pause/resume, reconcile, recover, and compare. |
| Advanced reader | Use separately granted advanced read-only inspection. This role alone is not granted ordinary comparison. |

Grant login roles membership in these group roles. Do not grant application
users superuser, direct private-schema access, or worker authority merely to
solve an authoring or diagnostic problem.

## Ownership and source access

Authors must own, or be a member of the owner of, the condition/candidate
relations and typed consequence functions they deploy. Operators retain the
documented administrative override. Source objects must be schema-qualified.

Evaluated sources must be ordinary caller-readable PostgreSQL relations.
Sources protected by row-level security are rejected rather than evaluated
through a policy-dependent view. Comparison also requires `SELECT` on every
current and proposed source it inspects. An unauthorized source fails with
`M34_UNAUTHORIZED_SOURCE`; an RLS source fails with
`M34_RLS_UNSUPPORTED`.

Do not use `pgreact_internal` or `pgreact_runtime` objects as application
sources. Their schema access and function execution are revoked from
`PUBLIC` and from the configured application roles.

## Comparison authorization

Only the configured author, operator, and reader roles receive execution
privileges on `pgreact.compare` and `pgreact.compare_results`.

Execution privilege alone is insufficient:

- the proposal kind and name must match the deployed target;
- the caller must own or inherit the target owner, be the configured
  operator, or be the configured reader;
- the caller must have `SELECT` on the evaluated sources.

Unauthorized target inspection fails with `M34_UNAUTHORIZED_TARGET`.
Unauthorized comparison returns no comparison rows or protected values.
There is no proven row-redaction substitute that returns a safe subset; grant
the required access or do not compare the target.

Fresh 0.31.0 installations must apply the explicit comparison grants shown in
the [installation guide](v1-installation.md) after `configure_roles`. Upgrades
from an already configured 0.30.0 installation receive those grants during the
0.31.0 migration. The fresh-install grant ordering is an RC blocker.

## `PUBLIC` and security-definer safety

The installed SQL revokes `PUBLIC` usage/execution from private schemas and
public API functions before granting named roles. Public `SECURITY DEFINER`
routines fix `search_path` to:

```text
pg_catalog, pg_temp
```

This prevents caller-controlled schemas from changing object resolution.
Application SQL should still schema-qualify its own relations and functions.

Verify the boundary:

```sql
SELECT has_schema_privilege('public', 'pgreact_api', 'USAGE');
SELECT has_schema_privilege('public', 'pgreact_internal', 'USAGE');
SELECT has_schema_privilege('public', 'pgreact_runtime', 'USAGE');
SELECT has_function_privilege(
  'public',
  'pgreact.compare(pgreact_api.declaration,pgreact_api.target,jsonb)',
  'EXECUTE'
);
SELECT pgreact.doctor();
```

The privilege checks must be false. Diagnose findings through public status,
doctor, health, and explanation surfaces. Never repair security state by
editing private catalogs or granting private-schema access.
