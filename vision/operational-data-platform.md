# PostgreSQL as an operational data platform

Related documents: [The trifecta](the-trifecta.md), [Product thesis](pg-react_product_thesis.md), and [Practical rule-engine features](pg-react_practical_rule_engine_features.md).

> Current state: M41 and extension `0.38.0` are pg-react's qualified baseline. M42 is the current planning milestone and defines evidence snapshots for extension `0.39.0`. The repository still contains the prepared `1.0.0-rc.1` candidate, but the `1.0.0` release and its complete feature freeze are postponed indefinitely. The qualified stack uses PostgreSQL 18.3 and pg_trickle 0.81.0 on Linux `amd64`. See the [support matrix](../docs/v1-support-matrix.md) for the full boundary. This document explains how the projects work together. Each project's documentation remains the source for its current releases and APIs.

Warehouse 7 has promised customers 50 units of a product, but it holds only 38. A shipment was supposed to fill the gap, and now that shipment will arrive two days late. No single row in the database says, "Customers are at risk." That conclusion comes from combining inventory, reservations, open orders, and shipment dates. Someone needs to notice the shortage, decide what to do, and give procurement enough information to act before customers receive bad news.

PostgreSQL already holds the facts behind that decision. The architecture described here lets PostgreSQL do more than store them. It keeps useful conclusions up to date, remembers when a problem appears or changes, and records the work needed to address it. Three projects divide those responsibilities:

