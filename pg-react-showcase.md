# Order review showcase implementation plan

## Goal

Build a runnable marketplace example that turns changing PostgreSQL order facts into current policy state, durable review work, routing decisions, explanations, and a safe policy comparison.

The example answers one question:

> Does this order require manual review, and if so, which queue should receive it?

The deadline chapter asks a separate follow-up question: has an open review passed its deadline? Order release remains an application decision. The showcase does not implement a release gate.

The example must teach the ordinary pg-react workflow before it introduces advanced features. A reader should be able to run the core scenario with PostgreSQL and pg-react, inspect the result with SQL, and add any retained advanced chapter without replacing the data model.

The showcase must demonstrate pg-react as a PostgreSQL rule and policy engine. It must not present pg-react as a fraud model, a synchronous checkout hook, a workflow system, or a distributed transaction coordinator.

## Product decision

Use **order review** as the single showcase scenario.

The scenario has enough relational change to exercise activation, change, deactivation, reactivation, decisions, durable work, retries, explanations, deadlines, and policy comparison. It also gives each feature a concrete business reason:

- An order becomes risky when its current facts satisfy a review condition.
- A review task is durable work created by a command rule.
- A route decision chooses the queue with the lowest priority.
- A policy set limits rules and decisions to eligible orders.
- A deadline creates escalation work when review remains open too long.
- A policy comparison shows which orders a new threshold would affect.
- A derived customer fact records why enhanced review remains required.

Keep the core scenario small. Do not add inventory reservation, payment authorization, shipping orchestration, release approval, or a web application.

## Target environment and publication gate

Target the repository's qualified v1 environment: pg-react `1.0.0-rc.1`, PostgreSQL 18.3, and pg_trickle 0.81.0 on Linux amd64. Run it through the repository's Docker environment on development hosts.

The ordinary rule, decision, policy-set, comparison, retry, and cleanup path is the publication gate. Deadline, derivation, provenance, and effective-dated policy chapters are follow-ups. Add each advanced chapter only after its public API call and exact output pass an executable fixture against the target environment.

## Audience and completion state

The audience is a PostgreSQL developer who understands tables, views, functions, and transactions but has not used pg-react.

The showcase is complete when a reader can:

1. Start the supported PostgreSQL and pg-react environment.
2. Load the example schema and deterministic seed data.
3. Deploy the first rule with `validate`, `preview`, and `deploy`.
4. Change an order and observe a lifecycle transition.
5. Inspect current matches, work, attempts, and explanations.
6. Route a review with a decision and inspect winner, ambiguity, and no-candidate states.
7. Compare a proposed policy without creating work or effects.
8. Trigger a retry and verify idempotent application state.
9. Run every included advanced chapter against its named public API and documented resource bounds.
10. Remove all deployed objects and disposable application objects with one cleanup script.

## Scope boundaries

### Core path

Use only the ordinary documented v1 workflow for the first runnable path:

- PostgreSQL application tables and views as authoritative facts.
- One `bigint` `order_id` semantic key for ordinary rule comparison.
- A `CONSTRAINT` rule for current risky-order truth.
- A `COMMAND` rule with typed activation, change, and deactivation consequences.
- A decision declaration for review routing.
- A policy-set declaration for order eligibility.
- `validate`, `preview`, `deploy`, `status`, `explain`, `compare`, and `compare_results`.
- Public projections such as `pgreact.matches`, `pgreact.decision_winners`, `pgreact.work`, `pgreact.attempts`, and `pgreact.health`.
- A PostgreSQL-managed runtime and one idempotent database-local consequence.
- Explicit `pgreact.run()` calls at fixed sampled times in the executable fixture.

Do not add an outbox or network consumer to the core path. A database-local consequence is enough to teach durable work and retries. External delivery would add a second reliability story without helping the first-run example.

### Advanced path

Add separate chapters for capabilities that are installed but have specialized APIs:

- Database-time deadline escalation.
- Derived facts, logical support, and bounded provenance.
- Effective-dated policy versions.
- Optional event-time windows only if the chapter can use the installed contract without turning the order example into a second product.

Each advanced chapter must name its API, resource bounds, evidence command, and unsupported cases. Do not call an advanced API through the ordinary `pgreact.deploy()` path unless the installed documentation classifies that API as an ordinary declaration.

### Explicit non-goals

Do not include these claims or features:

