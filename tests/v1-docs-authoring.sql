\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';

-- Clean any previous leftover state
DO $$
BEGIN
    PERFORM pgreact.remove('order-review-policy');
EXCEPTION WHEN OTHERS THEN NULL;
END $$;
DO $$
BEGIN
    PERFORM pgreact.remove('manual-review-route');
EXCEPTION WHEN OTHERS THEN NULL;
END $$;
DO $$
BEGIN
    PERFORM pgreact.pause_rule('author-command-rule');
    PERFORM pgreact.remove('author-command-rule');
EXCEPTION WHEN OTHERS THEN NULL;
END $$;

DROP VIEW IF EXISTS authoring_def.reviewable_orders CASCADE;
DROP VIEW IF EXISTS authoring_def.review_candidates CASCADE;
DROP TABLE IF EXISTS authoring_app.reviewer_candidates CASCADE;
DROP VIEW IF EXISTS authoring_def.high_risk_orders CASCADE;
DROP TABLE IF EXISTS authoring_app.reviews CASCADE;
DROP TABLE IF EXISTS authoring_app.orders CASCADE;
DROP SCHEMA IF EXISTS authoring_action CASCADE;
DROP SCHEMA IF EXISTS authoring_def CASCADE;
DROP SCHEMA IF EXISTS authoring_app CASCADE;

CREATE SCHEMA authoring_app;
CREATE SCHEMA authoring_def;
CREATE SCHEMA authoring_action;

CREATE TABLE authoring_app.orders (
    order_id bigint PRIMARY KEY,
    customer_id bigint NOT NULL,
    amount numeric(12,2) NOT NULL,
    risk_level text NOT NULL
);

CREATE TABLE authoring_app.reviews (
    order_id bigint PRIMARY KEY,
    status text NOT NULL,
    activation_id uuid NOT NULL
);

INSERT INTO authoring_app.orders VALUES
    (1, 10, 15000.00, 'HIGH'),
    (2, 20, 5000.00, 'LOW');

CREATE VIEW authoring_def.high_risk_orders AS
SELECT order_id, customer_id, amount
FROM authoring_app.orders
WHERE risk_level = 'HIGH' AND amount > 10000;

-- Typed consequences
CREATE FUNCTION authoring_action.on_open(
    context pgreact.activation_context,
    match authoring_def.high_risk_orders
) RETURNS void LANGUAGE SQL BEGIN ATOMIC
    INSERT INTO authoring_app.reviews (order_id, status, activation_id)
    VALUES ((match).order_id, 'OPEN', (context).activation_id)
    ON CONFLICT (order_id) DO UPDATE
    SET status = 'OPEN', activation_id = EXCLUDED.activation_id;
END;

CREATE FUNCTION authoring_action.on_close(
    context pgreact.activation_context,
    match authoring_def.high_risk_orders
) RETURNS void LANGUAGE SQL BEGIN ATOMIC
    UPDATE authoring_app.reviews
    SET status = 'CLOSED'
    WHERE order_id = (match).order_id;
END;

CREATE FUNCTION authoring_action.on_modify(
    context pgreact.activation_context,
    old_match authoring_def.high_risk_orders,
    new_match authoring_def.high_risk_orders
) RETURNS void LANGUAGE SQL BEGIN ATOMIC
    UPDATE authoring_app.reviews
    SET status = 'UPDATED'
    WHERE order_id = (new_match).order_id;
END;

-- 1. Constraint rule (no consequences)
SELECT pgreact.rule(
    name         => 'author-constraint-rule',
    condition    => 'authoring_def.high_risk_orders'::regclass,
    semantic_key => 'order_id'::name,
    kind         => 'CONSTRAINT'
);

-- Validation of valid constraint rule succeeds with state 'ready'
DO $$
DECLARE
    res jsonb;
BEGIN
    res := pgreact.validate(pgreact.rule(
        name         => 'author-constraint-rule',
        condition    => 'authoring_def.high_risk_orders'::regclass,
        semantic_key => 'order_id'::name,
        kind         => 'CONSTRAINT'
    ));
    IF res ->> 'state' <> 'ready' OR jsonb_array_length(res -> 'findings') <> 0 THEN
        RAISE EXCEPTION 'Constraint validation unexpected state: %', res;
    END IF;
