# Review marketplace orders with pg-react

An order crosses the review threshold, pg-react records a new activation, and a PostgreSQL consequence opens one durable task for that activation generation. Change the amount and the same task is revised. Make the order safe and the task closes. Make it risky again and a fresh generation begins. Meanwhile, a decision chooses a queue, an applicability relation says which orders belong to the policy, and a comparison tells us exactly what a lower threshold would change without creating work. That is the whole story, and it is enough to make the database feel pleasantly busy without pretending it has become a fraud model or a workflow product.

The finished example leaves this visible current truth after the scripted lifecycle. Orders `1001` and `1003` satisfy the independent constraint rule, while the policy considers `1001`, `1002`, and `1003` eligible. Those are different questions on purpose: eligibility says an order may participate, current truth says the order satisfies the risk condition, and routing says what to do when candidates exist.

```json
{"step":"policy applicability","eligible":[1001,1002,1003],"current_constraint_matches":[1001,1003]}
```

## 1. Build the order review policy

Start with the acceptance runner. It creates an isolated database, loads every core script, compares the complete normalized state with exact expected JSON, checks the reader-visible transcript byte for byte, runs cleanup, and removes its Compose project. This is the quickest way to establish that the image and repository agree before walking through the example by hand, and the four-line result is deliberately uneventful.

```bash
./tests/order-review-showcase.sh
```

```text
order-review SQL assertions passed
order-review transcript passed
order-review cleanup passed
order-review showcase passed
```

The rest of this tutorial runs the same package more slowly so each state change has time to introduce itself. For the smaller first-rule walkthrough, see [Getting Started](getting-started.md); for the vocabulary behind matches, generations, revisions, and work, see [Concepts](concepts.md).

## 2. Check the pg-react installation

Bring up the qualified image and create a disposable database. The Compose file pins Linux `amd64` and configures PostgreSQL with both libraries preloaded. The manual database is not added to the background worker list, so the scripts use explicit fixed-time coordination and bounded managed execution calls. That keeps this run deterministic while exercising the same durable PostgreSQL work path.

```bash
export COMPOSE_PROJECT_NAME=pgreact-order-review
export DB=order_review
docker compose up -d --wait --no-build
docker compose exec -T postgres psql -X -U postgres -d postgres \
  -v ON_ERROR_STOP=1 \
  -c "DROP DATABASE IF EXISTS $DB WITH (FORCE)" \
  -c "CREATE DATABASE $DB"
docker compose exec -T postgres psql -XAtq -U postgres -d "$DB" \
  -v ON_ERROR_STOP=1 \
  -c "CREATE EXTENSION pg_trickle; CREATE EXTENSION pg_react"
docker compose exec -T postgres psql -XAt -U postgres -d "$DB" \
  -c "SELECT extname || '=' || extversion FROM pg_extension WHERE extname IN ('pg_react','pg_trickle') ORDER BY extname" \
  -c "SELECT pgreact_api.worker_protocol_compatible(2)"
```

```text
pg_react=1.0.0-rc.1
pg_trickle=0.81.0
t
```

Stop if the extension versions or worker protocol differ. The supported server is PostgreSQL 18.3 with pg-react `1.0.0-rc.1` and pg_trickle 0.81.0. Installation and preload details live in [Installation](v1-installation.md), while runtime diagnosis belongs in [Operations](v1-operations.md).

## 3. Create the application facts

Load the schema and the deterministic seed matrix. Customers remain the authority for chargeback count and account status. A trigger copies those two policy inputs onto each order when the customer changes, which lets the pg_trickle-backed condition remain a single-table relation while preserving customer-driven revisions. The package also creates payment attempts, reviewer candidates, review tasks, and one explicit failure-control table used only to make retry repeatable.

```bash
for script in 01-schema.sql 02-seed.sql; do
  docker compose exec -T postgres psql -XAtq -U postgres -d "$DB" \
    -v ON_ERROR_STOP=1 -f - < "showcase/order-review/$script"
done
docker compose exec -T postgres psql -XAt -U postgres -d "$DB" -c \
  "SELECT order_id, amount, risk_level, customer_account_status FROM app.orders ORDER BY order_id"
```

