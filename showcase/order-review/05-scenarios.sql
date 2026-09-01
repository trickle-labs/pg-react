\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';

-- Fixed logical times make the transcript reproducible. pgreact.run refreshes
-- truth and creates durable work; managed_cycle executes that work.
SELECT jsonb_build_object(
    'step', 'initial truth',
    'active_orders', jsonb_agg(semantic_key ORDER BY semantic_key),
    'work_items', (SELECT count(*) FROM pgreact.work WHERE name = 'order-review-work'),
    'review_tasks', (SELECT count(*) FROM app.review_tasks)
)
FROM pgreact.matches
WHERE name = 'order-review-work' AND active;

UPDATE app.orders
SET risk_level = 'HIGH'
WHERE order_id = 1003;

-- Order 1003 enters the rule for the first time: generation 1, revision 0.
DO $$ BEGIN
    PERFORM pgreact.run('2035-01-01 12:11:00+00');
    PERFORM pgreact_api.managed_cycle();
END $$;

SELECT jsonb_build_object(
    'step', 'activate order 1003',
    'match', (
        SELECT jsonb_build_object(
            'active', active, 'generation', generation, 'revision', revision
        )
        FROM pgreact.matches
        WHERE name = 'order-review-work' AND semantic_key = '1003'
    ),
    'task', (
        SELECT jsonb_build_object(
            'generation', generation, 'state', state, 'reason_code', reason_code,
            'amount', amount, 'last_revision', last_revision
        )
        FROM app.review_tasks
        WHERE order_id = 1003 AND generation = 1
    ),
    'attempt', (
        SELECT jsonb_build_object(
            'event_kind', event_kind, 'attempt_no', attempt_no, 'status', status
        )
        FROM pgreact.attempts
        WHERE name = 'order-review-work'
        ORDER BY execution_id DESC
        LIMIT 1
    )
);

UPDATE app.orders
SET amount = 1350.00
WHERE order_id = 1003;

-- A watched change keeps the same generation and increments its revision.
DO $$ BEGIN
    PERFORM pgreact.run('2035-01-01 12:12:00+00');
    PERFORM pgreact_api.managed_cycle();
END $$;

SELECT jsonb_build_object(
    'step', 'change order amount',
    'match', (
        SELECT jsonb_build_object(
            'active', active, 'generation', generation, 'revision', revision
        )
        FROM pgreact.matches
        WHERE name = 'order-review-work' AND semantic_key = '1003'
    ),
    'task', (
        SELECT jsonb_build_object(
            'generation', generation, 'state', state, 'reason_code', reason_code,
            'amount', amount, 'last_revision', last_revision
        )
        FROM app.review_tasks
        WHERE order_id = 1003 AND generation = 1
    ),
    'attempt', (
        SELECT jsonb_build_object(
            'event_kind', event_kind, 'attempt_no', attempt_no, 'status', status
        )
        FROM pgreact.attempts
        WHERE name = 'order-review-work'
        ORDER BY execution_id DESC
        LIMIT 1
    )
);

UPDATE app.customers
SET chargeback_count = 1
WHERE customer_id = 503;

-- The customer trigger updates the order facts, producing another revision.
DO $$ BEGIN
    PERFORM pgreact.run('2035-01-01 12:13:00+00');
    PERFORM pgreact_api.managed_cycle();
END $$;

SELECT jsonb_build_object(
    'step', 'change supporting customer fact',
    'match', (
        SELECT jsonb_build_object(
            'active', active, 'generation', generation, 'revision', revision
        )
        FROM pgreact.matches
        WHERE name = 'order-review-work' AND semantic_key = '1003'
    ),
    'task', (
        SELECT jsonb_build_object(
            'generation', generation, 'state', state, 'reason_code', reason_code,
            'amount', amount, 'last_revision', last_revision
        )
        FROM app.review_tasks
        WHERE order_id = 1003 AND generation = 1
    ),
    'attempt', (
        SELECT jsonb_build_object(
            'event_kind', event_kind, 'attempt_no', attempt_no, 'status', status
        )
        FROM pgreact.attempts
        WHERE name = 'order-review-work'
        ORDER BY execution_id DESC
        LIMIT 1
    )
);

UPDATE app.orders
SET risk_level = 'LOW'
WHERE order_id = 1003;

-- Leaving the condition closes generation 1 instead of deleting its history.
DO $$ BEGIN
    PERFORM pgreact.run('2035-01-01 12:14:00+00');
    PERFORM pgreact_api.managed_cycle();
END $$;

SELECT jsonb_build_object(
    'step', 'deactivate order 1003',
    'match', (
        SELECT jsonb_build_object(
            'active', active, 'generation', generation, 'revision', revision
        )
        FROM pgreact.matches
        WHERE name = 'order-review-work' AND semantic_key = '1003'
    ),
    'task', (
        SELECT jsonb_build_object(
            'generation', generation, 'state', state, 'reason_code', reason_code,
            'amount', amount, 'last_revision', last_revision
        )
        FROM app.review_tasks
        WHERE order_id = 1003 AND generation = 1
    ),
    'attempt', (
        SELECT jsonb_build_object(
            'event_kind', event_kind, 'attempt_no', attempt_no, 'status', status
        )
        FROM pgreact.attempts
        WHERE name = 'order-review-work'
        ORDER BY execution_id DESC
        LIMIT 1
    )
);

