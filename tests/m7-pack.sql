\set ON_ERROR_STOP on

CREATE SCHEMA pack_clinical;
CREATE TYPE pack_clinical.patient_fever_row AS (patient_id bigint);
CREATE TABLE pack_clinical.temperatures (
    patient_id bigint PRIMARY KEY,
    temperature_c numeric(4,1) NOT NULL
);
CREATE VIEW pack_clinical.fever_from_temperature AS
SELECT patient_id, temperature_c
FROM pack_clinical.temperatures WHERE temperature_c >= 38.0;

CREATE TEMP TABLE manifests (version text PRIMARY KEY, definition jsonb, mappings jsonb);
INSERT INTO manifests VALUES (
    '1',
    jsonb_build_object(
        'format_version', 1, 'pack', 'clinical-pack', 'version', '1',
        'owner', 'owner', 'rules', '[]'::jsonb, 'remove', '[]'::jsonb,
        'derived_relations', jsonb_build_array(jsonb_build_object(
            'name', 'clinical.patient_fever',
            'row_type', 'clinical.patient_fever_row',
            'key', 'patient_id', 'version', 1)),
        'derivations', '[]'::jsonb,
        'remove_derivations', '[]'::jsonb,
        'remove_derived_relations', '[]'::jsonb
    ),
    jsonb_build_object(
        'roles', jsonb_build_object('owner', current_user),
        'objects', jsonb_build_object(
            'clinical.patient_fever', 'pack_clinical.patient_fever',
            'clinical.patient_fever_row', 'pack_clinical.patient_fever_row',
            'clinical.fever_from_temperature', 'pack_clinical.fever_from_temperature'))
);

DO $$
DECLARE actual text[];
BEGIN
    SELECT array_agg(code ORDER BY code) INTO actual FROM pgreact.validate_pack(
        (SELECT definition FROM manifests WHERE version = '1'),
        (SELECT mappings FROM manifests WHERE version = '1'));
    IF actual IS DISTINCT FROM ARRAY['OK', 'OK'] THEN
        RAISE EXCEPTION 'M7 relation-pack validation changed: %', actual;
    END IF;
    SELECT array_agg(format('%s|%s|%s|%s', action_order, action, rule_name, dependencies)
                     ORDER BY action_order) INTO actual
    FROM pgreact.preview_pack(
        (SELECT definition FROM manifests WHERE version = '1'),
        (SELECT mappings FROM manifests WHERE version = '1'));
    IF actual IS DISTINCT FROM ARRAY['1|ADD|clinical.patient_fever|{}'] THEN
        RAISE EXCEPTION 'M7 relation-pack preview changed: %', actual;
    END IF;
END $$;
SELECT min(plan_digest) AS plan_digest FROM pgreact.preview_pack(
    (SELECT definition FROM manifests WHERE version = '1'),
    (SELECT mappings FROM manifests WHERE version = '1')) \gset
SELECT pgreact.deploy_pack(
    (SELECT definition FROM manifests WHERE version = '1'), :'plan_digest',
    (SELECT mappings FROM manifests WHERE version = '1'));

CREATE VIEW pack_clinical.observe_patient_fever AS
SELECT patient_id FROM pack_clinical.patient_fever;

INSERT INTO manifests
SELECT '2',
    jsonb_set(jsonb_set(jsonb_set(definition, '{version}', '"2"'), '{derivations}',
        jsonb_build_array(jsonb_build_object(
            'name', 'clinical.fever_from_temperature',
            'definition', 'clinical.fever_from_temperature',
            'key', 'patient_id', 'target', 'clinical.patient_fever',
            'version', 1, 'depends_on', jsonb_build_array('clinical.patient_fever')))),
        '{rules}', jsonb_build_array(jsonb_build_object(
            'name', 'clinical.observe_patient_fever',
            'definition', 'pack_clinical.observe_patient_fever',
            'key', 'patient_id', 'kind', 'CONSTRAINT',
            'depends_on', jsonb_build_array('clinical.fever_from_temperature')))),
    mappings || jsonb_build_object('objects', mappings -> 'objects' || jsonb_build_object(
        'pack_clinical.observe_patient_fever', 'pack_clinical.observe_patient_fever'))
