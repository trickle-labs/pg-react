\set ON_ERROR_STOP on

CREATE SCHEMA clinical;
CREATE TYPE clinical.patient_fever_row AS (patient_id bigint);
CREATE TABLE clinical.positive_tests (
    patient_id bigint PRIMARY KEY,
    test_name text NOT NULL,
    positive boolean NOT NULL
);
CREATE TABLE clinical.temperatures (
    patient_id bigint PRIMARY KEY,
    temperature_c numeric(4,1) NOT NULL
);
CREATE VIEW clinical.fever_from_positive_test AS
SELECT patient_id, test_name, positive
FROM clinical.positive_tests WHERE positive;
CREATE VIEW clinical.fever_from_temperature AS
SELECT patient_id, temperature_c
FROM clinical.temperatures WHERE temperature_c >= 38.0;

SELECT pgreact.create_derived_relation(
    'clinical.patient_fever', 'clinical.patient_fever_row'::regtype,
    ARRAY['patient_id'], 1
) AS relation_version_id \gset

SELECT pgreact.create_derivation_rule(
    'clinical.fever_from_positive_test',
    'clinical.fever_from_positive_test'::regclass,
    ARRAY['patient_id'], :'relation_version_id'::uuid, 1
) AS positive_rule_version_id \gset
SELECT pgreact.create_derivation_rule(
    'clinical.fever_from_temperature',
    'clinical.fever_from_temperature'::regclass,
    ARRAY['patient_id'], :'relation_version_id'::uuid, 1
) AS temperature_rule_version_id \gset

CREATE VIEW clinical.observe_patient_fever AS
SELECT patient_id FROM clinical.patient_fever;
SELECT pgreact.create_rule(
    name => 'clinical.observe_patient_fever',
    definition => 'clinical.observe_patient_fever'::regclass,
    key_columns => ARRAY['patient_id'], kind => 'CONSTRAINT'
) AS observer_rule_version_id \gset

INSERT INTO clinical.positive_tests VALUES (42, 'influenza_a', true);
INSERT INTO clinical.temperatures VALUES (42, 39.2);
SELECT * FROM pgreact.refresh_derived_relation(:'relation_version_id'::uuid);
SELECT pgreact.refresh_rule(:'observer_rule_version_id'::uuid);
SELECT set_config('m7.relation', :'relation_version_id', false),
       set_config('m7.observer', :'observer_rule_version_id', false);

DO $$
DECLARE actual jsonb; expected jsonb;
BEGIN
    SELECT jsonb_build_object(
        'facts', COALESCE((SELECT jsonb_agg(jsonb_build_object(
            'patient_id', semantic_key, 'support_count', support_count,
            'first_frontier', first_frontier, 'last_frontier', last_frontier)
            ORDER BY semantic_key) FROM pgreact.current_facts(
                current_setting('m7.relation')::uuid)), '[]'::jsonb),
        'supports', COALESCE((SELECT jsonb_agg(jsonb_build_object(
            'rule', rule_name || '@' || rule_version,
            'generation', activation_generation, 'source_binding', source_binding,
            'active', active, 'first_frontier', first_frontier,
            'last_frontier', last_frontier)
            ORDER BY rule_name, activation_generation)
            FROM pgreact.support_history
            WHERE relation_version_id = current_setting('m7.relation')::uuid), '[]'::jsonb),
        'explanation', pgreact.explain_fact(current_setting('m7.relation')::uuid, 42),
        'events', COALESCE((SELECT jsonb_agg(jsonb_build_object(
            'event', event_kind, 'generation', generation) ORDER BY event_id)
            FROM pgreact_internal.lifecycle_events
            WHERE rule_version_id = current_setting('m7.observer')::uuid), '[]'::jsonb)
    ) INTO actual;
    expected := jsonb_build_object(
        'facts', jsonb_build_array(jsonb_build_object(
            'patient_id', 42, 'support_count', 2,
            'first_frontier', 1, 'last_frontier', 1)),
        'supports', jsonb_build_array(
            jsonb_build_object(
                'rule', 'clinical.fever_from_positive_test@1', 'generation', 1,
                'source_binding', jsonb_build_object(
                    'patient_id', 42, 'positive', true, 'test_name', 'influenza_a'),
                'active', true, 'first_frontier', 1, 'last_frontier', NULL),
            jsonb_build_object(
                'rule', 'clinical.fever_from_temperature@1', 'generation', 1,
                'source_binding', jsonb_build_object('patient_id', 42, 'temperature_c', 39.2),
                'active', true, 'first_frontier', 1, 'last_frontier', NULL)),
        'explanation', jsonb_build_object(
            'relation', 'clinical.patient_fever@1',
            'fact', jsonb_build_object('patient_id', 42),
            'active_supports', jsonb_build_array(
                jsonb_build_object(
                    'rule', 'clinical.fever_from_positive_test@1',
                    'activation_generation', 1,
                    'source_binding', jsonb_build_object(
                        'patient_id', 42, 'positive', true, 'test_name', 'influenza_a')),
                jsonb_build_object(
                    'rule', 'clinical.fever_from_temperature@1',
                    'activation_generation', 1,
                    'source_binding', jsonb_build_object(
                        'patient_id', 42, 'temperature_c', 39.2)))),
        'events', jsonb_build_array(jsonb_build_object('event', 'ACTIVATE', 'generation', 1))
    );
    IF actual IS DISTINCT FROM expected THEN
        RAISE EXCEPTION 'F1 output changed: %', actual;
    END IF;
