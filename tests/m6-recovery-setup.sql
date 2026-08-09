\set ON_ERROR_STOP on

CREATE EXTENSION pg_trickle;
CREATE EXTENSION pg_react;
CREATE SCHEMA m6_recovery;
CREATE TABLE m6_recovery.facts (id bigint PRIMARY KEY);
CREATE TABLE m6_recovery.effects (episode_id bigint PRIMARY KEY, fact_id bigint NOT NULL);
CREATE TABLE m6_recovery.control (rule_version_id uuid PRIMARY KEY, pending_batch_id uuid NOT NULL);
CREATE TABLE m6_recovery.snapshot (
    episodes jsonb NOT NULL,
    attempts jsonb NOT NULL,
    batches jsonb NOT NULL,
    effects jsonb NOT NULL
);
CREATE VIEW m6_recovery.active_fact AS SELECT id FROM m6_recovery.facts;
CREATE FUNCTION m6_recovery.apply_fact(
    context pgreact.activation_context, match m6_recovery.active_fact
) RETURNS void LANGUAGE SQL AS
'INSERT INTO m6_recovery.effects VALUES (($1).episode_id, ($2).id)';
SELECT pgreact.create_rule(
    name => 'm6-recovery', definition => 'm6_recovery.active_fact'::regclass,
    key_columns => ARRAY['id'], kind => 'COMMAND',
    on_activate => 'm6_recovery.apply_fact(pgreact.activation_context,m6_recovery.active_fact)'::regprocedure
) AS rule_version_id \gset
SELECT pgreact.declare_batch_safe(:'rule_version_id'::uuid, 'ACTIVATE');
INSERT INTO m6_recovery.facts VALUES (1), (2), (3), (4);
SELECT pgreact.begin_refresh(:'rule_version_id'::uuid, 6401);
BEGIN; SELECT pgreact.refresh_rule(:'rule_version_id'::uuid); COMMIT;
SELECT pgreact.clear_refresh_barrier(:'rule_version_id'::uuid);
SELECT pgreact.release_refresh_lock();
CREATE TEMP TABLE completed_claim AS
SELECT * FROM pgreact.claim_batch(:'rule_version_id'::uuid, 'ACTIVATE', 'm6-recovery-completed', 2, interval '120 seconds');
SELECT batch_id::text AS completed_batch_id FROM completed_claim ORDER BY item_order LIMIT 1 \gset
SELECT * FROM pgreact.execute_claimed_batch(:'completed_batch_id'::uuid, 'm6-recovery-completed');
CREATE TEMP TABLE pending_claim AS
SELECT * FROM pgreact.claim_batch(:'rule_version_id'::uuid, 'ACTIVATE', 'm6-recovery-pending', 2, interval '120 seconds');
SELECT batch_id::text AS pending_batch_id FROM pending_claim ORDER BY item_order LIMIT 1 \gset
INSERT INTO m6_recovery.control VALUES (:'rule_version_id'::uuid, :'pending_batch_id'::uuid);
INSERT INTO m6_recovery.snapshot
SELECT
    (SELECT jsonb_agg(to_jsonb(e) ORDER BY episode_id) FROM pgreact.episodes e),
    (SELECT COALESCE(jsonb_agg(to_jsonb(a) ORDER BY episode_id, attempt_no), '[]'::jsonb)
     FROM pgreact.attempts a),
    (SELECT jsonb_agg(to_jsonb(b) ORDER BY claimed_at, batch_id) FROM pgreact.batch_history() b),
    (SELECT jsonb_agg(to_jsonb(e) ORDER BY episode_id) FROM m6_recovery.effects e);

SELECT 'M6 restart and physical-recovery setup passed' AS result;
