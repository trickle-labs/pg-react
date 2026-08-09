\set ON_ERROR_STOP on

CREATE SCHEMA m1;
CREATE TABLE m1.facts (id bigint PRIMARY KEY, enabled boolean NOT NULL DEFAULT true);
CREATE TABLE m1.actions (activation_id uuid PRIMARY KEY, fact_id bigint NOT NULL);
CREATE VIEW m1.enabled_fact AS SELECT id FROM m1.facts WHERE enabled;
CREATE FUNCTION m1.activate(context pgreact.activation_context, match m1.enabled_fact)
RETURNS void LANGUAGE SQL AS $$
    INSERT INTO m1.actions VALUES ((context).activation_id, (match).id)
    ON CONFLICT (activation_id) DO NOTHING
$$;

SELECT count(*) = 1 AS validates
FROM pgreact.validate_rule('m1.enabled_fact'::regclass, ARRAY['id'],
    'm1.activate(pgreact.activation_context,m1.enabled_fact)'::regprocedure)
WHERE severity = 'INFO' \gset
\if :validates
\else
  \quit 1
\endif

CREATE TABLE m1.rls_fact (id bigint PRIMARY KEY);
ALTER TABLE m1.rls_fact ENABLE ROW LEVEL SECURITY;
CREATE VIEW m1.rls_view AS SELECT id FROM m1.rls_fact;
SELECT count(*) = 1 AS rls_rejected
FROM pgreact.validate_rule('m1.rls_view'::regclass, ARRAY['id'])
WHERE code = 'RLS_UNSUPPORTED' \gset
\if :rls_rejected
\else
  \quit 1
\endif

SELECT pgreact.create_rule(
    name => 'm1-enabled-fact',
    definition => 'm1.enabled_fact'::regclass,
    key_columns => ARRAY['id'],
    kind => 'COMMAND',
    on_activate => 'm1.activate(pgreact.activation_context,m1.enabled_fact)'::regprocedure
) AS rule_version_id \gset

SELECT pgreact.pause_rule('m1-enabled-fact');
SELECT state = 'PAUSED' AS paused FROM pgreact.rules WHERE rule_version_id = :'rule_version_id'::uuid \gset
\if :paused
\else
  \quit 1
\endif
SELECT pgreact.resume_rule('m1-enabled-fact');

INSERT INTO m1.facts VALUES (1);
SELECT pgreact.begin_refresh(:'rule_version_id'::uuid, 10001);
BEGIN ISOLATION LEVEL READ COMMITTED;
SELECT pgreact.refresh_rule(:'rule_version_id'::uuid);
COMMIT;
SELECT pgreact.clear_refresh_barrier(:'rule_version_id'::uuid);
SELECT pgreact.release_refresh_lock();

SELECT episode_id, lease_token
FROM pgreact.claim_episode(:'rule_version_id'::uuid, 'm1-test', 5) \gset
SELECT pgreact.execute_claimed_episode(:episode_id, 'm1-test', :'lease_token'::uuid) = 'COMPLETED' AS executed \gset
\if :executed
\else
  \quit 1
\endif
SELECT count(*) = 1 AS action_committed FROM m1.actions \gset
\if :action_committed
\else
  \quit 1
\endif

CREATE FUNCTION m1.fail(context pgreact.activation_context, match m1.enabled_fact)
RETURNS void LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'intentional M1 worker failure'; END $$;
SELECT pgreact.create_rule(
    name => 'm1-failing-command', definition => 'm1.enabled_fact'::regclass,
    key_columns => ARRAY['id'], on_activate => 'm1.fail(pgreact.activation_context,m1.enabled_fact)'::regprocedure
) AS failing_version_id \gset
INSERT INTO m1.facts VALUES (2);
SELECT pgreact.begin_refresh(:'failing_version_id'::uuid, 10003);
BEGIN ISOLATION LEVEL READ COMMITTED;
SELECT pgreact.refresh_rule(:'failing_version_id'::uuid);
COMMIT;
SELECT pgreact.clear_refresh_barrier(:'failing_version_id'::uuid);
SELECT pgreact.release_refresh_lock();
SELECT episode_id, lease_token FROM pgreact.claim_episode(:'failing_version_id'::uuid, 'm1-failure', 1) \gset
SELECT pgreact.execute_claimed_episode(:episode_id, 'm1-failure', :'lease_token'::uuid) = 'FAILED' AS failure_recorded \gset
\if :failure_recorded
\else
  \quit 1