FROM manifests WHERE version = '1';

DO $$
DECLARE actual text[];
BEGIN
    SELECT array_agg(code ORDER BY code) INTO actual FROM pgreact.validate_pack(
        (SELECT definition FROM manifests WHERE version = '2'),
        (SELECT mappings FROM manifests WHERE version = '2'));
    IF actual IS DISTINCT FROM ARRAY['OK', 'OK'] THEN
        RAISE EXCEPTION 'M7 mixed-pack validation changed: %', actual;
    END IF;
    SELECT array_agg(format('%s|%s|%s|%s', action_order, action, rule_name, dependencies)
                     ORDER BY action_order) INTO actual
    FROM pgreact.preview_pack(
        (SELECT definition FROM manifests WHERE version = '2'),
        (SELECT mappings FROM manifests WHERE version = '2'));
    IF actual IS DISTINCT FROM ARRAY[
        '1|KEEP|clinical.patient_fever|{}',
        '2|ADD|clinical.fever_from_temperature|{clinical.patient_fever}',
        '3|ADD|clinical.observe_patient_fever|{}'
    ] THEN
        RAISE EXCEPTION 'M7 mixed-pack preview changed: %', actual;
    END IF;
END $$;
SELECT min(plan_digest) AS plan_digest FROM pgreact.preview_pack(
    (SELECT definition FROM manifests WHERE version = '2'),
    (SELECT mappings FROM manifests WHERE version = '2')) \gset
SELECT pgreact.deploy_pack(
    (SELECT definition FROM manifests WHERE version = '2'), :'plan_digest',
    (SELECT mappings FROM manifests WHERE version = '2'));

DO $$
DECLARE actual jsonb; expected jsonb;
BEGIN
    SELECT jsonb_build_object(
        'relations', explanation -> 'derived_relations',
        'derivations', explanation -> 'derivations',
        'members', (SELECT jsonb_agg(jsonb_build_object(
            'rule', member.value ->> 'rule', 'state', member.value ->> 'state',
            'dependencies', member.value -> 'dependencies') ORDER BY member.value ->> 'rule')
            FROM jsonb_array_elements(explanation -> 'members') AS member(value)))
    INTO actual FROM (SELECT pgreact.explain_pack('clinical-pack') explanation) q;
    expected := jsonb_build_object(
        'relations', jsonb_build_array(jsonb_build_object(
            'name', 'clinical.patient_fever', 'version', 1, 'state', 'ACTIVE',
            'public_view', 'pack_clinical.patient_fever',
            'relation_version_id', (SELECT relation_version_id
                FROM pgreact.derived_relations WHERE relation_name = 'pack_clinical.patient_fever'))),
        'derivations', jsonb_build_array(jsonb_build_object(
            'name', 'clinical.fever_from_temperature', 'version', 1,
            'state', 'ACTIVE', 'target', 'clinical.patient_fever',
            'dependencies', jsonb_build_array('clinical.patient_fever'),
            'active_supports', 0,
            'rule_version_id', (SELECT rule_version_id FROM pgreact.rules
                WHERE rule_name = 'clinical.fever_from_temperature'))),
        'members', jsonb_build_array(jsonb_build_object(
            'rule', 'clinical.observe_patient_fever', 'state', 'ACTIVE',
            'dependencies', '[]'::jsonb)));
    IF actual IS DISTINCT FROM expected THEN
        RAISE EXCEPTION 'M7 pack explanation changed: %', actual;
    END IF;
END $$;

