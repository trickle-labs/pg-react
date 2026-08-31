# When PostgreSQL data needs to do something

Related documents: [Product thesis](pg-react_product_thesis.md), [PostgreSQL as an operational data platform](operational-data-platform.md), and [Practical rule-engine features](pg-react_practical_rule_engine_features.md).

> Current state: M41 and extension `0.38.0` are pg-react's qualified baseline. M42 is the current planning milestone and defines evidence snapshots for extension `0.39.0`. The repository retains the prepared `1.0.0-rc.1` candidate, but `1.0.0` and its complete feature freeze are postponed indefinitely. The qualified stack uses PostgreSQL 18.3 and pg_trickle 0.81.0. See the [support matrix](../docs/v1-support-matrix.md). pg_trickle and pg_tide remain separate projects whose own documentation defines their releases and APIs.

An order crosses EUR 10,000 while its customer is marked high risk. The business must open a manual review and notify a risk platform. This is a rule: when a set of facts meets a condition, the system records the result and may start work. The condition is easy to state, but a reliable reaction must remember whether this order already opened a review, survive a crash, and avoid sending the same effect as if it were new.

The facts live in PostgreSQL, yet the reaction often gets scattered across a refresh job, application callbacks, a queue, retry workers, and code that keeps track of earlier reviews. Three PostgreSQL projects divide this path by responsibility. [pg_trickle](https://github.com/trickle-labs/pg-trickle) keeps the SQL result for risky orders current. [pg-react](https://github.com/trickle-labs/pg-react) records when an order enters, changes within, or leaves that result, then creates durable work when policy requires it. [pg_tide](https://github.com/trickle-labs/pg-tide) is the delivery project that carries committed intent to another system, with its own documentation defining the exact transport and receipt contract.

In short, pg_trickle maintains the answer to the query. pg-react decides what that answer means for policy and work. A transactional delivery layer carries the committed work beyond PostgreSQL.

```text
Order and customer facts
          |
          v
      pg_trickle
Maintained condition relation
          |
          v
       pg-react
Lifecycle, decision, and durable work
          |
          v
 Transactional outbox
          |
          v
External risk platform
```

## Keep the condition current

SQL can find every high-risk order over EUR 10,000. The result of that query is the condition relation: each row means that an order matches the rule now. pg_trickle keeps this relation current as order and customer facts change. In the qualified pg-react runtime, pg-react turns off the pg_trickle scheduler and asks for each differential refresh itself. A differential refresh updates only what changed, and this coordination creates one controlled boundary between committed facts and policy evaluation.

The maintained condition is still an ordinary PostgreSQL relation. It describes the present, not the history. A row does not say when the match began, whether an earlier match already opened a review, or what work followed. That present-tense answer may be enough for a dashboard. A policy needs identity and memory.

## Remember what the match caused

A pg-react rule uses a relation or view as its condition and a semantic key to identify the subject. The semantic key is a stable business identity, such as the order ID. It lets pg-react follow the same order through many physical row updates. If order 42 rises from EUR 9,000 to EUR 12,000, the order enters the condition and pg-react records an activation, which means that this period of matching has begun.

A constraint rule records the match without running a consequence. A command rule may also create durable work when the match begins, changes, or ends. If the amount rises again while order 42 remains above the threshold, pg-react can update the revision or create `on_change` work according to the declaration. It does not record another activation merely because a source row changed.

If order 42 later drops below EUR 10,000, the activation ends. A later rise begins a new generation, which represents a new continuous period in which the rule is true. This distinction prevents pg-react from confusing work from the earlier period with work from the new one.

The public model exposes matches, work, attempts, decisions, and policy sets. A worker can claim work for a limited lease, retry it, complete it, fail it, or withdraw it. Priorities and conflict keys affect which work a worker may claim, but independent workers do not share one global order.

pg-react can also decide where to route the review. SQL produces candidate reviewers or queues, each with a numeric priority. The lowest number wins. If the best candidates tie, pg-react reports `AMBIGUOUS` instead of choosing arbitrarily. If no candidates remain, it reports `NO_CANDIDATE`. A policy set can group the review rule with the routing decision and use a relation to limit where that policy applies.

## Deliver without a dual write

Suppose one worker must create a local review and notify a remote risk platform. Calling the remote service from inside a PostgreSQL transaction cannot make the database change and the remote call succeed or fail as one atomic action. The connection may disappear after one side succeeds, leaving the worker unable to know whether it is safe to repeat the call.

A transactional outbox provides a safe local contract. An outbox is a PostgreSQL table of messages that still need delivery. In the transaction that completes the pg-react work, the worker inserts the local review into its table and the outgoing intent into the outbox. If the transaction commits, PostgreSQL keeps all three changes. If it rolls back, PostgreSQL keeps none of them. A separate relay reads the outbox and delivers the message after commit.

Delivery remains at least once. If the connection fails after the risk platform accepts the message, the relay may send it again. The receiver must use the message's stable identity to recognize the repeat and avoid applying it twice. pg_tide can provide the delivery role in this architecture, but pg-react neither bundles nor qualifies pg_tide's transports. Use the pg_tide documentation to choose and operate that relay.

## Follow one order through the stack

For order 42, the policy runs as follows:

1. The application commits an update that raises the order from EUR 9,000 to EUR 12,000.
2. The managed pg-react cycle asks pg_trickle to refresh the eligible maintained condition.
3. pg-react records a new activation and creates durable review work.
4. A worker claims the work. It inserts the local review row and, if remote delivery is required, an outbox row in one transaction with the pg-react completion.
5. A relay delivers the committed message. Failed delivery leaves durable state for retry.
6. The risk platform's response returns through an application or inbox path and becomes another PostgreSQL fact.
7. A later coordinated cycle updates the condition and records the next lifecycle transition.

Each handoff writes durable PostgreSQL state before the next stage begins. The components do not claim that the whole path is one distributed transaction.

## Compare a policy change before deployment

The current pg-react product can compare a deployed rule, decision, or policy set with a proposed declaration against the facts that PostgreSQL holds now. `pgreact.compare()` returns a limited amount of evidence about the current result, the proposed result, their differences, the resulting lifecycle changes, and the work that the proposal would create. It does not deploy the proposal or run its consequences.

For the order policy, a team can propose a lower threshold and see which current orders would be added, removed, or changed. The [order review showcase](../showcase/order-review/README.md) performs that kind of comparison. The comparison does not alter order facts, replay history, apply imaginary fact changes, or backtest the policy. pg-react v1 does not support those uses.

## Know the transaction and runtime boundaries

The default flow is asynchronous. The application first commits the source transaction. Refresh, policy evaluation, and consequence execution happen later. Any code that must accept or reject the original write before commit belongs in the application's write path.

The qualified runtime uses one PostgreSQL-managed worker for each configured database, `READ COMMITTED`, disabled pg_trickle scheduling, and coordinated differential refresh. `pg-reactd` remains a compatibility path rather than the normal runtime. Outside PostgreSQL, the guarantee ends at the destination. An outbox preserves committed intent and retries delivery, but exactly-once behavior across the full path requires the receiver to recognize duplicates.

Logical restore has a boundary too. Restore the application schema and data, replay the declarations, then rebuild and reconcile pg-react state. Private pg-react catalogs are not a portable logical backup.

## Adopt only the pieces you need

Use pg_trickle alone when a maintained SQL result meets the whole requirement. Add pg-react when that result needs a stable business identity, a lifecycle, a deterministic decision, a bounded explanation, or durable database work. Add an outbox and relay only when an effect must leave PostgreSQL.

The complete path fits when PostgreSQL owns the facts, SQL can express the condition, and the application can accept later execution. It does not fit synchronous write rejection, one global execution order, an atomic transaction across systems, or a general human workflow.

For order 42, the division remains direct. pg_trickle keeps the matching relation current. pg-react remembers what the match means and what work it caused. The delivery layer carries committed intent across the boundary that PostgreSQL cannot cross by itself.