END $$;

DELETE FROM clinical.temperatures WHERE patient_id = 42;
SELECT * FROM pgreact.refresh_derived_relation(:'relation_version_id'::uuid);
SELECT pgreact.refresh_rule(:'observer_rule_version_id'::uuid);

DO $$
DECLARE actual jsonb; expected jsonb;
BEGIN
    SELECT jsonb_build_object(
        'facts', COALESCE((SELECT jsonb_agg(jsonb_build_object(
            'patient_id', semantic_key, 'support_count', support_count,
            'first_frontier', first_frontier, 'last_frontier', last_frontier)
            ORDER BY semantic_key) FROM pgreact.current_facts(
                current_setting('m7.relation')::uuid)), '[]'::jsonb),
        'supports', COALESCE((SELECT jsonb_agg(jsonb_build_object(
            'rule', rule_name || '@' || rule_version,
            'generation', activation_generation, 'active', active,
            'first_frontier', first_frontier, 'last_frontier', last_frontier)
            ORDER BY rule_name, activation_generation)
            FROM pgreact.support_history
            WHERE relation_version_id = current_setting('m7.relation')::uuid), '[]'::jsonb),
        'explanation', pgreact.explain_fact(current_setting('m7.relation')::uuid, 42),
        'events', COALESCE((SELECT jsonb_agg(jsonb_build_object(
            'event', event_kind, 'generation', generation) ORDER BY event_id)
            FROM pgreact_internal.lifecycle_events
            WHERE rule_version_id = current_setting('m7.observer')::uuid), '[]'::jsonb)
    ) INTO actual;
    expected := jsonb_build_object(
        'facts', jsonb_build_array(jsonb_build_object(
            'patient_id', 42, 'support_count', 1,
            'first_frontier', 1, 'last_frontier', 2)),
        'supports', jsonb_build_array(
            jsonb_build_object(
                'rule', 'clinical.fever_from_positive_test@1', 'generation', 1,
                'active', true, 'first_frontier', 1, 'last_frontier', NULL),
            jsonb_build_object(
                'rule', 'clinical.fever_from_temperature@1', 'generation', 1,
                'active', false, 'first_frontier', 1, 'last_frontier', 2)),
        'explanation', jsonb_build_object(
            'relation', 'clinical.patient_fever@1',
            'fact', jsonb_build_object('patient_id', 42),
            'active_supports', jsonb_build_array(jsonb_build_object(
                'rule', 'clinical.fever_from_positive_test@1',
                'activation_generation', 1,
                'source_binding', jsonb_build_object(
                    'patient_id', 42, 'positive', true, 'test_name', 'influenza_a')))),
        'events', jsonb_build_array(jsonb_build_object('event', 'ACTIVATE', 'generation', 1))
    );
    IF actual IS DISTINCT FROM expected THEN
        RAISE EXCEPTION 'F2 output changed: %', actual;
    END IF;