END $$;

-- Validation of invalid declaration (unqualified relation) reports attention and blocking finding
DO $$
DECLARE
    res jsonb;
BEGIN
    res := pgreact.validate(pgreact_api.declaration(
        'rule', 'invalid-rule',
        '{"condition": "unqualified_orders", "semantic_key": "order_id"}'::jsonb
    ));
    IF res ->> 'state' <> 'attention'
       OR NOT (res -> 'findings' @> jsonb_build_array(jsonb_build_object('code', 'M32_INVALID_DECLARATION'))) THEN
        RAISE EXCEPTION 'Invalid declaration validation failed to report finding: %', res;
    END IF;
END $$;

-- 2. Command rule with full consequences
SELECT pgreact.rule(
    name          => 'author-command-rule',
    condition     => 'authoring_def.high_risk_orders'::regclass,
    semantic_key  => 'order_id'::name,
    kind          => 'COMMAND',
    on_activate   => 'authoring_action.on_open(pgreact.activation_context,authoring_def.high_risk_orders)'::regprocedure,
    on_deactivate => 'authoring_action.on_close(pgreact.activation_context,authoring_def.high_risk_orders)'::regprocedure,
    on_change     => 'authoring_action.on_modify(pgreact.activation_context,authoring_def.high_risk_orders,authoring_def.high_risk_orders)'::regprocedure
);

