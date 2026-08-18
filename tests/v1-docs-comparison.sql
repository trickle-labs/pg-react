\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';

-- Clean any previous leftover state
CREATE SCHEMA IF NOT EXISTS comp_app;
CREATE SCHEMA IF NOT EXISTS comp_def;
CREATE SCHEMA IF NOT EXISTS comp_action;

CREATE TABLE comp_app.orders (
    order_id bigint PRIMARY KEY,
    customer_id bigint NOT NULL,
    amount numeric(12,2) NOT NULL,
    risk_level text NOT NULL,
    channel text NOT NULL
);

INSERT INTO comp_app.orders VALUES
    (1, 100,  8000.00, 'HIGH', 'WEB'),     -- not in v1, added in v2
    (2, 200, 15000.00, 'HIGH', 'STORE'),   -- in v1 (amount > 10000), removed in v2 (channel != 'WEB')
    (3, 300, 12000.00, 'HIGH', 'WEB'),     -- in v1 and v2, unchanged bindings
    (4, 400,  6000.00, 'HIGH', 'WEB');     -- not in v1, added in v2

CREATE VIEW comp_def.review_v1 AS
SELECT order_id, customer_id, amount, channel
FROM comp_app.orders
WHERE risk_level = 'HIGH' AND amount > 10000;

CREATE VIEW comp_def.review_v2 AS
SELECT order_id, customer_id, amount, channel
FROM comp_app.orders
WHERE risk_level = 'HIGH' AND amount > 5000 AND channel = 'WEB';

CREATE FUNCTION comp_action.flag_v1(
    context pgreact.activation_context,
    match comp_def.review_v1
) RETURNS void LANGUAGE SQL BEGIN ATOMIC END;

CREATE FUNCTION comp_action.flag_v2(
    context pgreact.activation_context,
    match comp_def.review_v2
) RETURNS void LANGUAGE SQL BEGIN ATOMIC END;