```text
1001|1500.00|HIGH|OPEN
1002|750.00|HIGH|OPEN
1003|1200.00|LOW|OPEN
1004|2000.00|HIGH|SUSPENDED
```

The four rows already have jobs. Order `1001` is the initial match, `1002` is the policy-change subject, `1003` will travel through the lifecycle, and `1004` proves that high risk alone does not defeat applicability. No generic event table appears because pg-react already owns lifecycle history.

## 4. Define current risky-order truth

Run the core declaration script and keep its concise output. `rule_def.risky_orders` is an ordinary view with `order_id` as its one bigint semantic key. It requires pending status, open customer status, high risk, and at least `1000.00`; `reason_code` becomes `PRIOR_CHARGEBACK` when the customer has prior chargebacks and `HIGH_RISK_VALUE` otherwise. The neighboring v2 view changes only the amount threshold to `500.00`, which gives comparison a clean and understandable proposal later.

```bash
docker compose exec -T -e 'PGOPTIONS=-c client_min_messages=error' postgres \
  psql -XAtq -U postgres -d "$DB" -v ON_ERROR_STOP=1 -f - \
  < showcase/order-review/03-core-rules.sql | tee /tmp/order-review-core.txt
```

```text
{"step": "validate constraint", "state": "ready", "findings": 0}
{"step": "preview constraint", "deployment": "create", "current_state": null}
{"step": "deploy constraint", "state": "deployed"}
```

The script constructs declarations by stable name, validates them, previews the create, and supplies the preview digest to deployment. It never authors with generated UUIDs. The exact constructor fields and typed function signatures are in [Authoring Rules and Policies](v1-authoring.md).

## 5. Deploy and inspect a constraint rule

`order-review-required` is a `CONSTRAINT` rule, so it records current truth and has no consequences. Its default `SEED_CURRENT` bootstrap policy recognizes order `1001` without inventing activation work for facts that existed before deployment. Status and explanation use the stable name, and the subject-specific explanation accepts the bigint key as JSON.

```bash
docker compose exec -T postgres psql -XAtq -U postgres -d "$DB" -c \
  "SELECT name, semantic_key, active, generation, revision FROM pgreact.matches WHERE name='order-review-required' ORDER BY semantic_key" \
  -c "SELECT pgreact.status('order-review-required')->>'state'" \
  -c "SELECT pgreact.explain('order-review-required','1001'::jsonb)#>>'{evidence,runtime_state}'"
```

```text
order-review-required|1001|t|1|0
deployed
AUTHORITATIVE
```

This rule answers only whether review is currently required. It does not synchronously reject the source write, approve release, or claim that the order is fraudulent. Those decisions still belong to the application and its operators.

## 6. Add durable review work

The same core script deploys `order-review-work` as a separate `COMMAND` rule because a constraint cannot receive consequences. Its typed activation function opens one row per `(order_id, generation)`, its change function updates that row, and its deactivation function closes it. Every path stores the pg-react idempotency key, and the command allows two attempts with a one-second initial backoff. Bootstrap still creates no task or work, which is the quiet and correct answer for preexisting order `1001`.

```bash
docker compose exec -T postgres psql -XAtq -U postgres -d "$DB" \
  -c "SELECT kind, name, state, claimable FROM pgreact.work WHERE name='order-review-work' ORDER BY work_id" \
  -c "SELECT count(*) FROM app.review_tasks"
docker compose exec -T -e 'PGOPTIONS=-c client_min_messages=error' postgres \
  psql -XAtq -U postgres -d "$DB" -v ON_ERROR_STOP=1 -f - \
  < showcase/order-review/04-decisions-and-policy-set.sql \
  | tee /tmp/order-review-routing.txt
```

```text
0
```

The second command also deploys the routing decision and previews the policy set because the next script exercises all three together. The command consequence is database-local. A future outbox or remote consumer would be an at-least-once delivery path and would need its own idempotent consumer; this example does not smuggle that second reliability story into the first one.

## 7. Change facts and follow the lifecycle

Now run the scenario and save its compact JSON transcript. Order `1003` enters the condition, changes amount, changes reason when customer `503` gains a chargeback, leaves the condition, and enters again as generation 2. Fixed calls to `pgreact.run()` advance relational truth. Managed cycles execute the resulting PostgreSQL work. The retry path waits for its configured one-second wall-clock backoff, then drains with a bounded 100-cycle loop.

