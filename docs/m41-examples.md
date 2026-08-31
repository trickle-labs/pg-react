# M41 examples

Follow a selected decision result:

```sql
SELECT pgreact.explain(
    'order-routing', '100'::jsonb,
    '{"causal_path":{"root_kind":"decision_result","result_key":"9001"}}'
);
```

Follow one rule work item. First read its public episode identity:

```sql
SELECT episode_id AS work_id, activation_generation, activation_revision, event_kind
FROM pgreact.episodes
WHERE rule_version_id = (SELECT rule_version_id FROM pgreact.rules
                         WHERE name = 'manual-review-required');
```

Then ask for the path:

```sql
SELECT pgreact.explain(
    'manual-review-required', '100'::jsonb,
    jsonb_build_object('causal_path', jsonb_build_object(
        'root_kind', 'rule_work', 'work_id', '42', 'generation', 1,
        'revision', 0, 'event_kind', 'ACTIVATE'))
);
```

Read `state` before acting. `complete` means the bounded model reached facts;
`partial` or `unavailable` means the answer needs investigation.
