\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';

-- Clean any previous leftover state
DROP VIEW IF EXISTS rule_def.high_value_risky_order CASCADE;
DROP TABLE IF EXISTS app.manual_review_tasks CASCADE;
DROP TABLE IF EXISTS app.orders CASCADE;
DROP SCHEMA IF EXISTS rule_action CASCADE;
DROP SCHEMA IF EXISTS rule_def CASCADE;
DROP SCHEMA IF EXISTS app CASCADE;

-- 1. Verify the environment
SELECT extname, extversion
FROM pg_extension
WHERE extname IN ('pg_react', 'pg_trickle')
ORDER BY extname;

SELECT pgreact.doctor();
SELECT pgreact_api.managed_status();

-- Verify doctor state is ready
DO $$
DECLARE
    doc jsonb;
BEGIN
    doc := pgreact.doctor();
    IF doc ->> 'state' <> 'ready' THEN
        RAISE EXCEPTION 'Getting Started doctor check failed: %', doc;
    END IF;
END $$;

-- 2. Create authoritative application facts
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

-- 3. Describe the condition
CREATE VIEW rule_def.high_value_risky_order AS
SELECT order_id, customer_id, amount
FROM app.orders
WHERE risk_level = 'HIGH'
  AND amount > 10000;

-- 4. Create a typed consequence
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

-- 5. Construct and validate the declaration
SELECT pgreact.validate(pgreact.rule(
    name         => 'manual-review-required',
    condition    => 'rule_def.high_value_risky_order'::regclass,
    semantic_key => 'order_id'::name,
    kind         => 'COMMAND',
    on_activate  =>
      'rule_action.open_review(pgreact.activation_context,rule_def.high_value_risky_order)'::regprocedure
));

-- 6. Preview and deploy
SELECT pgreact.preview(pgreact.rule(
    name         => 'manual-review-required',
    condition    => 'rule_def.high_value_risky_order'::regclass,
    semantic_key => 'order_id'::name,
    kind         => 'COMMAND',
    on_activate  =>
      'rule_action.open_review(pgreact.activation_context,rule_def.high_value_risky_order)'::regprocedure
));

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

-- 7. Let the managed runtime process a change
UPDATE app.orders
SET amount = 12000.00
WHERE order_id = 42;

-- Allow managed worker to poll or execute managed cycle
SELECT pg_sleep(2);
SELECT pgreact_api.managed_cycle();

-- 8. Inspect current state and work
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

-- Assertions on results
DO $$
DECLARE
    match_count integer;
    task_amount numeric(12,2);
BEGIN
    SELECT count(*) INTO match_count
    FROM pgreact.matches
    WHERE name = 'manual-review-required' AND active AND semantic_key = '42';
    IF match_count <> 1 THEN
        RAISE EXCEPTION 'Getting Started match count mismatch: %', match_count;
    END IF;

    SELECT amount INTO task_amount
    FROM app.manual_review_tasks
    WHERE order_id = 42;
    IF task_amount <> 12000.00 THEN
        RAISE EXCEPTION 'Getting Started manual review task amount mismatch: %', task_amount;
    END IF;
END $$;

-- 9. Explain the rule
SELECT pgreact.explain('manual-review-required');

-- Cleanup Getting Started fixture
SELECT pgreact.pause_rule('manual-review-required');
SELECT pgreact.remove('manual-review-required');
DROP VIEW IF EXISTS rule_def.high_value_risky_order CASCADE;
DROP TABLE IF EXISTS app.manual_review_tasks CASCADE;
DROP TABLE IF EXISTS app.orders CASCADE;
DROP SCHEMA IF EXISTS rule_action CASCADE;
DROP SCHEMA IF EXISTS rule_def CASCADE;
DROP SCHEMA IF EXISTS app CASCADE;
