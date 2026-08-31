# M42 examples

## Keep one decision result

Add a finite retention period to the declaration:

```sql
SELECT pgreact_api.deploy(
    pgreact_api.declaration(
        'decision_program',
        'order-routing',
        jsonb_build_object(
            'candidate_relation', 'app.order_routes',
            'subject_key', 'order_id',
            'candidate_key', 'route_id',
            'priority', 'priority',
            'results', jsonb_build_array('route'),
            'evidence_snapshot', jsonb_build_object('retention_seconds', 2592000)
        )
    )
);
```

Capture a complete current result:

```sql
SELECT pgreact_api.capture_evidence_snapshot(
    pgreact_api.target('decision_program', 'order-routing', '1'),
    '1001'::jsonb,
    '{"root_kind":"decision_result","result_key":"42"}'::jsonb,
    'audit-2026-08-31'
);
```

Save `metadata.root_identity` from the response. Read it later without reading
the source tables:

```sql
SELECT pgreact_api.read_evidence_snapshot(
    pgreact_api.target('decision_program', 'order-routing', '1'),
    'decision_result:order-routing@1:subject=1001:candidate=42',
    'audit-2026-08-31'
);
```

Delete the snapshot after `deletion_eligible_at`:

```sql
SELECT pgreact_api.delete_evidence_snapshot(
    pgreact_api.target('decision_program', 'order-routing', '1'),
    'decision_result:order-routing@1:subject=1001:candidate=42',
    'audit-2026-08-31'
);
```
