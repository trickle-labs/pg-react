\set ON_ERROR_STOP on

SELECT extversion = '0.81.0' AS pinned_pg_trickle
FROM pg_extension WHERE extname = 'pg_trickle' \gset
\if :pinned_pg_trickle
\else
  \quit 1
\endif

SELECT encode(pgreact_internal.canonical_bigint_v1(42), 'hex') =
       '010100000008000000000000002a' AS codec_ok,
       encode(pgreact_internal.activation_digest(
           '00000000-0000-0000-0000-000000000000',
           pgreact_internal.canonical_bigint_v1(42)), 'hex') =
       '8307bd70b28711d35b356a1df7c9bb606b720b2be74025b0d2c7dab15f4fa23e' AS digest_ok,
       pgreact_internal.activation_uuid(pgreact_internal.activation_digest(
           '00000000-0000-0000-0000-000000000000',
           pgreact_internal.canonical_bigint_v1(42))) =
       '8307bd70-b287-81d3-9b35-6a1df7c9bb60'::uuid AS uuid_ok
\gset
\if :codec_ok
\else
  \quit 1
\endif
\if :digest_ok
\else
  \quit 1
\endif
\if :uuid_ok
\else
  \quit 1
\endif

CREATE SCHEMA app;
CREATE SCHEMA rule_def;
CREATE SCHEMA rule_action;

CREATE TABLE app.customers (
    id bigint PRIMARY KEY,
    risk_level text NOT NULL
);
CREATE TABLE app.orders (
    id bigint PRIMARY KEY,
    semantic_id bigint,
    customer_id bigint NOT NULL REFERENCES app.customers,
    amount numeric NOT NULL
);
CREATE TABLE app.manual_review_tasks (
    activation_id uuid PRIMARY KEY,
    order_id bigint NOT NULL,
    customer_id bigint NOT NULL,
    amount numeric NOT NULL
);
CREATE TABLE app.identity_fixture AS
SELECT pgreact_internal.canonical_bigint_v1(42) AS canonical_key,
       pgreact_internal.activation_digest(
           '00000000-0000-0000-0000-000000000000',
           pgreact_internal.canonical_bigint_v1(42)) AS digest,
       pgreact_internal.activation_uuid(pgreact_internal.activation_digest(
           '00000000-0000-0000-0000-000000000000',
           pgreact_internal.canonical_bigint_v1(42))) AS activation_id;

CREATE VIEW rule_def.high_value_risky_order AS
SELECT o.semantic_id AS order_id, o.customer_id, o.amount
FROM app.orders o
JOIN app.customers c ON c.id = o.customer_id
WHERE o.amount > 10000 AND c.risk_level = 'HIGH';

CREATE FUNCTION rule_action.activate_high_value_risky_order(
    context pgreact.activation_context,
    match rule_def.high_value_risky_order
)
RETURNS void
LANGUAGE plpgsql
SECURITY INVOKER
AS $$
BEGIN
    PERFORM pg_sleep(5);
    INSERT INTO app.manual_review_tasks (activation_id, order_id, customer_id, amount)
    VALUES ((context).activation_id, (match).order_id, (match).customer_id, (match).amount)
    ON CONFLICT (activation_id) DO UPDATE SET
        order_id = EXCLUDED.order_id,
        customer_id = EXCLUDED.customer_id,
        amount = EXCLUDED.amount;
END
$$;

SELECT pgreact_internal.register_reference_rule(
    'high_value_risky_order',
    'rule_def.high_value_risky_order'::regclass,
    'order_id',
    'rule_action.activate_high_value_risky_order(pgreact.activation_context,rule_def.high_value_risky_order)'::regprocedure,
    'SEED_CURRENT'
) AS rule_version_id \gset

SELECT match_name AS match_name
FROM pgreact_internal.rule_versions
WHERE rule_version_id = :'rule_version_id' \gset

INSERT INTO app.customers VALUES (1, 'HIGH');
INSERT INTO app.orders VALUES (1, 1001, 1, 20000);

SELECT pgreact_internal.begin_refresh(:'rule_version_id', 1);
BEGIN ISOLATION LEVEL READ COMMITTED;
SELECT pgreact_internal.refresh_rule(:'rule_version_id');
ROLLBACK;
SELECT count(*) = 0 AS rollback_clean
FROM pgreact_internal.lifecycle_events
WHERE rule_version_id = :'rule_version_id' \gset
\if :rollback_clean
\else
  \quit 1
\endif

BEGIN ISOLATION LEVEL READ COMMITTED;
SELECT pgreact_internal.refresh_rule(:'rule_version_id');
COMMIT;
SELECT pgreact_internal.clear_refresh_barrier(:'rule_version_id');
SELECT pgreact_internal.release_refresh_lock();

SELECT count(*) = 1 AS first_activation
FROM pgreact_internal.lifecycle_events
WHERE rule_version_id = :'rule_version_id' AND event_kind = 'ACTIVATE' \gset
\if :first_activation
\else
  \quit 1
\endif

