# Your first rule

[Tutorials](tutorials/index.md) · [Documentation home](index.md)

In this lesson, you will turn a changing order into a durable review task. The order begins below your review threshold, you deploy a rule, and then you raise its amount. By the end, you will be able to point to the source row, the active match, the work item, the execution attempt, and the task written by the consequence. Those are the building blocks you will use again in larger policies.

You need Git, Docker with Compose, and basic SQL. Everything runs in a disposable local container, so no existing PostgreSQL installation is required. This lesson uses the qualified **pg-react 0.46.0**, **PostgreSQL 18.3**, and **pg_trickle 0.108.0** environment on **Linux amd64**. On another host architecture, Docker must support running the pinned amd64 image. If you already prepared the environment from the README, skip to step 2.

## 1. Start a learning database

Run these commands in your shell. Keep the same shell open so the Compose project and image settings remain available for later commands.

```bash
git clone https://github.com/trickle-labs/pg-react.git
cd pg-react
export COMPOSE_PROJECT_NAME=pgreact-learning
export PG_REACT_IMAGE=ghcr.io/trickle-labs/pg-react:v0.46.0
export PG_REACT_INIT_VERSION=0.46.0
docker compose pull postgres
docker compose up -d --wait --no-build postgres
for attempt in $(seq 1 60); do
    docker compose exec -T postgres pg_isready -h 127.0.0.1 -U postgres -d postgres >/dev/null 2>&1 && break
    sleep 1
done
docker compose exec -T postgres pg_isready -h 127.0.0.1 -U postgres -d postgres && \
    docker compose exec postgres psql -X -U postgres -d postgres
```

The readiness loop waits up to a minute for the final server's TCP listener, avoiding the temporary socket-only server used during initialization. Continue only after it reports accepting connections; if it does not, inspect `docker compose logs postgres`. The last command then opens `psql` inside the container. The Compose initializer has installed both extensions, and the `postgres` database is configured for the managed worker. The service binds to a random loopback port, so using `docker compose exec` avoids guessing a host port. This is a local learning setup using the `postgres` superuser; the [installation](installation.md) and [security](security.md) guides describe the roles to use for a shared deployment.

## 2. Verify your starting point

Run the following at the `psql` prompt. The first line makes `psql` stop processing a script when a SQL statement fails, which makes mistakes easier to locate as you work through the lesson.

```sql
\set ON_ERROR_STOP on

SELECT extname, extversion
FROM pg_extension
WHERE extname IN ('pg_react', 'pg_trickle')
ORDER BY extname;

SELECT pgreact.doctor();
SELECT pgreact_api.managed_status();
```

The extension rows should be `pg_react | 0.46.0` and `pg_trickle | 0.108.0`. The doctor should report `ready`, and after the first poll the managed process should also report `ready`. If the versions differ, check [release identity](reference/release-identity.md); changing the initializer environment variable does not upgrade a database that already exists in a Compose volume. For a missing or unhealthy worker, use [Troubleshooting](troubleshooting.md) before continuing.

## 3. Create the application facts

Create three schemas to keep the application data, condition views, and consequence functions easy to recognize. The order table is authoritative application data. The task table is an ordinary application table too: pg-react will call a function that writes it, but your application remains free to query and use it.

```sql
CREATE SCHEMA app;
CREATE SCHEMA rule_def;
CREATE SCHEMA rule_action;

CREATE TABLE app.orders (
    order_id bigint PRIMARY KEY,
    customer_id bigint NOT NULL,
    amount numeric(12,2) NOT NULL,
    risk_level text NOT NULL
);

CREATE TABLE app.manual_review_tasks (
    order_id bigint PRIMARY KEY,
    customer_id bigint NOT NULL,
    amount numeric(12,2) NOT NULL,
    activation_id uuid NOT NULL,
    idempotency_key text NOT NULL UNIQUE
);

INSERT INTO app.orders
    (order_id, customer_id, amount, risk_level)
VALUES
    (42, 7, 9000.00, 'HIGH');
```

Order 42 is high risk, but its amount is still below the threshold we will choose. Starting with a nonmatching row lets you see an activation happen after deployment, rather than introducing bootstrap behavior at the same time.

## 4. Describe the condition

A condition is a relation whose rows mean that something is currently true. Here, a row means that an order is high risk and its amount is greater than 10,000. The `order_id` is the semantic key: pg-react uses it to recognize the same order as its projected values change.

```sql
CREATE VIEW rule_def.high_value_risky_order AS
SELECT order_id, customer_id, amount
FROM app.orders
WHERE risk_level = 'HIGH'
  AND amount > 10000;

SELECT * FROM rule_def.high_value_risky_order;
```

The query returns no rows. Keep that observation in mind: the view is the condition itself, so checking it directly is often the quickest way to understand whether your rule should have a match.

## 5. Give an activation something to do

Create a typed consequence that receives the activation context and the matching condition row. It inserts or updates one review task for the order. The upsert makes a repeated call safe for this small example, while the stored idempotency key lets you associate the application result with the work that produced it.

```sql
CREATE FUNCTION rule_action.open_review(
    context pgreact.activation_context,
    match rule_def.high_value_risky_order
)
RETURNS void
LANGUAGE SQL
BEGIN ATOMIC
    INSERT INTO app.manual_review_tasks (
        order_id, customer_id, amount, activation_id, idempotency_key
    )
    VALUES (
        (match).order_id,
        (match).customer_id,
        (match).amount,
        (context).activation_id,
        (context).idempotency_key
    )
    ON CONFLICT (order_id) DO UPDATE
    SET customer_id = EXCLUDED.customer_id,
        amount = EXCLUDED.amount,
        activation_id = EXCLUDED.activation_id,
        idempotency_key = EXCLUDED.idempotency_key;
END;
```

