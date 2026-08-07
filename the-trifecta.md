# When PostgreSQL Data Needs to Do Something

An order crosses €10,000 while the customer is already marked high risk. Someone now has to open a review and notify the risk platform.

The facts live in PostgreSQL, but the reaction often gets scattered across a refresh job, application callbacks, a queue, a retry worker, and whatever code remembers whether this order has already triggered a review. Coordinating those parts is harder than any one of them.

Three PostgreSQL projects cover that path:

- [pg_trickle](https://github.com/trickle-labs/pg-trickle) keeps the SQL result that finds risky orders up to date.
- [pg_react](https://github.com/trickle-labs/pg-react) is a proposed rule layer that notices when an order enters or leaves that result and records the work to do.
- [pg_tide](https://github.com/trickle-labs/pg-tide) carries the resulting event to another system without losing it after the database commits.

pg_trickle maintains the answer. pg_react decides whether the answer calls for work. pg_tide delivers that work beyond PostgreSQL.

```text
Order and customer data
      │
      ▼
 pg_trickle
Keeps the matching query current
      │
      ▼
  pg_react (proposed)
Notices lifecycle changes and records work
      │
      ▼
   pg_tide
Delivers an event to the risk platform
```

pg_trickle and pg_tide already stand on their own. pg_react is still a design proposal. It will require pg_trickle and will use pg_tide only when work must leave the database. pg_trickle is also under active pre-1.0 development, so check current releases and compatibility before adopting either project.

## Keep expensive queries current

SQL can find every high-risk order over €10,000. Running that query after every write is another matter, especially when it joins large tables or computes aggregates.

pg_trickle maintains the result incrementally. You define a **stream table** with a SQL query, much as you would define a view. When source rows change, pg_trickle computes their effect on the result instead of rerunning the query over the full dataset. One new order should require work proportional to that change, not to years of order history.

The result is still a PostgreSQL relation. You can query it, index it, grant permissions on it, back it up, and join it with other tables. Stream tables can also depend on one another; pg_trickle tracks the dependency order and refreshes them accordingly.

For a dashboard or a live aggregate, that may be the whole job. A rule needs more context. Order 42 appearing in the result could be a new problem, a changed problem, or a problem that already produced a review task. The query result alone does not remember which.

## Remember what a match has already done

pg_react is a proposed rule runtime built on pg_trickle. A rule condition is ordinary SQL, preferably a PostgreSQL view. Each row represents a situation that currently needs attention. pg_trickle keeps those rows current; pg_react remembers their history.

Suppose order 42 rises from €9,000 to €12,000. It enters the matching view, so pg_react records an activation and creates a durable agenda item, called an **episode**. If the amount rises again to €14,000, an activation-only rule does not open a second review. Avoiding repeat work while the same condition remains true is known as refraction.

If the order drops below €10,000, the activation ends. A later rise starts a new **activation generation**, meaning a new continuous period during which the condition holds. The rule may then create a fresh review. Rules can also define `on_change` or `on_deactivate` consequences when those transitions matter.

To make this work, pg_react gives each logical match a stable identity and stores its lifecycle separately from the current query result. The pg_trickle table says which orders match now. Activation state says when each match began and ended. The agenda says what work was requested and whether it is pending, running, complete, failed, withdrawn, or cancelled.

This separation keeps history intact. If yesterday's risk condition disappears today, an operator can still find the rule version that opened the review, the values that matched, and the eventual outcome. Rebuilding the maintained result also does not make an old match look new just because its physical row changed.

The proposed runtime includes the less glamorous pieces that make durable work usable: leases, retries, worker routing, priorities, and conflict keys that stop incompatible actions for the same customer from running together. Priorities influence what a worker claims next; they do not promise one global firing order across all workers.

A consequence can stay inside PostgreSQL, perhaps by inserting a row into `manual_review_tasks`. It can also need an HTTP call, a Kafka event, or a notification to another service. That second case crosses a transaction boundary.

## Deliver without a dual write

Consider the transaction that completes a review episode and publishes `order.review_requested`. If PostgreSQL commits but the broker call fails, the review exists without its event. If the broker accepts the event and PostgreSQL rolls back, the risk platform hears about a review that does not exist. This is the dual-write problem.

pg_tide solves the PostgreSQL side with a transactional outbox. The worker writes the business change and an outgoing message in one transaction. A commit keeps both; a rollback keeps neither. Afterward, a relay reads the committed message and delivers it to a broker, an HTTP endpoint, another PostgreSQL database, or another supported destination.

Delivery is **at least once**. If a connection drops at the wrong moment, the relay cannot know whether the destination accepted the message, so it sends it again. pg_tide gives the message a stable identity, but the receiver must use that identity to reject duplicates. A third-party HTTP endpoint does not become idempotent merely because the sender has an outbox.

For messages coming into PostgreSQL, pg_tide's idempotent inbox records which event identities have already been processed. Other receivers need an equivalent deduplication mechanism.

Under this contract, PostgreSQL commits local state and the outbox message atomically. pg_tide preserves and retries the message, and the destination handles possible duplicates.

## Follow one order through the stack

> When an order from a high-risk customer exceeds €10,000, open a manual review and notify the risk platform.

For order 42, that policy runs as follows:

1. The application commits an update that raises the order from €9,000 to €12,000.
2. pg_trickle refreshes the maintained query. Because the customer is high risk, order 42 enters the result.
3. pg_react records a new activation and adds a review episode to its agenda.
4. A worker claims the episode. In one transaction, it inserts a row into `manual_review_tasks`, writes a pg_tide outbox message with a deterministic idempotency key, and completes the episode.
5. pg_tide relays the message to the risk platform. A failed attempt leaves the message in PostgreSQL for retry.
6. The risk platform's decision returns through an inbox or another application write. That fact can update another stream table and activate another rule.

Each handoff leaves durable evidence in PostgreSQL before the next begins. The components do not pretend the whole path is one distributed transaction.

```text
Order data commits
        │
        ▼
pg_trickle updates the matching relation
        │
        ▼
pg_react records lifecycle state and work
        │
        ▼
A worker commits local effects and an outbox message
        │
        ▼
pg_tide retries delivery until the destination accepts it
        │
        ▼
The external decision returns as another fact
```

## Know where the boundaries are

The proposed default flow is epochal. The application commits source data first. pg_trickle incorporates that change at its configured refresh boundary. pg_react records the resulting lifecycle transition and agenda work. A worker executes the consequence in a later transaction.

This means rule consequences are not synchronous with the original write. Freshness depends on pg_trickle's refresh mode and schedule, and independent workers do not share a global firing order.

Inside PostgreSQL, related records can still commit together:

- pg_trickle can commit a maintained result and its pg_tide refresh-summary event in one transaction.
- pg_react is designed to commit a lifecycle transition with its agenda episode.
- A worker can commit a database consequence with its execution record, or complete an external episode with its outbox message.

The guarantee ends at the external destination. pg_tide keeps retrying a committed message, but end-to-end exactly-once behavior requires the receiver to deduplicate by event identity.

## Adopt only the pieces you need

pg_trickle alone is useful for live aggregates, operational summaries, and query results that are expensive to rebuild. pg_tide alone gives an application a transactional outbox and inbox. pg_react with pg_trickle can support continuously evaluated constraints or database-local automation without sending anything outside PostgreSQL.

pg_trickle and pg_tide can also connect directly. A stream table may publish a summary event after a non-empty refresh, including the source table and counts of inserted or deleted rows. This works for invalidation and refresh coordination, but it is a refresh summary rather than a row-level change feed.

The full stack fits when PostgreSQL holds the authoritative facts, the condition is naturally relational, and later worker execution is acceptable. It is a poor fit for work that must happen synchronously with every source write, requires one global order, or needs atomic commits across unrelated systems. Those requirements call for a synchronous application path, an ordered workflow engine, or a distributed transaction protocol.

## Why keep this in PostgreSQL?

Each stage leaves a row an operator can inspect. For order 42, you can follow the source data to the maintained match, activation, episode, execution attempt, and outbox message. Those records use PostgreSQL's existing backup, recovery, replication, permissions, and auditing machinery.

The design also gives failures an obvious home. A stale query result belongs to pg_trickle's refresh path. Work stuck before execution appears in pg_react's agenda. A message that has not reached its destination remains in pg_tide's outbox. Operators do not have to reconstruct the whole story from timestamps across several log systems.

pg_trickle answers a changing SQL query efficiently. pg_react is designed to remember when an answer became actionable and what happened next. pg_tide carries the result across the boundary PostgreSQL cannot commit through on its own.

For applications built around relational conditions, a fact can become durable work without losing its history on the way out of the database.