INSERT INTO pack_clinical.temperatures VALUES (42, 39.2);
SELECT pgreact.refresh_derived_relation((SELECT relation_version_id
    FROM pgreact.derived_relations
    WHERE relation_name = 'pack_clinical.patient_fever' AND state = 'ACTIVE'));
SELECT pgreact.refresh_rule((SELECT rule_version_id FROM pgreact.rules
    WHERE rule_name = 'clinical.observe_patient_fever'));

DO $$
DECLARE actual jsonb;
BEGIN
    SELECT jsonb_build_object(
        'facts', (SELECT jsonb_agg(jsonb_build_object(
            'fact', fact, 'support_count', support_count) ORDER BY semantic_key)
            FROM pgreact.derived_facts WHERE relation_name = 'pack_clinical.patient_fever'),
        'supports', (SELECT jsonb_agg(jsonb_build_object(
            'rule', rule_name || '@' || rule_version,
            'generation', activation_generation, 'active', active,
            'source_binding', source_binding) ORDER BY rule_name, rule_version)
            FROM pgreact.support_history WHERE relation_name = 'pack_clinical.patient_fever'),
        'events', (SELECT jsonb_agg(jsonb_build_object(
            'event', e.event_kind, 'generation', e.generation) ORDER BY e.event_id)
            FROM pgreact_internal.lifecycle_events e JOIN pgreact.rules r USING (rule_version_id)
            WHERE r.rule_name = 'clinical.observe_patient_fever')
    ) INTO actual;
    IF actual IS DISTINCT FROM jsonb_build_object(
        'facts', jsonb_build_array(jsonb_build_object(
            'fact', jsonb_build_object('patient_id', 42), 'support_count', 1)),
        'supports', jsonb_build_array(jsonb_build_object(
            'rule', 'clinical.fever_from_temperature@1', 'generation', 1,
            'active', true, 'source_binding', jsonb_build_object(
                'patient_id', 42, 'temperature_c', 39.2))),
        'events', jsonb_build_array(jsonb_build_object(
            'event', 'ACTIVATE', 'generation', 1))) THEN
        RAISE EXCEPTION 'M7 deployed pack output changed: %', actual;
    END IF;
END $$;

CREATE VIEW pack_clinical.fever_from_temperature_v2 AS
SELECT patient_id, temperature_c
FROM pack_clinical.temperatures WHERE temperature_c >= 38.0;
INSERT INTO manifests
SELECT '3',
       jsonb_set(jsonb_set(definition, '{version}', '"3"'), '{derivations,0}',
           (definition -> 'derivations' -> 0) || jsonb_build_object(
               'definition', 'clinical.fever_from_temperature_v2', 'version', 2)),
       mappings || jsonb_build_object('objects', mappings -> 'objects' || jsonb_build_object(
           'clinical.fever_from_temperature_v2', 'pack_clinical.fever_from_temperature_v2'))
FROM manifests WHERE version = '2';

SELECT min(plan_digest) AS failed_digest FROM pgreact.preview_pack(
    (SELECT definition FROM manifests WHERE version = '3'),
    (SELECT mappings FROM manifests WHERE version = '3')) \gset
SELECT set_config('m7.failed_digest', :'failed_digest', false);
DO $$
BEGIN
    BEGIN
        PERFORM set_config('pgreact.test_fail_pack_phase', 'derived', true);
        PERFORM pgreact.deploy_pack(
            (SELECT definition FROM manifests WHERE version = '3'),
            current_setting('m7.failed_digest'),
            (SELECT mappings FROM manifests WHERE version = '3'));
        RAISE EXCEPTION 'injected derived deployment unexpectedly succeeded';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'injected rule-pack failure after derived phase' THEN RAISE; END IF;
    END;
END $$;

