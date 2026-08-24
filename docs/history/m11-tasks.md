# M11 tasks

`pgreact_api` is the supported application schema in `0.8.0`. Keep engine
schemas private and grant only this schema to application roles:

```sql
GRANT USAGE ON SCHEMA pgreact_api TO rule_author, rule_operator, rule_worker;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA pgreact_api
    TO rule_author, rule_operator, rule_worker;
```

Validate and author an ordinary view-backed rule by name. The action identity
is text so an author does not have to resolve internal PostgreSQL identifiers.

```sql
SELECT code, severity, message
FROM pgreact_api.validate_rule(
    'rule_def.high_value_risky_order'::regclass,
    'order_id',
    'rule_action.open_review(pgreact.activation_context,rule_def.high_value_risky_order)'
);

SELECT pgreact_api.author_rule(
    'manual_review_required',
    'rule_def.high_value_risky_order'::regclass,
    'order_id',
    'COMMAND',
    'rule_action.open_review(pgreact.activation_context,rule_def.high_value_risky_order)'
);
```

Use the JSON pack overloads for a released `0.7.0` pack while migrating a rule
set, then inspect and operate by its name:

```sql
SELECT * FROM pgreact_api.validate_rule(:'pack'::jsonb, '{}'::jsonb);
SELECT pgreact_api.author_rule(:'pack'::jsonb, '{}'::jsonb);
SELECT pgreact_api.rule_status('manual_review_required');
SELECT pgreact_api.explain_rule('manual_review_required');
SELECT pgreact_api.run_rule('manual_review_required');
SELECT pgreact_api.health();
```

Workers claim and complete durable work through `pgreact_api.claim` and
`pgreact_api.execute`. Protocols 1 and 2, batch handling, physical backup/PITR,
and recovery keep their M10 behavior. Stop workers before `ALTER EXTENSION`,
take the tested physical backup, upgrade to `0.8.0`, check `health()`, then
resume them. There is no downgrade; restore that backup to roll back.

If validation, deployment, or execution is rejected, retain the returned
diagnostic envelope and use its code, hint, and details. Do not query engine
catalogs or fabricate lower-level durable identifiers.
