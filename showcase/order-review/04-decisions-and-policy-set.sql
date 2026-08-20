\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';

CREATE VIEW rule_def.review_candidates AS
SELECT order_id, reviewer_id, priority, queue_name
FROM app.reviewer_candidates;

CREATE VIEW rule_def.reviewable_orders AS
SELECT orders.order_id
FROM app.orders AS orders
WHERE orders.status = 'PENDING'
    AND orders.customer_account_status = 'OPEN';

WITH declaration AS (
    SELECT pgreact.decision(
        name               => 'order-review-route',
        candidate_relation => 'rule_def.review_candidates'::regclass,
        subject_key        => 'order_id'::name,
        candidate_key      => 'reviewer_id'::name,
        priority           => 'priority'::name,
        results            => ARRAY['queue_name']::name[],
        valid_from         => '2026-08-20 12:00:00+00',
        max_candidates     => 1000
    ) AS value
)
SELECT jsonb_build_object(
    'step', 'validate decision',
    'state', result ->> 'state',
    'findings', jsonb_array_length(result -> 'findings')
)
FROM declaration
CROSS JOIN LATERAL pgreact.validate(value) AS result;

WITH declaration AS (
    SELECT pgreact.decision(
        name               => 'order-review-route',
        candidate_relation => 'rule_def.review_candidates'::regclass,
        subject_key        => 'order_id'::name,
        candidate_key      => 'reviewer_id'::name,
        priority           => 'priority'::name,
        results            => ARRAY['queue_name']::name[],
        valid_from         => '2026-08-20 12:00:00+00',
        max_candidates     => 1000
    ) AS value
), preview AS (
    SELECT value, pgreact.preview(value) AS result
    FROM declaration
)
SELECT jsonb_build_object(
    'step', 'preview decision',
    'deployment', result #>> '{summary,deployment}',
    'current_state', result #>> '{summary,current_state}'
)
FROM preview;

WITH declaration AS (
    SELECT pgreact.decision(
        name               => 'order-review-route',
        candidate_relation => 'rule_def.review_candidates'::regclass,
        subject_key        => 'order_id'::name,
        candidate_key      => 'reviewer_id'::name,
        priority           => 'priority'::name,
        results            => ARRAY['queue_name']::name[],
        valid_from         => '2026-08-20 12:00:00+00',
        max_candidates     => 1000
    ) AS value
), preview AS (
    SELECT value, pgreact.preview(value) AS result
    FROM declaration
), deployment AS (
    SELECT pgreact.deploy(
        value,
        jsonb_build_object('preview_digest', result #>> '{summary,preview_digest}')
    ) AS result
    FROM preview
)
SELECT jsonb_build_object('step', 'deploy decision', 'state', result ->> 'state')
FROM deployment;

WITH members AS (
    SELECT ARRAY[
        pgreact.rule(
            name                    => 'order-review-work',
            condition               => 'rule_def.risky_orders'::regclass,
            semantic_key            => 'order_id'::name,
            kind                    => 'COMMAND',
            on_activate             => 'rule_action.open_review(pgreact.activation_context,rule_def.risky_orders)'::regprocedure,
            on_deactivate           => 'rule_action.close_review(pgreact.activation_context,rule_def.risky_orders)'::regprocedure,
            on_change               => 'rule_action.update_review(pgreact.activation_context,rule_def.risky_orders,rule_def.risky_orders)'::regprocedure,
            max_attempts            => 2,
            initial_backoff_seconds => 1
        ),
        pgreact.decision(
            name               => 'order-review-route',
            candidate_relation => 'rule_def.review_candidates'::regclass,
            subject_key        => 'order_id'::name,
            candidate_key      => 'reviewer_id'::name,
            priority           => 'priority'::name,
            results            => ARRAY['queue_name']::name[],
            valid_from         => '2026-08-20 12:00:00+00',
            max_candidates     => 1000
        )
    ]::pgreact_api.declaration[] AS value
), declaration AS (
    SELECT pgreact.policy_set(
        name           => 'order-review-policy',
        version        => '1',
        members        => value,
        applicability  => 'rule_def.reviewable_orders'::regclass,
        subject_keys   => ARRAY['order_id']::name[],
        valid_from     => '2035-01-01 12:15:02+00',
        evidence_limit => 100
    ) AS value
    FROM members
)
SELECT jsonb_build_object(
    'step', 'validate policy set',
    'state', result ->> 'state',
    'findings', jsonb_array_length(result -> 'findings')
)
FROM declaration
CROSS JOIN LATERAL pgreact.validate(value) AS result;

WITH members AS (
    SELECT ARRAY[
        pgreact.rule(
            name                    => 'order-review-work',
            condition               => 'rule_def.risky_orders'::regclass,
            semantic_key            => 'order_id'::name,
            kind                    => 'COMMAND',
            on_activate             => 'rule_action.open_review(pgreact.activation_context,rule_def.risky_orders)'::regprocedure,
            on_deactivate           => 'rule_action.close_review(pgreact.activation_context,rule_def.risky_orders)'::regprocedure,
            on_change               => 'rule_action.update_review(pgreact.activation_context,rule_def.risky_orders,rule_def.risky_orders)'::regprocedure,
            max_attempts            => 2,
            initial_backoff_seconds => 1
        ),
        pgreact.decision(
            name               => 'order-review-route',
            candidate_relation => 'rule_def.review_candidates'::regclass,
            subject_key        => 'order_id'::name,
            candidate_key      => 'reviewer_id'::name,
            priority           => 'priority'::name,
            results            => ARRAY['queue_name']::name[],
            valid_from         => '2026-08-20 12:00:00+00',
            max_candidates     => 1000
        )
    ]::pgreact_api.declaration[] AS value
), declaration AS (
    SELECT pgreact.policy_set(
        name           => 'order-review-policy',
        version        => '1',
        members        => value,
        applicability  => 'rule_def.reviewable_orders'::regclass,
        subject_keys   => ARRAY['order_id']::name[],
        valid_from     => '2035-01-01 12:15:02+00',
        evidence_limit => 100
    ) AS value
    FROM members
), preview AS (
    SELECT value, pgreact.preview(value) AS result
    FROM declaration
)
SELECT jsonb_build_object(
    'step', 'preview policy set',
    'deployment', result #>> '{summary,deployment}',
    'current_state', result #>> '{summary,current_state}'
)
FROM preview;

DO $$ BEGIN
    PERFORM pgreact.run('2035-01-01 12:10:00+00');
END $$;

SELECT jsonb_build_object(
    'step', 'routing matrix',
    'subjects', jsonb_agg(jsonb_build_object(
        'order_id', subject_key,
        'state', state,
        'reviewer_id', winner_candidate,
        'queue_name', winner_result ->> 'queue_name'
    ) ORDER BY subject_key)
)
FROM pgreact.decision_winners
WHERE program_name = 'order-review-route';