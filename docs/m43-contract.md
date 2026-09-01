# M43 contract: semantic policy differences

M43 is extension `0.40.0`. It answers one review question: “What changed in
this proposed policy compared with the deployed policy?” It compares the
canonical declarations already understood by pg-react. It does not run either
policy or guess what arbitrary SQL means.

## Operation

```sql
pgreact_api.semantic_diff(
    proposed pgreact_api.declaration,
    deployed pgreact_api.target,
    options jsonb DEFAULT '{}'
) returns jsonb
```

The proposed declaration and target must have the same name and kind. Supported
kinds are `rule`, `decision_program`, and `policy_set`. A target version selects
one deployed version; ordinary declarations use version `1`.

The operation reads one PostgreSQL statement snapshot and never deploys,
evaluates, refreshes, advances a frontier, creates work, captures evidence, or
calls an action. Missing, replaced, and inaccessible targets return the same
fail-closed `M43_TARGET_UNAVAILABLE` result.

## Result

The result always contains `contract_version: 43`, the state, both declaration
digests when available, ordered `differences`, `opaque` records, completeness,
limits, findings, a stable `semantic_digest`, reproducible cost counters, and
`read_only: true`.

Each difference has a stable `field_path`, `field_kind`, `change_kind` (`added`,
`removed`, or `changed`), and typed `before` and `after` values. Missing and
explicit JSON null are different values. Ordered lists preserve order. Policy
set members are a keyed set and are returned in canonical key order.

The inventory calls action-function references `function_identity` and decision
output columns `result_binding`; both remain opaque at the SQL boundary.

`opaque` records are separate from semantic differences. They expose only a
public relation or function identity and the stored and current definition
digests. They never assign business meaning, safety, or risk to SQL text,
relation definitions, or function bodies.

## Bounds

The options are `max_declaration_bytes` (65,536), `max_fields` (128),
`max_collection_members` (256), `max_differences` (128),
`max_opaque_records` (64), `max_nesting_depth` (8), and
`max_payload_bytes` (1,048,576). Each has a published upper ceiling. A reached
bound returns `partial`, the exact reached limit, and no claim about omitted
differences.

The complete field inventory is in
[`m43-api-inventory.json`](m43-api-inventory.json) and is exposed to the
installed implementation through `pgreact_internal.m43_field_inventory()`.
