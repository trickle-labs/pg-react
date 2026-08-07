# From Change to Consequence: A PostgreSQL-Native Trifecta

PostgreSQL is very good at recording what happened. The harder work usually begins afterward.

A row changes. A derived metric must be recalculated. A business condition becomes true. A task needs to be scheduled. An event must reach another service. Before long, one database change is moving through a collection of refresh jobs, CDC connectors, streaming platforms, rule engines, workflow services, queues, and custom retry code.

[pg_trickle](https://github.com/trickle-labs/pg-trickle), [pg_reason](https://github.com/trickle-labs/pg-reason), and [pg_tide](https://github.com/trickle-labs/pg-tide) offer a different model: keep the authoritative state, decision logic, and delivery guarantees close to PostgreSQL while giving each concern a clear boundary.

Together, they answer three questions:

| Project        | Core question                                          |
| -------------- | ------------------------------------------------------ |
| **pg_trickle** | What is true now?                                      |
| **pg_reason**  | What does that truth mean, and should anything happen? |
| **pg_tide**    | How does the resulting event or command move reliably? |

```text
Application facts
       │
       ▼
  pg_trickle
Maintain current derived truth
       │
       ▼
   pg_reason
Recognize conditions and schedule consequences
       │
       ▼
    pg_tide
Deliver events to the wider system
```

This is not simply a collection of PostgreSQL extensions. It is a composable path from **data**, to **decision**, to **delivery**.

> **Project-status note:** pg_reason is currently a proposed design, so its role below describes the intended architecture. pg_trickle is also pre-1.0 and under active development. Teams should evaluate the current release and compatibility status of each component before production adoption.

## pg_trickle: Keep derived truth continuously fresh

Most applications contain important queries whose results are expensive to calculate but need to remain current: revenue by region, inventory availability, account risk, service health, customer eligibility, recommendation candidates, or unresolved data-quality findings.

A conventional PostgreSQL materialized view gives you a stored result, but keeping it fresh usually means rerunning the entire query. That is wasteful when millions of source rows exist and only a handful have changed.

pg_trickle introduces **stream tables**: tables defined by SQL queries that are maintained automatically as their source data changes.

Instead of recomputing an entire result, pg_trickle uses incremental view maintenance. An insert, update, or delete becomes a delta that is propagated through the query’s filters, joins, aggregates, windows, subqueries, and other supported operators. Change one source row, and the system calculates the effect of that change rather than starting over.

Stream tables can also depend on other stream tables. That makes it possible to construct a graph of derived state in which changes flow through each layer in dependency order.

The value is straightforward:

* Derived data stays fresh without application-managed refresh jobs.
* Work is generally proportional to the amount of change rather than the total dataset.
* Teams continue to express transformations in SQL.
* The maintained result remains an ordinary PostgreSQL relation that applications can query, index, secure, back up, and inspect.

In other words, pg_trickle turns PostgreSQL from a database that can *calculate* derived truth into one that can *continuously maintain* it.

But knowing what is true is not the same as knowing what should happen.

A maintained table can tell us that order 42 now requires manual review. It does not, by itself, tell us whether this is a new condition, whether a review was already requested, which review has priority, or what to do if the condition disappears before anyone handles it.

That is the boundary where pg_reason begins.

## pg_reason: Turn changing truth into durable decisions

pg_reason is designed as a PostgreSQL-native rule and reasoning layer built on pg_trickle.

A rule begins with an ordinary SQL query. Every row returned by that query represents a situation in which the rule is currently true. pg_trickle maintains those matches incrementally; pg_reason adds the semantics needed to interpret their evolution.

Consider a rule for large orders placed by high-risk customers. Its match query might return an order whenever both conditions are true.

pg_trickle maintains the current set of matching orders. pg_reason then distinguishes among several meaningful transitions:

* An order appears in the result for the first time.
* The order remains in the result, but its amount or other payload changes.
* The order disappears because it no longer satisfies the rule.
* The order becomes eligible again after previously becoming ineligible.

Those differences matter. A simplistic trigger might create a new review task every time the maintained row is updated. pg_reason instead gives each match a stable semantic identity and tracks its active interval as an episode.

By default, a command rule fires when the match changes from false to true. It does not fire repeatedly merely because non-key data changes while the condition remains true. If the condition later becomes false and then true again, a new episode may be created. This production-rule behavior is often called **refraction**.

On top of that transition model, pg_reason is designed to provide:

* Constraint rules that continuously expose current violations or findings.
* Command rules that create work on meaningful transitions.
* Priorities and agenda groups.
* Conflict keys that prevent incompatible actions from running concurrently.
* Durable leases, heartbeats, retries, and failure states.
* Immutable rule versions and controlled deployment.
* Execution history and auditability.
* Reconciliation after refreshes, restores, or failures.
* A future path toward derived facts, logical support, and truth maintenance.

A particularly important design choice is the separation of **current truth** from **historical work**.

The pg_trickle match table answers, “Which situations are true now?”
The pg_reason activation state answers, “How has each situation evolved?”
The pg_reason agenda answers, “What work was requested, and what happened to it?”

If a condition disappears, its current activation can be deactivated without erasing the fact that an earlier action was scheduled or completed. That separation makes the system easier to debug, audit, and explain.

Some consequences can be completed entirely inside PostgreSQL. A database handler might create a review record, update an account status, or insert a derived business fact in the same transaction that records successful execution.

Other consequences must leave the database. They may need to reach Kafka, NATS, an HTTP service, an analytics platform, an email provider, or another PostgreSQL instance. Performing those effects directly inside a database transaction would be slow and unsafe.

That is the boundary where pg_tide takes over.

## pg_tide: Move events without dual writes

pg_tide provides a transactional outbox, an idempotent inbox, and relay pipelines for PostgreSQL.

The transactional outbox addresses one of the most common failure modes in distributed applications. Suppose an application updates an order and then publishes an event to a broker:

1. The database commit succeeds.
2. The broker call fails.
3. The system now contains a changed order but no corresponding event.

Reversing the order creates the opposite problem: the event can be published even though the database transaction later rolls back.

With pg_tide, the business change and the outbox message are written in the same PostgreSQL transaction. Either both commit or neither does. A separate relay then delivers committed messages to external systems using at-least-once delivery, deduplication, retry handling, and high-availability coordination.

The inbox provides the complementary capability for incoming events. Unique event identifiers allow consumers to recognize redelivery and avoid processing the same logical message repeatedly.

pg_tide’s relay can connect PostgreSQL to streaming platforms, cloud messaging systems, HTTP endpoints, notification services, analytical databases, object stores, and other destinations. Configuration lives in PostgreSQL and can be changed without rebuilding the application that created the event.

The result is a messaging boundary that preserves database transactionality without pretending PostgreSQL and an unrelated external service can participate in one magical exactly-once transaction. Delivery may be repeated, but stable event identities and idempotent consumers make that repetition safe and observable.

## How the three work together

Imagine an order-processing system with the following policy:

> When an order from a high-risk customer exceeds €10,000, request a manual review and notify the risk platform.

Here is how the complete flow can work.

### 1. The application writes ordinary facts

The application inserts or updates orders and customers using normal PostgreSQL transactions. It does not need to run the rule itself or remember which downstream systems should be notified.

### 2. pg_trickle updates the relevant truth

A stream table represents the SQL condition for high-risk, high-value orders.

When the order amount changes—or when the customer’s risk classification changes—pg_trickle incrementally updates the maintained result. It does not need to rescan every customer and every order.

The result is an always-current relation containing the orders that satisfy the policy.

### 3. pg_reason recognizes the semantic transition

pg_reason observes that order 42 has moved from absent to present in the match relation. It creates an activation and one durable agenda episode.

If the amount later changes from €12,000 to €14,000 while the order remains eligible, pg_reason updates the activation payload but does not create another review request under its default refraction policy.

It can also assign a high priority, route the work to a `risk` agenda group, and serialize it against other actions for the same customer.

### 4. The consequence is committed to an outbox

A pg_reason worker claims the agenda episode. A database-only consequence could be executed transactionally inside PostgreSQL.

For an external consequence, the worker writes a message to a pg_tide outbox using a deterministic idempotency key. The outbox insertion and the successful completion of the rule episode are committed together.

A crash cannot leave pg_reason believing the message was created when no committed outbox row exists.

### 5. pg_tide delivers the message

The pg_tide relay sends the event to the risk platform, Kafka topic, NATS subject, webhook, PagerDuty service, or another configured destination.

If the network fails after the destination accepts the message but before the relay records success, the message may be sent again. The idempotency key allows the destination or an inbox to recognize it as the same logical request.

### 6. The result can re-enter the loop

The review service may later write a decision back to PostgreSQL or publish a response into a pg_tide inbox.

That new fact can change another pg_trickle stream table, activate another pg_reason rule, and produce another event. The architecture becomes a visible, durable feedback loop rather than a hidden chain of callbacks.

```text
Order or customer changes
          │
          ▼
pg_trickle updates the matching relation
          │
          ▼
pg_reason creates one durable rule episode
          │
          ▼
Worker commits an idempotent outbox message
          │
          ▼
pg_tide relays it to the risk platform
          │
          ▼
Review result becomes a new PostgreSQL fact
```

## Transactional boundaries without distributed-transaction fiction

The trifecta does not claim that one transaction can extend from a PostgreSQL row all the way into every external API. Instead, it creates explicit, reliable boundaries.

Within a pg_trickle refresh, maintained results and associated refresh events can commit atomically.

Within pg_reason, activation changes and agenda changes are designed to commit with the maintained match state. Database handlers commit their PostgreSQL changes with their execution record. Outbox handlers commit the message with the rule episode’s completion.

Beyond PostgreSQL, pg_tide uses at-least-once delivery and idempotency.

That is a more useful guarantee than vague promises of “exactly once.” Each handoff has a durable record, a defined retry model, and an identifier that lets the next component determine whether it has already processed the work.

## Composable by design

Not every workload requires all three projects.

When an application only needs continuously maintained derived tables, pg_trickle can stand alone.

When a team wants current constraints, policy findings, or database-local actions, pg_trickle and pg_reason form the relevant pair.

When a database transaction simply needs to publish an event safely, pg_tide can be used without either of the other projects.

There is also already a direct integration between pg_trickle and pg_tide. A stream table can be attached to a pg_tide outbox, causing non-empty refresh summaries to be published in the same transaction as the refresh. Those events contain refresh metadata and row counts rather than a complete row-level change feed, making them suitable for invalidation, orchestration, and downstream refresh signals.

The full trifecta becomes valuable when a system needs all three capabilities:

1. Maintain a complex condition efficiently.
2. Interpret its transitions using durable business semantics.
3. Carry the resulting consequence beyond PostgreSQL safely.

Each project owns one responsibility, and the boundaries between them are explicit.

## Why this architecture matters

The most immediate benefit is operational simplicity. For database-centered applications, it can reduce the amount of bespoke infrastructure required to keep derived state fresh, detect important conditions, and publish reliable events.

The deeper benefit is coherence.

The data, current matches, rule versions, activations, agenda episodes, execution history, outbox messages, inbox records, and relay configuration can all be represented as inspectable PostgreSQL state. They participate in ordinary backup, recovery, replication, permissions, and auditing practices.

The architecture is also explainable. An operator can trace an external notification back through its outbox message, rule episode, activation, maintained match, and source facts. That is far easier than reconstructing a business decision from unrelated service logs and ephemeral queue messages.

Finally, the three projects preserve modularity. pg_trickle does not need to become a workflow engine. pg_reason does not need to rebuild relational query maintenance. pg_tide does not need to understand business rules. Each component can improve independently while communicating through durable SQL-level contracts.

## PostgreSQL as more than a system of record

The traditional role of PostgreSQL is to be the place where authoritative facts are stored.

This trifecta expands that role without abandoning it.

**pg_trickle** makes PostgreSQL a system of continuously maintained truth.

**pg_reason** makes it a system that can recognize the meaning of changing truth and schedule durable consequences.

**pg_tide** gives those consequences a reliable path into the rest of the architecture.

Together, they create a PostgreSQL-native progression from **change**, to **understanding**, to **action**—with fewer dual writes, fewer hidden transitions, and far more of the system’s behavior available for inspection in one place.