- Synchronous rejection of an order during the source write.
- A machine-learning fraud classifier inside pg-react.
- Exactly-once delivery outside PostgreSQL.
- One global firing order across independent workers.
- A human workflow or case-management interface.
- Arbitrary remote calls from a typed PostgreSQL consequence.
- Historical replay or backtesting of a policy against past facts.
- Private catalog queries as part of the tutorial.

## Artifact set

Create the showcase as a small package with one narrative document, one runnable SQL path, and one executable transcript.

```text
pg-react-showcase.md

docs/order-review-tutorial.md
showcase/order-review/README.md
showcase/order-review/01-schema.sql
showcase/order-review/02-seed.sql
showcase/order-review/03-core-rules.sql
showcase/order-review/04-decisions-and-policy-set.sql
showcase/order-review/05-scenarios.sql
showcase/order-review/06-advanced.sql        # only qualified advanced chapters
showcase/order-review/99-cleanup.sql

tests/order-review-showcase.sql
tests/order-review-showcase.sh
tests/fixtures/order-review-showcase/expected-transcript.txt
```

### `docs/order-review-tutorial.md`

Write one tutorial. Open with the finished result and the first visible query output. Use numbered steps in the order a reader runs them.

Each step must include:

- the SQL or command to run;
- the result the reader should see;
- one short explanation of the pg-react concept involved;
- a link to a reference page when the reader needs exact API details.

Keep reference material out of the tutorial. Link to [Getting Started](docs/getting-started.md), [Concepts](docs/concepts.md), [Authoring Rules and Policies](docs/v1-authoring.md), and [Changing Policies Safely](docs/changing-policies.md).

### `showcase/order-review/README.md`

Document prerequisites, the supported environment, the script order, expected runtime behavior, cleanup, and the limits of the example. Keep this file short enough to serve as the entry point for someone who wants to run the demo without reading the tutorial first.

### SQL files

Keep setup, facts, declarations, scenarios, and cleanup separate. A reader must be able to run the core path without the advanced file.

- `01-schema.sql` creates disposable `app`, `rule_def`, and `rule_action` objects.
- `02-seed.sql` inserts deterministic customers, orders, payment attempts, review candidates, and policy applicability data.
- `03-core-rules.sql` creates condition views, typed consequences, declarations, validation output, preview output, and deployment statements.
- `04-decisions-and-policy-set.sql` creates the routing candidate relation, decision declaration, applicability relation, and policy-set declaration.
- `05-scenarios.sql` performs source changes and inspection queries in a fixed order.
- `06-advanced.sql` contains deadline, provenance, and effective-date examples behind clear prerequisites.
- `99-cleanup.sql` removes deployed objects before dropping the disposable schemas.

Use stable names and explicit schema qualification in every declaration. Do not use internal UUIDs in authoring examples.

### Executable transcript

`tests/order-review-showcase.sql` must follow the existing v1 documentation fixture style: build stable JSON from the public projections and compare it with exact expected JSON in SQL. `tests/order-review-showcase.sh` must create an isolated database in the supported Docker environment, execute the fixture with `ON_ERROR_STOP`, run the tutorial transcript, and compare that transcript with `tests/fixtures/order-review-showcase/expected-transcript.txt`.

The transcript must prove behavior, not only row counts. Include stable columns and normalized values. Exclude nondeterministic timestamps, worker identifiers, and generated UUIDs unless the test can fix or normalize them.

## Application data model

Create only the tables needed to tell the story.

### Authoritative facts

`app.customers`:

- `customer_id bigint primary key`
- `chargeback_count integer not null`
- `account_status text not null`

`app.orders`:

- `order_id bigint primary key`
- `customer_id bigint not null`
- `amount numeric(12,2) not null`
- `risk_level text not null`
- `status text not null`
- `review_deadline timestamptz`

`app.payment_attempts`:

- `payment_attempt_id bigint primary key`
- `order_id bigint not null`
- `outcome text not null`
- `attempted_at timestamptz not null`

`app.review_tasks`:

- `order_id bigint not null`
- `generation bigint not null`
- `state text not null`
- `reason_code text not null`
- `amount numeric(12,2) not null`
- `activation_id uuid not null`
- `last_revision bigint not null`
- `last_idempotency_key text not null unique`
- primary key on `(order_id, generation)`

The task table represents one row per activation episode. Routing remains a decision result; do not copy `queue_name` into the task and create a second source of truth.

`app.failure_controls`:

- `order_id bigint primary key`
- `fail_review_task boolean not null`

The consequence reads this table only to create the deterministic retry scenario. Do not project the flag from the condition view because changing the flag must not create a lifecycle revision.