UPDATE app.failure_controls
SET fail_review_task = true
WHERE order_id = 1003;

UPDATE app.orders
SET risk_level = 'HIGH'
WHERE order_id = 1003;

-- Re-entering starts generation 2. The injected failure makes retry visible.
DO $$ BEGIN
    PERFORM pgreact.run('2035-01-01 12:15:00+00');
    PERFORM pgreact_api.managed_cycle();
END $$;

SELECT jsonb_build_object(
    'step', 'first reactivation attempt',
    'match', (
        SELECT jsonb_build_object(
            'active', active, 'generation', generation, 'revision', revision
        )
        FROM pgreact.matches
        WHERE name = 'order-review-work' AND semantic_key = '1003'
    ),
    'work_state', (
        SELECT state
        FROM pgreact.work
        WHERE name = 'order-review-work'
        ORDER BY work_id::bigint DESC
        LIMIT 1
    ),
    'attempt', (
        SELECT jsonb_build_object(
            'event_kind', event_kind, 'attempt_no', attempt_no, 'status', status,
            'error_code', error_code, 'error_message', error_message
        )
        FROM pgreact.attempts
        WHERE name = 'order-review-work'
        ORDER BY execution_id DESC
        LIMIT 1
    ),
    'generation_2_tasks', (
        SELECT count(*) FROM app.review_tasks WHERE order_id = 1003 AND generation = 2
    )
);

UPDATE app.failure_controls
SET fail_review_task = false
WHERE order_id = 1003;

-- Retry availability uses the database wall clock, so cross the configured
-- one-second backoff before draining managed work.
DO $$
DECLARE
    latest_state text;
    retry_deadline timestamptz := clock_timestamp() + interval '1.1 seconds';
BEGIN
    PERFORM pgreact.run('2035-01-01 12:15:02+00');
    WHILE clock_timestamp() < retry_deadline LOOP
        PERFORM pgreact.run('2035-01-01 12:15:02+00');
    END LOOP;
    FOR cycle_no IN 1..100 LOOP
        PERFORM pgreact_api.managed_cycle();
        SELECT state INTO latest_state
        FROM pgreact.work
        WHERE name = 'order-review-work'
        ORDER BY work_id::bigint DESC
        LIMIT 1;
        EXIT WHEN latest_state = 'COMPLETED';
    END LOOP;
    IF latest_state IS DISTINCT FROM 'COMPLETED' THEN
        RAISE EXCEPTION 'review-task retry did not complete within 100 managed cycles';
    END IF;
END $$;

SELECT jsonb_build_object(
    'step', 'successful retry',
    'work_state', (
        SELECT state
        FROM pgreact.work
        WHERE name = 'order-review-work'
        ORDER BY work_id::bigint DESC
        LIMIT 1
    ),
    'attempts', (
        SELECT jsonb_agg(jsonb_build_object(
            'attempt_no', attempt_no, 'status', status,
            'error_code', error_code, 'event_kind', event_kind
        ) ORDER BY attempt_no)
        FROM pgreact.attempts
        WHERE name = 'order-review-work'
          AND episode_id = (
              SELECT episode_id
              FROM pgreact.attempts
              WHERE name = 'order-review-work'
              ORDER BY execution_id DESC
              LIMIT 1
          )
    ),
    'task', (
        SELECT jsonb_build_object(
            'generation', generation, 'state', state, 'reason_code', reason_code,
            'amount', amount, 'last_revision', last_revision
        )
        FROM app.review_tasks
        WHERE order_id = 1003 AND generation = 2
    ),
    'generation_2_tasks', (
        SELECT count(*) FROM app.review_tasks WHERE order_id = 1003 AND generation = 2
    )
);

DELETE FROM app.reviewer_candidates
WHERE order_id = 1003;

-- Removing the last candidate preserves the decision as NO_CANDIDATE.
DO $$ BEGIN
    PERFORM pgreact.run('2035-01-01 12:16:00+00');
END $$;

SELECT jsonb_build_object(
    'step', 'routing after candidate removal',
    'subjects', jsonb_agg(jsonb_build_object(
        'order_id', subject_key,
        'state', state,
        'reviewer_id', winner_candidate,
        'queue_name', winner_result ->> 'queue_name'
    ) ORDER BY subject_key)
)
FROM pgreact.decision_winners
WHERE program_name = 'order-review-route';

SELECT jsonb_build_object(
    'step', 'bounded explanation',
    'name', result #>> '{target,name}',
    'kind', result #>> '{target,kind}',
    'state', result ->> 'state',
    'subject', result #> '{evidence,subject}',
    'runtime_state', result #>> '{runtime,runtime_state}',
    'truncated', result -> 'truncated'
)
FROM (SELECT pgreact.explain('order-review-work', '1003'::jsonb) AS result) AS explanation;