BEGIN;
SELECT pgreact_internal.execute_one(:'rule_version_id', 'rollback-worker');
ROLLBACK;
SELECT count(*) = 0 AS consequence_rolled_back FROM app.manual_review_tasks \gset
\if :consequence_rolled_back
\else
  \quit 1
\endif

SELECT pgreact_internal.execute_one(:'rule_version_id', 'm0-test');
SELECT count(*) = 1 AS consequence_committed FROM app.manual_review_tasks \gset
SELECT count(*) = 1 AS execution_committed
FROM pgreact_internal.executions x
JOIN pgreact_internal.agenda a USING (episode_id)
WHERE a.rule_version_id = :'rule_version_id' AND a.state = 'COMPLETED' \gset
\if :consequence_committed
\else
  \quit 1
\endif
\if :execution_committed
\else
  \quit 1
\endif

-- Physical delete+insert with the same semantic key is one continuous activation.
DELETE FROM app.orders WHERE id = 1;
INSERT INTO app.orders VALUES (2, 1001, 1, 21000);
SELECT pgreact_internal.begin_refresh(:'rule_version_id', 2);
SELECT pgreact_internal.refresh_rule(:'rule_version_id');
SELECT pgreact_internal.clear_refresh_barrier(:'rule_version_id');
SELECT pgreact_internal.release_refresh_lock();
SELECT count(*) = 1 AS coalesced
FROM pgreact_internal.lifecycle_events
WHERE rule_version_id = :'rule_version_id' \gset
\if :coalesced
\else
  \quit 1
\endif

-- A true disappearance closes generation 1 without creating an episode.
DELETE FROM app.orders WHERE id = 2;
SELECT pgreact_internal.begin_refresh(:'rule_version_id', 3);
SELECT pgreact_internal.refresh_rule(:'rule_version_id');
SELECT pgreact_internal.clear_refresh_barrier(:'rule_version_id');
SELECT pgreact_internal.release_refresh_lock();
SELECT count(*) = 1 AS deactivated
FROM pgreact_internal.lifecycle_events
WHERE rule_version_id = :'rule_version_id' AND event_kind = 'DEACTIVATE' AND generation = 1 \gset
SELECT count(*) = 1 AS no_deactivation_episode
FROM pgreact_internal.agenda
WHERE rule_version_id = :'rule_version_id' \gset
\if :deactivated
\else
  \quit 1
\endif
\if :no_deactivation_episode
\else
  \quit 1
\endif

INSERT INTO app.orders VALUES (3, 1001, 1, 22000);
SELECT pgreact_internal.begin_refresh(:'rule_version_id', 4);
SELECT pgreact_internal.refresh_rule(:'rule_version_id');
SELECT pgreact_internal.clear_refresh_barrier(:'rule_version_id');
SELECT pgreact_internal.release_refresh_lock();
SELECT count(*) = 1 AS reactivated
FROM pgreact_internal.lifecycle_events
WHERE rule_version_id = :'rule_version_id' AND event_kind = 'ACTIVATE' AND generation = 2 \gset
\if :reactivated
\else
  \quit 1
\endif

-- STATE_ONLY repairs state, emits no work, and is idempotent.
CREATE TEMP TABLE expected_reconciled_state AS
SELECT semantic_key, canonical_key, canonical_key_digest, key_codec_version,
       active, generation, current_bindings, last_active_bindings
FROM pgreact_internal.activation_state
WHERE rule_version_id = :'rule_version_id' AND semantic_key = 1001;
UPDATE pgreact_internal.activation_state SET current_bindings = '{}'::jsonb
WHERE rule_version_id = :'rule_version_id' AND semantic_key = 1001;
SELECT count(*) AS events_before FROM pgreact_internal.lifecycle_events
WHERE rule_version_id = :'rule_version_id' \gset
SELECT pgreact_internal.reconcile_state_only(:'rule_version_id') = 1 AS repaired_once \gset
SELECT pgreact_internal.reconcile_state_only(:'rule_version_id') = 0 AS repaired_twice \gset
SELECT count(*) = :'events_before'::bigint AS reconciliation_no_events
FROM pgreact_internal.lifecycle_events WHERE rule_version_id = :'rule_version_id' \gset
SELECT NOT EXISTS (
    (SELECT * FROM expected_reconciled_state
     EXCEPT
     SELECT semantic_key, canonical_key, canonical_key_digest, key_codec_version,
            active, generation, current_bindings, last_active_bindings
     FROM pgreact_internal.activation_state
     WHERE rule_version_id = :'rule_version_id' AND semantic_key = 1001)
    UNION ALL
    (SELECT semantic_key, canonical_key, canonical_key_digest, key_codec_version,
            active, generation, current_bindings, last_active_bindings
     FROM pgreact_internal.activation_state
     WHERE rule_version_id = :'rule_version_id' AND semantic_key = 1001
     EXCEPT
     SELECT * FROM expected_reconciled_state)
) AS reconciliation_matches_differential \gset
\if :repaired_once
\else
  \quit 1
\endif
\if :repaired_twice
\else
  \quit 1
\endif
\if :reconciliation_no_events
\else
  \quit 1
\endif
\if :reconciliation_matches_differential
\else
  \quit 1
\endif

SELECT 'M0 SQL integration checks passed' AS result;