Add foreign keys and checks where they clarify the example. Do not add a generic event table to imitate pg-react's internal history.

### Deterministic seed matrix

Use these four orders as the stable fixture. Exact customer and reviewer identifiers belong in `02-seed.sql`, but the role of each row is part of the showcase contract.

| Order | Initial facts | Expected role |
| --- | --- | --- |
| `1001` | Open customer with a prior chargeback, `HIGH` risk, pending, amount `1500.00` | Current v1 match and one routing winner. |
| `1002` | Open customer, `HIGH` risk, pending, amount `750.00` | Absent from v1, `ADDED` by the v2 threshold, and tied routing candidates. |
| `1003` | Open customer, `LOW` risk, pending, amount `1200.00` | Lifecycle subject. Raising risk activates it; its only routing candidate is later removed to produce `NO_CANDIDATE`. |
| `1004` | Suspended customer, `HIGH` risk, pending, amount `2000.00` | Ineligible for the policy and absent from the risky-order condition. |

Use checks on `risk_level`, `status`, task state, and non-negative counts. Seed timestamps in UTC from one fixed fixture time.

## Core rule design

### Define the risky-order condition

Create `rule_def.risky_orders` with one row per risky order and `order_id` as the semantic key. Project the values needed by consequences and explanations:

- `order_id`
- `customer_id`
- `merchant_id`
- `amount`
- `risk_level`
- `reason_code`
- `review_deadline`

Define v1 exactly:

- the order status is `PENDING`;
- the customer account status is `OPEN`;
- the order risk level is `HIGH`;
- the amount is at least `1000.00`.

Set `reason_code` to `PRIOR_CHARGEBACK` when `chargeback_count > 0` and `HIGH_RISK_VALUE` otherwise. Define v2 with the same logic and a `500.00` amount threshold. This makes order `1002` the comparison's single `ADDED` subject.

Keep the condition relational. The view may join customer and payment facts, but the first chapter should make the rule understandable from one order row and a small number of supporting facts.

### Deploy current truth

Deploy `order-review-required` as a `CONSTRAINT` rule first. Show that existing matching rows are seeded as current state under the default `SEED_CURRENT` policy and do not create command work during bootstrap.

Inspect:

- `pgreact.matches` for current truth and lifecycle state;
- `pgreact.status('order-review-required')` for the deployed object;
- `pgreact.explain('order-review-required')` for bounded evidence.

### Add durable work

Create `order-review-work` as a `COMMAND` rule with typed consequences:

- `on_activate` inserts or idempotently restores the task for `(order_id, context.generation)`;
- `on_change` updates that generation's task and records `context.revision`;
- `on_deactivate` closes that generation's task.

Make every consequence idempotent. Use `context.idempotency_key` and the stable `(order_id, generation)` identity. The consequence must not call a network service.

Use a separate command-rule name from the constraint rule if the installed runtime cannot safely replace the first declaration in place. The tutorial must say why both names exist rather than implying that a constraint can receive consequences.

### Exercise lifecycle transitions

Seed and execute these transitions in order:

1. An order below the threshold is not active.
2. Raising its risk level activates the order and creates one review task.
3. Changing its amount creates one revision and updates the task.
4. Increasing the customer's chargeback count changes `reason_code`, creates the next revision, and updates the same task.
5. Marking the order safe deactivates the match and closes the task.
6. Making the order risky again creates a new generation and one new activation episode.

Query `pgreact.matches`, `pgreact.work`, and `pgreact.attempts` after each transition. The transcript must show generation and revision values, work state, event kind, and application state.

## Decision and policy-set design

### Route review candidates

Create `rule_def.review_candidates` with these columns:

- `order_id`
- `reviewer_id`
- `priority`
- `queue_name`

Deploy `order-review-route` with `pgreact.decision()`:

- subject key: `order_id`;
- candidate key: `reviewer_id`;
- priority: `priority`;
- result: `queue_name`.

Seed and run three cases:

- one order with one best candidate, producing `WINNER`;
- one order with tied best candidates, producing `AMBIGUOUS`;
- one order with a winner whose only candidate is then deleted, producing `NO_CANDIDATE` for a known subject.

An unseen subject with no candidate is `never_observed`; it does not produce a `NO_CANDIDATE` row. Show the three retained states through `pgreact.decision_winners` and `pgreact.explain()`. Do not silently resolve ambiguity in SQL. The tutorial should say what an application must decide when the result is ambiguous.

### Define applicability

