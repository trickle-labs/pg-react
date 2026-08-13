# PostgreSQL as an Operational Data Platform

Related vision documents: [The trifecta](the-trifecta.md) · [Product thesis](pg-react_product_thesis.md) · [30-milestone vision](pg-react_30_milestone_vision.md) · [Practical rule-engine features](pg-react_practical_rule_engine_features.md)

Warehouse 7 has promised 50 units of a product, holds 38, and just learned that its replenishment shipment will arrive two days late. The shortage emerges from inventory, open orders, reservations, and shipment status rather than any single row. Someone needs to intervene before customers receive bad news, and the procurement system needs to know.

For an operations team, the useful answer must arrive while there is still time to act. The system must also remember the action, deliver it, and incorporate the response.

PostgreSQL already holds the facts and provides transactions, SQL, indexes, permissions, backup, and recovery. Three projects extend those strengths into an operational loop:

- [pg_trickle](https://github.com/trickle-labs/pg-trickle) keeps derived SQL results current as source data changes.
- [pg_react](https://github.com/trickle-labs/pg-react) is the PostgreSQL-native rule and lifecycle layer that turns meaningful changes in those results into durable decisions and work.
- [pg_tide](https://github.com/trickle-labs/pg-tide) delivers that work and records incoming message identities so retries can be deduplicated.

The three projects let PostgreSQL maintain operational state and act on it, while preserving the facts behind each action.

```text
Authoritative facts
        │
        ▼
Current derived state       pg_trickle
        │
        ▼
Durable decisions           pg_react
        │
        ▼
Messages and commands       pg_tide
        │
        ▼
External outcomes return as new facts
```

Here, "complete" describes a bounded operational loop. Applications commit facts, pg_trickle maintains current state, pg_react creates work from meaningful changes, pg_tide delivers it, and outcomes return to the system of record. Warehousing, business intelligence, cataloging, and large-scale file processing remain separate jobs.

The pg-react repository has implemented M0–M17, adding derived facts, recursion, negation, aggregates, database-time deadlines, fixed UTC tumbling windows, durable watermarks, ordered corrections, and bounded history. pg_trickle is under active pre-1.0 development. Check the current releases and compatibility requirements before adopting the stack.

## Operational data is about now

An analytical system may explain last quarter or compare customer cohorts. An operational system has to tell warehouse 7 whether it can still fulfill its promises, identify the account that needs review, or detect the service that has exceeded its error budget.

Detecting a shortage creates an obligation that may need an owner, a deadline, a retry policy, or a message sent to another system. The platform has to distinguish a new problem from one already handled and preserve the response if a worker crashes.

Teams often assemble that behavior from an OLTP database, CDC pipeline, stream processor, rule service, broker, retry workers, and application callbacks. Each component can be excellent. Preserving identity and transaction intent across all of them is the difficult part.

As data moves, a customer ID may be recast as a message key, a query result as an event, and that event as a workflow instance. Logs often become the only record connecting the stages. When delivery fails or a condition reverses, operators must reconstruct which system believed what and when.

A PostgreSQL-native platform keeps authoritative facts, derived state, decision history, and delivery state in relations until work has to leave the database.

## Keep derived state current

The warehouse shortage can be expressed as SQL. Join inventory with reservations and open orders, include expected replenishments, then return each product and warehouse whose available supply falls below committed demand.

Running that query occasionally produces a report. Running it after every source write wastes work as the tables grow. pg_trickle turns the query into a **stream table** and maintains its result incrementally. A new order, stock adjustment, or delayed shipment updates only the affected part of the result.

The maintained result remains a PostgreSQL relation. Applications can query it, index it, join it with other relations, grant access to it, and include it in normal backup and recovery. Teams do not have to translate the condition into a separate streaming language or treat the result as an opaque cache owned by another service.

That relation is also a stable representation of what is true now. Dashboards can read it directly, other derived relations can build on it, and rules can observe rows entering, changing, and leaving.

For warehouse 7, pg_trickle can keep the shortage visible for as long as committed demand exceeds expected supply. It does not decide whether to page an operator, create a replenishment request, or suppress a duplicate alert. Those decisions need memory.

## Give decisions a history

A stateless callback sees the shortage every time an input changes. Without durable context, it may open five tickets for the same underlying problem or lose track of a ticket when the result is rebuilt.

pg_react is designed to give each logical match a stable identity and lifecycle. When the warehouse-product pair first enters the shortage relation, the rule records an activation and creates a durable agenda episode. Changes while the shortage remains active can update its payload or create separate `on_change` work. When supply catches up, the activation ends and may produce an `on_deactivate` consequence. Derived facts, stratified negation, aggregate thresholds, deadlines, and event-time windows build upon this same lifecycle foundation with durable supports and watermarks.

The rule responds to business transitions rather than raw row operations. It can open one intervention when the shortage begins, avoid duplicates while it continues, and open a new intervention if the shortage clears and later returns.

pg_react stores the agenda in PostgreSQL, including pending, leased, completed, failed, withdrawn, and cancelled work. Leases and retries let another worker recover an episode after a crash. Conflict keys can stop two actions for the same warehouse or account from running at once. Immutable rule versions preserve the meaning of work created under an older policy.

Current truth and historical work stay separate. pg_trickle says which shortages exist now. pg_react records how each shortage developed and which work the rule created. An operator can inspect both—and trace bounded causal provenance—without inferring state from application logs.

## Cross system boundaries without losing intent

Some consequences belong inside PostgreSQL. A worker can create an intervention record and complete its agenda episode in one transaction. Other consequences must reach procurement software, a carrier, a broker, or an HTTP service.

Calling the external system inside the transaction does not make the two systems atomic. PostgreSQL might commit after the remote call succeeds, or the remote call might fail after PostgreSQL commits. Either order can leave the systems disagreeing.

pg_tide provides the transactional outbox for this boundary. The worker records the outgoing command in the same PostgreSQL transaction that completes the episode and applies any local change. A rollback removes all of them. After commit, a relay delivers the message and retries failures.

Delivery is at least once because a broken connection can hide whether the receiver accepted the previous attempt. Each message carries a stable identity so a participating destination can reject duplicates. pg_tide's inbox applies the same principle to messages returning to PostgreSQL.

Suppose procurement responds with an expedited shipment. The inbox records the response, and the application stores the new arrival estimate as another fact. pg_trickle updates the shortage relation. pg_react sees whether the intervention is still needed. The loop closes without inventing a special path for the response.

## The loop is the platform

The shared PostgreSQL substrate turns these extensions into a platform. Facts, maintained results, activations, episodes, execution attempts, inbox entries, and outbox messages all have durable identities. Transactions define which local changes belong together, and SQL remains the language for conditions and inspection.

An operator can trace a command back through its outbox message, episode, activation, maintained result, and source facts. If the result later vanishes, the activation preserves its history. If a worker completes an external episode, the outbox row can commit with that completion. A process restart leaves pending agenda work in PostgreSQL.

Permissions, backup, point-in-time recovery, and replication also cover the state that explains each decision. The platform uses the database's existing operational machinery instead of creating a second truth store for derived state and work.

The projects remain useful independently. A team can adopt pg_trickle for maintained operational views, pg_tide for transactional messaging, or pg_trickle with pg_react for database-local automation. Each addition solves a specific problem without forcing a platform migration first.

```text
PostgreSQL provides       transactions, SQL, security, recovery
pg_trickle provides       current derived state
pg_react provides        lifecycle, policy, and durable work
pg_tide provides          reliable delivery and receipt
```

Failures remain visible at the stage that owns them. Refresh lag appears in maintained-state progress, unclaimed or failed work appears in the agenda, and undelivered messages remain in the outbox. Operators can find the stalled stage without comparing timestamps across unrelated services.

## Keep the boundaries explicit

Historical analytics may still belong in a warehouse. Large-scale file processing may belong in an object store and compute engine. Source ingestion may still use connectors or application APIs. This platform covers the operational loop around facts already committed to PostgreSQL.

Independent pg_react workers do not share one global firing order. Priorities and agenda groups influence execution, but distributed work remains concurrent. A process that requires centrally ordered steps should use a workflow engine built around that guarantee.

External delivery is at least once. PostgreSQL can atomically commit local state with an outbox message, but it cannot atomically commit with an unrelated broker or HTTP service without a shared distributed transaction protocol. Receivers must honor idempotency keys.

The default flow is asynchronous. pg_trickle refreshes at its configured boundary, pg_react records work from that maintained state, and a worker executes later. Actions that must complete before the original transaction returns belong in the application's synchronous path.

The platform owns the durable operational loop inside PostgreSQL and defines the contract for systems that participate beyond it.

## Where it fits

This model works best when PostgreSQL is the authoritative source, the condition is relational, and the response can run after the source transaction commits.

It fits risk review, inventory intervention, billing controls, entitlement changes, fraud signals, SLA violations, approval queues, and data-quality remediation. In each case, several facts combine into a current condition, the transition matters more than another physical update, and the response needs durable execution or reliable delivery.

Many operational applications already have the essential foundation: a transactional, relational account of the business. pg_trickle can keep important interpretations of that account current. pg_react can remember which interpretations became actionable. pg_tide can carry the resulting intent across system boundaries.

A warehouse shortage begins as several ordinary rows. On this platform, it becomes current state, one durable intervention, a reliably delivered command, and eventually a new fact that resolves the condition. PostgreSQL carries the decision from current data, through action, and back into current data with durable state at every step. The broader vision expands this into a full policy platform—supporting shared conditions, effective-dated and parameterized policy, deterministic decision tables, what-if simulation, and backtesting—while keeping PostgreSQL the single authoritative foundation.