- [pg_trickle](https://github.com/trickle-labs/pg-trickle) keeps the results of SQL queries current as the underlying facts change.
- [pg-react](https://github.com/trickle-labs/pg-react) remembers which policies apply, what decisions were made, and what work remains.
- [pg_tide](https://github.com/trickle-labs/pg-tide) can deliver work to systems outside PostgreSQL. Its own documentation defines the delivery and receipt contracts it currently supports.

```text
Facts stored in PostgreSQL
        |
        v
Current conditions           pg_trickle
        |
        v
Decisions and durable work   pg-react
        |
        v
Delivery to other systems    transactional outbox, optionally pg_tide
        |
        v
Results return to PostgreSQL as new facts
```

The result is a controlled loop. An application first commits facts such as the late shipment. pg_trickle updates the SQL results that describe current conditions. pg-react notices whether each condition is new, changed, resolved, or recurring, then records a decision or creates work. If that work must leave PostgreSQL, a transactional outbox stores the request until a delivery process can send it safely. Any response, such as a revised arrival date, returns through the application or an inbox and becomes another fact in PostgreSQL.

This approach has a deliberate limit. It does not try to replace a data warehouse, a business intelligence tool, a file-processing system, a synchronous authorization service, or a general workflow product. Those jobs have different needs.

## Operational data answers what needs attention now

An analytical system can explain what happened last quarter. An operational system must answer a more immediate question: can warehouse 7 still keep its promises, and what is already being done about the shortage? The answer changes whenever inventory, orders, reservations, or delivery dates change.

Finding the shortage is only the start. The system also needs to know whether it has seen this particular shortage before, whether someone already claimed the work, and whether an earlier attempt failed. If a worker stops halfway through a job, another worker must be able to continue without losing the history. These details turn a query result into an operational responsibility.

Teams often spread this responsibility across a database, change tracking, stream processing, a rule service, a message broker, retry workers, and application callbacks. Each handoff makes it harder to preserve the identity of the original business problem and the intent of the transaction that found it. Keeping the facts, current conditions, decisions, and pending work in PostgreSQL removes many of those handoffs. Work leaves the database only when another system must perform the final effect.

## A rule engine in plain language

A rule engine is software that repeatedly applies an "if this is true, then do that" policy. For the warehouse, a rule might say: if expected supply falls below promised demand, record a shortage and ask procurement to review it. The facts can change at any time, so the engine must also recognize when the shortage gets worse, improves, disappears, or returns later.

In this architecture, SQL describes the "if" part. pg_trickle keeps the result of that SQL current, and pg-react manages what happens as rows enter, change within, or leave that result. This division matters because a current query result does not contain a history. A row can show that warehouse 7 is short today, but the row alone cannot say whether the shortage first appeared today or whether a team has been working on it for a week.

## pg_trickle keeps each condition current

The warehouse shortage begins as a SQL query. The query combines inventory, reservations, open orders, and expected deliveries. It returns every warehouse and product for which expected supply is lower than committed demand. As the source facts change, pg_trickle maintains that result so applications do not need to recalculate the entire answer themselves.

In the qualified pg-react setup, pg_trickle maintains the query results and pg-react chooses when to refresh them. The regular pg_trickle scheduler stays off. This gives the managed runtime one controlled point at which it observes a consistent set of changes.

The maintained result describes what is true now. A dashboard can read it, and other SQL queries can build on it. pg-react treats each returned row as a condition that currently matches a policy. The result does not, by itself, remember when the match began or what anyone did about it.

## pg-react remembers what happened

pg-react gives each matching business problem a stable identity and a lifecycle. When a warehouse and product first enter the shortage result, pg-react records that the shortage became active. It can also create work that remains in PostgreSQL until a worker handles it. If the shortage clears and later returns, pg-react starts a new occurrence instead of reopening work from the earlier shortage.

Not every rule needs to cause an action. A constraint rule records whether a condition is currently true. A command rule can create a specific response when a condition appears, changes, or disappears. The public runtime contract defines how workers claim that response, keep the claim while working, retry after a problem, and mark the work complete, failed, or no longer needed. The attempt history remains available for inspection.

Rules are one part of pg-react. A decision declaration compares the available choices for each subject and selects the lowest-priority candidate. If candidates tie, the result is `AMBIGUOUS` so the system does not hide the conflict. A policy set groups related rules and decisions under a version that cannot change, then uses a query result to decide where that version applies.

PostgreSQL-managed workers run this process in the normal setup. Each configured database gets one worker. The worker coordinates updates to current conditions and processes work that is ready to run. All of this happens after the application has committed the source facts, so it does not delay the original transaction.

## External work needs a safe handoff

When a response stays inside PostgreSQL, one transaction can update application data and mark the pg-react work complete as a single all-or-nothing operation. Either both changes take effect or neither does. An HTTP request or a message sent to a broker cannot join that local transaction, so the system needs a clear handoff point.

A transactional outbox provides that handoff. The response writes both the business change and a description of the outgoing message in the same PostgreSQL transaction. If the transaction rolls back, both records disappear. After the transaction commits, a separate delivery process reads the outbox and sends the message to the other system.

The delivery process guarantees at-least-once delivery, which means that it may send the same message more than once. For example, a network connection can fail after the destination accepts a message but before PostgreSQL receives confirmation. The receiving system must therefore recognize a stable message identity and ignore duplicates. pg-react preserves the outgoing intent, but it cannot make an unrelated remote system part of the PostgreSQL transaction.

Suppose procurement responds with an earlier arrival date. The application or an inbox process stores that date as a new fact. pg_trickle updates the shortage result, and pg-react records whether the shortage changed or ended. The response follows the same path as every other source change, which keeps the loop understandable and recoverable.

## What pg-react supports today

The ordinary v1 API provides database functions for defining rules, decisions, and policy sets. These functions check that authors supply values of the expected type. Before deployment, authors can check a declaration with `validate`, inspect its result with `preview`, and install it with `deploy`. Operators can use stable names, public views, `status`, `explain`, `doctor`, and documented recovery operations to understand and manage the running system.

The installed advanced APIs cover more involved policies. They can calculate facts from other facts, follow relationships that refer back to themselves within set limits, and combine exclusions or totals without producing conflicting results. Policies can also share conditions, change by date, reuse one definition with different values, compare decision options, and retain a limited record of how the system reached a result. These features use precise database concepts, but they serve the same basic goal: describe a condition, recognize its lifecycle, and keep the resulting decision or work durable.

M34 adds a read-only way to compare a proposed declaration with one that is already deployed. `pgreact.compare()` and `pgreact.compare_results()` show how a proposed rule, decision, or policy set would behave against the facts currently in PostgreSQL. They report the current and proposed results, the differences between them, expected lifecycle changes, and work that would be created. The comparison does not deploy the proposal or run any effects.

This comparison is a focused safety check, not a general simulation tool. It cannot edit facts, replay history, or test a policy against past data. Each result compared for a rule needs one unique PostgreSQL `bigint` identifier, and that identifier cannot be empty. If the result is too large to return in full, the partial result does not include a token for fetching the next page.

## The boundaries are part of the design

The normal flow is asynchronous. The application commits its facts first, then managed maintenance records policy changes and work. If a consequence must finish before the source transaction returns, the application must perform that consequence in its own synchronous path.

Workers can run independently, so pg-react does not promise one global order for every action. Priorities and conflict keys decide which work is eligible, but concurrent workers may still finish tasks in different orders. A process that requires every human and automated step to happen in one central sequence may fit a workflow product better.

Effects outside PostgreSQL use at-least-once delivery, and consumers must ignore duplicates. This architecture also does not provide the distributed transaction protocol needed to commit one change atomically across PostgreSQL and an unrelated external system.

Tables and query results used for evaluation must include their schema name and must be readable by the caller. They cannot use PostgreSQL row-level security, commonly called RLS, which normally hides selected rows from selected users. During a logical restore, restore the application schema and data first. Then replay the declarations so pg-react can rebuild and reconcile its state. Moving the live contents of pg-react's private internal catalogs between systems is not a supported restore method.

Some work still belongs elsewhere. Historical analysis may belong in a warehouse. Large files may belong in object storage and a compute engine. The point is not to make PostgreSQL perform every job. The point is to keep an operational decision close to its facts when doing so removes unnecessary handoffs.

## Where this approach fits

This approach fits when PostgreSQL owns the relevant facts, SQL can describe the condition, and the response may happen after the source transaction commits. Examples include reviewing risk, responding to inventory shortages, enforcing billing controls, finding entitlement differences, reconciling records, detecting service-level violations, and correcting data-quality problems. In each case, several facts combine into a current condition, the moment that condition changes matters, and the response needs durable state or work.

Teams do not need to adopt every project at once. pg_trickle can maintain current SQL results without pg-react. pg-react can run database-local responses without sending anything to another system. An outbox and a delivery process are necessary only when the work must leave PostgreSQL.

The warehouse shortage started as ordinary rows in several tables. Together, the projects turn those rows into a current condition, remember each occurrence of the shortage, record the work needed to address it, and send a message outside PostgreSQL when necessary. When procurement responds, that response becomes another fact and the cycle continues. PostgreSQL keeps the history that connects the original shortage, the decision, the work, and the outcome.