-- 1. Deploy current target rule
WITH decl AS (
    SELECT pgreact.rule(
        name         => 'order-review-rule',
        condition    => 'comp_def.review_v1'::regclass,
        semantic_key => 'order_id'::name,
        kind         => 'COMMAND',
        on_activate  => 'comp_action.flag_v1(pgreact.activation_context,comp_def.review_v1)'::regprocedure
    ) AS value
),
prev AS (
    SELECT value, pgreact.preview(value) AS preview_res
    FROM decl
)
SELECT pgreact.deploy(
    value,
    jsonb_build_object('preview_digest', preview_res #>> '{summary,preview_digest}')
)
FROM prev;

-- Run a cycle to evaluate target rule state
SELECT pgreact.run('2026-08-18 12:00:00+00');

-- 2. Construct proposed declaration
-- Proposed rule with condition comp_def.review_v2

-- 3. Strengthened No-Effect Validation (Part E)
-- Capture explicit before snapshots across 9 state tables/frontiers
CREATE TEMP TABLE snap_api_declarations AS
SELECT * FROM pgreact_internal.api_declarations ORDER BY declaration_id;

CREATE TEMP TABLE snap_rule_versions AS
SELECT * FROM pgreact_internal.rule_versions ORDER BY rule_version_id;

CREATE TEMP TABLE snap_activation_state AS
SELECT * FROM pgreact_internal.activation_state ORDER BY activation_id;

CREATE TEMP TABLE snap_decision_subject_state AS
SELECT * FROM pgreact_internal.decision_subject_state ORDER BY program_id, subject_key;

CREATE TEMP TABLE snap_policy_set_versions AS
SELECT * FROM pgreact_internal.policy_set_versions ORDER BY policy_set_version_id;

CREATE TEMP TABLE snap_work AS
SELECT * FROM pgreact.work ORDER BY work_id;

CREATE TEMP TABLE snap_attempts AS
SELECT * FROM pgreact.attempts ORDER BY execution_id;

CREATE TEMP TABLE snap_orders AS
SELECT * FROM comp_app.orders ORDER BY order_id;

CREATE TEMP TABLE snap_clock_frontier AS
SELECT * FROM pgreact_internal.clock_frontier;

-- Execute comparisons (envelope and relational)
SELECT pgreact.compare(
    pgreact.rule(
        name         => 'order-review-rule',
        condition    => 'comp_def.review_v2'::regclass,
        semantic_key => 'order_id'::name,
        kind         => 'COMMAND',
        on_activate  => 'comp_action.flag_v2(pgreact.activation_context,comp_def.review_v2)'::regprocedure
    ),
    pgreact_api.target('rule', 'order-review-rule'),
    '{"evidence_limit": 100}'::jsonb
);

SELECT * FROM pgreact.compare_results(
    pgreact.rule(
        name         => 'order-review-rule',
        condition    => 'comp_def.review_v2'::regclass,
        semantic_key => 'order_id'::name,
        kind         => 'COMMAND',
        on_activate  => 'comp_action.flag_v2(pgreact.activation_context,comp_def.review_v2)'::regprocedure
    ),
    pgreact_api.target('rule', 'order-review-rule'),
    '{"evidence_limit": 100}'::jsonb
);

-- Assert all 9 before/after snapshots are completely identical!
DO $$
BEGIN
    IF EXISTS (SELECT * FROM pgreact_internal.api_declarations EXCEPT SELECT * FROM snap_api_declarations)
       OR EXISTS (SELECT * FROM snap_api_declarations EXCEPT SELECT * FROM pgreact_internal.api_declarations) THEN
        RAISE EXCEPTION 'No-effect violation on api_declarations';
    END IF;

    IF EXISTS (SELECT * FROM pgreact_internal.rule_versions EXCEPT SELECT * FROM snap_rule_versions)
       OR EXISTS (SELECT * FROM snap_rule_versions EXCEPT SELECT * FROM snap_rule_versions) THEN
        RAISE EXCEPTION 'No-effect violation on rule_versions';
    END IF;

    IF EXISTS (SELECT * FROM pgreact_internal.activation_state EXCEPT SELECT * FROM snap_activation_state)
       OR EXISTS (SELECT * FROM snap_activation_state EXCEPT SELECT * FROM pgreact_internal.activation_state) THEN
        RAISE EXCEPTION 'No-effect violation on activation_state';
    END IF;

    IF EXISTS (SELECT * FROM pgreact_internal.decision_subject_state EXCEPT SELECT * FROM snap_decision_subject_state)
       OR EXISTS (SELECT * FROM snap_decision_subject_state EXCEPT SELECT * FROM pgreact_internal.decision_subject_state) THEN
        RAISE EXCEPTION 'No-effect violation on decision_subject_state';
    END IF;

    IF EXISTS (SELECT * FROM pgreact_internal.policy_set_versions EXCEPT SELECT * FROM snap_policy_set_versions)
       OR EXISTS (SELECT * FROM snap_policy_set_versions EXCEPT SELECT * FROM snap_policy_set_versions) THEN
        RAISE EXCEPTION 'No-effect violation on policy_set_versions';
    END IF;

    IF EXISTS (SELECT * FROM pgreact.work EXCEPT SELECT * FROM snap_work)
       OR EXISTS (SELECT * FROM snap_work EXCEPT SELECT * FROM pgreact.work) THEN
        RAISE EXCEPTION 'No-effect violation on work';
    END IF;

    IF EXISTS (SELECT * FROM pgreact.attempts EXCEPT SELECT * FROM snap_attempts)
       OR EXISTS (SELECT * FROM snap_attempts EXCEPT SELECT * FROM pgreact.attempts) THEN
        RAISE EXCEPTION 'No-effect violation on attempts';
    END IF;

    IF EXISTS (SELECT * FROM comp_app.orders EXCEPT SELECT * FROM snap_orders)
       OR EXISTS (SELECT * FROM snap_orders EXCEPT SELECT * FROM comp_app.orders) THEN
        RAISE EXCEPTION 'No-effect violation on source table orders';
    END IF;

    IF EXISTS (SELECT * FROM pgreact_internal.clock_frontier EXCEPT SELECT * FROM snap_clock_frontier)
       OR EXISTS (SELECT * FROM snap_clock_frontier EXCEPT SELECT * FROM pgreact_internal.clock_frontier) THEN
        RAISE EXCEPTION 'No-effect violation on clock frontier';
    END IF;
END $$;

-- 4. Verify delta statuses in compare_results (ADDED, REMOVED, CHANGED, UNCHANGED)
DO $$
DECLARE
    added_count integer;
    removed_count integer;
    unchanged_count integer;
BEGIN
    SELECT count(*) INTO added_count
    FROM pgreact.compare_results(
        pgreact.rule(
            name         => 'order-review-rule',
            condition    => 'comp_def.review_v2'::regclass,
            semantic_key => 'order_id'::name,
            kind         => 'COMMAND',
            on_activate  => 'comp_action.flag_v2(pgreact.activation_context,comp_def.review_v2)'::regprocedure
        ),
        pgreact_api.target('rule', 'order-review-rule'),
        '{"evidence_limit": 100}'::jsonb
    )
    WHERE result_set = 'delta' AND delta = 'ADDED';

    SELECT count(*) INTO removed_count
    FROM pgreact.compare_results(
        pgreact.rule(
            name         => 'order-review-rule',
            condition    => 'comp_def.review_v2'::regclass,
            semantic_key => 'order_id'::name,
            kind         => 'COMMAND',
            on_activate  => 'comp_action.flag_v2(pgreact.activation_context,comp_def.review_v2)'::regprocedure
        ),
        pgreact_api.target('rule', 'order-review-rule'),
        '{"evidence_limit": 100}'::jsonb
    )
    WHERE result_set = 'delta' AND delta = 'REMOVED';

    IF added_count <> 2 OR removed_count <> 1 THEN
        RAISE EXCEPTION 'Delta counts unexpected: added=%, removed=%', added_count, removed_count;
    END IF;
END $$;

-- 5. Verify evidence_limit bounds & partial results
-- Evidence limit 1 produces partial state and M34_COMPARISON_INCOMPLETE finding
DO $$
DECLARE
    res jsonb;
BEGIN
    res := pgreact.compare(
        pgreact.rule(
            name         => 'order-review-rule',
            condition    => 'comp_def.review_v2'::regclass,
            semantic_key => 'order_id'::name,
            kind         => 'COMMAND',
            on_activate  => 'comp_action.flag_v2(pgreact.activation_context,comp_def.review_v2)'::regprocedure
        ),
        pgreact_api.target('rule', 'order-review-rule'),
        '{"evidence_limit": 1}'::jsonb
    );

    IF res ->> 'state' <> 'partial' OR (res ->> 'truncated')::boolean <> true THEN
        RAISE EXCEPTION 'Expected partial truncated result at evidence_limit 1, got: %', res;
    END IF;

    IF NOT (res -> 'findings' @> jsonb_build_array(jsonb_build_object('code', 'M34_COMPARISON_INCOMPLETE'))) THEN
        RAISE EXCEPTION 'Expected M34_COMPARISON_INCOMPLETE finding, got: %', res;
    END IF;
END $$;

-- Out-of-bounds evidence limit (0 or > 1000) rejected with M34_RESOURCE_LIMIT
DO $$
BEGIN
    PERFORM pgreact.compare(
        pgreact.rule(
            name         => 'order-review-rule',
            condition    => 'comp_def.review_v2'::regclass,
            semantic_key => 'order_id'::name,
            kind         => 'COMMAND',
            on_activate  => 'comp_action.flag_v2(pgreact.activation_context,comp_def.review_v2)'::regprocedure
        ),
        pgreact_api.target('rule', 'order-review-rule'),
        '{"evidence_limit": 0}'::jsonb
    );
    RAISE EXCEPTION 'Should have failed with M34_RESOURCE_LIMIT';
EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%M34_RESOURCE_LIMIT%' THEN
        RAISE EXCEPTION 'Unexpected error message: %', SQLERRM;
    END IF;
END $$;

-- 6. Target mismatch checks
-- Kind mismatch: M34_TARGET_KIND
DO $$
BEGIN
    PERFORM pgreact.compare(
        pgreact.rule(
            name         => 'order-review-rule',
            condition    => 'comp_def.review_v2'::regclass,
            semantic_key => 'order_id'::name,
            kind         => 'COMMAND',
            on_activate  => 'comp_action.flag_v2(pgreact.activation_context,comp_def.review_v2)'::regprocedure
        ),
        pgreact_api.target('decision_program', 'order-review-rule'),
        '{"evidence_limit": 100}'::jsonb
    );
    RAISE EXCEPTION 'Should have failed with M34_TARGET_KIND';
EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%M34_TARGET_KIND%' THEN
        RAISE EXCEPTION 'Unexpected error message: %', SQLERRM;
    END IF;
END $$;

-- Name mismatch: M34_TARGET_NAME
DO $$
BEGIN
    PERFORM pgreact.compare(
        pgreact.rule(
            name         => 'order-review-rule-v2',
            condition    => 'comp_def.review_v2'::regclass,
            semantic_key => 'order_id'::name,
            kind         => 'COMMAND',
            on_activate  => 'comp_action.flag_v2(pgreact.activation_context,comp_def.review_v2)'::regprocedure
        ),
        pgreact_api.target('rule', 'order-review-rule'),
        '{"evidence_limit": 100}'::jsonb
    );
    RAISE EXCEPTION 'Should have failed with M34_TARGET_NAME';
EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%M34_TARGET_NAME%' THEN
        RAISE EXCEPTION 'Unexpected error message: %', SQLERRM;
    END IF;
END $$;

-- 7. Deterministic-Field Projection (Part L)
-- Two runs produce identical normalized semantic projections
DO $$
DECLARE
    run1 jsonb;
    run2 jsonb;
    norm1 jsonb;
    norm2 jsonb;
BEGIN
    run1 := pgreact.compare(
        pgreact.rule(
            name         => 'order-review-rule',
            condition    => 'comp_def.review_v2'::regclass,
            semantic_key => 'order_id'::name,
            kind         => 'COMMAND',
            on_activate  => 'comp_action.flag_v2(pgreact.activation_context,comp_def.review_v2)'::regprocedure
        ),
        pgreact_api.target('rule', 'order-review-rule'),
        '{"evidence_limit": 100}'::jsonb
    );

    run2 := pgreact.compare(
        pgreact.rule(
            name         => 'order-review-rule',
            condition    => 'comp_def.review_v2'::regclass,
            semantic_key => 'order_id'::name,
            kind         => 'COMMAND',
            on_activate  => 'comp_action.flag_v2(pgreact.activation_context,comp_def.review_v2)'::regprocedure
        ),
        pgreact_api.target('rule', 'order-review-rule'),
        '{"evidence_limit": 100}'::jsonb
    );

    -- Strip elapsed_ms and variable cost timestamps for semantic projection comparison
    norm1 := run1 - 'cost';
    norm2 := run2 - 'cost';

    IF norm1 <> norm2 THEN
        RAISE EXCEPTION 'Semantic projection determinism mismatch:\nrun1=%\nrun2=%', norm1, norm2;
    END IF;
END $$;

-- 8. Clean up comparison fixture
SELECT pgreact.pause_rule('order-review-rule');
SELECT pgreact.remove('order-review-rule');
DROP VIEW IF EXISTS comp_def.review_v2 CASCADE;
DROP VIEW IF EXISTS comp_def.review_v1 CASCADE;
DROP TABLE IF EXISTS comp_app.orders CASCADE;
DROP SCHEMA IF EXISTS comp_action CASCADE;
DROP SCHEMA IF EXISTS comp_def CASCADE;
DROP SCHEMA IF EXISTS comp_app CASCADE;
