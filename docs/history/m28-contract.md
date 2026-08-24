# M28 contract — one ordinary PostgreSQL workflow

M28 is extension `0.25.0`. It adds an interaction layer; it does not add a
new rule language or change M0–M27 evaluation semantics.

## Ordinary workflow

The recommended path is:

```text
define → validate → preview → deploy → run → status / explain
```

Declarations use one versioned envelope and named fields:

```sql
SELECT pgreact_api.validate(
    pgreact_api.declaration(
        'rule', 'manual_review_required',
        jsonb_build_object(
            'condition', 'rule_def.high_value_risky_order',
            'semantic_key', 'order_id',
            'kind', 'COMMAND'))
);
```

`pgreact_api.target(kind, name, version)` is the names-first inspection
reference. UUIDs remain available for advanced historical work but are not
needed for the ordinary path.

## Frozen façade

| Operation | Contract |
| --- | --- |
| `validate(declaration)` | Read-only strict field and reference validation |
| `preview(declaration, options)` | Read-only normalized declaration and deterministic digest |
| `deploy(declaration, preconditions)` | Atomic declaration deployment with stale-preview checks |
| `remove(target, preconditions)` | Owner/operator removal of a façade declaration |
| `run(target, sampled_time)` | Delegates to the existing runtime for delegated objects |
| `status(target, options)` | Names-first state and digest inspection |
| `explain(target, subject, options)` | Common envelope with bounded subject evidence |
| `doctor(target, options)` | Read-only diagnostics and remediation guidance |

The result envelope has contract version `16` and stable top-level fields:
`operation`, `target`, `state`, `summary`, `findings`, `evidence`,
`diagnostics`, and `truncated`.

The checked-in inventory is also exposed as `pgreact.api_inventory`, including
function identity and arguments, result type, volatility, security-definer
status, grants, and ordinary/advanced classification.

## Supported boundary

The envelope accepts declarations for rules, derived programs, temporal
policies, shared conditions, effective-dated policies, parameter families,
decision programs, and decision analyses. Existing specialized APIs remain
the authoritative advanced and compatibility surfaces. The façade reuses
those APIs for rule and decision-program deployment and stores only the
canonical declaration metadata for kinds that need their existing specialized
workflow.

Unknown fields, unqualified relation names, missing required fields, unsafe
names, and unsupported kinds are errors before durable mutation. `PUBLIC`
receives no new access; role grants are added only by the existing
`configure_roles` path.

M28 is additive. The supported direct upgrade is:

```sql
ALTER EXTENSION pg_react UPDATE TO '0.25.0';
```
