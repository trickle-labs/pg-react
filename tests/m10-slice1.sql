\set ON_ERROR_STOP on
\o /dev/null
SET client_min_messages = error;

CREATE SCHEMA m10_slice1;
CREATE TYPE m10_slice1.fact_row AS (id bigint);
CREATE TABLE m10_slice1.groups (id bigint PRIMARY KEY);
CREATE TABLE m10_slice1.items (item_id bigint PRIMARY KEY, id bigint NOT NULL);
CREATE VIEW m10_slice1.group_source AS SELECT id FROM m10_slice1.groups;
CREATE VIEW m10_slice1.item_source AS SELECT id FROM m10_slice1.items;

SELECT pgreact.create_derived_relation(
    'm10_slice1.alert', 'm10_slice1.fact_row'::regtype, ARRAY['id']);
CREATE VIEW m10_slice1.observe_alert AS SELECT id FROM m10_slice1.alert;
SELECT pgreact.create_rule(
    name => 'm10.observe_alert', definition => 'm10_slice1.observe_alert'::regclass,
    key_columns => ARRAY['id'], kind => 'CONSTRAINT') AS observer_rule_version_id \gset
SELECT set_config('m10.slice1_observer', :'observer_rule_version_id', false);

INSERT INTO m10_slice1.groups VALUES (7), (8);
INSERT INTO m10_slice1.items VALUES (1, 7);

CREATE TABLE m10_slice1.manifest AS
SELECT jsonb_build_object(
    'format_version', 1, 'pack', 'm10-slice1-pack', 'version', '1', 'owner', 'owner',
    'rules', jsonb_build_array(jsonb_build_object(
        'name', 'm10.slice1.base', 'definition', 'm10.group_source',
        'key', 'id', 'kind', 'CONSTRAINT', 'depends_on', '[]'::jsonb)),
    'remove', '[]'::jsonb,
    'derived_relations', '[]'::jsonb, 'derivations', '[]'::jsonb,
    'remove_derivations', '[]'::jsonb, 'remove_derived_relations', '[]'::jsonb,
    'programs', jsonb_build_array(jsonb_build_object(
        'name', 'm10.slice1', 'version', 1, 'max_iterations', 4, 'max_facts', 2,
        'rules', jsonb_build_array(jsonb_build_object(
            'name', 'm10.groups_to_alert', 'definition', 'm10.group_source',
            'key', 'id', 'target', 'm10.alert', 'version', 1, 'inputs', '[]'::jsonb,
            'aggregate_input', jsonb_build_object(
                'relation', 'm10.item_source', 'key', 'id',
                'comparison', '>=', 'threshold', 2))))),
    'remove_programs', '[]'::jsonb) AS definition,
    jsonb_build_object(
        'roles', jsonb_build_object('owner', current_user),
        'objects', jsonb_build_object(
            'm10.group_source', 'm10_slice1.group_source',
            'm10.item_source', 'm10_slice1.item_source',
            'm10.alert', 'm10_slice1.alert')) AS mappings;

SELECT min(plan_digest) AS plan_digest
FROM pgreact.preview_pack(
    (SELECT definition FROM m10_slice1.manifest),
    (SELECT mappings FROM m10_slice1.manifest)) \gset
SELECT pgreact.deploy_pack(
    (SELECT definition FROM m10_slice1.manifest), :'plan_digest',
    (SELECT mappings FROM m10_slice1.manifest));
SELECT program_version_id FROM pgreact.derivation_programs
WHERE program_name = 'm10.slice1' AND state = 'ACTIVE' \gset
SELECT set_config('m10.slice1_program', :'program_version_id', false);

CREATE FUNCTION m10_slice1.state()
RETURNS jsonb
LANGUAGE SQL
STABLE
AS $$
SELECT jsonb_build_object(
    'frontier', (SELECT frontier FROM pgreact.derivation_programs
                 WHERE program_version_id = current_setting('m10.slice1_program')::uuid),
    'facts', COALESCE((
        SELECT jsonb_agg(jsonb_build_object('id', semantic_key, 'fact', fact)
                         ORDER BY semantic_key)
        FROM pgreact.derived_facts WHERE relation_name = 'm10_slice1.alert'), '[]'::jsonb),
    'evidence', COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
            'key', group_key, 'count', exact_count, 'comparison', comparison,
            'threshold', threshold, 'source_stratum', source_stratum,
            'target_stratum', target_stratum, 'lower_frontier', lower_frontier)
            ORDER BY group_key)
        FROM pgreact.aggregate_dependency_evidence
        WHERE program_version_id = current_setting('m10.slice1_program')::uuid), '[]'::jsonb),
    'events', COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
            'event', event_kind, 'key',
            (COALESCE(new_bindings, old_bindings) ->> 'id')::bigint)
            ORDER BY event_id)
        FROM pgreact_internal.lifecycle_events
        WHERE rule_version_id = current_setting('m10.slice1_observer')::uuid), '[]'::jsonb));
$$;

CREATE FUNCTION m10_slice1.assert_state(expected jsonb)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    IF m10_slice1.state() IS DISTINCT FROM expected THEN
        RAISE EXCEPTION 'M10 state mismatch: expected %, got %', expected, m10_slice1.state();
    END IF;
END
$$;

