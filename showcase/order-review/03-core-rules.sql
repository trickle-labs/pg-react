\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';

-- This view answers the constraint question: which pending, open, high-risk
-- orders are at least $1,000? The order_id is the semantic key.
CREATE VIEW rule_def.risky_orders AS
SELECT orders.order_id,
       orders.customer_id,
       orders.merchant_id,
       orders.amount,
       orders.risk_level,
       CASE
                     WHEN orders.customer_chargeback_count > 0 THEN 'PRIOR_CHARGEBACK'
           ELSE 'HIGH_RISK_VALUE'
       END::text AS reason_code,
       orders.review_deadline
FROM app.orders AS orders
WHERE orders.status = 'PENDING'
    AND orders.customer_account_status = 'OPEN'
  AND orders.risk_level = 'HIGH'
  AND orders.amount >= 1000.00;

CREATE VIEW rule_def.risky_orders_v2 AS
SELECT orders.order_id,
       orders.customer_id,
       orders.merchant_id,
       orders.amount,
       orders.risk_level,
       CASE
                     WHEN orders.customer_chargeback_count > 0 THEN 'PRIOR_CHARGEBACK'
           ELSE 'HIGH_RISK_VALUE'
       END::text AS reason_code,
       orders.review_deadline
FROM app.orders AS orders
WHERE orders.status = 'PENDING'
    AND orders.customer_account_status = 'OPEN'
  AND orders.risk_level = 'HIGH'
  AND orders.amount >= 500.00;

-- Consequences are ordinary PostgreSQL functions. pg-react supplies the
-- activation context and the typed row that matched the condition.
CREATE FUNCTION rule_action.open_review(
    context pgreact.activation_context,
    match rule_def.risky_orders
) RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM app.failure_controls
        WHERE order_id = (match).order_id
          AND fail_review_task
    ) THEN
        RAISE EXCEPTION 'injected review-task failure for order %', (match).order_id
            USING ERRCODE = 'P6001';
    END IF;

    INSERT INTO app.review_tasks (
        order_id, generation, state, reason_code, amount, activation_id,
        last_revision, last_idempotency_key
    ) VALUES (
        (match).order_id, (context).generation, 'OPEN', (match).reason_code,
        (match).amount, (context).activation_id, (context).revision,
        (context).idempotency_key
    )
    ON CONFLICT (order_id, generation) DO UPDATE
    SET state = 'OPEN',
        reason_code = EXCLUDED.reason_code,
        amount = EXCLUDED.amount,
        activation_id = EXCLUDED.activation_id,
        last_revision = EXCLUDED.last_revision,
        last_idempotency_key = EXCLUDED.last_idempotency_key;
END;
$$;

CREATE FUNCTION rule_action.update_review(
    context pgreact.activation_context,
    old_match rule_def.risky_orders,
    new_match rule_def.risky_orders
) RETURNS void
LANGUAGE SQL
BEGIN ATOMIC
    UPDATE app.review_tasks
    SET state = 'OPEN',
        reason_code = (new_match).reason_code,
        amount = (new_match).amount,
        last_revision = (context).revision,
        last_idempotency_key = (context).idempotency_key
    WHERE order_id = (new_match).order_id
      AND generation = (context).generation;
END;

CREATE FUNCTION rule_action.close_review(
    context pgreact.activation_context,
    match rule_def.risky_orders
) RETURNS void
LANGUAGE SQL
BEGIN ATOMIC
    UPDATE app.review_tasks
    SET state = 'CLOSED',
        last_revision = (context).revision,
        last_idempotency_key = (context).idempotency_key
    WHERE order_id = (match).order_id
      AND generation = (context).generation;
END;

CREATE FUNCTION rule_action.open_review_v2(
    context pgreact.activation_context,
    match rule_def.risky_orders_v2
) RETURNS void
LANGUAGE SQL
BEGIN ATOMIC
    INSERT INTO app.review_tasks (
        order_id, generation, state, reason_code, amount, activation_id,
        last_revision, last_idempotency_key
    ) VALUES (
        (match).order_id, (context).generation, 'OPEN', (match).reason_code,
        (match).amount, (context).activation_id, (context).revision,
        (context).idempotency_key
    )
    ON CONFLICT (order_id, generation) DO UPDATE
    SET state = 'OPEN',
        reason_code = EXCLUDED.reason_code,
        amount = EXCLUDED.amount,
        activation_id = EXCLUDED.activation_id,
        last_revision = EXCLUDED.last_revision,
        last_idempotency_key = EXCLUDED.last_idempotency_key;
END;

CREATE FUNCTION rule_action.update_review_v2(
    context pgreact.activation_context,
    old_match rule_def.risky_orders_v2,
    new_match rule_def.risky_orders_v2
) RETURNS void
LANGUAGE SQL
BEGIN ATOMIC
    UPDATE app.review_tasks
    SET state = 'OPEN',
        reason_code = (new_match).reason_code,
        amount = (new_match).amount,
        last_revision = (context).revision,
        last_idempotency_key = (context).idempotency_key
    WHERE order_id = (new_match).order_id
      AND generation = (context).generation;
END;