END $$;

DELETE FROM clinical.positive_tests WHERE patient_id = 42;
SELECT * FROM pgreact.refresh_derived_relation(:'relation_version_id'::uuid);
SELECT pgreact.refresh_rule(:'observer_rule_version_id'::uuid);

DO $$
DECLARE actual jsonb; expected jsonb;
BEGIN
    SELECT jsonb_build_object(
        'facts', COALESCE((SELECT jsonb_agg(fact ORDER BY semantic_key)
            FROM pgreact.current_facts(current_setting('m7.relation')::uuid)), '[]'::jsonb),
        'supports', COALESCE((SELECT jsonb_agg(jsonb_build_object(
            'rule', rule_name || '@' || rule_version,
            'generation', activation_generation, 'active', active,
            'first_frontier', first_frontier, 'last_frontier', last_frontier)
            ORDER BY rule_name, activation_generation)
            FROM pgreact.support_history
            WHERE relation_version_id = current_setting('m7.relation')::uuid), '[]'::jsonb),
        'explanation', pgreact.explain_fact(current_setting('m7.relation')::uuid, 42),
        'events', COALESCE((SELECT jsonb_agg(jsonb_build_object(
            'event', event_kind, 'generation', generation) ORDER BY event_id)
            FROM pgreact_internal.lifecycle_events
            WHERE rule_version_id = current_setting('m7.observer')::uuid), '[]'::jsonb)
    ) INTO actual;
    expected := jsonb_build_object(
        'facts', '[]'::jsonb,
        'supports', jsonb_build_array(
            jsonb_build_object(
                'rule', 'clinical.fever_from_positive_test@1', 'generation', 1,
                'active', false, 'first_frontier', 1, 'last_frontier', 3),
            jsonb_build_object(
                'rule', 'clinical.fever_from_temperature@1', 'generation', 1,
                'active', false, 'first_frontier', 1, 'last_frontier', 2)),
        'explanation', NULL,
        'events', jsonb_build_array(
            jsonb_build_object('event', 'ACTIVATE', 'generation', 1),
            jsonb_build_object('event', 'DEACTIVATE', 'generation', 1))
    );
    IF actual IS DISTINCT FROM expected THEN
        RAISE EXCEPTION 'F3 output changed: %', actual;
    END IF;
END $$;

INSERT INTO clinical.temperatures VALUES (42, 39.2);
SELECT * FROM pgreact.refresh_derived_relation(:'relation_version_id'::uuid);
SELECT pgreact.refresh_rule(:'observer_rule_version_id'::uuid);

CREATE TEMP TABLE f4_snapshot AS
SELECT jsonb_build_object(
    'facts', COALESCE((SELECT jsonb_agg(jsonb_build_object(
        'patient_id', semantic_key, 'support_count', support_count,
        'first_frontier', first_frontier, 'last_frontier', last_frontier)
        ORDER BY semantic_key) FROM pgreact.current_facts(
            current_setting('m7.relation')::uuid)), '[]'::jsonb),
    'supports', COALESCE((SELECT jsonb_agg(jsonb_build_object(
        'rule', rule_name || '@' || rule_version,
        'generation', activation_generation, 'source_binding', source_binding,
        'active', active, 'first_frontier', first_frontier,
        'last_frontier', last_frontier)
        ORDER BY rule_name, activation_generation)
        FROM pgreact.support_history
        WHERE relation_version_id = current_setting('m7.relation')::uuid), '[]'::jsonb),
    'explanation', pgreact.explain_fact(current_setting('m7.relation')::uuid, 42),
    'events', COALESCE((SELECT jsonb_agg(jsonb_build_object(
        'event', event_kind, 'generation', generation) ORDER BY event_id)
        FROM pgreact_internal.lifecycle_events
        WHERE rule_version_id = current_setting('m7.observer')::uuid), '[]'::jsonb),
    'frontier', (SELECT frontier FROM pgreact_internal.derived_frontiers
                 WHERE relation_version_id = current_setting('m7.relation')::uuid)
) AS snapshot;

