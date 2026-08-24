# PostgreSQL as an operational data platform

Related documents: [The trifecta](the-trifecta.md), [Product thesis](pg-react_product_thesis.md), and [Practical rule-engine features](pg-react_practical_rule_engine_features.md).

> Current state: M34 and extension `0.31.0` are pg-react's qualified baseline. The repository retains the prepared `1.0.0-rc.1` candidate, but `1.0.0` and its complete feature freeze are postponed indefinitely while development continues one milestone at a time. Its qualified stack uses PostgreSQL 18.3 and pg_trickle 0.81.0 on Linux `amd64`. See the [support matrix](../docs/v1-support-matrix.md) for the complete boundary. This essay describes the cross-project architecture; each sibling project's documentation owns its current releases and APIs.

Warehouse 7 has promised 50 units of a product, holds 38, and learns that its replenishment shipment will arrive two days late. The shortage emerges from inventory, reservations, open orders, and shipment status. Someone needs to act before customers receive bad news, and procurement needs the decision.

PostgreSQL already holds the authoritative facts. Three projects give those facts distinct operational roles:

- [pg_trickle](https://github.com/trickle-labs/pg-trickle) maintains SQL results as source facts change.
- [pg-react](https://github.com/trickle-labs/pg-react) records policy state, lifecycle, decisions, and durable work from those results.
- [pg_tide](https://github.com/trickle-labs/pg-tide) is the delivery project in this architecture when work must cross the database boundary. Its own documentation defines its current delivery and receipt contracts.

```text
Authoritative facts
        |
        v
Current derived state       pg_trickle
        |
        v
Policy state and work       pg-react
        |
        v
External delivery           transactional outbox, optionally pg_tide
        |
        v
External outcomes return as new facts
```

This is a bounded operational loop. Applications commit facts. pg_trickle maintains eligible conditions at a coordinated refresh boundary. pg-react records the resulting lifecycle or decision and may create work. A transactional outbox records outgoing intent, and a relay carries it across the first boundary that PostgreSQL cannot commit through. Responses return through an application or inbox path as new facts.

Warehousing, business intelligence, file processing, synchronous authorization, and general workflow remain separate jobs.

## Operational data is about now

An analytical system may explain last quarter. An operational system must say whether warehouse 7 can still meet its promises and which intervention is already in progress.

Detecting a shortage creates an obligation with identity. The system must distinguish a new problem from one already handled, retain attempt state, and recover if a worker stops after claiming work.

Teams often assemble this behavior from an OLTP database, change-data capture, a stream processor, a rule service, a broker, retry workers, and application callbacks. The hard part is preserving business identity and transaction intent while data changes shape between those systems.

Keeping facts, current conditions, policy state, and work in PostgreSQL reduces that translation. Work leaves the database only when the effect requires another system.

## Maintained relations describe current conditions

The warehouse shortage is a SQL query. It joins inventory, reservations, open orders, and expected replenishments, then returns each warehouse and product whose expected supply is below committed demand.

In the qualified pg-react configuration, pg_trickle maintains eligible condition relations and pg-react coordinates explicit differential refresh. The pg_trickle scheduler remains off so the managed runtime observes one controlled maintenance boundary.

The maintained relation describes what is true now. Dashboards and other SQL can read it. pg-react treats each row as a current match, not as an event. The relation alone does not remember whether a shortage is new, changed, resolved, or recurring.

## pg-react records policy state

pg-react gives each logical match a semantic identity and lifecycle. When a warehouse and product first enter the shortage condition, pg-react records an activation. A command rule may also create durable work. If the shortage clears and later returns, pg-react starts a new generation instead of reviving work from the earlier period.

Constraint rules record current truth without consequences. Command rules may bind typed `on_activate`, `on_change`, and `on_deactivate` consequences. Work is claimable, leased, retried, completed, failed, or withdrawn according to the public runtime contract. Attempts remain queryable.

Rules are only one part of the current product. A decision declaration selects the lowest-priority candidate for each subject and makes tied winners `AMBIGUOUS`. A policy set groups rules and decisions under an immutable version and uses a relation to define applicability.

PostgreSQL-managed workers are the normal runtime. One worker runs for each configured database, coordinates maintenance, and drains eligible work. Execution happens after source data commits.

## Cross the external boundary with an outbox

A database consequence can update application state and complete pg-react work in one PostgreSQL transaction. An HTTP request or broker publish cannot share that local atomic commit.

The safe boundary is a transactional outbox. The consequence writes the business change and the outgoing intent in the same transaction. A rollback removes both. After commit, a relay delivers the message.

Delivery is at least once. A broken connection can hide whether the destination accepted an attempt, so a relay may send the same intent again. The receiver must deduplicate by stable identity. pg-react does not turn an unrelated remote system into part of a PostgreSQL transaction.

If procurement returns an expedited arrival date, the application or an inbox path stores that response as a new fact. pg_trickle updates the condition. pg-react then records whether the shortage remains active. The response uses the same fact-to-condition path as any other source change.

## Current pg-react capabilities

The ordinary v1 API provides typed constructors for rules, decisions, and policy sets. Authors use `validate`, `preview`, and `deploy`; operators use stable names, public views, `status`, `explain`, `doctor`, and documented recovery operations.

Installed advanced APIs support derived facts, bounded positive recursion, stratified negation and aggregation, shared conditions, temporal and effective-dated policy, parameter families, decision analysis, and bounded provenance.

M34 adds read-only declaration comparison. `pgreact.compare()` and `pgreact.compare_results()` compare a deployed and proposed rule, decision, or policy set over current authoritative facts. They expose bounded current, proposed, delta, lifecycle, and would-be work evidence without deployment or effects.

Comparison is not general simulation. It cannot change facts, replay history, or backtest policy. Rule comparison is limited to one non-null, unique `bigint` key, and partial results have no continuation token.

## Keep the boundaries explicit

The default flow is asynchronous. Source facts commit first. Managed maintenance records policy state and work later. Consequences that must finish before the source transaction returns belong in the application's synchronous path.

Independent workers do not share one global firing order. Priority and conflict keys influence eligible work, but they do not turn concurrent execution into a workflow with one total order.

External effects are at least once. Consumers must deduplicate. Cross-system atomic commit requires a distributed transaction protocol that this architecture does not provide.

Evaluated relations must be schema-qualified, readable by the caller, and free of RLS. Logical restore replays declarations after restoring application schema and data, then rebuilds and reconciles pg-react state. Portable restoration of live private catalogs is not part of the contract.

Historical analytics may still belong in a warehouse. Large file processing may belong in object storage and a compute engine. A process with centrally ordered human steps may belong in a workflow product.

## Where this platform fits

This model fits when PostgreSQL owns the facts, the condition is relational, and the response can run after the source transaction commits.

Examples include risk review, inventory intervention, billing controls, entitlement drift, reconciliation, SLA violations, and data-quality remediation. Several facts combine into a current condition. The transition matters. The response needs durable state or work.

Teams can adopt the pieces separately. pg_trickle can maintain operational SQL without pg-react. pg-react can drive database-local consequences without an external delivery project. An outbox and relay are needed only when work must leave PostgreSQL.

The warehouse shortage starts as ordinary rows. In this architecture it becomes a maintained condition, one durable lifecycle, explicit work, and, if needed, an outbox message. A later procurement response returns as another fact. PostgreSQL retains the policy state that connects each step.