DO $$
DECLARE actual jsonb;
BEGIN
    SELECT jsonb_build_object(
        'active_pack', (SELECT version FROM pgreact.pack_history('clinical-pack')
                        WHERE status = 'ACTIVE'),
        'active_derivation', (SELECT d.version
            FROM pgreact_internal.derivation_rule_versions d
            JOIN pgreact_internal.rule_versions v USING (rule_version_id)
            JOIN pgreact_internal.rules r ON r.rule_id = d.rule_id
            WHERE r.rule_name = 'clinical.fever_from_temperature' AND v.state = 'ACTIVE'),
        'facts', (SELECT jsonb_agg(jsonb_build_object(
            'fact', fact, 'support_count', support_count))
            FROM pgreact.derived_facts WHERE relation_name = 'pack_clinical.patient_fever')
    ) INTO actual;
    IF actual IS DISTINCT FROM jsonb_build_object(
        'active_pack', '2', 'active_derivation', 1,
        'facts', jsonb_build_array(jsonb_build_object(
            'fact', jsonb_build_object('patient_id', 42), 'support_count', 1))) THEN
        RAISE EXCEPTION 'derived deployment rollback changed state: %', actual;
    END IF;
END $$;

SELECT min(plan_digest) AS stale_digest FROM pgreact.preview_pack(
    (SELECT definition FROM manifests WHERE version = '3'),
    (SELECT mappings FROM manifests WHERE version = '3')) \gset
CREATE OR REPLACE VIEW pack_clinical.fever_from_temperature_v2 AS
SELECT patient_id, temperature_c
FROM pack_clinical.temperatures WHERE temperature_c >= 38.0 AND patient_id > 0;
SELECT set_config('m7.stale_digest', :'stale_digest', false);
DO $$
BEGIN
    BEGIN
        PERFORM pgreact.deploy_pack(
            (SELECT definition FROM manifests WHERE version = '3'),
            current_setting('m7.stale_digest'),
            (SELECT mappings FROM manifests WHERE version = '3'));
        RAISE EXCEPTION 'stale M7 preview unexpectedly deployed';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'rule-pack preview is stale' THEN RAISE; END IF;
    END;
END $$;

SELECT min(plan_digest) AS plan_digest FROM pgreact.preview_pack(
    (SELECT definition FROM manifests WHERE version = '3'),
    (SELECT mappings FROM manifests WHERE version = '3')) \gset
SELECT pgreact.deploy_pack(
    (SELECT definition FROM manifests WHERE version = '3'), :'plan_digest',
    (SELECT mappings FROM manifests WHERE version = '3'));

DO $$
DECLARE actual jsonb;
BEGIN
    SELECT jsonb_build_object(
        'fact', (SELECT jsonb_build_object('fact', fact, 'support_count', support_count)
                 FROM pgreact.derived_facts WHERE relation_name = 'pack_clinical.patient_fever'),
        'supports', (SELECT jsonb_agg(jsonb_build_object(
            'version', rule_version, 'active', active, 'generation', activation_generation)
            ORDER BY rule_version) FROM pgreact.support_history
            WHERE relation_name = 'pack_clinical.patient_fever'),
        'actions', (SELECT jsonb_agg(jsonb_build_object(
            'kind', COALESCE(action_item.value -> 'details' ->> 'object_kind', 'STANDARD'),
            'action', action_item.value ->> 'action', 'name', action_item.value ->> 'rule')
            ORDER BY action_item.value ->> 'rule')
            FROM pgreact.pack_history('clinical-pack') h,
                 jsonb_array_elements(h.actions) AS action_item(value)
            WHERE h.version = '3')
    ) INTO actual;
    IF actual IS DISTINCT FROM jsonb_build_object(
        'fact', jsonb_build_object(
            'fact', jsonb_build_object('patient_id', 42), 'support_count', 1),
        'supports', jsonb_build_array(
            jsonb_build_object('version', 1, 'active', false, 'generation', 1),
            jsonb_build_object('version', 2, 'active', true, 'generation', 1)),
        'actions', jsonb_build_array(
            jsonb_build_object('kind', 'DERIVATION', 'action', 'REPLACE',
                               'name', 'clinical.fever_from_temperature'),
            jsonb_build_object('kind', 'STANDARD', 'action', 'REPLACE',
                               'name', 'clinical.observe_patient_fever'),
            jsonb_build_object('kind', 'DERIVED_RELATION', 'action', 'KEEP',
                               'name', 'clinical.patient_fever'))) THEN
        RAISE EXCEPTION 'M7 replacement output changed: %', actual;
    END IF;
