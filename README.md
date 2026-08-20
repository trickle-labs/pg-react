# pg-react

**Turn changing PostgreSQL facts into durable, inspectable policy state and work.**

pg-react is a PostgreSQL-native rule and policy engine. Conditions are ordinary
relations or views; declarations are typed SQL values; lifecycle, decisions,
work, attempts, and explanations remain queryable in PostgreSQL.

The repository currently targets `1.0.0-rc.1`. Its v1 feature baseline is
M34 / extension `0.31.0`, including read-only comparison of a proposed rule,
decision, or policy set before deployment. Start with the
[documentation home](docs/index.md).

## Choose a path

| Audience | Start here | Main question |
|---|---|---|
| Application developer | [Getting Started](docs/getting-started.md) | How do I define and deploy a first rule? |
| PostgreSQL developer | [Order review showcase](showcase/order-review/README.md) | How do facts, views, consequences, and durable work fit together? |
| Operator | [Operations](docs/v1-operations.md) | How do I inspect, retry, pause, replace, and remove work? |
| Reviewer or architect | [Concepts](docs/concepts.md) and [Changing Policies Safely](docs/changing-policies.md) | What does pg-react guarantee, and where are the boundaries? |

```text
authoritative PostgreSQL facts
             |
             v
      condition relation
             |
             v
     lifecycle / decision
             |
             v
       durable work
```

## A first rule

This constraint rule records the high-risk orders that currently require
review:

```sql
CREATE VIEW rule_def.high_value_risky_order AS
SELECT o.order_id, o.customer_id, o.amount
FROM app.orders AS o
WHERE o.risk_level = 'HIGH'
  AND o.amount > 10000;

SELECT pgreact.validate(pgreact.rule(
    name         => 'manual-review-required',
    condition    => 'rule_def.high_value_risky_order'::regclass,
    semantic_key => 'order_id'::name
));

SELECT pgreact.preview(pgreact.rule(
    name         => 'manual-review-required',
    condition    => 'rule_def.high_value_risky_order'::regclass,
    semantic_key => 'order_id'::name
));

SELECT pgreact.deploy(pgreact.rule(
    name         => 'manual-review-required',
    condition    => 'rule_def.high_value_risky_order'::regclass,
    semantic_key => 'order_id'::name
));
```

`pgreact.rule()` defaults to `kind => 'CONSTRAINT'`. A rule with
`on_activate`, `on_change`, or `on_deactivate` consequences must explicitly use
`kind => 'COMMAND'`. See [Getting Started](docs/getting-started.md) for the
complete managed-runtime workflow.

## What pg-react provides

- **Rules:** stable semantic identity, current matches, activation generations,
  revisions, typed consequences, retries, and explanations.
- **Decisions:** candidate evaluation with explicit winner, ambiguity, and
  no-candidate states.
- **Policy sets:** versioned membership and relational applicability.
- **Safe changes:** `pgreact.compare()` and `pgreact.compare_results()` compare
  current and proposed declarations over current authoritative facts without
  deploying or executing effects.
- **Advanced reasoning:** installed public surfaces include maintained derived
  facts and logical support, bounded positive recursion, stratified negation
  and aggregation, shared conditions, temporal and effective-dated policies,
  parameter families, provenance, and decision analysis. These are advanced
  APIs, not required for the ordinary first-rule path.

PostgreSQL-managed workers are the normal runtime. One managed worker is
started for each configured database, polls on
`pg_react.poll_interval_ms`, coordinates maintenance, and drains eligible
work. The external `pg-reactd` program is a compatibility path; it can call
`pgreact_api.run()` and therefore can create work as well as drain it.

## Compare before deploying

Comparison varies the declaration, not the facts:

```text
current facts + deployed declaration
versus
current facts + proposed declaration
```

It reports bounded `current`, `proposed`, `delta`, `lifecycle`, and would-be
`work` evidence. It does not support hypothetical fact changes or historical
replay. Rule comparison is limited to one `bigint` key even though separate
advanced installed authoring surfaces support broader typed keys.

## Guarantees and boundaries

- PostgreSQL remains the authoritative fact store.
- Database consequences and their pg-react state changes use PostgreSQL
  transactions.
- External delivery is at least once; consumers must deduplicate.
- Private schemas and internal UUIDs are not part of the ordinary API.
- Comparison is bounded and may be `partial`; it has no continuation token.
- pg-react is not a synchronous write-path hook, a global-ordering service, a
  distributed transaction coordinator, or a general workflow/BPM engine.

The qualified `1.0.0-rc.1` environment is PostgreSQL 18.3, pg_trickle 0.81.0,
pgrx 0.18.0, Linux `amd64`, `READ COMMITTED`, and the PostgreSQL-managed
runtime. See the [Support Matrix](docs/v1-support-matrix.md) before adopting it.

## Documentation

- [Glossary](GLOSSARY.md)
- [Getting Started](docs/getting-started.md)
- [Order review showcase](showcase/order-review/README.md): a runnable PostgreSQL example covering rules, durable review work, routing decisions, retries, policy applicability, and side-effect-free comparison.
- [Concepts](docs/concepts.md)
- [Authoring Rules and Policies](docs/v1-authoring.md)
- [Changing Policies Safely](docs/changing-policies.md)
- [Operations](docs/v1-operations.md)
- [API Reference](docs/v1-api-reference.md)
- [Known Limitations](docs/v1-known-limitations.md)

Release and milestone evidence is available through
[History](docs/history.md), not required for normal use.

## Naming

The project is **pg-react**. PostgreSQL and Rust identifiers use underscores:
install `pg_react` and call the public `pgreact` or `pgreact_api` SQL surfaces.

## License

Licensed under the [Apache License 2.0](LICENSE).