Create `rule_def.reviewable_orders` with one `order_id` per order eligible for the review policy. Use order status and account status to make applicability distinct from the risky-order condition.

Create `order-review-policy` with the command rule, the routing decision, the applicability relation, and a bounded evidence limit. Use policy-set version `1`.

Show that an order can be eligible for the policy without currently matching the risky-order condition. Explain that membership, applicability, and current match state answer different questions.

## Safe policy change

Create `rule_def.risky_orders_v2` with the `500.00` threshold and matching typed consequences for its row type. Build the proposal with the deployed command rule's stable name, `order-review-work`, and target `pgreact_api.target('rule', 'order-review-work')`. Proposal and target names and kinds must match.

Run both:

- `pgreact.compare()` for the complete JSON envelope;
- `pgreact.compare_results()` for a relational report of added, removed, changed, and unchanged orders.

The comparison must show order `1002` as `ADDED` and show would-be work without inserting a row into `pgreact.work`. Use `evidence_limit => 100`, assert complete evidence, and state that each `compare_results()` call performs a new comparison rather than reading the prior JSON envelope.

Check the no-effect contract directly:

- the deployed rule version remains unchanged;
- no new attempt exists for the proposed order;
- no application review task appears because of comparison;
- the comparison result reports its evidence limit, completeness, and matching before/after authoritative checksums.

Stop the core chapter after review; it does not need a cutover to prove safe comparison. Link to [v1 operations](docs/v1-operations.md) for the qualified rule cutover, which pauses the stable name and uses `pgreact_api.replace_rule()`. Identify that call as a compatibility operation, not ordinary `pgreact.deploy()`.

## Failure and recovery scenario

Set `max_attempts => 2` on `order-review-work`. Enable the failure flag before order `1003` reactivates so that generation 2 fails once without changing condition membership.

The scenario must show:

1. A command creates one pending work item.
2. The first attempt fails with a visible error code and message.
3. The work state reflects the configured retry policy.
4. Clearing the failure flag allows a later attempt to succeed.
5. The idempotent consequence leaves one review task, not duplicate tasks.
6. `pgreact.attempts` records both attempts.

Drive both attempts with `pgreact.run()` at fixed, increasing sampled times beyond the configured one-second backoff. Do not use `pg_sleep()` or wait for the managed worker in the expected transcript. Query durable state after each completed run.

## Advanced chapters

### Add a deadline escalation

Use the installed deadline-specific API and its documented direct deadline column contract. Reuse `review_deadline` from `app.orders`.

The chapter must demonstrate:

- a review that is before its deadline;
- a review at the deadline boundary;
- a review after the deadline;
- one escalation consequence;
- database-time sampling and the limit that this is not a general wall-clock scheduler.

Keep deadline work separate from the ordinary rule declarations unless the installed adapter explicitly composes them.

### Add a derived customer fact

Create a derived relation named `customer_requires_enhanced_review`. Derive it from at least two independent supports, such as a chargeback count and repeated payment failures.

Demonstrate:

- both supports make the fact true;
- removing one support keeps the fact true;
- removing the last support retracts the fact;
- the explanation identifies the surviving support or the retraction;
- bounded provenance links the derived fact to the rule versions and source bindings.

Use the specialized derivation and provenance APIs. Do not explain derived facts as command consequences.

### Add effective-dated policy versions

If the installed effective-policy API is part of the target support matrix, add a chapter with policy version `2` beginning at a fixed effective time. Show that policy applicability depends on business-effective time and that versions remain immutable.

Keep this chapter out of the first-run script. Readers should be able to understand the core rule lifecycle without effective-date semantics.

## Implementation phases

### Phase 1: Freeze the showcase contract

Write the scenario README and this plan's artifact list into the implementation checklist. Verify pg-react `1.0.0-rc.1`, PostgreSQL 18.3, pg_trickle 0.81.0, the managed-worker configuration, and `pgreact.run()` before writing SQL.

Stop on a version mismatch. The published showcase targets one qualified environment rather than branching around multiple versions.

### Phase 2: Build the deterministic data set

Create the schemas, tables, constraints, seed rows, and cleanup script. Run the schema and seed scripts without pg-react declarations. Verify that every later expected state has a stable order, customer, candidate, and deadline row.

### Phase 3: Implement the ordinary rule path

Create the condition view and the typed consequences. Validate and preview declarations before deployment. Deploy the constraint and command rules. Add inspection queries after every meaningful source change.

### Phase 4: Add decisions and applicability

