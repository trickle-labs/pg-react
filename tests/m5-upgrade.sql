\set ON_ERROR_STOP on

CREATE EXTENSION pg_trickle;
CREATE EXTENSION pg_react VERSION '0.1.1';
CREATE SCHEMA m5_upgrade;
CREATE TABLE m5_upgrade.facts (id bigint PRIMARY KEY);
CREATE VIEW m5_upgrade.active_fact AS SELECT id FROM m5_upgrade.facts;
CREATE FUNCTION m5_upgrade.activate(context pgreact.activation_context, match m5_upgrade.active_fact)
RETURNS void LANGUAGE plpgsql AS 'BEGIN NULL; END';
SELECT pgreact.create_rule(
    'legacy-rule', 'm5_upgrade.active_fact'::regclass, ARRAY['id'], 'COMMAND',
    'm5_upgrade.activate(pgreact.activation_context,m5_upgrade.active_fact)'::regprocedure
);

ALTER EXTENSION pg_react UPDATE TO '0.2.0';

DO $$
DECLARE
    manifest jsonb := '{
        "format_version": 1,
        "pack": "upgrade-pack",
        "version": "1",
        "owner": "postgres",
        "rules": [{
            "name": "packed-rule",
            "definition": "m5_upgrade.active_fact",
            "key": "id",
            "kind": "CONSTRAINT",
            "depends_on": []
        }],
        "remove": []
    }'::jsonb;
    digest text;
    actual jsonb;
    expected jsonb;
BEGIN
    IF (SELECT extversion FROM pg_extension WHERE extname = 'pg_react') <> '0.2.0'
       OR NOT pgreact.worker_protocol_compatible(1) THEN
        RAISE EXCEPTION 'upgrade changed extension or worker protocol compatibility';
    END IF;
    SELECT jsonb_agg(jsonb_build_object('rule', rule_name, 'state', state) ORDER BY rule_name)
      INTO actual FROM pgreact.rule_status();
    IF actual IS DISTINCT FROM '[{"rule": "legacy-rule", "state": "ACTIVE"}]'::jsonb THEN
        RAISE EXCEPTION 'upgrade did not preserve the exact legacy rule: %', actual;
    END IF;
    SELECT min(plan_digest) INTO digest FROM pgreact.preview_pack(manifest);
    PERFORM pgreact.deploy_pack(manifest, digest);
    SELECT jsonb_agg(jsonb_build_object(
        'version', version,
        'status', status,
        'actions', (
            SELECT jsonb_agg(value - 'old_rule_version_id' - 'new_rule_version_id' ORDER BY value ->> 'order')
            FROM jsonb_array_elements(actions) AS a(value)
        )
    ) ORDER BY deployed_at) INTO actual
    FROM pgreact.pack_history('upgrade-pack');
    expected := '[{
        "version": "1",
        "status": "ACTIVE",
        "actions": [{
            "order": 1,
            "action": "ADD",
            "rule": "packed-rule",
            "old_work_policy": "DRAIN_OLD",
            "details": {"source": "m5_upgrade.active_fact", "dependencies": []}
        }]
    }]'::jsonb;
    IF actual IS DISTINCT FROM expected THEN
        RAISE EXCEPTION 'upgraded pack history changed: %', actual;
    END IF;
END
$$;

SELECT 'M5 direct 0.1.1 to 0.2.0 upgrade checks passed' AS result;
