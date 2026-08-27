# M35 contract: hypothetical fact simulation

M35 targets extension `0.32.0`. It extends the M34 comparison functions so a
caller can supply one ordered set of typed row changes. The comparison reads
one complete current snapshot and does not write to the source relation or to
pg-react state.

## SQL surface

```text
pgreact.compare(proposed, deployed, change_set, options)
pgreact.compare_results(proposed, deployed, change_set, options)
```

The existing three-argument functions remain unchanged. `proposed` may be
`NULL` when the deployed declaration is also the proposal. `deployed` names one
deployed `rule`, `decision_program`, or `policy_set`.

`change_set` is a JSON array. Every item must contain exactly these fields:

```json
{
  "relation": "app.orders",
  "operation": "UPDATE",
  "ordinal": 1,
  "key": {"order_id": 10},
  "before": {"order_id": 10, "status": "review"},
  "after": {"order_id": 10, "status": "approved"}
}
```

The relation must be a direct table with no row-level security. The identity
column must be one non-null `bigint` column. The row image must name every
visible source column exactly once and use that column's PostgreSQL type.

- `INSERT` requires a null `before` image and an absent key in the snapshot.
- `UPDATE` requires matching `before` and `after` images. The identity cannot
  change.
- `DELETE` requires a matching `before` image and a null `after` image.

Ordinals are positive, unique integers. M35 applies changes in ordinal order.
An indirect dependency must not also appear as a direct change.

## Result and limits

The result keeps the M34 `current`, `proposed`, `delta`, `lifecycle`, and `work`
arrays. It also includes a change-set digest, source checksums, the source
frontier, sampled time, declaration digest, changed fact images, causal
evidence, and the cost of the read-only evaluation.

`options` accepts `evidence_limit` from 1 through 1000, `max_changes` from 1
through 1000, and the M34 `sampled_time` field. A partial result marks every
bounded array as incomplete and does not report exact delta counts.

Validation fails closed for missing or extra fields, duplicate ordinals,
conflicts, stale images, unsupported relations, unsupported target kinds,
unauthorized sources, row-level security, and resource limits. These failures
leave the source and pg-react checksums unchanged.

M35 reuses the M34 evaluator. It adds no predicate language, scenario store,
history replay, consequence execution, external delivery, or new ordinary
top-level verb.