\endif
SELECT pgreact.requeue_episode(:episode_id);
SELECT episode_id IS NOT NULL AS lease_reclaimed
FROM pgreact.claim_episode(:'failing_version_id'::uuid, 'm1-crash', 1) \gset
\if :lease_reclaimed
\else
  \quit 1
\endif
SELECT pg_sleep(1.1);
SELECT pgreact.sweep_expired_leases(:'failing_version_id'::uuid) = 1 AS expired_lease_recovered \gset
\if :expired_lease_recovered
\else
  \quit 1
\endif

CREATE VIEW m1.enabled_fact_v2 AS SELECT id FROM m1.facts WHERE enabled;
SELECT pgreact.create_rule(
    name => 'm1-constraint', kind => 'CONSTRAINT',
    definition => 'm1.enabled_fact'::regclass, key_columns => ARRAY['id']
) AS constraint_version_id \gset
SELECT pgreact.begin_refresh(:'constraint_version_id'::uuid, 10002);
BEGIN ISOLATION LEVEL READ COMMITTED;
SELECT pgreact.refresh_rule(:'constraint_version_id'::uuid);
COMMIT;
SELECT pgreact.clear_refresh_barrier(:'constraint_version_id'::uuid);
SELECT pgreact.release_refresh_lock();
SELECT count(*) >= 1 AS constraint_visible FROM pgreact.current_matches('m1-constraint') \gset
\if :constraint_visible
\else
  \quit 1
\endif

SELECT pgreact.pause_rule('m1-constraint');
SELECT pgreact.replace_rule(
    :'constraint_version_id'::uuid, 'm1.enabled_fact_v2'::regclass, ARRAY['id'], NULL, 'SEED_CURRENT'
) IS NOT NULL AS replaced \gset
\if :replaced
\else
  \quit 1
\endif
SELECT pgreact.pause_rule('m1-constraint');
SELECT pgreact.remove_rule((SELECT rule_version_id FROM pgreact.rules WHERE rule_name = 'm1-constraint'));
SELECT count(*) = 0 AS removed FROM pgreact.rules WHERE rule_name = 'm1-constraint' \gset
\if :removed
\else
  \quit 1
\endif

CREATE OR REPLACE VIEW m1.enabled_fact AS SELECT id FROM m1.facts WHERE enabled AND id > 0;
SELECT count(*) >= 1 AS drift_visible FROM pgreact.health_check() WHERE code = 'SOURCE_DRIFT' \gset
\if :drift_visible
\else
  \quit 1
\endif

CREATE VIEW m1.drift_fact AS SELECT id FROM m1.facts WHERE enabled;
CREATE FUNCTION m1.drift_activate(context pgreact.activation_context, match m1.drift_fact)
RETURNS void LANGUAGE plpgsql AS $$ BEGIN NULL; END $$;
SELECT pgreact.create_rule(
    name => 'm1-drift-command', definition => 'm1.drift_fact'::regclass,
    key_columns => ARRAY['id'], on_activate => 'm1.drift_activate(pgreact.activation_context,m1.drift_fact)'::regprocedure
) AS drift_version_id \gset
INSERT INTO m1.facts VALUES (3);
SELECT pgreact.begin_refresh(:'drift_version_id'::uuid, 10004);
BEGIN ISOLATION LEVEL READ COMMITTED;
SELECT pgreact.refresh_rule(:'drift_version_id'::uuid);
COMMIT;
SELECT pgreact.clear_refresh_barrier(:'drift_version_id'::uuid);
SELECT pgreact.release_refresh_lock();
SELECT episode_id, lease_token FROM pgreact.claim_episode(:'drift_version_id'::uuid, 'm1-drift', 5) \gset
CREATE OR REPLACE FUNCTION m1.drift_activate(context pgreact.activation_context, match m1.drift_fact)
RETURNS void LANGUAGE plpgsql AS $$ BEGIN PERFORM 1; END $$;
SELECT count(*) = 1 AS consequence_drift_visible FROM pgreact.health_check()
WHERE code = 'CONSEQUENCE_DRIFT' AND object_identity = :'drift_version_id' \gset
\if :consequence_drift_visible
\else
  \quit 1