CREATE FUNCTION rule_action.close_review_v2(
    context pgreact.activation_context,
    match rule_def.risky_orders_v2
) RETURNS void
LANGUAGE SQL
BEGIN ATOMIC
    UPDATE app.review_tasks
    SET state = 'CLOSED',
        last_revision = (context).revision,
        last_idempotency_key = (context).idempotency_key
    WHERE order_id = (match).order_id
      AND generation = (context).generation;
END;

WITH declaration AS (
    SELECT pgreact.rule(
        name         => 'order-review-required',
        condition    => 'rule_def.risky_orders'::regclass,
        semantic_key => 'order_id'::name,
        kind         => 'CONSTRAINT'
    ) AS value
)
SELECT jsonb_build_object(
    'step', 'validate constraint',
    'state', result ->> 'state',
    'findings', jsonb_array_length(result -> 'findings')
)
FROM declaration
CROSS JOIN LATERAL pgreact.validate(value) AS result;

WITH declaration AS (
    SELECT pgreact.rule(
        name         => 'order-review-required',
        condition    => 'rule_def.risky_orders'::regclass,
        semantic_key => 'order_id'::name,
        kind         => 'CONSTRAINT'
    ) AS value
), preview AS (
    SELECT value, pgreact.preview(value) AS result
    FROM declaration
)
SELECT jsonb_build_object(
    'step', 'preview constraint',
    'deployment', result #>> '{summary,deployment}',
    'current_state', result #>> '{summary,current_state}'
)
FROM preview;

WITH declaration AS (
    SELECT pgreact.rule(
        name         => 'order-review-required',
        condition    => 'rule_def.risky_orders'::regclass,
        semantic_key => 'order_id'::name,
        kind         => 'CONSTRAINT'
    ) AS value
), preview AS (
    SELECT value, pgreact.preview(value) AS result
    FROM declaration
), deployment AS (
    SELECT pgreact.deploy(
        value,
        pgreact.review_token(result)
    ) AS result
    FROM preview
)
SELECT jsonb_build_object('step', 'deploy constraint', 'state', result ->> 'state')
FROM deployment;

WITH declaration AS (
    SELECT pgreact.rule(
        name                    => 'order-review-work',
        condition               => 'rule_def.risky_orders'::regclass,
        semantic_key            => 'order_id'::name,
        kind                    => 'COMMAND',
        on_activate             => 'rule_action.open_review(pgreact.activation_context,rule_def.risky_orders)'::regprocedure,
        on_deactivate           => 'rule_action.close_review(pgreact.activation_context,rule_def.risky_orders)'::regprocedure,
        on_change               => 'rule_action.update_review(pgreact.activation_context,rule_def.risky_orders,rule_def.risky_orders)'::regprocedure,
        max_attempts            => 2,
        initial_backoff_seconds => 1
    ) AS value
)
SELECT jsonb_build_object(
    'step', 'validate command',
    'state', result ->> 'state',
    'findings', jsonb_array_length(result -> 'findings')
)
FROM declaration
CROSS JOIN LATERAL pgreact.validate(value) AS result;

WITH declaration AS (
    SELECT pgreact.rule(
        name                    => 'order-review-work',
        condition               => 'rule_def.risky_orders'::regclass,
        semantic_key            => 'order_id'::name,
        kind                    => 'COMMAND',
        on_activate             => 'rule_action.open_review(pgreact.activation_context,rule_def.risky_orders)'::regprocedure,
        on_deactivate           => 'rule_action.close_review(pgreact.activation_context,rule_def.risky_orders)'::regprocedure,
        on_change               => 'rule_action.update_review(pgreact.activation_context,rule_def.risky_orders,rule_def.risky_orders)'::regprocedure,
        max_attempts            => 2,
        initial_backoff_seconds => 1
    ) AS value
), preview AS (
    SELECT value, pgreact.preview(value) AS result
    FROM declaration
)
SELECT jsonb_build_object(
    'step', 'preview command',
    'deployment', result #>> '{summary,deployment}',
    'current_state', result #>> '{summary,current_state}'
)
FROM preview;

WITH declaration AS (
    SELECT pgreact.rule(
        name                    => 'order-review-work',
        condition               => 'rule_def.risky_orders'::regclass,
        semantic_key            => 'order_id'::name,
        kind                    => 'COMMAND',
        on_activate             => 'rule_action.open_review(pgreact.activation_context,rule_def.risky_orders)'::regprocedure,
        on_deactivate           => 'rule_action.close_review(pgreact.activation_context,rule_def.risky_orders)'::regprocedure,
        on_change               => 'rule_action.update_review(pgreact.activation_context,rule_def.risky_orders,rule_def.risky_orders)'::regprocedure,
        max_attempts            => 2,
        initial_backoff_seconds => 1
    ) AS value
), preview AS (
    SELECT value, pgreact.preview(value) AS result
    FROM declaration
), deployment AS (
    SELECT pgreact.deploy(
        value,
        pgreact.review_token(result)
    ) AS result
    FROM preview
)
SELECT jsonb_build_object('step', 'deploy command', 'state', result ->> 'state')
FROM deployment;

SELECT jsonb_build_object(
    'step', 'bootstrap',
    'current_matches', count(*) FILTER (WHERE active),
    'work_items', (SELECT count(*) FROM pgreact.work WHERE name = 'order-review-work'),
    'review_tasks', (SELECT count(*) FROM app.review_tasks)
)
FROM pgreact.matches
WHERE name = 'order-review-work';