```bash
docker compose exec -T -e 'PGOPTIONS=-c client_min_messages=error' postgres \
  psql -XAtq -U postgres -d "$DB" -v ON_ERROR_STOP=1 -f - \
  < showcase/order-review/05-scenarios.sql \
  | tee /tmp/order-review-scenarios.txt
grep -E 'activate order|change order|supporting customer|deactivate order' \
  /tmp/order-review-scenarios.txt
```

```text
{"step":"activate order 1003",..."generation":1,..."event_kind":"ACTIVATE"}
{"step":"change order amount",..."revision":1,..."event_kind":"CHANGE"}
{"step":"change supporting customer fact",..."reason_code":"PRIOR_CHARGEBACK","last_revision":2}
{"step":"deactivate order 1003",..."state":"CLOSED",..."event_kind":"DEACTIVATE"}
```

Generation identifies an activation episode; revision counts watched changes inside that episode. The amount and customer fact update the same generation 1 task, deactivation closes it, and reactivation creates generation 2 instead of reopening history under a new name.

The lifecycle in one view:

| Time | Source change | Match state | Generation | Revision | Work result |
|---|---|---|---:|---:|---|
| 12:11 | `risk_level = HIGH` | Activates | 1 | 0 | Task opens |
| 12:12 | Amount changes | Remains active | 1 | 1 | Task updates |
| 12:13 | Customer chargeback changes | Remains active | 1 | 2 | Task updates |
| 12:14 | `risk_level = LOW` | Deactivates | 1 | 2 | Task closes |
| 12:15 | `risk_level = HIGH` | Activates again | 2 | 0 | Retryable task opens |

## 8. Route reviews with a decision

The decision reads candidate rows, chooses the lowest numeric priority, and refuses to break equal best priorities behind your back. Order `1001` has a clear winner, `1002` is ambiguous, and deleting order `1003`'s only candidate leaves a retained `NO_CANDIDATE` state. An unseen order with no candidate is `never_observed` and receives no row at all.

```bash
grep -E 'routing matrix|routing after candidate removal' \
  /tmp/order-review-routing.txt /tmp/order-review-scenarios.txt
```

```text
order 1001: WINNER, reviewer 201, chargeback-review
order 1002: AMBIGUOUS
order 1003: NO_CANDIDATE
```

Ambiguity is application work, not a secret tiebreaker. A caller may ask for another candidate, send the order to an explicit fallback, or stop release, but the database result remains `AMBIGUOUS` until the candidate facts change.

## 9. Limit the policy with applicability

`rule_def.reviewable_orders` includes pending orders whose copied customer account status is open. The final policy set contains the command rule and routing decision, uses version `1`, and caps evidence at 100 rows. Deploying it makes eligibility visible as a separate public projection, while the independent constraint continues to say which eligible orders currently satisfy the risk threshold.

```bash
grep 'policy applicability' /tmp/order-review-scenarios.txt
```

```json
{"step":"policy applicability","eligible":[1001,1002,1003],"current_constraint_matches":[1001,1003]}
```

Order `1002` is the useful odd one out: it belongs to the policy but does not satisfy v1. Membership, applicability, and current match state answer different questions, and combining them into one boolean would make policy review much harder to reason about.

## 10. Compare a lower threshold without executing it

Before policy-set deployment changes command scope, the scenario compares `rule_def.risky_orders_v2` with deployed `order-review-work`. Proposal and target share the same stable name and kind. The complete envelope reports exact counts and equal authoritative checksums, while `compare_results()` provides relational delta and would-be-work rows. Order `1002` is the single addition, and the comparison creates no task, work item, attempt, or deployment.

```bash
grep -E 'compare lower threshold|comparison has no effects' \
  /tmp/order-review-scenarios.txt
```

```text
added_orders=[1002], current_count=2, proposed_count=3, complete=true
work_unchanged=true, attempts_unchanged=true, proposed_task_count=0
```