\endif
SELECT set_config('m1.episode_id', :'episode_id', false);
SELECT set_config('m1.lease_token', :'lease_token', false);
DO $$
BEGIN
  PERFORM pgreact.execute_claimed_episode(current_setting('m1.episode_id')::bigint, 'm1-drift', current_setting('m1.lease_token')::uuid);
  RAISE EXCEPTION 'changed consequence unexpectedly executed';
EXCEPTION WHEN OTHERS THEN
  IF SQLERRM NOT LIKE 'pg-react consequence or dispatcher drift%' THEN RAISE; END IF;
END
$$;
ALTER VIEW m1.drift_fact RENAME COLUMN id TO fact_id;
SELECT count(*) = 1 AS source_signature_drift_visible FROM pgreact.health_check()
WHERE code = 'SOURCE_DRIFT' AND severity = 'ERROR' AND object_identity = :'drift_version_id' \gset
\if :source_signature_drift_visible
\else
  \quit 1
\endif
DO $$
BEGIN
  PERFORM pgreact.execute_claimed_episode(current_setting('m1.episode_id')::bigint, 'm1-drift', current_setting('m1.lease_token')::uuid);
  RAISE EXCEPTION 'source signature drift unexpectedly executed';
EXCEPTION WHEN OTHERS THEN
  IF SQLERRM NOT LIKE 'pg-react source row signature drift%' THEN RAISE; END IF;
END
$$;

CREATE ROLE m1_author;
CREATE ROLE m1_intruder;
GRANT USAGE ON SCHEMA pgreact TO m1_author, m1_intruder;
GRANT USAGE ON SCHEMA pgtrickle TO m1_author;
GRANT ALL ON ALL TABLES IN SCHEMA pgtrickle TO m1_author;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA pgtrickle TO m1_author;
GRANT USAGE, CREATE ON SCHEMA m1 TO m1_author;
GRANT SELECT ON m1.facts TO m1_author;
SET SESSION AUTHORIZATION m1_author;
CREATE VIEW m1.author_fact AS SELECT id FROM m1.facts;
CREATE FUNCTION m1.author_activate(context pgreact.activation_context, match m1.author_fact)
RETURNS void LANGUAGE plpgsql AS $$ BEGIN NULL; END $$;
SELECT pgreact.create_rule('m1-author-rule', 'm1.author_fact'::regclass, ARRAY['id'],
    on_activate => 'm1.author_activate(pgreact.activation_context,m1.author_fact)'::regprocedure) AS author_version_id \gset
RESET SESSION AUTHORIZATION;
SELECT NOT has_schema_privilege('m1_author', 'pgreact_internal', 'USAGE')
   AND NOT has_table_privilege('m1_author', 'pgreact_internal.rules', 'SELECT') AS private_catalog_hidden \gset
\if :private_catalog_hidden
\else
  \quit 1
\endif
SET SESSION AUTHORIZATION m1_intruder;
DO $$
BEGIN
  PERFORM pgreact.pause_rule((SELECT rule_version_id FROM pgreact.rules WHERE rule_name = 'm1-author-rule'));
  RAISE EXCEPTION 'intruder unexpectedly managed an author rule';
EXCEPTION WHEN OTHERS THEN
  IF SQLERRM NOT LIKE 'only the rule owner%' THEN RAISE; END IF;
END
$$;
RESET SESSION AUTHORIZATION;

SELECT 'M1 public API and worker checks passed' AS result;
