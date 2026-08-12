\set ON_ERROR_STOP on

CREATE SCHEMA m13_drift;
CREATE TABLE m13_drift.source (id bigint PRIMARY KEY, enabled boolean NOT NULL);
CREATE VIEW m13_drift.condition AS
SELECT id FROM m13_drift.source WHERE enabled;
CREATE TABLE m13_drift.effects (id bigint PRIMARY KEY);
CREATE FUNCTION m13_drift.activate(candidate m13_drift.condition)
RETURNS void LANGUAGE SQL
AS $$ INSERT INTO m13_drift.effects VALUES (candidate.id) $$;
SELECT pgreact_api.author_rule(
    rule_name => 'drift-rule',
    condition => 'm13_drift.condition'::regclass,
    semantic_key => 'id',
    action_schema => 'm13_drift',
    on_activate => 'activate') AS version_id \gset
SELECT set_config('m13.drift_version', :'version_id', false);
CREATE OR REPLACE FUNCTION m13_drift.activate(candidate m13_drift.condition)
RETURNS void LANGUAGE SQL
AS $$ INSERT INTO m13_drift.effects VALUES (candidate.id) ON CONFLICT DO NOTHING $$;
INSERT INTO m13_drift.source VALUES (1, true);
SELECT pgreact_api.run('2032-01-01 00:00:00+00');

DO $$
DECLARE claimed record; failure text; actual jsonb;
BEGIN
    SELECT * INTO STRICT claimed FROM pgreact_api.claim('drift-worker', 1);
    BEGIN
        PERFORM pgreact_api.execute(
            claimed.episode_id, 'drift-worker', claimed.lease_token);
    EXCEPTION WHEN OTHERS THEN
        failure := SQLERRM;
    END;
    SELECT jsonb_build_object(
        'failure', failure,
        'job_state', (SELECT state FROM pgreact_internal.agenda
            WHERE episode_id = claimed.episode_id),
        'attempts', (SELECT COALESCE(jsonb_agg(to_jsonb(attempt)
            ORDER BY attempt.attempt_no), '[]'::jsonb)
            FROM pgreact_internal.executions attempt
            WHERE episode_id = claimed.episode_id),
        'effects', (SELECT COALESCE(jsonb_agg(to_jsonb(effect)
            ORDER BY id), '[]'::jsonb)
            FROM m13_drift.effects effect),
        'binding', (SELECT jsonb_build_object(
            'identity', function_identity,
            'digest_current', function_digest = sha256(convert_to(
                pg_get_functiondef(function_oid), 'UTF8')))
            FROM pgreact_internal.consequence_bindings
            WHERE rule_version_id = current_setting('m13.drift_version')::uuid
              AND event_kind = 'ACTIVATE'))
      INTO actual;
    IF actual IS DISTINCT FROM jsonb_build_object(
        'failure', format(
            'pg-react consequence or dispatcher drift for rule version %s',
            current_setting('m13.drift_version')),
        'job_state', 'LEASED', 'attempts', '[]'::jsonb,
        'effects', '[]'::jsonb,
        'binding', jsonb_build_object(
            'identity', 'm13_drift.activate(m13_drift.condition)',
            'digest_current', false)) THEN
        RAISE EXCEPTION 'M13 drift rejection changed: %', actual;
    END IF;
END
$$;

SELECT 'M13 immutable action drift gate passed';