SELECT m10_slice1.assert_state(jsonb_build_object(
    'frontier', 1, 'facts', '[]'::jsonb,
    'evidence', jsonb_build_array(
        jsonb_build_object('key', 7, 'count', 1, 'comparison', '>=', 'threshold', 2,
            'source_stratum', 0, 'target_stratum', 1, 'lower_frontier', 1),
        jsonb_build_object('key', 8, 'count', 0, 'comparison', '>=', 'threshold', 2,
            'source_stratum', 0, 'target_stratum', 1, 'lower_frontier', 1)),
    'events', '[]'::jsonb));

INSERT INTO m10_slice1.items VALUES (2, 7);
SELECT pgreact.refresh_derivation_program(current_setting('m10.slice1_program')::uuid) = 2 AS crossed \gset
SELECT pgreact.refresh_rule(current_setting('m10.slice1_observer')::uuid);
SELECT m10_slice1.assert_state(jsonb_build_object(
    'frontier', 2,
    'facts', jsonb_build_array(jsonb_build_object('id', 7, 'fact', jsonb_build_object('id', 7))),
    'evidence', jsonb_build_array(
        jsonb_build_object('key', 7, 'count', 2, 'comparison', '>=', 'threshold', 2,
            'source_stratum', 0, 'target_stratum', 1, 'lower_frontier', 2),
        jsonb_build_object('key', 8, 'count', 0, 'comparison', '>=', 'threshold', 2,
            'source_stratum', 0, 'target_stratum', 1, 'lower_frontier', 1)),
    'events', jsonb_build_array(jsonb_build_object('event', 'ACTIVATE', 'key', 7))));

DO $$
DECLARE actual jsonb; expected jsonb;
BEGIN
    SELECT pgreact.explain_recursive_fact(
        current_setting('m10.slice1_program')::uuid,
        (SELECT relation_version_id FROM pgreact.derived_relations
         WHERE relation_name = 'm10_slice1.alert' AND state = 'ACTIVE'), 7)
    INTO actual;
    SELECT jsonb_build_object(
        'program', 'm10.slice1@1', 'frontier', 2,
        'relation', 'm10_slice1.alert@1', 'fact', jsonb_build_object('id', 7),
        'proof', jsonb_build_object(
            'relation', 'm10_slice1.alert@1', 'fact', jsonb_build_object('id', 7),
            'supports', jsonb_build_array(jsonb_build_object(
                'rule', 'm10.groups_to_alert@1',
                'source_binding', jsonb_build_object('id', 7),
                'inputs', '[]'::jsonb, 'negative_checks', '[]'::jsonb,
                'aggregate_conditions', jsonb_build_array(jsonb_build_object(
                    'evidence_id', evidence_id, 'relation', 'm10_slice1.item_source',
                    'group_key', 7, 'count', 2, 'comparison', '>=', 'threshold', 2,
                    'source_stratum', 0, 'lower_frontier', 2))))))
    INTO expected
    FROM pgreact.aggregate_dependency_evidence
    WHERE program_version_id = current_setting('m10.slice1_program')::uuid
      AND group_key = 7;
    IF actual IS DISTINCT FROM expected THEN
        RAISE EXCEPTION 'M10 aggregate explanation changed: expected %, got %',
            expected, actual;
    END IF;
END
$$;

INSERT INTO m10_slice1.items VALUES (3, 7);
SELECT pgreact.refresh_derivation_program(current_setting('m10.slice1_program')::uuid) = 3 AS stays_true \gset
SELECT pgreact.refresh_rule(current_setting('m10.slice1_observer')::uuid);
SELECT m10_slice1.assert_state(jsonb_build_object(
    'frontier', 3,
    'facts', jsonb_build_array(jsonb_build_object('id', 7, 'fact', jsonb_build_object('id', 7))),
    'evidence', jsonb_build_array(
        jsonb_build_object('key', 7, 'count', 3, 'comparison', '>=', 'threshold', 2,
            'source_stratum', 0, 'target_stratum', 1, 'lower_frontier', 3),
        jsonb_build_object('key', 8, 'count', 0, 'comparison', '>=', 'threshold', 2,
            'source_stratum', 0, 'target_stratum', 1, 'lower_frontier', 1)),
    'events', jsonb_build_array(jsonb_build_object('event', 'ACTIVATE', 'key', 7))));

DELETE FROM m10_slice1.items WHERE item_id = 3;
SELECT pgreact.refresh_derivation_program(current_setting('m10.slice1_program')::uuid) = 4 AS remains_true \gset
SELECT pgreact.refresh_rule(current_setting('m10.slice1_observer')::uuid);
DELETE FROM m10_slice1.items WHERE item_id = 2;
SELECT pgreact.refresh_derivation_program(current_setting('m10.slice1_program')::uuid) = 5 AS recrossed \gset
SELECT pgreact.refresh_rule(current_setting('m10.slice1_observer')::uuid);
SELECT m10_slice1.assert_state(jsonb_build_object(
    'frontier', 5, 'facts', '[]'::jsonb,
    'evidence', jsonb_build_array(
        jsonb_build_object('key', 7, 'count', 1, 'comparison', '>=', 'threshold', 2,
            'source_stratum', 0, 'target_stratum', 1, 'lower_frontier', 5),
        jsonb_build_object('key', 8, 'count', 0, 'comparison', '>=', 'threshold', 2,
            'source_stratum', 0, 'target_stratum', 1, 'lower_frontier', 1)),
    'events', jsonb_build_array(
        jsonb_build_object('event', 'ACTIVATE', 'key', 7),
        jsonb_build_object('event', 'DEACTIVATE', 'key', 7))));

\o
SELECT 'M10 slice 1 aggregate threshold gate passed';