Create candidate and applicability relations. Deploy the decision and policy set. Add exact output assertions for winner, ambiguity, no candidate, eligible, and ineligible cases.

### Phase 5: Add comparison and no-effect checks

Create the v2 condition and consequence. Run comparison at the current authoritative frontier. Assert both the returned delta and the absence of durable work or application effects.

### Phase 6: Add failure and advanced chapters

Implement the deterministic retry case first. After the core transcript passes, qualify advanced chapters one at a time. Omit any chapter whose public call, resource bound, or exact expected output is not proved by its fixture.

### Phase 7: Freeze the tutorial and transcript

Run the same scripts from a clean database. Replace unstable output with stable projections or explicit normalization. Make the expected transcript the acceptance artifact for the documented behavior.

### Phase 8: Link the documentation

Add the tutorial and showcase README to the documentation index. Link the tutorial to the existing API, concepts, operations, and safe-change guides. Do not copy reference material into the new tutorial.

## Test plan

Use the existing SQL fixture style. The showcase test must run from a clean disposable database and must remove all objects at the end.

Test these behaviors:

| Area | Required proof |
| --- | --- |
| Schema | Tables, views, functions, constraints, and cleanup run in the documented order. |
| Deployment | Validation and preview succeed before deployment. |
| Constraint state | Current risky orders match the condition and bootstrap creates no command work. |
| Activation | A new risky order creates one generation and one activation work item. |
| Change | A watched value creates one revision and updates the idempotent task. |
| Deactivation | Leaving the condition closes current state and creates the declared deactivation work. |
| Reactivation | Re-entry creates the next generation and one new activation work item. |
| Decision | Winner, ambiguous, and no-candidate states are exact. |
| Applicability | Eligible and ineligible orders are distinguishable from current matches. |
| Comparison | Added, removed, changed, and unchanged rows are correct at one frontier. |
| Comparison effects | Comparison creates no deployment, work, attempt, consequence call, or application task. |
| Failure | Attempts, retry state, error details, and later success are durable. |
| Explanation | Explanation output names the rule, subject, lifecycle state, and bounded evidence. |
| Advanced APIs | Each included advanced chapter proves its documented limit and failure behavior. |
| Cleanup | No showcase schema or deployed object remains after cleanup. |

The test should fail if output changes unexpectedly. Do not weaken assertions to row counts when the exact lifecycle state is part of the contract.

## Tutorial outline

Use this order for `docs/order-review-tutorial.md`:

1. Build the order review policy.
2. Check the pg-react installation.
3. Create the application facts.
4. Define current risky-order truth.
5. Deploy and inspect a constraint rule.
6. Add durable review work.
7. Change facts and follow the lifecycle.
8. Route reviews with a decision.
9. Limit the policy with applicability.
10. Compare a lower threshold without executing it.
11. Recover a failed consequence.
12. Remove the core showcase objects.
13. Optional: add deadline escalation.
14. Optional: explain a derived customer fact.
15. Read the limits and choose the next reference guide.

The first five steps must produce visible output. Do not make the reader wait until the advanced chapters to see a match, a work item, or an explanation.

## Acceptance criteria

The showcase is ready to publish when all of these statements are true:

- A new reader can run the core SQL path from a clean supported environment.
- The tutorial uses only public, documented names.
- Every declaration has a stable name and schema-qualified relation or procedure identity.
- The first command rule uses an explicit `kind => 'COMMAND'`.
- Consequences are idempotent and do not make network calls.
- The transcript proves activation, change, deactivation, reactivation, decision outcomes, comparison no-effect behavior, and retry state.
- The comparison chapter does not imply historical replay or hypothetical fact mutation.
- The tutorial states that external delivery is at least once.
- Every included advanced chapter identifies its specialized API and limits.
- The cleanup script removes deployed objects before dropping their source relations.
- The test uses an isolated database in the supported Docker environment and reports only its summary when it passes.
- The documentation index links the tutorial and the showcase README.

## Checks before implementation

Only two checks remain before writing the final SQL:

1. Name and fixture-test each specialized API used by an optional advanced chapter. Drop the chapter if its call is not qualified for `1.0.0-rc.1`.
2. Identify the public output fields that need omission or normalization because they contain timestamps, UUIDs, worker identifiers, or elapsed time.

Record the answers in `showcase/order-review/README.md`. The core uses no outbox, deterministic execution uses `pgreact.run()`, and safe comparison stops before replacement. The tutorial must describe only behavior that the executable transcript proves.