Every `compare_results()` call performs a fresh comparison rather than reading the prior JSON envelope. Evidence is bounded at 100 and complete in this four-order fixture. This is current-state proposal review, not historical replay and not a way to mutate source facts hypothetically. Use [Changing Policies Safely](changing-policies.md) to review proposals, then follow the qualified `pgreact.replace_rule()` cutover in [Operations](v1-operations.md) if a deployed stable rule must actually change.

## 11. Recover a failed consequence

The failure control flips before generation 2 activates, so the first attempt raises SQLSTATE `P6001` and leaves work in `RETRY_WAIT`. Clearing the flag lets attempt 2 complete. The application table ends with one row for generation 2, not two, because `(order_id, generation)` and the pg-react idempotency key make repeated application safe.

```bash
grep -E 'first reactivation attempt|successful retry' \
  /tmp/order-review-scenarios.txt
docker compose exec -T postgres psql -XAt -U postgres -d "$DB" -c \
  "SELECT order_id, generation, state, reason_code, amount FROM app.review_tasks ORDER BY order_id, generation" \
  -c "SELECT attempt_no, status, error_code, event_kind FROM pgreact.attempts WHERE name='order-review-work' ORDER BY execution_id"
```

```text
1003|1|CLOSED|PRIOR_CHARGEBACK|1350.00
1003|2|OPEN|PRIOR_CHARGEBACK|1350.00
...
1|RETRY_WAIT|P6001|ACTIVATE
2|COMPLETED||ACTIVATE
```

The error remains durable and visible after success, which is exactly what an operator needs. Retrying does not erase the first attempt or rewrite it as a happy ending.

## 12. Remove the core example objects

Cleanup removes the policy set first, removes the decision, cancels pending policy-migration episodes with the public `pgreact.cancel_episode()` call, pauses and removes both rules, then drops the disposable schemas. The policy name may remain in immutable history, but no declaration remains deployed and no source object survives.

```bash
docker compose exec -T postgres psql -XAtq -U postgres -d "$DB" \
  -v ON_ERROR_STOP=1 -f - < showcase/order-review/99-cleanup.sql
docker compose down --volumes --remove-orphans
```

```text
All order-review declarations are removed; app, rule_def, and rule_action are absent.
```

## 13. Optional: add deadline escalation

The advanced script currently reports deadline escalation as omitted. The repository has specialized deadline machinery, but this package does not publish a call until that exact public API, its direct deadline-column contract, boundary behavior, resource limit, and transcript all pass against `1.0.0-rc.1`. A deadline is database-time crossing work, not a general wall-clock scheduler, and it deserves a real fixture rather than hopeful prose.

```bash
docker compose up -d --wait --no-build
docker compose exec -T postgres psql -XAtq -U postgres -d postgres \
  -v ON_ERROR_STOP=1 -f - < showcase/order-review/06-advanced.sql
```

```json
{"step":"advanced chapters","state":"omitted","chapters":["deadline escalation","derived facts and provenance","effective-dated policy versions"],"reason":"no specialized API call is qualified by this fixture"}
```

## 14. Optional: explain a derived customer fact

Derived facts and bounded provenance are omitted for the same reason. A later chapter should prove at least two independent supports, show that one surviving support keeps the fact true, retract the fact only after the last support disappears, and identify the surviving or removed support in public explanation output. Until that script exists, `customer_requires_enhanced_review` is a good design note and a bad tutorial promise.

```bash
grep -n 'derived facts and provenance' showcase/order-review/06-advanced.sql
```

```text
The chapter is listed in the explicit omission report.
```

## 15. Read the limits and choose the next guide

The example proves one bigint semantic key, relational current truth, typed database-local consequences, activation and change lifecycle, retries, decision winner states, applicability, bounded explanation, side-effect-free comparison, and cleanup. It does not prove synchronous source-write rejection, machine-learning classification, exactly-once remote delivery, a total firing order across workers, human case management, historical replay, effective-dated business policy, or advanced provenance.

Run the acceptance test once more after experimenting, then continue with [Authoring Rules and Policies](v1-authoring.md), [Changing Policies Safely](changing-policies.md), or [Operations](v1-operations.md), depending on whether the next job is writing, reviewing, or running a policy. The pleasant part is that all three guides begin from the same stable names and public projections used here.

```bash
./tests/order-review-showcase.sh
```

```text
order-review showcase passed
```