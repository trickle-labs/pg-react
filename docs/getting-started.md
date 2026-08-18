# Getting Started

This walkthrough creates one command rule, lets the PostgreSQL-managed runtime
process a source change, and inspects the result. It assumes the qualified
`0.31.0` environment from [Installation](v1-installation.md): PostgreSQL 18.3,
pg_trickle 0.81.0, Linux `amd64`, both libraries preloaded, the database listed
in `pg_react.databases`, roles configured, and PostgreSQL restarted.

The example uses only public SQL and stable names.

## 1. Verify the environment

```sql
SELECT extname, extversion
FROM pg_extension
WHERE extname IN ('pg_react', 'pg_trickle')
ORDER BY extname;

SELECT pgreact.doctor();

SELECT pgreact_api.managed_status();
```

Expect pg-react `0.31.0`, pg_trickle `0.81.0`, a doctor state of `ready`, and a
managed process state of `ready`. If not, stop here and use
[Installation](v1-installation.md) and [Troubleshooting](v1-troubleshooting.md).

## 2. Create authoritative application facts

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

Order 42 does not yet meet the rule.

## 3. Describe the condition

```sql
CREATE VIEW rule_def.high_value_risky_order AS
SELECT order_id, customer_id, amount
FROM app.orders
WHERE risk_level = 'HIGH'
  AND amount > 10000;
```

The view is the current relational truth. `order_id` is the semantic key: one
stable identity for each match.

## 4. Create a typed consequence

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

Activation and deactivation consequences receive
`(pgreact.activation_context, condition_row)`. A change consequence receives
the context, old row, and new row. Database consequences may be retried, so
make them idempotent.

## 5. Construct and validate the declaration

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

`pgreact.rule()` defaults to `CONSTRAINT`; consequences require
`kind => 'COMMAND'`. `pgreact.validate()` returns `jsonb` and does not deploy.

## 6. Preview and deploy

Preview the exact declaration:

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

Deploy using the preview digest:

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
),
preview AS (
    SELECT value, pgreact.preview(value) AS result
    FROM declaration
)
SELECT pgreact.deploy(
    value,
    jsonb_build_object(
        'preview_digest', result #>> '{summary,preview_digest}'
    )
)
FROM preview;
```

The operation returns `jsonb` with state `deployed`. Existing matching rows
are seeded according to the declaration's bootstrap policy; this example
changes the source only after deployment.

## 7. Let the managed runtime process a change

```sql
UPDATE app.orders
SET amount = 12000.00
WHERE order_id = 42;

SELECT pg_sleep(2);
```

With the supported default `pg_react.poll_interval_ms = 1000`, the
per-database managed worker calls the managed cycle, coordinates the current
source frontier, creates eligible work, claims it, and executes the typed
consequence. If your configured poll interval is longer, wait at least that
long. Do not enable uncoordinated pg_trickle automatic refresh.

## 8. Inspect current state and work

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

SELECT *
FROM app.manual_review_tasks
ORDER BY order_id;
```

The expected application row is order 42 with amount `12000.00`; the public
views show an active match, completed work, and a completed attempt.

## 9. Explain the rule

```sql
SELECT pgreact.explain('manual-review-required');
```

`pgreact.explain()` returns `jsonb`. It uses the stable public name; no internal
UUID or private catalog lookup is required.

## Next steps

- Add change and deactivation behavior in
  [Authoring Rules and Policies](v1-authoring.md).
- Compare a replacement before deployment in
  [Changing Policies Safely](changing-policies.md).
- Learn health, retry, recovery, and backlog procedures in
  [Operations](v1-operations.md).
- Review roles and external-effect requirements in
  [Security](v1-security.md) and [Known Limitations](v1-known-limitations.md).

External delivery is at least once. Keep network delivery outside typed
database consequences and deduplicate by a stable idempotency key.
