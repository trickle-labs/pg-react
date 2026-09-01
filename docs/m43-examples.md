# M43 examples

## Review a threshold and action change

```sql
SELECT pgreact_api.semantic_diff(
    pgreact_api.declaration('rule', 'payment-review', jsonb_build_object(
        'condition', 'review.proposed_payments',
        'semantic_key', 'payment_id',
        'kind', 'CONSTRAINT',
        'salience', 30,
        'on_activate', 'review.flag_payment(pgreact.activation_context, review.proposed_payments)' )),
    pgreact_api.target('rule', 'payment-review', '1'),
    jsonb_build_object('max_differences', 64));
```

The result can say that `spec.salience` changed and that the action binding was
added or changed. If the function body changed behind the same public binding,
the result also contains an opaque record with only public identity and digest
evidence.

## Review a decision period

```sql
SELECT pgreact_api.semantic_diff(
    pgreact_api.declaration('decision_program', 'routing', jsonb_build_object(
        'candidate_relation', 'review.proposed_routes',
        'subject_key', 'customer_id',
        'candidate_key', 'route_id',
        'priority', 'priority',
        'results', jsonb_build_array('provider', 'service_level'),
        'valid_from', '2026-09-01 00:00:00+00',
        'valid_to', '2026-10-01 00:00:00+00')),
    pgreact_api.target('decision_program', 'routing', '1'));
```

## Review policy-set applicability

```sql
SELECT pgreact_api.semantic_diff(
    pgreact_api.declaration('policy_set', 'eu-controls', jsonb_build_object(
        'version', '2026-09',
        'members', jsonb_build_array(
            jsonb_build_object('kind','rule','name','payment-review','version','1')),
        'applicability', jsonb_build_object(
            'source_kind','relation', 'relation','review.eu_accounts',
            'subject_key','account_id'),
        'valid_from', '2026-09-01 00:00:00+00')),
    pgreact_api.target('policy_set', 'eu-controls', '2026-08'));
```
