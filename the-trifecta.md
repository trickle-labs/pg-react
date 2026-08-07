# Data, Decisions, and Delivery in PostgreSQL

PostgreSQL stores facts. An order was placed, an account balance changed, a customer entered a new risk category, or a service crossed an error threshold. After the transaction commits, derived data may need updating, a rule may create work, and an event or command may need to reach another system. Teams often implement that path with refresh jobs, change-data-capture pipelines, rule engines, message brokers, retry workers, and application code.

[pg_trickle](https://github.com/trickle-labs/pg-trickle) and [pg_tide](https://github.com/trickle-labs/pg-tide) are deployable PostgreSQL-native parts of that path. [pg_reason](https://github.com/trickle-labs/pg-reason) is a proposed rule layer that depends on pg_trickle and can use pg_tide for external effects. The three projects keep PostgreSQL at the center of a path from changing data to reliable action.

Each layer has a distinct role. pg_trickle keeps query results current. The proposed pg_reason layer interprets those results as business conditions and creates work. pg_tide delivers resulting events and commands to other systems. The layers answer different questions: pg_trickle asks **"What is true now?"** pg_reason asks **"What does that truth mean?"** pg_tide asks **"How do we deliver the consequence reliably?"**

```text
Architecture

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

Teams can use pg_trickle and pg_tide independently. pg_reason, when available, will require pg_trickle. It uses pg_tide only when a rule has an external consequence.

> **Project status:** pg_reason is currently a proposed design rather than a completed production release. pg_trickle is also under active pre-1.0 development, so APIs and compatibility requirements may still change. Teams evaluating the stack should check the current release status and compatibility requirements of each component.

## pg_trickle: Keeping derived data fresh

Applications often need current query results that cost too much to recalculate after every write. A retailer may need inventory totals by warehouse. A finance application may need exposure by customer and asset class. An operations platform may track services outside their reliability targets. An analytics product may maintain revenue, retention, or engagement metrics.

PostgreSQL can calculate these results with SQL, but a traditional materialized-view refresh reruns the whole query. Recalculation wastes work when a dataset contains millions of rows and only a few have changed.

pg_trickle maintains these results through **stream tables**. A stream table is defined by a SQL query, like a view. When rows are inserted, updated, or deleted, pg_trickle calculates the resulting delta and applies it to the query result.

This technique is incremental view maintenance. If a new order enters a table with millions of historical orders, pg_trickle processes that order's effect on the result instead of recalculating the entire history.

Stream tables remain ordinary PostgreSQL relations. Applications can query them, add indexes, protect them with PostgreSQL permissions, include them in backups, inspect them with familiar tools, and join them to other relations. Developers continue writing SQL rather than moving transformations into a separate streaming language or service.

A stream table can depend on another stream table. pg_trickle tracks those dependencies and refreshes each layer in order, so teams can build derived-data layers without coordinating refreshes themselves.

pg_trickle therefore gives applications a current, queryable representation of derived facts. That representation can show that an order requires manual review, but it cannot determine whether the condition is new, whether a review task already exists, how to prioritize it, or what to do when the condition ends. pg_reason handles those lifecycle decisions.

## pg_reason: Rules and durable work

pg_reason is a proposed PostgreSQL-native rule and reasoning layer built on pg_trickle. SQL and pg_trickle define and maintain rule conditions. pg_reason adds the lifecycle state and work management needed to interpret changing results as business events.

A rule condition is ordinary SQL, preferably a PostgreSQL view. Each returned row identifies a situation where the rule currently holds. A rule might select orders over €10,000 whose customer is high risk. pg_trickle keeps the result current as orders and customer records change. pg_reason tracks the history of each logical match.

Rules usually act on a transition rather than every physical database update. For example, when order 42 rises from €9,000 to €12,000, it becomes eligible for manual review and may create a review task. If the value later falls below the threshold and rises again, the rule may create work for a new activation generation.

pg_reason assigns every match a stable identity. It tracks whether the match is active, when it became active, whether it created work, and when it ceased to hold. Application behavior therefore remains independent of whether pg_trickle expresses an internal change as an update, a delete and insert, or a full rebuild.

An **activation generation** is one continuous interval in which a match remains active. An **episode** is one durable agenda item for a lifecycle event such as activation, deactivation, or a payload change. An activation-only rule creates work when a generation starts and does not create duplicate activation work while the condition remains active. This behavior is refraction. A rule with an `on_change` consequence can create a separate episode when its meaningful payload changes.

A rule can therefore create one review request when an order first becomes high risk while another consequence responds to later changes in the active order.

The proposed runtime also defines operating constraints for the rule system. Priorities guide episode selection within configured workers but do not establish a global firing order. Agenda groups route work to workers. Conflict keys prevent incompatible actions for the same account or customer from running concurrently. Durable leases and retries preserve work across worker failures. Immutable rule versions retain the meaning of historical executions after a rule changes.

The design keeps current conditions separate from work caused by those conditions. The pg_trickle match table records the current condition. pg_reason activation state records its lifecycle. The pg_reason agenda records work requested, claimed, completed, failed, withdrawn, or cancelled.

If a condition disappears, pg_reason marks the current activation inactive and retains the earlier work history. When a risk alert created yesterday no longer matches the customer's status today, operators can still see that alert, its cause, and its disposition.

That durable state also supports inspection. An operator can identify the rule and rule version that created a task, the data that produced the match, when the condition became active, later changes, and execution results. The system keeps that account in database state rather than scattering it across logs.

Some rule consequences stay inside PostgreSQL. A handler can create a review record, update an application table, or add a business fact. Other consequences publish an event to Kafka, call a risk service, send an alert, update a search index, or notify another PostgreSQL instance.

External effects performed inside a database transaction create consistency problems. pg_tide handles the delivery boundary.

## pg_tide: Transactional messaging

pg_tide provides a transactional outbox, an idempotent inbox, and relay pipelines for PostgreSQL. It records a database change and its outgoing message in one PostgreSQL transaction, so an application does not coordinate two independent writes.

A service might update an order in PostgreSQL and publish an `order.updated` event to a broker. If the database transaction succeeds but the broker call fails, the order changes without an event. If the service publishes first and the database transaction later rolls back, downstream systems receive an event for a change that never occurred.

This is the dual-write problem. The operations belong together but separate systems commit them.

A transactional outbox writes the business change and the outgoing message in the same PostgreSQL transaction. A commit creates both records; a rollback creates neither. A relay process reads committed outbox messages and sends them to their destinations.

pg_tide packages that outbox as a PostgreSQL extension and adds operations needed in production. Teams can retry, group, observe, replay, and route messages. The relay delivers to messaging systems, cloud services, HTTP endpoints, notification platforms, analytical stores, object storage, or another PostgreSQL deployment.

External delivery is at least once. A network failure can leave the relay unable to determine whether a destination received an attempt, so it may send the message again. pg_tide assigns every message a stable event identity. A destination must persist and honor that identity to deduplicate deliveries; an unmodified HTTP endpoint or third-party service will not deduplicate them on its own.

The idempotent inbox applies this protection to messages entering PostgreSQL. A consumer can recognize an event identifier it has already processed and avoid applying the same operation twice. Other receivers need an equivalent deduplication contract.

PostgreSQL cannot atomically commit with an unrelated email provider, HTTP service, or message broker unless all participants share a distributed transaction protocol. pg_tide makes the boundary explicit: PostgreSQL commits the business data and outbox atomically, the relay preserves and retries delivery, and participating destinations use stable identities to handle duplicates.

## How the three projects work together

An order-review policy shows the interaction:

> When an order from a high-risk customer exceeds €10,000, create a manual-review request and notify the risk platform.

The application writes orders, amounts, and customer risk classifications in ordinary PostgreSQL transactions. It does not evaluate the complete policy on every row write or manage each downstream notification.

pg_trickle maintains a stream table for orders that meet the policy. Its query joins orders with customers and filters on order value and customer risk. When either value changes, pg_trickle updates the maintained result.

Suppose order 42 moves from €9,000 to €12,000 while its customer is already high risk. The order enters the stream table. pg_reason records a new activation for order 42 and creates one durable agenda episode for manual review when the rule defines an activation consequence.

If the value later reaches €14,000, pg_trickle updates the match. A rule with only an activation consequence updates the latest payload without creating another activation episode. A rule with an `on_change` consequence creates a separate change episode for the meaningful payload change.

A worker claims the activation episode. For a database-local consequence, it can insert a row into `manual_review_tasks` and complete the episode in the same PostgreSQL transaction. For an external consequence, it writes a pg_tide outbox message with a deterministic idempotency key in the transaction that completes the external episode.

The transaction commits the outbox message and episode completion together. After the commit, pg_tide's relay sends the message to the risk platform, a Kafka topic, a NATS subject, a webhook, or another configured destination. A relay failure leaves the message in PostgreSQL for another attempt. A destination that receives the event twice must use the idempotency key to treat both deliveries as one review request.

The risk platform can return a decision directly to PostgreSQL or through a pg_tide inbox. Stored as a new fact, that decision can update another pg_trickle stream table, activate another pg_reason rule, and produce another event.

The feedback loop is durable:

```text
An order or customer changes
            │
            ▼
pg_trickle updates the current matching relation
            │
            ▼
pg_reason records a rule episode
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

pg_trickle maintains the derived relation. pg_reason manages rule lifecycle and work. pg_tide delivers the resulting message. Durable state keeps those responsibilities separate.

## Clear transaction boundaries and timing

The architecture exposes transaction boundaries and separates source-data writes, maintained-condition updates, and consequence execution.

In the proposed default epochal flow, an application commits its source-data transaction first. pg_trickle incorporates the committed change at its configured refresh boundary. pg_reason records lifecycle state and agenda work with the maintained match, then a worker executes the consequence in a later transaction. Freshness depends on the refresh mode and schedule. Independent workers have no global firing order.

pg_trickle can commit changes to a maintained result inside a PostgreSQL transaction. It can also publish a non-empty refresh summary to a pg_tide outbox in that transaction. A rollback removes both the refresh and its outbox event.

The proposed pg_reason design commits activation and agenda state with the maintained rule match. A database handler can commit application changes with its execution record. An external action can commit an outbox message with completion of its agenda episode.

After a message leaves PostgreSQL, delivery is at least once. The stable event identity supports idempotent handling at destinations that participate, but it cannot provide end-to-end exactly-once delivery.

The proposed integration guarantees that a processed maintained match and lifecycle transition commit together. For an external consequence, episode completion commits with its outbox message. A relay restart does not remove an outgoing message. A destination can recognize a repeated delivery only when it implements the required deduplication contract.

## Useful separately, stronger together

Teams can adopt the components independently. pg_trickle and pg_tide work alone. pg_reason, once available, requires pg_trickle and uses pg_tide only for external consequences.

pg_trickle alone supports live dashboards, operational summaries, search candidates, and maintained aggregates. pg_tide alone lets an application transaction publish to an outbox without stream tables or a rule engine. A team can pair pg_reason with pg_trickle for continuously evaluated constraints or database-local automation.

pg_trickle and pg_tide also integrate directly. A stream table can attach to a pg_tide outbox, publishing a transactional summary event for each non-empty refresh. Those events identify the source stream table and count inserted or deleted rows. They support downstream invalidation, refresh coordination, or orchestration; they are not a row-level change feed.

The full stack suits an application that maintains a complex relational condition, tracks meaningful changes in that condition, and communicates the consequence beyond PostgreSQL.

## Why this model is valuable

This arrangement reduces application plumbing by keeping derived-data maintenance, durable rule state, retries, and transactional messaging in PostgreSQL state instead of spreading them across application code and logs.

Teams can inspect stream tables, rule matches, activations, agenda episodes, execution attempts, outbox messages, inbox records, and relay configuration with database tools. Those records participate in backup, recovery, replication, permissions, and auditing. An operator can trace an external notification through its message, episode, activation, maintained match, and source rows.

Use this model when conditions are relational, PostgreSQL is the authoritative source of facts, and a configured refresh boundary with later worker execution is acceptable. Use a globally ordered workflow engine for global ordering, a distributed transaction protocol for cross-system atomicity, and a synchronous path for actions that must run with each source-data write.

pg_trickle maintains derived data. The proposed pg_reason layer manages rule meaning and durable work. pg_tide provides reliable messaging and delivery.

## PostgreSQL as a system of action

Teams use PostgreSQL as a system of record for authoritative facts. pg_trickle keeps derived facts queryable, the proposed pg_reason layer can turn meaningful transitions into durable work, and pg_tide can carry that work to other systems.

Together, the projects connect **data**, **decisions**, and **delivery**. They keep important transitions durable, understandable, and close to the data that caused them.