END $$;

INSERT INTO manifests
SELECT '4', jsonb_build_object(
        'format_version', 1, 'pack', 'clinical-pack', 'version', '4',
        'owner', 'owner', 'rules', '[]'::jsonb,
        'remove', jsonb_build_array(jsonb_build_object(
            'name', 'clinical.observe_patient_fever', 'old_work_policy', 'CANCEL_OLD')),
        'derived_relations', '[]'::jsonb, 'derivations', '[]'::jsonb,
        'remove_derivations', jsonb_build_array(jsonb_build_object(
            'name', 'clinical.fever_from_temperature')),
        'remove_derived_relations', jsonb_build_array(jsonb_build_object(
            'name', 'clinical.patient_fever'))), mappings
FROM manifests WHERE version = '3';

SELECT min(plan_digest) AS plan_digest FROM pgreact.preview_pack(
    (SELECT definition FROM manifests WHERE version = '4'),
    (SELECT mappings FROM manifests WHERE version = '4')) \gset
SELECT pgreact.deploy_pack(
    (SELECT definition FROM manifests WHERE version = '4'), :'plan_digest',
    (SELECT mappings FROM manifests WHERE version = '4'));

DO $$
DECLARE actual jsonb;
BEGIN
    SELECT jsonb_build_object(
        'active_pack', (SELECT version FROM pgreact.pack_history('clinical-pack')
                        WHERE status = 'ACTIVE'),
        'relation_states', (SELECT jsonb_agg(state ORDER BY relation_version)
            FROM pgreact.derived_relations WHERE relation_name = 'pack_clinical.patient_fever'),
        'rule_kinds', (SELECT jsonb_agg(DISTINCT rule_kind ORDER BY rule_kind)
            FROM pgreact_internal.rule_versions v
            JOIN pgreact_internal.rules r USING (rule_id)
            WHERE r.rule_name IN ('clinical.fever_from_temperature',
                                  'clinical.observe_patient_fever')),
        'rule_states', (SELECT jsonb_agg(DISTINCT state ORDER BY state)
            FROM pgreact_internal.rule_versions v
            JOIN pgreact_internal.rules r USING (rule_id)
            WHERE r.rule_name IN ('clinical.fever_from_temperature',
                                  'clinical.observe_patient_fever')),
        'facts', COALESCE((SELECT jsonb_agg(fact) FROM pgreact.derived_facts
            WHERE relation_name = 'pack_clinical.patient_fever'), '[]'::jsonb),
        'active_supports', COALESCE((SELECT jsonb_agg(source_binding)
            FROM pgreact.support_history
            WHERE relation_name = 'pack_clinical.patient_fever' AND active), '[]'::jsonb),
        'public_rows', COALESCE((SELECT jsonb_agg(to_jsonb(v))
            FROM pack_clinical.patient_fever v), '[]'::jsonb)
    ) INTO actual;
    IF actual IS DISTINCT FROM jsonb_build_object(
        'active_pack', '4', 'relation_states', jsonb_build_array('REMOVED'),
        'rule_kinds', jsonb_build_array('DERIVATION', 'STANDARD'),
        'rule_states', jsonb_build_array('REMOVED'),
        'facts', '[]'::jsonb, 'active_supports', '[]'::jsonb,
        'public_rows', '[]'::jsonb) THEN
        RAISE EXCEPTION 'M7 removal output changed: %', actual;
    END IF;
END $$;

SELECT 'M7 pack validation, preview, failure, drift, replace, and remove checks passed' AS result;
