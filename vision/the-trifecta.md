# When PostgreSQL data needs to do something

Related documents: [Product thesis](pg-react_product_thesis.md), [PostgreSQL as an operational data platform](operational-data-platform.md), and [Practical rule-engine features](pg-react_practical_rule_engine_features.md).

> Current state: pg-react targets `1.0.0-rc.1`, with M34 and extension `0.31.0` as the v1 feature boundary. The qualified stack uses PostgreSQL 18.3 and pg_trickle 0.81.0. See the [support matrix](../docs/v1-support-matrix.md). pg_trickle and pg_tide remain separate projects whose own documentation defines their releases and APIs.

An order crosses EUR 10,000 while its customer is marked high risk. The business must open a manual review and notify a risk platform.

The facts live in PostgreSQL, but the reaction often gets scattered across a refresh job, application callbacks, a queue, retry workers, and code that remembers whether this order already opened a review. Three PostgreSQL projects divide that path by responsibility:

- [pg_trickle](https://github.com/trickle-labs/pg-trickle) maintains the SQL result that finds risky orders.
- [pg-react](https://github.com/trickle-labs/pg-react) records when an order enters, changes within, or leaves that result and creates durable work when policy requires it.
- [pg_tide](https://github.com/trickle-labs/pg-tide) is the delivery project for carrying committed intent to another system. Its documentation owns the exact transport and receipt contract.

pg_trickle maintains the answer. pg-react decides whether the answer changes policy state or requires work. A transactional delivery layer carries the work beyond PostgreSQL.

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

SQL can find every high-risk order over EUR 10,000. The qualified pg-react runtime uses pg_trickle with its scheduler off and coordinates explicit differential refresh itself. That creates one controlled boundary between committed source facts and policy evaluation.

The maintained condition is still a PostgreSQL relation. Each row means that the order matches now. It is not a durable event and does not record what an earlier match already caused.

For a dashboard, the relation may be enough. A policy needs identity and history.

## Remember what the match caused

A pg-react rule uses a relation or view as its condition. A semantic key identifies the subject. If order 42 rises from EUR 9,000 to EUR 12,000, the order enters the condition and pg-react records an activation.

A constraint rule records the match without executing a consequence. A command rule may create durable work for activation, change, or deactivation. If the amount rises again while the order remains active, pg-react can update the revision or create `on_change` work according to the declaration. It does not create another activation merely because a source row changed.

If the order drops below EUR 10,000, the activation ends. A later rise starts a new generation. This separates one continuous period of truth from the next.

The current public model exposes matches, work, attempts, decisions, and policy sets. Work can be claimed, leased, retried, completed, failed, or withdrawn. Priorities and conflict keys influence claims, but independent workers do not share one global order.

pg-react can also route the review with a decision declaration. SQL emits reviewer or queue candidates. The lowest numeric priority wins; a tied best priority becomes `AMBIGUOUS`, and losing all candidates becomes `NO_CANDIDATE`. A policy set can group the review rule and routing decision and limit them with a relational applicability source.

## Deliver without a dual write

Suppose one worker must create the local review and notify a remote risk platform. Calling the remote service inside the PostgreSQL transaction does not make the two systems atomic.

The safe local contract is a transactional outbox. The worker writes the review row and outgoing intent in the same transaction that completes pg-react work. A commit keeps them together; a rollback removes them together. A relay delivers the message after commit.

Delivery remains at least once. If a connection fails after the receiver accepts the message, the relay may repeat it. The receiver must deduplicate by stable identity.

pg_tide can fill the delivery role in this architecture, but pg-react does not bundle or qualify pg_tide's transports. Use the pg_tide project documentation to choose and operate that relay.

## Follow one order through the stack

For order 42, the policy runs as follows:

1. The application commits an update that raises the order from EUR 9,000 to EUR 12,000.
2. The managed pg-react cycle asks pg_trickle to refresh the eligible maintained condition.
3. pg-react records a new activation and creates durable review work.
4. A worker claims the work. It inserts the local review row and, if remote delivery is required, an outbox row in one transaction with the pg-react completion.
5. A relay delivers the committed message. Failed delivery leaves durable state for retry.
6. The risk platform's response returns through an application or inbox path and becomes another PostgreSQL fact.
7. A later coordinated cycle updates the condition and records the next lifecycle transition.

Each handoff leaves durable PostgreSQL state before the next stage begins. The components do not claim that the whole path is one distributed transaction.

## Compare a policy change before deployment

The current pg-react product can compare a deployed rule, decision, or policy set with a proposed declaration over current authoritative facts. `pgreact.compare()` returns bounded current, proposed, delta, lifecycle, and would-be work evidence without deploying the proposal or executing consequences.

For this order policy, a team can lower the threshold in a proposed rule and see which current orders would be added, removed, or changed. The [order review showcase](../showcase/order-review/README.md) runs that exact kind of comparison.

Comparison does not change the order facts and does not replay history. Hypothetical fact changes and backtesting are not supported in v1.

## Know the transaction and runtime boundaries

The default flow is asynchronous. The source transaction commits before refresh, evaluation, and consequence execution. Code that must accept or reject the original write synchronously belongs in the application write path.

The qualified runtime uses one PostgreSQL-managed worker for each configured database, `READ COMMITTED`, pg_trickle scheduling disabled, and coordinated differential refresh. `pg-reactd` remains a compatibility path, not the normal runtime.

The external guarantee ends at the destination. An outbox preserves and retries committed intent, but end-to-end exactly-once behavior requires receiver-side deduplication.

Logical restore also has a boundary. Restore the application schema and data, replay declarations, then rebuild and reconcile pg-react state. Do not treat private pg-react catalogs as a portable logical backup.

## Adopt only the pieces you need

Use pg_trickle alone when a maintained SQL result is the full requirement. Use pg-react when the result needs semantic identity, lifecycle, deterministic policy, bounded explanation, or durable database work. Add an outbox and relay only when an effect must leave PostgreSQL.

The full path fits when PostgreSQL owns the facts, the condition is relational, and later execution is acceptable. It is a poor fit for synchronous write rejection, one global execution order, cross-system atomic commit, or a general human workflow.

For order 42, the division stays simple: pg_trickle maintains the matching relation, pg-react remembers what the match means and what work it caused, and the delivery layer carries committed intent across the boundary PostgreSQL cannot cross alone.