DO $$
DECLARE actual jsonb; expected jsonb;
BEGIN
    SELECT snapshot INTO actual FROM f4_snapshot;
    expected := jsonb_build_object(
        'facts', jsonb_build_array(jsonb_build_object(
            'patient_id', 42, 'support_count', 1,
            'first_frontier', 4, 'last_frontier', 4)),
        'supports', jsonb_build_array(
            jsonb_build_object(
                'rule', 'clinical.fever_from_positive_test@1', 'generation', 1,
                'source_binding', jsonb_build_object(
                    'patient_id', 42, 'positive', true, 'test_name', 'influenza_a'),
                'active', false, 'first_frontier', 1, 'last_frontier', 3),
            jsonb_build_object(
                'rule', 'clinical.fever_from_temperature@1', 'generation', 1,
                'source_binding', jsonb_build_object('patient_id', 42, 'temperature_c', 39.2),
                'active', false, 'first_frontier', 1, 'last_frontier', 2),
            jsonb_build_object(
                'rule', 'clinical.fever_from_temperature@1', 'generation', 2,
                'source_binding', jsonb_build_object('patient_id', 42, 'temperature_c', 39.2),
                'active', true, 'first_frontier', 4, 'last_frontier', NULL)),
        'explanation', jsonb_build_object(
            'relation', 'clinical.patient_fever@1',
            'fact', jsonb_build_object('patient_id', 42),
            'active_supports', jsonb_build_array(jsonb_build_object(
                'rule', 'clinical.fever_from_temperature@1',
                'activation_generation', 2,
                'source_binding', jsonb_build_object('patient_id', 42, 'temperature_c', 39.2)))),
        'events', jsonb_build_array(
            jsonb_build_object('event', 'ACTIVATE', 'generation', 1),
            jsonb_build_object('event', 'DEACTIVATE', 'generation', 1),
            jsonb_build_object('event', 'ACTIVATE', 'generation', 2)),
        'frontier', 4
    );
    IF actual IS DISTINCT FROM expected THEN
        RAISE EXCEPTION 'F4 output changed: %', actual;
    END IF;
END $$;

-- A no-change refresh cannot advance the public frontier or duplicate history.
SELECT * FROM pgreact.refresh_derived_relation(:'relation_version_id'::uuid);
SELECT pgreact.refresh_rule(:'observer_rule_version_id'::uuid);
DO $$
DECLARE actual jsonb;
BEGIN
    SELECT jsonb_build_object(
        'facts', COALESCE((SELECT jsonb_agg(jsonb_build_object(
            'patient_id', semantic_key, 'support_count', support_count,
            'first_frontier', first_frontier, 'last_frontier', last_frontier)
            ORDER BY semantic_key) FROM pgreact.current_facts(
                current_setting('m7.relation')::uuid)), '[]'::jsonb),
        'supports', COALESCE((SELECT jsonb_agg(jsonb_build_object(
            'rule', rule_name || '@' || rule_version,
            'generation', activation_generation, 'source_binding', source_binding,
            'active', active, 'first_frontier', first_frontier,
            'last_frontier', last_frontier)
            ORDER BY rule_name, activation_generation)
            FROM pgreact.support_history
            WHERE relation_version_id = current_setting('m7.relation')::uuid), '[]'::jsonb),
        'explanation', pgreact.explain_fact(current_setting('m7.relation')::uuid, 42),
        'events', COALESCE((SELECT jsonb_agg(jsonb_build_object(
            'event', event_kind, 'generation', generation) ORDER BY event_id)
            FROM pgreact_internal.lifecycle_events
            WHERE rule_version_id = current_setting('m7.observer')::uuid), '[]'::jsonb),
        'frontier', (SELECT frontier FROM pgreact_internal.derived_frontiers
                     WHERE relation_version_id = current_setting('m7.relation')::uuid)
    ) INTO actual;
    IF actual IS DISTINCT FROM (SELECT snapshot FROM f4_snapshot) THEN
        RAISE EXCEPTION 'no-op refresh changed F4: %', actual;
    END IF;
END $$;

-- Corrupt every M7 state category frozen by the entry fixture.
DELETE FROM pgreact_internal.derived_facts
WHERE relation_version_id = :'relation_version_id'::uuid AND semantic_key = 42;
DELETE FROM pgreact_internal.derived_supports
WHERE relation_version_id = :'relation_version_id'::uuid
  AND activation_generation = 2;
