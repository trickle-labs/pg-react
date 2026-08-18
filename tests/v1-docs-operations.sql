\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';

-- 1. Baseline diagnostics
SELECT pgreact.doctor();
SELECT pgreact_api.managed_status();
SELECT * FROM pgreact.health WHERE severity = 'ERROR' AND blocking;
SELECT * FROM pgreact.work WHERE state IN ('PENDING', 'LEASED');
SELECT * FROM pgreact.attempts WHERE status = 'FAILED';

-- 2. Setup rule for operations testing
CREATE SCHEMA IF NOT EXISTS ops_app;
CREATE SCHEMA IF NOT EXISTS ops_def;
CREATE SCHEMA IF NOT EXISTS ops_action;

CREATE TABLE ops_app.orders (
    order_id bigint PRIMARY KEY,
    amount numeric(12,2) NOT NULL,
    risk_level text NOT NULL
);

INSERT INTO ops_app.orders VALUES (10, 500.00, 'LOW'), (20, 2000.00, 'HIGH');

CREATE VIEW ops_def.flagged_orders AS
SELECT order_id, amount
FROM ops_app.orders
WHERE risk_level = 'HIGH';

CREATE FUNCTION ops_action.process_flagged(
    context pgreact.activation_context,
    match ops_def.flagged_orders
) RETURNS void LANGUAGE SQL BEGIN ATOMIC END;

-- Deploy rule
WITH decl AS (
    SELECT pgreact.rule(
        name         => 'ops-flagged-rule',
        condition    => 'ops_def.flagged_orders'::regclass,
        semantic_key => 'order_id'::name,
        kind         => 'COMMAND',
        on_activate  => 'ops_action.process_flagged(pgreact.activation_context,ops_def.flagged_orders)'::regprocedure
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

-- Run cycle
SELECT pgreact.run('2026-08-18 13:00:00+00');

-- 3. Pause and Resume rule
SELECT pgreact.pause_rule('ops-flagged-rule');

DO $$
DECLARE
    rule_state text;
BEGIN
    SELECT state INTO rule_state
    FROM pgreact.rules
    WHERE name = 'ops-flagged-rule';

    IF rule_state <> 'PAUSED' THEN
        RAISE EXCEPTION 'Expected rule state PAUSED, got: %', rule_state;
    END IF;
END $$;

SELECT pgreact.resume_rule('ops-flagged-rule');

DO $$
DECLARE
    rule_state text;
BEGIN
    SELECT state INTO rule_state
    FROM pgreact.rules
    WHERE name = 'ops-flagged-rule';

    IF rule_state <> 'ACTIVE' THEN
        RAISE EXCEPTION 'Expected rule state ACTIVE, got: %', rule_state;
    END IF;
END $$;

-- 4. Sweep leases and Reconcile
SELECT pgreact.sweep_expired_leases(
    (SELECT rule_version_id FROM pgreact.rules WHERE name = 'ops-flagged-rule')
);

-- Prepare recovery and state-only reconciliation
SELECT pgreact.prepare_recovery();

SELECT pgreact.reconcile_rule(
    (SELECT rule_version_id FROM pgreact.rules WHERE name = 'ops-flagged-rule'),
    'STATE_ONLY'
);

-- 5. Health checks with structured details filtering
SELECT code, severity, target, field, message, hint, details, blocking
FROM pgreact.health
WHERE code = 'M32_SOURCE_DRIFT'
  AND details ->> 'source_code' = 'CONSEQUENCE_DRIFT';

-- 6. Cleanup
SELECT pgreact.pause_rule('ops-flagged-rule');
SELECT pgreact.remove('ops-flagged-rule');
DROP VIEW IF EXISTS ops_def.flagged_orders CASCADE;
DROP TABLE IF EXISTS ops_app.orders CASCADE;
DROP SCHEMA IF EXISTS ops_action CASCADE;
DROP SCHEMA IF EXISTS ops_def CASCADE;
DROP SCHEMA IF EXISTS ops_app CASCADE;
