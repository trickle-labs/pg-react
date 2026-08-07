# From Data to Decisions to Delivery: A PostgreSQL-Native Trifecta

PostgreSQL is excellent at storing facts. An order was placed, an account balance changed, a customer entered a new risk category, or a service crossed an error threshold. The difficult part often begins after the transaction is committed. A derived result needs to be recalculated, someone must decide whether the change matters, and an event or command may need to reach another system. What begins as a simple database update can quickly turn into a collection of refresh jobs, change-data-capture pipelines, rule engines, message brokers, retry workers, and custom application code.

[pg_trickle](https://github.com/trickle-labs/pg-trickle) and [pg_tide](https://github.com/trickle-labs/pg-tide) provide two deployable PostgreSQL-native pieces of that path today. [pg_reason](https://github.com/trickle-labs/pg-reason) is a proposed rule layer that would depend on pg_trickle and can use pg_tide for external effects. Together, they describe a path from changing data to reliable action while keeping PostgreSQL at the center of the architecture.

Each layer has a distinct role. pg_trickle keeps important query results continuously up to date. The proposed pg_reason layer interprets those changing results as meaningful business conditions and decides when work should be created. pg_tide carries resulting events and commands safely to other systems. Put more simply, pg_trickle answers **“What is true now?”**, pg_reason answers **“What does that truth mean?”**, and pg_tide answers **“How do we deliver the consequence reliably?”**

```text
Intended architecture

Application data
      │
      ▼
 pg_trickle
Maintains current derived truth
      │
      ▼
  pg_reason (proposed)
Recognizes conditions and schedules work
      │
      ▼
   pg_tide
Delivers events to other systems
```

This separation is what makes the combination valuable. pg_trickle and pg_tide can each be used independently. pg_reason, when available, will require pg_trickle; pg_tide remains optional when a rule has no external consequence.

> **Project status:** pg_reason is currently a proposed design rather than a completed production release. pg_trickle is also under active pre-1.0 development, so APIs and compatibility requirements may still change. Teams evaluating the stack should check the current release status and compatibility requirements of each component.

## pg_trickle: Keeping derived data fresh

Many applications depend on query results that are expensive to calculate but need to remain current. A retailer may need inventory totals by warehouse. A finance application may need live exposure by customer and asset class. An operations platform may need a current list of services outside their reliability targets. An analytics product may need continuously updated revenue, retention, or engagement metrics.

PostgreSQL can calculate all of these results with SQL, but keeping them fresh is often awkward. A traditional materialized view stores the result of a query, yet refreshing it normally means running the whole query again. That can be wasteful when the underlying dataset contains millions of rows and only a small number have changed.

pg_trickle addresses this with **stream tables**. A stream table is defined by a SQL query, much like a view, but its contents are maintained automatically as the underlying data changes. When rows are inserted, updated, or deleted, pg_trickle calculates how those changes affect the query result and applies only the necessary difference.

This approach is known as incremental view maintenance. Instead of repeatedly asking, “What is the full result of this query?” pg_trickle asks, “What changed since the last refresh, and how does that change affect the result?” If a single order is added to a table containing millions of orders, the system can process the effect of that one order rather than recalculating every historical order.

The result is easier to work with than a separate streaming system because it remains inside PostgreSQL. Applications can query a stream table like an ordinary table. Teams can index it, secure it with PostgreSQL permissions, include it in backups, inspect it with familiar tools, and join it with other relations. Developers continue to write SQL instead of moving business transformations into an unrelated streaming language or external processing service.

Stream tables can also depend on other stream tables. This allows teams to build layers of derived data without manually coordinating refresh order. A change to a base table can flow through several dependent results, with pg_trickle maintaining the dependency graph and refreshing each layer in the correct order.

In practical terms, pg_trickle turns PostgreSQL from a database that can calculate derived information into a database that can continuously maintain it. It gives applications a current and queryable representation of what is true, without requiring every team to build its own refresh framework.

However, a current result is not yet a decision. A table may show that an order now requires manual review, but that does not tell us whether the condition is new, whether a review task was already created, whether the order has the highest priority, or what should happen if it stops matching before the review begins.

That is where pg_reason fits.

## pg_reason: Turning current truth into meaningful action

pg_reason is designed as a PostgreSQL-native rule and reasoning layer built on top of pg_trickle. Its purpose is not to replace SQL query processing or incremental view maintenance. Instead, it adds the concepts needed to interpret changing query results as durable business events.

A rule condition is ordinary SQL, preferably expressed as a PostgreSQL view. Every row returned by that condition represents a situation in which the rule is currently true. For example, a rule might select orders over €10,000 where the customer is classified as high risk. pg_trickle keeps that result current as orders and customer records change. pg_reason then watches how each logical match changes over time.

This distinction is important because a rule should usually respond to a meaningful transition, not to every physical database update. Imagine that order 42 becomes eligible for manual review when its value rises from €9,000 to €12,000. That is a new condition, so creating a review task makes sense. If the value falls below the threshold and later rises above it again, a new activation generation may be appropriate.

pg_reason is designed to understand those differences. It gives each match a stable identity and tracks whether it is currently active, when it became active, whether it has already caused work to be created, and when it stops being true. This prevents application behavior from depending on whether pg_trickle happened to express an internal change as an update, a delete followed by an insert, or a full rebuild.

The design calls one continuous false-to-true-to-false interval an **activation generation**. An **episode** is one durable agenda item for one lifecycle event, such as activation, deactivation, or a meaningful change. An activation-only rule creates work when a generation begins but does not repeatedly create the same activation work while the condition remains true. This behavior is called refraction. A rule that defines an `on_change` consequence can create a distinct change episode when its meaningful payload changes.

That model lets a rule say, in effect, “Create one review request when an order first becomes high risk,” while still allowing a different consequence to respond when the active order changes.

The proposed runtime also includes the operational concepts required for a dependable rule system. Priorities influence episode selection within configured workers but do not promise one global firing order. Agenda groups can route different kinds of work to different workers. Conflict keys can prevent two incompatible actions for the same account or customer from running at the same time. Durable leases and retries allow work to survive worker crashes. Immutable rule versions preserve the meaning of historical executions even after a rule is updated.

One of the strongest ideas in the design is the separation between **what is currently true** and **what work has happened because of it**. The pg_trickle match table represents the current condition. The pg_reason activation state records how that condition has evolved. The pg_reason agenda records the work that was requested, claimed, completed, failed, withdrawn, or cancelled.

This means that when a condition disappears, the current activation can be marked inactive without erasing the history of what happened earlier. If a risk alert was created yesterday and the customer is no longer high risk today, the system should retain the fact that the alert existed, why it was created, and how it was handled. Current state and historical action are related, but they are not the same thing.

That separation also improves explainability. An operator can ask which rule created a task, which version of the rule was active, what data caused the match, when the condition first became true, whether it later changed, and what happened during execution. Instead of reconstructing the story from unrelated log entries, the system can represent the story as durable database state.

Some rule consequences can remain entirely inside PostgreSQL. A handler might create a review record, update an application table, or record a new business fact. Other consequences need to leave the database. A rule may need to publish an event to Kafka, call a risk service, send an alert, update a search index, or notify another PostgreSQL instance.

Trying to perform those external effects directly inside a database transaction creates a new set of problems. That is where pg_tide becomes the third part of the trifecta.

## pg_tide: Delivering events without unsafe dual writes

pg_tide provides a transactional outbox, an idempotent inbox, and relay pipelines for PostgreSQL. Its main purpose is to make communication between PostgreSQL and external systems reliable without requiring the application to coordinate two independent writes.

Consider a common application pattern. A service updates an order in PostgreSQL and then publishes an `order.updated` event to a message broker. If the database transaction succeeds but the broker call fails, the order has changed but no event exists. If the event is published first and the database transaction later rolls back, downstream systems receive an event about a change that never actually happened.

This is known as the dual-write problem. The two operations belong together logically, but they are committed by different systems and cannot normally be made atomic.

A transactional outbox solves the problem by writing the business change and the outgoing message into PostgreSQL in the same transaction. If the transaction commits, both records exist. If it rolls back, neither exists. A separate relay process then reads committed outbox messages and sends them to their destinations.

pg_tide provides that outbox as a PostgreSQL extension and adds the surrounding operational features needed to use it in production. Messages can be retried, grouped, observed, replayed, and routed to different destinations. The relay can deliver to messaging systems, cloud services, HTTP endpoints, notification platforms, analytical stores, object storage, or another PostgreSQL deployment.

Delivery to an external system is generally at least once. That means a message may occasionally be delivered more than once, especially when a network failure makes it unclear whether the destination received the first attempt. pg_tide gives each message a stable event identity, but an arbitrary destination is idempotent only when it persists and honors that identity. The identity makes duplicate handling possible; it does not make an unmodified HTTP endpoint or third-party service deduplicate automatically.

The idempotent inbox provides that protection for messages entering PostgreSQL. When a message arrives with an event identifier that has already been processed, the consumer can recognize the repeat rather than applying the same operation twice. Other receivers need an equivalent deduplication contract.

This approach is more honest and practical than promising universal “exactly once” behavior. PostgreSQL cannot atomically commit a transaction together with an unrelated email provider, HTTP service, or message broker unless every participant supports a shared distributed transaction protocol. pg_tide instead makes each boundary explicit: the database commit is atomic, delivery is durable and retryable, and stable identities support duplicate handling when the destination participates.

## How the three projects work together

The easiest way to understand the combination is to follow one business condition from source data to external action.

Imagine an order-processing application with the following policy:

> When an order from a high-risk customer exceeds €10,000, create a manual-review request and notify the risk platform.

The application continues to write normal business data. It inserts orders, updates amounts, and changes customer risk classifications using ordinary PostgreSQL transactions. The application does not need to evaluate the complete rule every time it writes a row, and it does not need to know how every downstream system should be notified.

pg_trickle maintains a stream table containing the orders that currently satisfy the condition. The query can join orders with customers and filter by both order value and customer risk. When an order amount or customer classification changes, pg_trickle calculates the effect of that change and updates the maintained result.

Suppose order 42 moves from €9,000 to €12,000 while its customer is already classified as high risk. The order now appears in the stream table. pg_reason recognizes that this is a false-to-true transition for the activation identified by order 42 and records the activation. When the rule declares an activation consequence, it creates one durable agenda episode for manual review.

If the order value later rises to €14,000, pg_trickle updates the matching row. For a rule that defines only an activation consequence, pg_reason can update the latest payload without creating another activation episode. If the rule also defines an `on_change` consequence, that meaningful payload change creates a separate change episode instead.

A worker then claims the activation episode. For a database-local consequence, it might insert a row into a `manual_review_tasks` table and mark the episode complete in the same PostgreSQL transaction. For an external consequence, it creates a message in a pg_tide outbox using a deterministic idempotency key in the same transaction that marks the external episode complete.

The outbox message and completion of that external episode are committed together. If the transaction fails, neither is recorded. If it succeeds, pg_tide’s relay can deliver the message to the risk platform, a Kafka topic, a NATS subject, a webhook, or another configured destination.

If the relay crashes, the message remains in PostgreSQL and can be attempted again. If the destination receives the event twice because of an ambiguous network failure, it must use the idempotency key to recognize both deliveries as the same review request.

The risk platform may eventually return a decision. That decision can be written back to PostgreSQL directly or delivered through a pg_tide inbox. Once stored as a new fact, it may affect another pg_trickle stream table, which may activate another pg_reason rule and produce another event.

The result is a durable feedback loop:

```text
An order or customer changes
            │
            ▼
pg_trickle updates the current matching relation
            │
            ▼
pg_reason recognizes a new rule episode
            │
            ▼
A worker commits an idempotent outbox message
            │
            ▼
pg_tide delivers it to the external system
            │
            ▼
The external result becomes a new PostgreSQL fact
```

Each step has a clear responsibility. pg_trickle does not decide what business action should occur. pg_reason does not need to implement incremental joins and aggregates. pg_tide does not need to understand why a particular event matters. The projects cooperate through durable state while remaining independently understandable.

## Clear transaction boundaries and timing

An important strength of this architecture is that it does not hide its transaction boundaries. It also does not make every transition synchronous with the source-data write.

In the proposed default epochal flow, an application first commits its ordinary source-data transaction. pg_trickle incorporates that committed change at its configured refresh boundary. pg_reason then records lifecycle state and agenda work with the maintained match, and a worker executes the consequence in a later transaction. Freshness therefore depends on the configured refresh mode and schedule, and independent workers do not promise one global firing order.

Within pg_trickle, changes to a maintained result can be committed as part of a PostgreSQL transaction. pg_trickle can also publish refresh summaries into a pg_tide outbox in the same transaction as a non-empty refresh. If that refresh rolls back, the outbox event rolls back as well.

Within the proposed pg_reason design, changes to activation state and agenda state are intended to commit with the maintained rule match. A database handler can commit its application changes together with the execution record. An external action can commit an outbox message together with the completion of the agenda episode.

Once the message leaves PostgreSQL, delivery becomes at least once. The stable event identity supports idempotent handling when the destination participates; it does not create an end-to-end exactly-once guarantee.

The proposed integration therefore has narrow, understandable guarantees. A processed maintained match and its lifecycle transition are intended to commit together. For an external consequence, episode completion cannot commit without its outbox message. An outgoing message cannot disappear merely because a relay process restarted. A repeated delivery can be recognized only by a destination that implements the required deduplication contract.

## Useful separately, stronger together

The components form a coherent stack, but they do not have to be adopted as a bundle. pg_trickle and pg_tide can be used independently; pg_reason, once available, requires pg_trickle and only needs pg_tide for external consequences.

A team that only needs fresh derived tables can use pg_trickle by itself. It may be enough for live dashboards, operational summaries, search candidates, or continuously maintained aggregates.

A team that needs reliable database messaging can use pg_tide by itself. An application transaction can publish to an outbox without using stream tables or a rule engine.

A team that needs continuously evaluated constraints or database-local automation could, once pg_reason is available, use it with pg_trickle without adopting pg_tide. pg_trickle maintains the condition, while pg_reason interprets its transitions and manages the resulting work.

pg_trickle and pg_tide also have a direct integration. A stream table can be attached to a pg_tide outbox so that non-empty refreshes publish transactional summary events. These events contain metadata such as the source stream table and the number of inserted or deleted rows. They are useful for downstream invalidation, refresh coordination, or orchestration, although they are not a complete row-level change feed.

The intended full stack becomes especially useful when an application needs to maintain a complex condition, understand when that condition meaningfully changes, and communicate the consequence beyond PostgreSQL.

## Why this model is valuable

The intended value is reduced application plumbing. The components can express derived-data maintenance, durable rule state, retries, and transactional messaging as PostgreSQL state rather than as disconnected application code and logs.

The operational value is just as important. Stream tables, rule matches, activations, agenda episodes, execution attempts, outbox messages, inbox records, and relay configuration can be inspected with familiar database tools and participate in normal backup, recovery, replication, permission, and auditing practices. An operator can trace an external notification back through its message, episode, activation, maintained match, and source rows.

The model fits best when the condition is relational, PostgreSQL is the authoritative source of facts, and a configured refresh boundary plus later worker execution is acceptable. It is not a replacement for a globally ordered workflow engine, a cross-system atomic transaction, or an action that must execute synchronously with every source-data write.

The boundaries remain clean: pg_trickle focuses on incremental data maintenance, the proposed pg_reason layer on rule meaning and durable work, and pg_tide on reliable messaging and delivery.

## PostgreSQL as a system of action

PostgreSQL is traditionally described as a system of record: the place where authoritative facts are stored. pg_trickle makes those facts continuously queryable as derived truth; the proposed pg_reason layer can turn meaningful transitions into durable work; pg_tide can carry that work into the wider architecture.

Together, they describe a progression from **data**, to **decision**, to **delivery**. The aim is not to place every part of a distributed system inside PostgreSQL, but to keep the important transitions durable, understandable, and close to the data that caused them.