CREATE TEMP TABLE showcase_before_comparison AS
SELECT (SELECT rule_version_id::text FROM pgreact.rules WHERE name = 'order-review-work') AS rule_version_id,
       (SELECT count(*) FROM pgreact.work WHERE name = 'order-review-work') AS work_count,
       (SELECT count(*) FROM pgreact.attempts WHERE name = 'order-review-work') AS attempt_count,
       (SELECT count(*) FROM app.review_tasks WHERE order_id = 1002) AS proposed_task_count;

-- Compare the lower threshold without deploying it or creating command work.
CREATE TEMP TABLE showcase_comparison AS
SELECT pgreact.compare(
    pgreact.rule(
        name                    => 'order-review-work',
        condition               => 'rule_def.risky_orders_v2'::regclass,
        semantic_key            => 'order_id'::name,
        kind                    => 'COMMAND',
        on_activate             => 'rule_action.open_review_v2(pgreact.activation_context,rule_def.risky_orders_v2)'::regprocedure,
        on_deactivate           => 'rule_action.close_review_v2(pgreact.activation_context,rule_def.risky_orders_v2)'::regprocedure,
        on_change               => 'rule_action.update_review_v2(pgreact.activation_context,rule_def.risky_orders_v2,rule_def.risky_orders_v2)'::regprocedure,
        max_attempts            => 2,
        initial_backoff_seconds => 1
    ),
    pgreact_api.target('rule', 'order-review-work'),
    jsonb_build_object('evidence_limit', 100)
) AS result;

CREATE TEMP TABLE showcase_comparison_rows AS
SELECT result_set, subject_key, state, delta, current_value, proposed_value,
       evidence, complete
FROM pgreact.compare_results(
    pgreact.rule(
        name                    => 'order-review-work',
        condition               => 'rule_def.risky_orders_v2'::regclass,
        semantic_key            => 'order_id'::name,
        kind                    => 'COMMAND',
        on_activate             => 'rule_action.open_review_v2(pgreact.activation_context,rule_def.risky_orders_v2)'::regprocedure,
        on_deactivate           => 'rule_action.close_review_v2(pgreact.activation_context,rule_def.risky_orders_v2)'::regprocedure,
        on_change               => 'rule_action.update_review_v2(pgreact.activation_context,rule_def.risky_orders_v2,rule_def.risky_orders_v2)'::regprocedure,
        max_attempts            => 2,
        initial_backoff_seconds => 1
    ),
    pgreact_api.target('rule', 'order-review-work'),
    jsonb_build_object('evidence_limit', 100)
);

SELECT jsonb_build_object(
    'step', 'compare lower threshold',
    'state', result ->> 'state',
    'complete', result #> '{evidence,complete}',
    'counts_exact', result #> '{summary,counts_exact}',
    'current_count', result #> '{summary,current_count}',
    'proposed_count', result #> '{summary,proposed_count}',
    'delta_counts', result #> '{summary,delta_counts}',
    'checksums_equal',
        result #>> '{evidence,authoritative_checksum_before}' =
        result #>> '{evidence,authoritative_checksum_after}',
    'added_orders', (
        SELECT jsonb_agg(subject_key ORDER BY subject_key)
        FROM showcase_comparison_rows
        WHERE result_set = 'delta' AND delta = 'ADDED'
    ),
    'would_be_work', (
        SELECT jsonb_agg(jsonb_build_object(
            'order_id', subject_key, 'state', state, 'change', delta
        ) ORDER BY subject_key)
        FROM showcase_comparison_rows
        WHERE result_set = 'work' AND subject_key = '1002'
    )
)
FROM showcase_comparison;

SELECT jsonb_build_object(
    'step', 'comparison has no effects',
    'rule_version_unchanged', before_state.rule_version_id = rules.rule_version_id::text,
    'work_unchanged', before_state.work_count = (
        SELECT count(*) FROM pgreact.work WHERE name = 'order-review-work'
    ),
    'attempts_unchanged', before_state.attempt_count = (
        SELECT count(*) FROM pgreact.attempts WHERE name = 'order-review-work'
    ),
    'proposed_task_count', (
        SELECT count(*) FROM app.review_tasks WHERE order_id = 1002
    )
)
FROM showcase_before_comparison AS before_state
JOIN pgreact.rules AS rules ON rules.name = 'order-review-work';

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
), deployment AS (
    SELECT pgreact.deploy(
        value,
        pgreact.review_token(result)
    ) AS result
    FROM preview
)
SELECT jsonb_build_object('step', 'deploy policy set', 'state', result ->> 'state')
FROM deployment;

SELECT jsonb_build_object(
    'step', 'policy applicability',
    'eligible', (
        SELECT jsonb_agg(subject ORDER BY subject)
        FROM pgreact.policy_set_eligible_subjects
        WHERE set_name = 'order-review-policy'
    ),
    'current_constraint_matches', (
        SELECT jsonb_agg(semantic_key ORDER BY semantic_key)
        FROM pgreact.matches
        WHERE name = 'order-review-required' AND active
    )
);
