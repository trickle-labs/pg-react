\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';

DO $$
DECLARE
    actual jsonb;
    expected jsonb;
    comparison jsonb;
BEGIN
    SELECT jsonb_build_object(
        'orders', (
            SELECT jsonb_agg(jsonb_build_object(
                'order_id', order_id,
                'customer_id', customer_id,
                'customer_chargeback_count', customer_chargeback_count,
                'customer_account_status', customer_account_status,
                'amount', amount,
                'risk_level', risk_level,
                'status', status
            ) ORDER BY order_id)
            FROM app.orders
        ),
        'review_tasks', (
            SELECT jsonb_agg(jsonb_build_object(
                'order_id', order_id,
                'generation', generation,
                'state', state,
                'reason_code', reason_code,
                'amount', amount,
                'last_revision', last_revision,
                'has_activation_id', activation_id IS NOT NULL,
                'has_idempotency_key', last_idempotency_key <> ''
            ) ORDER BY order_id, generation)
            FROM app.review_tasks
        ),
        'matches', (
            SELECT jsonb_agg(jsonb_build_object(
                'name', name,
                'semantic_key', semantic_key,
                'active', active,
                'generation', generation,
                'revision', revision
            ) ORDER BY name, semantic_key)
            FROM pgreact.matches
            WHERE name IN ('order-review-required', 'order-review-work')
        ),
        'work', (
            SELECT jsonb_agg(jsonb_build_object(
                'kind', kind,
                'name', name,
                'state', state,
                'claimable', claimable
            ) ORDER BY kind, name, work_id)
            FROM pgreact.work
        ),
        'attempts', (
            SELECT jsonb_agg(jsonb_build_object(
                'attempt_no', attempt_no,
                'status', status,
                'error_code', error_code,
                'error_message', error_message,
                'event_kind', event_kind
            ) ORDER BY execution_id)
            FROM pgreact.attempts
            WHERE name = 'order-review-work'
        ),
        'routing', (
            SELECT jsonb_agg(jsonb_build_object(
                'order_id', subject_key,
                'state', state,
                'reviewer_id', winner_candidate,
                'priority', winner_priority,
                'queue_name', winner_result ->> 'queue_name',
                'generation', generation,
                'revision', revision
            ) ORDER BY subject_key)
            FROM pgreact.decision_winners
            WHERE program_name = 'order-review-route'
        ),
        'eligible', (
            SELECT jsonb_agg(subject ORDER BY subject)
            FROM pgreact.policy_set_eligible_subjects
            WHERE set_name = 'order-review-policy'
        ),
        'declarations', (
            SELECT jsonb_agg(jsonb_build_object(
                'kind', kind, 'name', name, 'state', state
            ) ORDER BY kind, name)
            FROM pgreact.api_declarations
            WHERE name IN (
                'order-review-required', 'order-review-work',
                'order-review-route', 'order-review-policy'
            )
        ),
        'policy_sets', (
            SELECT jsonb_agg(name ORDER BY name)
            FROM pgreact.policy_sets
            WHERE name = 'order-review-policy'
        )
    ) INTO actual;

    expected := jsonb_build_object(
        'orders', jsonb_build_array(
            jsonb_build_object('order_id', 1001, 'customer_id', 501,
                'customer_chargeback_count', 1, 'customer_account_status', 'OPEN',
                'amount', 1500.00, 'risk_level', 'HIGH', 'status', 'PENDING'),
            jsonb_build_object('order_id', 1002, 'customer_id', 502,
                'customer_chargeback_count', 0, 'customer_account_status', 'OPEN',
                'amount', 750.00, 'risk_level', 'HIGH', 'status', 'PENDING'),
            jsonb_build_object('order_id', 1003, 'customer_id', 503,
                'customer_chargeback_count', 1, 'customer_account_status', 'OPEN',
                'amount', 1350.00, 'risk_level', 'HIGH', 'status', 'PENDING'),
            jsonb_build_object('order_id', 1004, 'customer_id', 504,
                'customer_chargeback_count', 0, 'customer_account_status', 'SUSPENDED',
                'amount', 2000.00, 'risk_level', 'HIGH', 'status', 'PENDING')
        ),
        'review_tasks', jsonb_build_array(
            jsonb_build_object('order_id', 1003, 'generation', 1, 'state', 'CLOSED',
                'reason_code', 'PRIOR_CHARGEBACK', 'amount', 1350.00,
                'last_revision', 0, 'has_activation_id', true,
                'has_idempotency_key', true),
            jsonb_build_object('order_id', 1003, 'generation', 2, 'state', 'OPEN',
                'reason_code', 'PRIOR_CHARGEBACK', 'amount', 1350.00,
                'last_revision', 0, 'has_activation_id', true,
                'has_idempotency_key', true)
        ),
        'matches', jsonb_build_array(
            jsonb_build_object('name', 'order-review-required', 'semantic_key', 1001,
                'active', true, 'generation', 1, 'revision', 0),
            jsonb_build_object('name', 'order-review-required', 'semantic_key', 1003,
                'active', true, 'generation', 2, 'revision', 0),
            jsonb_build_object('name', 'order-review-work', 'semantic_key', 1001,
                'active', false, 'generation', 1, 'revision', 0),
            jsonb_build_object('name', 'order-review-work', 'semantic_key', 1003,
                'active', false, 'generation', 2, 'revision', 0)
        ),
        'work', jsonb_build_array(
            jsonb_build_object('kind', 'decision', 'name', 'order-review-route',
                'state', 'WINNER', 'claimable', false),
            jsonb_build_object('kind', 'decision', 'name', 'order-review-route',
                'state', 'AMBIGUOUS', 'claimable', false),
            jsonb_build_object('kind', 'decision', 'name', 'order-review-route',
                'state', 'NO_CANDIDATE', 'claimable', false),
            jsonb_build_object('kind', 'rule', 'name', 'order-review-work',
                'state', 'COMPLETED', 'claimable', false),
            jsonb_build_object('kind', 'rule', 'name', 'order-review-work',
                'state', 'COMPLETED', 'claimable', false),
            jsonb_build_object('kind', 'rule', 'name', 'order-review-work',
                'state', 'COMPLETED', 'claimable', false),
            jsonb_build_object('kind', 'rule', 'name', 'order-review-work',
                'state', 'COMPLETED', 'claimable', false),
            jsonb_build_object('kind', 'rule', 'name', 'order-review-work',
                'state', 'COMPLETED', 'claimable', false),
            jsonb_build_object('kind', 'rule', 'name', 'order-review-work',
                'state', 'PENDING', 'claimable', true),
            jsonb_build_object('kind', 'rule', 'name', 'order-review-work',
                'state', 'PENDING', 'claimable', true)
        ),
        'attempts', jsonb_build_array(
            jsonb_build_object('attempt_no', 1, 'status', 'COMPLETED',
                'error_code', NULL, 'error_message', NULL, 'event_kind', 'ACTIVATE'),
            jsonb_build_object('attempt_no', 1, 'status', 'COMPLETED',
                'error_code', NULL, 'error_message', NULL, 'event_kind', 'CHANGE'),
            jsonb_build_object('attempt_no', 1, 'status', 'COMPLETED',
                'error_code', NULL, 'error_message', NULL, 'event_kind', 'CHANGE'),
            jsonb_build_object('attempt_no', 1, 'status', 'COMPLETED',
                'error_code', NULL, 'error_message', NULL, 'event_kind', 'DEACTIVATE'),
            jsonb_build_object('attempt_no', 1, 'status', 'RETRY_WAIT',
                'error_code', 'P6001',
                'error_message', 'injected review-task failure for order 1003',
                'event_kind', 'ACTIVATE'),
            jsonb_build_object('attempt_no', 2, 'status', 'COMPLETED',
                'error_code', NULL, 'error_message', NULL, 'event_kind', 'ACTIVATE')
        ),
        'routing', jsonb_build_array(
            jsonb_build_object('order_id', 1001, 'state', 'WINNER',
                'reviewer_id', 201, 'priority', 1, 'queue_name', 'chargeback-review',
                'generation', 1, 'revision', 0),
            jsonb_build_object('order_id', 1002, 'state', 'AMBIGUOUS',
                'reviewer_id', NULL, 'priority', 1, 'queue_name', NULL,
                'generation', 0, 'revision', 0),
            jsonb_build_object('order_id', 1003, 'state', 'NO_CANDIDATE',
                'reviewer_id', NULL, 'priority', NULL, 'queue_name', NULL,
                'generation', 1, 'revision', 0)
        ),
        'eligible', jsonb_build_array(1001, 1002, 1003),
        'declarations', jsonb_build_array(
            jsonb_build_object('kind', 'decision_program', 'name', 'order-review-route',
                'state', 'DEPLOYED'),
            jsonb_build_object('kind', 'rule', 'name', 'order-review-required',
                'state', 'DEPLOYED'),
            jsonb_build_object('kind', 'rule', 'name', 'order-review-work',
                'state', 'DEPLOYED')
        ),
        'policy_sets', jsonb_build_array('order-review-policy')
    );

    IF actual IS DISTINCT FROM expected THEN
        RAISE EXCEPTION 'order-review final state changed: actual %, expected %',
            actual, expected;
    END IF;

    comparison := pgreact.compare(
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

    IF comparison ->> 'state' <> 'ready'
       OR comparison #>> '{evidence,complete}' <> 'true'
       OR comparison #>> '{summary,counts_exact}' <> 'true'
         OR comparison #>> '{summary,current_count}' <> '0'
       OR comparison #>> '{summary,proposed_count}' <> '3'
       OR comparison #> '{summary,delta_counts}' IS DISTINCT FROM
             '{"added": 3, "changed": 0, "removed": 0, "unchanged": 0}'::jsonb
       OR comparison #>> '{evidence,authoritative_checksum_before}' <>
          comparison #>> '{evidence,authoritative_checksum_after}'
       OR NOT (comparison -> 'findings' @> jsonb_build_array(
           jsonb_build_object('code', 'M34_NO_EFFECT')))
       OR EXISTS (SELECT 1 FROM app.review_tasks WHERE order_id = 1002)
    THEN
        RAISE EXCEPTION 'order-review comparison changed: %', comparison;
    END IF;
END $$;

SELECT 'order-review showcase assertions passed';