The consequence is database-local: it writes a table in the same PostgreSQL transaction as its execution bookkeeping. Later, you can use an outbox for external delivery, but that introduces a separate at-least-once delivery boundary. For now, keeping the entire effect in PostgreSQL makes the result easy to inspect.

## 6. Validate, preview, and deploy the rule

Build a `COMMAND` declaration because this rule has a consequence. A declaration is a typed SQL value; constructing or validating it does not install a running rule. The default rule kind is `CONSTRAINT`, which records matches without executable consequences.

```sql
SELECT pgreact.validate(pgreact.rule(
    name         => 'manual-review-required',
    condition    => 'rule_def.high_value_risky_order'::regclass,
    semantic_key => 'order_id'::name,
    kind         => 'COMMAND',
    on_activate  =>
      'rule_action.open_review(pgreact.activation_context,rule_def.high_value_risky_order)'::regprocedure
));
```

Expect a validation state of `ready`. If it is `attention`, read the findings and resolve the reported error before continuing. Next, preview the same declaration so you can inspect the proposed operation without applying it:

```sql
SELECT pgreact.preview(pgreact.rule(
    name         => 'manual-review-required',
    condition    => 'rule_def.high_value_risky_order'::regclass,
    semantic_key => 'order_id'::name,
    kind         => 'COMMAND',
    on_activate  =>
      'rule_action.open_review(pgreact.activation_context,rule_def.high_value_risky_order)'::regprocedure
));
```

When the preview has no blocking findings, deploy the same definition with a review token. This compact teaching example takes a fresh preview and passes its token directly to deployment in one statement. In a reviewed deployment process, retain the preview you actually inspected and pass its token; if the token becomes stale, preview and review again. Tokens bind the reviewed plan to the declaration and current state; they do not grant permission.

```sql
WITH declaration AS (
    SELECT pgreact.rule(
        name         => 'manual-review-required',
        condition    => 'rule_def.high_value_risky_order'::regclass,
        semantic_key => 'order_id'::name,
        kind         => 'COMMAND',
        on_activate  =>
          'rule_action.open_review(pgreact.activation_context,rule_def.high_value_risky_order)'::regprocedure
    ) AS value
), preview AS (
    SELECT value, pgreact.preview(value) AS result
    FROM declaration
)
SELECT pgreact.deploy(value, pgreact.review_token(result))
FROM preview;
```

Look for a result with state `deployed`. The default bootstrap policy seeds existing matches as current state; it does not treat them as fresh activation work. Our order does not match yet, so the task table should still be empty.

## 7. Change the order and observe the task

Raise order 42 above the threshold, then request a coordination cycle. Use `psql`'s normal autocommit behavior for this lesson; do not wrap all its steps in a long transaction, because the background worker needs to see committed changes.

```sql
UPDATE app.orders
SET amount = 12000.00
WHERE order_id = 42;

SELECT pgreact.run();

SELECT order_id, customer_id, amount
FROM app.manual_review_tasks
ORDER BY order_id;
```

The managed worker coordinates and executes durable work asynchronously. `pgreact.run()` advances coordination and can create work, but it is not a wait-until-all-consequences-finish operation. If the final query initially returns no rows, repeat it after the next worker poll. Once the consequence completes, the result is:

```text
 order_id | customer_id |  amount
----------+-------------+----------
       42 |           7 | 12000.00
```

You have now turned a change in application data into a durable application task. If the row does not appear, inspect the work and attempts in the next step; their state will tell you whether the issue is evaluation, execution, or worker configuration.

## 8. Follow the evidence

Ask each public view a different question. `matches` tells you whether the order satisfies the rule, `work` tells you what execution is recorded, and `attempts` tells you what happened when a worker tried it. Seeing those separately is useful: an active match can be perfectly correct even while its consequence is waiting or has failed.

```sql
SELECT name, semantic_key, active, generation, revision, bindings
FROM pgreact.matches
WHERE name = 'manual-review-required'
ORDER BY semantic_key;

SELECT kind, name, version, work_id, state, claimable, updated_at
FROM pgreact.work
WHERE name = 'manual-review-required'
ORDER BY work_id;

SELECT name, attempt_no, status, error_code, error_message
FROM pgreact.attempts
WHERE name = 'manual-review-required'
ORDER BY execution_id;

SELECT pgreact.explain('manual-review-required');
```

After successful execution, order 42 has an active match in generation `1`, revision `0`, a `COMPLETED` work item, and a `COMPLETED` attempt. The generated identifiers and timestamps will differ between runs. The explanation uses the stable rule name, so you do not need to discover private catalog identifiers to ask what happened.

## 9. Finish or keep exploring

This rule attaches only an activation consequence. It does not yet revise or close the task when the order changes or leaves the condition. The next lesson, [Review marketplace orders](order-review-tutorial.md), adds those behaviors and introduces routing, applicability, retries, and comparison. If you would rather adapt the rule immediately, use [Authoring rules and policies](authoring.md).

When you are finished with this disposable environment, leave `psql` and remove the learning project's container and data volume. These commands delete the data created in this lesson; run them from the same shell and checkout, with the same Compose project name.

```text
\q
```

```bash
docker compose down --volumes
```

For a shared database, remove deployed objects through the public API and use your normal data lifecycle procedure instead of deleting a volume. The [operations guide](operations.md) explains how to inspect work before changing or removing a deployment.