-- Validate, preview, deploy command rule
WITH decl AS (
    SELECT pgreact.rule(
        name          => 'author-command-rule',
        condition     => 'authoring_def.high_risk_orders'::regclass,
        semantic_key  => 'order_id'::name,
        kind          => 'COMMAND',
        on_activate   => 'authoring_action.on_open(pgreact.activation_context,authoring_def.high_risk_orders)'::regprocedure,
        on_deactivate => 'authoring_action.on_close(pgreact.activation_context,authoring_def.high_risk_orders)'::regprocedure,
        on_change     => 'authoring_action.on_modify(pgreact.activation_context,authoring_def.high_risk_orders,authoring_def.high_risk_orders)'::regprocedure
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

-- 3. Decision declarations
CREATE TABLE authoring_app.reviewer_candidates (
    subject_id bigint NOT NULL,
    reviewer_id bigint NOT NULL,
    priority bigint NOT NULL,
    queue_name text NOT NULL
);
INSERT INTO authoring_app.reviewer_candidates VALUES
    (1, 101, 1, 'tier1'),
    (1, 102, 2, 'tier2');

CREATE VIEW authoring_def.review_candidates AS
SELECT subject_id, reviewer_id, priority, queue_name
FROM authoring_app.reviewer_candidates;

SELECT pgreact.decision(
    name               => 'manual-review-route',
    candidate_relation => 'authoring_def.review_candidates'::regclass,
    subject_key        => 'subject_id'::name,
    candidate_key      => 'reviewer_id'::name,
    priority           => 'priority'::name,
    results            => ARRAY['queue_name']::name[],
    max_candidates     => 1000
);

WITH decision_decl AS (
    SELECT pgreact.decision(
        name               => 'manual-review-route',
        candidate_relation => 'authoring_def.review_candidates'::regclass,
        subject_key        => 'subject_id'::name,
        candidate_key      => 'reviewer_id'::name,
        priority           => 'priority'::name,
        results            => ARRAY['queue_name']::name[],
        max_candidates     => 1000
    ) AS value
),
prev AS (
    SELECT value, pgreact.preview(value) AS preview_res
    FROM decision_decl
)
SELECT pgreact.deploy(
    value,
    jsonb_build_object('preview_digest', preview_res #>> '{summary,preview_digest}')
)
FROM prev;

-- 4. Policy-set declarations
CREATE VIEW authoring_def.reviewable_orders AS
SELECT order_id
FROM authoring_app.orders;

WITH review_rule AS (
    SELECT pgreact.rule(
        name          => 'author-command-rule',
        condition     => 'authoring_def.high_risk_orders'::regclass,
        semantic_key  => 'order_id'::name,
        kind          => 'COMMAND',
        on_activate   => 'authoring_action.on_open(pgreact.activation_context,authoring_def.high_risk_orders)'::regprocedure,
        on_deactivate => 'authoring_action.on_close(pgreact.activation_context,authoring_def.high_risk_orders)'::regprocedure,
        on_change     => 'authoring_action.on_modify(pgreact.activation_context,authoring_def.high_risk_orders,authoring_def.high_risk_orders)'::regprocedure
    ) AS value
)
SELECT pgreact.policy_set(
    name           => 'order-review-policy',
    version        => '1',
    members        => ARRAY[value]::pgreact_api.declaration[],
    applicability  => 'authoring_def.reviewable_orders'::regclass,
    subject_keys   => ARRAY['order_id']::name[],
    evidence_limit => 100
)
FROM review_rule;

WITH review_rule AS (
    SELECT pgreact.rule(
        name          => 'author-command-rule',
        condition     => 'authoring_def.high_risk_orders'::regclass,
        semantic_key  => 'order_id'::name,
        kind          => 'COMMAND',
        on_activate   => 'authoring_action.on_open(pgreact.activation_context,authoring_def.high_risk_orders)'::regprocedure,
        on_deactivate => 'authoring_action.on_close(pgreact.activation_context,authoring_def.high_risk_orders)'::regprocedure,
        on_change     => 'authoring_action.on_modify(pgreact.activation_context,authoring_def.high_risk_orders,authoring_def.high_risk_orders)'::regprocedure
    ) AS value
),
policy_decl AS (
    SELECT pgreact.policy_set(
        name           => 'order-review-policy',
        version        => '1',
        members        => ARRAY[value]::pgreact_api.declaration[],
        applicability  => 'authoring_def.reviewable_orders'::regclass,
        subject_keys   => ARRAY['order_id']::name[],
        evidence_limit => 100
    ) AS value
    FROM review_rule
),
prev AS (
    SELECT value, pgreact.preview(value) AS preview_res
    FROM policy_decl
)
SELECT pgreact.deploy(
    value,
    jsonb_build_object('preview_digest', preview_res #>> '{summary,preview_digest}')
)
FROM prev;

-- 5. Public views inspection
SELECT * FROM pgreact.rules ORDER BY name, version;
SELECT * FROM pgreact.matches ORDER BY name, semantic_key;
SELECT * FROM pgreact.decisions ORDER BY name;
SELECT * FROM pgreact.policy_sets ORDER BY name;
SELECT * FROM pgreact.work ORDER BY work_id;
SELECT * FROM pgreact.attempts ORDER BY execution_id;
SELECT * FROM pgreact.health ORDER BY code;

-- 6. Status and explain
SELECT pgreact.status('author-command-rule');
SELECT pgreact.explain('author-command-rule');
SELECT pgreact.status('manual-review-route');
SELECT pgreact.status('order-review-policy');

-- 7. Cleanup
SELECT pgreact.remove('order-review-policy');
SELECT pgreact.remove('manual-review-route');
SELECT pgreact.pause_rule('author-command-rule');
SELECT pgreact.remove('author-command-rule');

DROP VIEW IF EXISTS authoring_def.reviewable_orders CASCADE;
DROP VIEW IF EXISTS authoring_def.review_candidates CASCADE;
DROP TABLE IF EXISTS authoring_app.reviewer_candidates CASCADE;
DROP VIEW IF EXISTS authoring_def.high_risk_orders CASCADE;
DROP TABLE IF EXISTS authoring_app.reviews CASCADE;
DROP TABLE IF EXISTS authoring_app.orders CASCADE;
DROP SCHEMA IF EXISTS authoring_action CASCADE;
DROP SCHEMA IF EXISTS authoring_def CASCADE;
DROP SCHEMA IF EXISTS authoring_app CASCADE;
