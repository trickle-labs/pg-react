# Configure roles and protect policy execution

[How-to guides](how-to/index.md) · [Installation](installation.md)

pg-react uses PostgreSQL ownership and privileges as its security boundary. In the **0.46.0 core profile**, you configure roles for authors, operators, workers, readers, and advanced readers, then grant application logins only the memberships they need. This makes the distinction between changing a policy, executing authorized work, and inspecting an outcome visible in the database's normal permission model.

## Configure the role groups

Create the groups and a dedicated worker login using the [installation procedure](installation.md#2-create-the-database-and-roles), then connect to each pg-react database as an administrator and configure its mapping:

```sql
SELECT pgreact_api.configure_roles(
    'pgreact_author',
    'pgreact_operator',
    'pgreact_worker',
    'pgreact_reader',
    'pgreact_advanced_reader'
);
```

| Role | Responsibility |
| --- | --- |
| Author | Validate, preview, deploy, replace, remove, run, and compare targets it is authorized to own. |
| Operator | Coordinate work, inspect health, pause and resume rules, and perform authorized repair and recovery. |
| Worker | Perform managed cycles or claim and execute already-authorized work. Worker membership does not grant policy deployment or ordinary comparison authority. |
| Reader | Inspect ordinary status, diagnostics, explanations, and comparisons, subject to source and target access. |
| Advanced reader | Use separately granted advanced inspection. This membership alone does not grant ordinary comparison. |

There is no separate installed deployer role. Grant group memberships to your application's actual login roles through your normal role-management process, and keep superuser access for extension installation and administration. The tutorial's superuser connection is a convenience for its disposable environment, not a required application privilege.

## Preserve ownership and source access

Authors must own, or inherit the owner role of, the condition or candidate relations and typed consequence functions they deploy. Authorized operator behavior follows its administrative contract. Use schema-qualified relation and function names so the declaration identifies the intended object, and retain the source definitions with the policy specification.

Evaluated sources must be caller-readable relations within the supported boundary. Comparison requires `SELECT` on the current and proposed sources it inspects, and sources protected by row-level security are rejected. Giving a caller permission to execute a comparison function does not grant access to every target or source. `M34_UNAUTHORIZED_TARGET`, `M34_UNAUTHORIZED_SOURCE`, and `M34_RLS_UNSUPPORTED` identify these different failures; fix the required access or choose a supported source design instead of expecting a redacted partial answer.

## Treat review tokens as evidence

A review token binds a successful preview to a target, declaration digest, and preview or plan digest. It contains no credentials or source rows and does not bypass ownership, permissions, source identity, current state, or barrier checks. Store it with the reviewed declaration when it is useful to your deployment process, but do not use possession of a token as a substitute for authorization.

If a token is stale, preview and review again. If it belongs to another declaration, reconstruct the intended proposal rather than reusing it. [Changing policies safely](changing-policies.md) explains how the token fits into a deployment, and [Troubleshooting](troubleshooting.md) lists the corresponding finding codes.

## Keep consequences safe to retry

Database consequences run transactionally with pg-react's execution state. Keep external network delivery outside those functions and write a transactional outbox request when an effect must leave PostgreSQL. A remote consumer may receive the same delivery again after a retry or recovery, so it must deduplicate a stable idempotency identity and retain that state for the required recovery window.

Secrets should stay in the appropriate deployment or credential-management system, not in declaration JSON, condition views, exported policy documents, logs, or explanation payloads. A source row used as policy evidence can appear in authorized inspection, so choose the projected data deliberately.

## Verify the public boundary

Use a representative application login to verify the operations it should and should not perform, including source access. As an administrator, these catalog checks help confirm that private schemas and comparison have not been exposed to the PostgreSQL `PUBLIC` pseudo-role:

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

The privilege checks should be false. Diagnose issues through public status, health, doctor, and explanation surfaces. Granting direct access to `pgreact_internal` or `pgreact_runtime`, or editing their rows to repair permissions, bypasses the supported application boundary. Use the role-configuration operation and the appropriate public repair workflow instead.
