# Authoring Rules and Policies

The current release is pg-react `0.43.0`. Application code normally uses the
ordinary declaration path:

```sql
WITH declaration AS (
    SELECT pgreact.rule(
        name => 'review-orders',
        condition => 'rule_def.review_orders'::regclass,
        semantic_key => 'order_id'::name,
        kind => 'COMMAND',
        change_columns => ARRAY['amount', 'status']::name[],
        conflict_key_columns => ARRAY['customer_id']::name[]
    ) AS value
)
SELECT pgreact.validate(value) FROM declaration;
```

Validate first, preview second, and deploy only the reviewed result. A
`COMMAND` rule with executable consequences must name its consequences and use
an idempotent database effect. `CONSTRAINT` rules describe durable matches and
do not run consequences.

`change_columns` and `conflict_key_columns` use the installed source-view
rules. Columns must be projected by the condition, and a semantic key cannot
also be a watched change column. Omit `change_columns` to retain the existing
default watched-column behavior; an explicit empty array remains distinct.

Decision declarations use the same validate, preview, and deploy path. Use
[Changing Policies Safely](changing-policies.md) for replacements and
[API Reference](api-reference.md) for the complete current surface.