UPDATE pgreact_internal.derived_supports
SET active = true
WHERE relation_version_id = :'relation_version_id'::uuid
  AND activation_generation = 1;
INSERT INTO pgreact_internal.derived_facts (
    relation_version_id, fact_id, semantic_key, fact, support_count,
    first_frontier, last_frontier
)
SELECT :'relation_version_id'::uuid,
       pgreact_internal.activation_uuid(pgreact_internal.activation_digest(
           :'relation_version_id'::uuid, pgreact_internal.canonical_bigint_v1(99))),
       99, '{"patient_id":99}'::jsonb, 1, 4, 4;

SELECT pgreact.reconcile_derived_relation(:'relation_version_id'::uuid) AS repairs \gset
\if :{?repairs}
\else
  \quit 1
\endif

DO $$
DECLARE actual jsonb; codes text[];
BEGIN
    SELECT jsonb_build_object(
        'facts', COALESCE((SELECT jsonb_agg(jsonb_build_object(
            'patient_id', semantic_key, 'support_count', support_count,
            'first_frontier', first_frontier, 'last_frontier', last_frontier)
            ORDER BY semantic_key) FROM pgreact.current_facts(
                current_setting('m7.relation')::uuid)), '[]'::jsonb),
        'supports', COALESCE((SELECT jsonb_agg(jsonb_build_object(
            'rule', rule_name || '@' || rule_version,
            'generation', activation_generation, 'source_binding', source_binding,
            'active', active, 'first_frontier', first_frontier,
            'last_frontier', last_frontier)
            ORDER BY rule_name, activation_generation)
            FROM pgreact.support_history
            WHERE relation_version_id = current_setting('m7.relation')::uuid), '[]'::jsonb),
        'explanation', pgreact.explain_fact(current_setting('m7.relation')::uuid, 42),
        'events', COALESCE((SELECT jsonb_agg(jsonb_build_object(
            'event', event_kind, 'generation', generation) ORDER BY event_id)
            FROM pgreact_internal.lifecycle_events
            WHERE rule_version_id = current_setting('m7.observer')::uuid), '[]'::jsonb),
        'frontier', (SELECT frontier FROM pgreact_internal.derived_frontiers
                     WHERE relation_version_id = current_setting('m7.relation')::uuid)
    ) INTO actual;
    IF actual IS DISTINCT FROM (SELECT snapshot FROM f4_snapshot) THEN
        RAISE EXCEPTION 'reconciliation did not restore F4: %', actual;
    END IF;
    SELECT array_agg(code ORDER BY code, diagnostic_order) INTO codes
    FROM pgreact.derived_repair_diagnostics
    WHERE reconciliation_id = (
        SELECT max(reconciliation_id) FROM pgreact.derived_repair_diagnostics);
    IF codes IS DISTINCT FROM ARRAY[
        'EXTRA_FACT', 'MISSING_FACT', 'MISSING_SUPPORT',
        'STALE_SUPPORT', 'STALE_SUPPORT'
    ] THEN
        RAISE EXCEPTION 'repair diagnostics changed: %', codes;
    END IF;
END $$;

SELECT pgreact.reconcile_derived_relation(:'relation_version_id'::uuid) = 0 AS second_reconcile_noop \gset
\if :second_reconcile_noop
\else
  \quit 1
\endif

DO $$
DECLARE actual text[];
BEGIN
    SELECT COALESCE(array_agg(code ORDER BY code), ARRAY[]::text[]) INTO actual
    FROM pgreact.health_check()
    WHERE code LIKE 'DERIVED_%';
    IF actual IS DISTINCT FROM ARRAY[]::text[] THEN
        RAISE EXCEPTION 'derived health did not recover: %', actual;
    END IF;
    IF EXISTS (
        SELECT 1 FROM pgreact_internal.agenda
        WHERE rule_version_id IN (
            SELECT rule_version_id FROM pgreact_internal.derivation_rule_versions)
    ) THEN
        RAISE EXCEPTION 'derivations created agenda work';
    END IF;
END $$;

SELECT 'M7 two-support lifecycle, provenance, no-op, and reconciliation checks passed' AS result;
