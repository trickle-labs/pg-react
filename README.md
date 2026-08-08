# pg-react

**Turn changing PostgreSQL data into durable decisions and work.**

> [!IMPORTANT]
> pg-react is currently a **design proposal**, not a released extension. The SQL API below describes the intended interface. Start with the [design document](DESIGN.md) for the complete semantics and implementation plan.

An order crosses a risk threshold. An invoice becomes overdue. Available stock falls below committed demand.

SQL can describe each condition, but a query result does not remember when a match first appeared, whether someone already handled it, or what should happen if it changes or disappears. pg-react is designed to add that memory.

A PostgreSQL view defines what is true now. [pg_trickle](https://github.com/trickle-labs/pg-trickle) maintains the result incrementally. pg-react turns meaningful changes in that result into durable lifecycle events and, when needed, work for a database function or external worker.

```text
ordinary PostgreSQL data
          |
          v
    condition view       SQL says what is true
          |
          v
      pg_trickle         keeps the result current
          |
          v
       pg-react          remembers what changed and records work
          |
          v
 function, worker,       acts inside PostgreSQL or through an outbox
 or outbox
```

## A rule in three steps

Suppose every high-value order from a high-risk customer needs manual review.

First, describe the condition with an ordinary view:

```sql
CREATE VIEW rule_def.high_value_risky_order AS
SELECT
    o.id          AS order_id,
    o.customer_id AS customer_id,
    o.amount
FROM app.orders AS o
JOIN app.customers AS c ON c.id = o.customer_id
WHERE o.amount > 10000
  AND c.risk_level = 'HIGH';
```

Then define a typed PostgreSQL function for the consequence:

```sql
CREATE FUNCTION rule_action.open_review(
    context pgreact.activation_context,
    match   rule_def.high_value_risky_order
)
RETURNS void
LANGUAGE SQL
BEGIN ATOMIC
    INSERT INTO app.manual_review_tasks (
        activation_id, order_id, customer_id, amount, condition_active
    )
    VALUES (
        (context).activation_id,
        (match).order_id,
        (match).customer_id,
        (match).amount,
        true
    )
    ON CONFLICT (activation_id) DO UPDATE
       SET customer_id = EXCLUDED.customer_id,
           amount = EXCLUDED.amount,
           condition_active = true;
END;
```

Finally, register the view, its semantic key, and the consequence:

```sql
SELECT pgreact.create_rule(
    name        => 'manual_review_required',
    definition  => 'rule_def.high_value_risky_order'::regclass,
    key_columns => ARRAY['order_id'],
    on_activate => 'rule_action.open_review(
        pgreact.activation_context,
        rule_def.high_value_risky_order
    )'::regprocedure
);
```

If order 42 enters the view, pg-react records one activation and one durable episode of work. Further updates do not open duplicate reviews while the same condition remains true. If the order leaves the view and later returns, a new activation generation begins and the rule may act again.

The condition remains SQL. The consequence remains a PostgreSQL function. The state connecting them is explicit and queryable.

## The lifecycle model

A maintained result tells you which conditions are true now. pg-react is designed to preserve how each match develops over time:

| Transition | Meaning | Optional consequence |
|---|---|---|
| A keyed row enters the result | A condition became true | `on_activate` |
| Its watched values change | The same condition evolved | `on_change` |
| The row leaves the result | The condition stopped being true | `on_deactivate` |
| The row stays unchanged | Nothing new happened | None |

All projected non-key columns are watched by default. A rule can choose a smaller `change_columns` set when some values are needed by a consequence but should not create a new revision.

Three kinds of state stay separate:

1. The match relation contains current truth.
2. Activation state records the lifecycle of each semantic match.
3. The agenda records requested work, leases, retries, and outcomes.

This separation preserves history when a condition disappears, prevents a rebuild from looking like new work, and gives operators a direct path from source facts to a completed or failed consequence.

## What pg-react is trying to achieve

- Use PostgreSQL SQL as the condition language. Views stay directly queryable, explainable, typed, and governed by normal permissions.
- Reuse incremental query maintenance. pg_trickle owns joins, aggregates, negation, windows, recursion, change capture, and refresh ordering.
- Give business matches stable identity. Authors choose semantic keys such as `order_id` or `(tenant_id, account_id, policy_id)` instead of relying on physical rows.
- Make work durable. Activations, immutable rule versions, agenda episodes, attempts, leases, retries, and audit history live in PostgreSQL.
- Keep side effects honest. Database consequences run transactionally; external effects use an at-least-once outbox with deterministic event identity that receivers must deduplicate.
- Stay inspectable. Conditions, current matches, pending work, execution history, source drift, and reconciliation state are available through SQL. Version one explains operational causality but does not promise automatic base-tuple lineage for every query.
- Leave room for reasoning. Later releases can add logical support, derived facts, provenance, and fixed-point evaluation without introducing a second truth store.

## Architecture

```mermaid
flowchart LR
    F[Base facts] --> V[Condition view]
    V --> T[pg_trickle match relation]
    T --> A[Activation lifecycle]
    A --> Q[Durable agenda]
    Q --> W[pg-reactd or application worker]
    W --> D[Database consequence]
    W --> O[Transactional outbox]
    D --> F
    O --> X[External system]
```

pg-react deliberately sits above pg_trickle instead of building another RETE or DBSP engine. It observes the maintained match relation and owns the rule-specific concerns: identity, activation generations, refraction, priorities, conflict handling, versioning, recovery, and audit history.

The proposed `pg-reactd` service executes command episodes outside PostgreSQL backend processes. It may claim several items efficiently, but it executes one episode per transaction by default and rechecks eligibility immediately before invoking a consequence. Slow network calls and external delivery remain outside the extension through an outbox.

## Rule types

**Constraint rules** maintain a live set of rows that satisfy or violate a condition. They need no worker and can power operational views, controls, and diagnostics.

**Command rules** add optional activation, change, and deactivation consequences. They support durable scheduling, retries, worker routing, priorities, and conflict keys.

**Derivation rules** are a later goal. They will represent logical support for derived facts and maintain those facts while at least one valid support remains.

## Where it fits

pg-react is a good fit when PostgreSQL holds the authoritative facts, conditions are naturally relational, actions may run asynchronously after commit, and durable SQL-visible lifecycle state matters. Examples include risk review, inventory intervention, billing controls, entitlement changes, fraud signals, SLA violations, approval queues, and data-quality remediation.

It is a poor fit when:

- the source write must wait for the action;
- one global total order is required;
- several systems must commit atomically;
- the workload is warehouse-scale distributed processing;
- the primary abstraction is a long-running human workflow; or
- arbitrary untrusted code must execute dynamically.

Those requirements need a synchronous application path, an ordered workflow engine, a distributed transaction protocol, a batch platform, or a sandbox designed for untrusted code. Any future synchronous pg-react mode would be a narrowly restricted database-local fixed-point facility, not a general workflow engine.

## Project status

The repository currently contains the design, not an implementation. The initial target is PostgreSQL 18 with Rust, `pgrx`, and a compatible pg_trickle release.

The planned delivery path starts with an integration spike and view-backed constraint rules, then adds lifecycle command rules, the durable agenda, and `pg-reactd`. Production hardening comes before shared-condition optimization or logical derivation.

The design is specific about the difficult parts up front: semantic transition coalescing, crash recovery, source-definition drift, immutable versions, concurrency, reconciliation after rebuilds, typed payloads, and the exact boundary of external delivery guarantees.

## Read more

- [DESIGN.md](DESIGN.md) contains the complete product semantics, SQL API, catalog, worker architecture, security model, testing strategy, and phased plan.
- [When PostgreSQL Data Needs to Do Something](the-trifecta.md) explains how pg_trickle, pg-react, and pg_tide divide the work.
- [PostgreSQL as an Operational Data Platform](operational-data-platform.md) places the projects in a broader operational loop.
- [pg_trickle](https://github.com/trickle-labs/pg-trickle) is the incremental view-maintenance engine pg-react is designed to build on.
- [pg_tide](https://github.com/trickle-labs/pg-tide) provides transactional messaging when consequences need to cross the database boundary.

## Naming

The project is **pg-react**. PostgreSQL and Rust identifiers use underscores: install `pg_react`, call functions in the `pgreact` schema, and run the optional worker as `pg-reactd`.

## License

This project is licensed under the [Apache License 2.0](LICENSE).
