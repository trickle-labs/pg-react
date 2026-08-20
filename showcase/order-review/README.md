# Order review example

This package asks one practical question: does the current order require manual review, and if it does, which queue should receive it? PostgreSQL owns the customers, orders, payment attempts, reviewer candidates, and review tasks. pg-react watches the relational policy, records lifecycle state, creates durable command work, chooses the lowest-priority routing candidate, and compares a lower amount threshold without deploying it. The result is intentionally a database example rather than a small application in disguise. There is no checkout hook, fraud model, remote consumer, release gate, or case-management screen.

## The four fixture orders

```text
1001  already risky       proves bootstrap and clear routing
1002  eligible, below v1   proves ambiguity and threshold comparison
1003  changes over time    proves activation, revisions, deactivation, and retry
1004  high risk, suspended proves that applicability limits participation
```

The example uses these rows to tell one small story. You can follow the
scenario without first understanding every internal table.

## Vocabulary

| Term | Meaning here |
|---|---|
| Match | A row currently satisfies the condition view. |
| Activation | A subject enters the condition. |
| Generation | One continuous active period for a subject. |
| Revision | A watched change during that active period. |
| Work item | Durable execution work for one lifecycle event. |
| Attempt | One execution try for a work item. |
| Eligibility | A subject belongs to the policy, whether or not it currently matches. |

## Prerequisites

Run from the repository root with Docker available and the `pg-react:1.0.0-rc.1` image already built. The qualified environment is pg-react `1.0.0-rc.1`, PostgreSQL 18.3, pg_trickle 0.81.0, and Linux `amd64`, which is the platform pinned by `docker-compose.yml`. The runner creates a disposable Compose project and an isolated database, then removes both on exit.

```bash
./tests/order-review-showcase.sh
```

A passing run prints four summary lines: SQL assertions, transcript, cleanup, and the complete example all pass. Failures print the captured PostgreSQL or transcript diff output instead of burying the useful line in routine server notices.

## Script order

Run `01-schema.sql`, `02-seed.sql`, `03-core-rules.sql`, `04-decisions-and-policy-set.sql`, and `05-scenarios.sql` in that order. The first two scripts create deterministic facts. The next two validate, preview, and deploy the constraint rule, command rule, and decision, then validate and preview the policy set. The scenario script drives activation, two changes, deactivation, failed reactivation, retry, candidate removal, explanation, comparison, and final policy-set deployment. `99-cleanup.sql` removes the policy and decision, cancels pending policy-migration episodes through the public API, removes both rules, and drops the disposable schemas.

The scripts call `pgreact.run()` at fixed sampled times so rule and decision coordination does not depend on polling. Consequence execution uses the installed PostgreSQL-managed cycle because `pgreact.run()` creates durable work but does not wait for every consequence attempt. Retry uses the configured one-second database-time backoff and a bounded managed-cycle loop, with no `pg_sleep()`. The consequence writes only to `app.review_tasks`, uses the activation generation and idempotency key, and never calls a network service.

Declarations are typed SQL values. The scripts reconstruct the same declaration
for validation, preview, deployment, and comparison so every operation uses the
same definition. The repetition is deliberate and avoids relying on generated
UUIDs or private catalog state.

This example does not reject an order write, call a remote service, assign a
human case, or guarantee exactly-once external delivery. It creates durable
PostgreSQL work and executes a database-local function.

## Expected behavior and limits

Order `1001` starts as a current match and routes to `chargeback-review`. Order `1002` is eligible but below the v1 amount threshold, has tied routing candidates, and becomes the single `ADDED` order under the proposed `500.00` threshold. Order `1003` moves through generation 1, closes, then enters generation 2; its first reactivation attempt returns `P6001`, its second attempt completes, and candidate removal leaves the retained decision state at `NO_CANDIDATE`. Order `1004` remains ineligible because its customer is suspended.

The exact fixture omits generated UUIDs, worker identifiers, deployment timestamps, attempt timestamps, and elapsed milliseconds. It preserves semantic keys, generations, revisions, event kinds, work states, error details, application rows, decision results, eligibility, declaration state, comparison completeness, and the before and after authoritative checksums. The comparison is a current-state proposal review, not historical replay or hypothetical source mutation, and it creates no application task or attempt for order `1002`.

`06-advanced.sql` reports advanced chapters as omitted. Deadline escalation, derived facts, provenance, and effective-dated policy versions remain out until this package names each specialized public call, states its resource bounds, and freezes exact output against the qualified image. External delivery is also absent. If a database-local consequence is replaced with an outbox or remote consumer later, delivery is at least once and the consumer must remain idempotent.

Read [the tutorial](../../docs/order-review-tutorial.md) for the guided path, [Authoring Rules and Policies](../../docs/v1-authoring.md) for constructor details, and [Operations](../../docs/v1-operations.md) before changing or removing deployed work.

## Inspect the result

After running the scenario, these queries show current matches, durable work,
execution attempts, application tasks, and routing decisions.

```sql
SELECT *
FROM pgreact.matches
WHERE name = 'order-review-work';

SELECT *
FROM pgreact.work
WHERE name = 'order-review-work';

SELECT *
FROM pgreact.attempts
WHERE name = 'order-review-work';

SELECT *
FROM app.review_tasks
ORDER BY order_id, generation;

SELECT *
FROM pgreact.decision_winners
WHERE program_name = 'order-review-route';
```