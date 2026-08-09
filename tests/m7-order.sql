\set ON_ERROR_STOP on

CREATE SCHEMA order_a;
CREATE SCHEMA order_b;
CREATE TYPE order_a.patient_fever_row AS (patient_id bigint);
CREATE TYPE order_b.patient_fever_row AS (patient_id bigint);

CREATE TABLE order_a.positive_tests (patient_id bigint PRIMARY KEY, test_name text, positive boolean);
CREATE TABLE order_a.temperatures (patient_id bigint PRIMARY KEY, temperature_c numeric(4,1));
CREATE TABLE order_b.positive_tests (patient_id bigint PRIMARY KEY, test_name text, positive boolean);
CREATE TABLE order_b.temperatures (patient_id bigint PRIMARY KEY, temperature_c numeric(4,1));

CREATE VIEW order_a.positive AS SELECT patient_id, test_name, positive FROM order_a.positive_tests WHERE positive;
CREATE VIEW order_a.temperature AS SELECT patient_id, temperature_c FROM order_a.temperatures WHERE temperature_c >= 38.0;
CREATE VIEW order_b.positive AS SELECT patient_id, test_name, positive FROM order_b.positive_tests WHERE positive;
CREATE VIEW order_b.temperature AS SELECT patient_id, temperature_c FROM order_b.temperatures WHERE temperature_c >= 38.0;

SELECT pgreact.create_derived_relation('order_a.patient_fever', 'order_a.patient_fever_row'::regtype,
    ARRAY['patient_id'], 1) AS relation_a \gset
SELECT pgreact.create_derived_relation('order_b.patient_fever', 'order_b.patient_fever_row'::regtype,
    ARRAY['patient_id'], 1) AS relation_b \gset
SELECT pgreact.create_derivation_rule('order_a.positive', 'order_a.positive'::regclass,
    ARRAY['patient_id'], :'relation_a'::uuid, 1) AS positive_a \gset
SELECT pgreact.create_derivation_rule('order_a.temperature', 'order_a.temperature'::regclass,
    ARRAY['patient_id'], :'relation_a'::uuid, 1) AS temperature_a \gset
SELECT pgreact.create_derivation_rule('order_b.positive', 'order_b.positive'::regclass,
    ARRAY['patient_id'], :'relation_b'::uuid, 1) AS positive_b \gset
SELECT pgreact.create_derivation_rule('order_b.temperature', 'order_b.temperature'::regclass,
    ARRAY['patient_id'], :'relation_b'::uuid, 1) AS temperature_b \gset

CREATE VIEW order_a.observe AS SELECT patient_id FROM order_a.patient_fever;
CREATE VIEW order_b.observe AS SELECT patient_id FROM order_b.patient_fever;
SELECT pgreact.create_rule('order_a.observe', 'order_a.observe'::regclass,
    ARRAY['patient_id'], kind => 'CONSTRAINT') AS observer_a \gset
SELECT pgreact.create_rule('order_b.observe', 'order_b.observe'::regclass,
    ARRAY['patient_id'], kind => 'CONSTRAINT') AS observer_b \gset
SELECT set_config('m7.observer_a', :'observer_a', false),
       set_config('m7.observer_b', :'observer_b', false);

INSERT INTO order_a.positive_tests VALUES (42, 'influenza_a', true);
INSERT INTO order_a.temperatures VALUES (42, 39.2);
INSERT INTO order_b.temperatures VALUES (42, 39.2);
INSERT INTO order_b.positive_tests VALUES (42, 'influenza_a', true);
SELECT pgreact.refresh_derived_relation(:'relation_a'::uuid);
SELECT pgreact.refresh_rule(:'observer_a'::uuid);
SELECT pgreact.refresh_derived_relation(:'relation_b'::uuid);
SELECT pgreact.refresh_rule(:'observer_b'::uuid);

DO $$
DECLARE a jsonb; b jsonb; expected jsonb;
BEGIN
    SELECT jsonb_build_object(
        'facts', (SELECT jsonb_agg(jsonb_build_object(
            'patient_id', semantic_key, 'support_count', support_count) ORDER BY semantic_key)
            FROM pgreact.derived_facts WHERE relation_name = 'order_a.patient_fever'),
        'supports', (SELECT jsonb_agg(jsonb_build_object(
            'kind', CASE WHEN rule_name LIKE '%.positive' THEN 'positive' ELSE 'temperature' END,
            'generation', activation_generation, 'source_binding', source_binding,
            'active', active) ORDER BY rule_name)
            FROM pgreact.support_history WHERE relation_name = 'order_a.patient_fever'),
        'events', (SELECT jsonb_agg(jsonb_build_object(
            'event', event_kind, 'generation', generation) ORDER BY event_id)
            FROM pgreact_internal.lifecycle_events
            WHERE rule_version_id = current_setting('m7.observer_a')::uuid)
    ) INTO a;
    SELECT jsonb_build_object(
        'facts', (SELECT jsonb_agg(jsonb_build_object(
            'patient_id', semantic_key, 'support_count', support_count) ORDER BY semantic_key)
            FROM pgreact.derived_facts WHERE relation_name = 'order_b.patient_fever'),
        'supports', (SELECT jsonb_agg(jsonb_build_object(
            'kind', CASE WHEN rule_name LIKE '%.positive' THEN 'positive' ELSE 'temperature' END,
            'generation', activation_generation, 'source_binding', source_binding,
            'active', active) ORDER BY rule_name)
            FROM pgreact.support_history WHERE relation_name = 'order_b.patient_fever'),
        'events', (SELECT jsonb_agg(jsonb_build_object(
            'event', event_kind, 'generation', generation) ORDER BY event_id)
            FROM pgreact_internal.lifecycle_events
            WHERE rule_version_id = current_setting('m7.observer_b')::uuid)
    ) INTO b;
    expected := jsonb_build_object(
        'facts', jsonb_build_array(jsonb_build_object('patient_id', 42, 'support_count', 2)),
        'supports', jsonb_build_array(
            jsonb_build_object('kind', 'positive', 'generation', 1,
                'source_binding', jsonb_build_object(
                    'patient_id', 42, 'positive', true, 'test_name', 'influenza_a'),
                'active', true),
            jsonb_build_object('kind', 'temperature', 'generation', 1,
                'source_binding', jsonb_build_object('patient_id', 42, 'temperature_c', 39.2),
                'active', true)),
        'events', jsonb_build_array(jsonb_build_object('event', 'ACTIVATE', 'generation', 1)));
    IF a IS DISTINCT FROM expected OR b IS DISTINCT FROM expected THEN
        RAISE EXCEPTION 'arrival-order output changed: a %, b %', a, b;
    END IF;
END $$;

DELETE FROM order_a.temperatures WHERE patient_id = 42;
DELETE FROM order_b.positive_tests WHERE patient_id = 42;
SELECT pgreact.refresh_derived_relation(:'relation_a'::uuid);
SELECT pgreact.refresh_rule(:'observer_a'::uuid);
SELECT pgreact.refresh_derived_relation(:'relation_b'::uuid);
SELECT pgreact.refresh_rule(:'observer_b'::uuid);

DO $$
DECLARE actual jsonb; expected jsonb;
BEGIN
    SELECT jsonb_build_object(
        'a_fact', (SELECT jsonb_agg(jsonb_build_object(
            'patient_id', semantic_key, 'support_count', support_count))
            FROM pgreact.derived_facts WHERE relation_name = 'order_a.patient_fever'),
        'a_active', (SELECT jsonb_agg(jsonb_build_object(
            'kind', 'positive', 'source_binding', source_binding))
            FROM pgreact.support_history
            WHERE relation_name = 'order_a.patient_fever' AND active),
        'b_fact', (SELECT jsonb_agg(jsonb_build_object(
            'patient_id', semantic_key, 'support_count', support_count))
            FROM pgreact.derived_facts WHERE relation_name = 'order_b.patient_fever'),
        'b_active', (SELECT jsonb_agg(jsonb_build_object(
            'kind', 'temperature', 'source_binding', source_binding))
            FROM pgreact.support_history
            WHERE relation_name = 'order_b.patient_fever' AND active),
        'events', (SELECT jsonb_agg(jsonb_build_object(
            'side', side, 'event', event_kind, 'generation', generation)
            ORDER BY side, event_id)
            FROM (
                SELECT 'a' AS side, event_id, event_kind, generation
                FROM pgreact_internal.lifecycle_events
                WHERE rule_version_id = current_setting('m7.observer_a')::uuid
                UNION ALL
                SELECT 'b', event_id, event_kind, generation
                FROM pgreact_internal.lifecycle_events
                WHERE rule_version_id = current_setting('m7.observer_b')::uuid
            ) events)
    ) INTO actual;
    expected := jsonb_build_object(
        'a_fact', jsonb_build_array(jsonb_build_object('patient_id', 42, 'support_count', 1)),
        'a_active', jsonb_build_array(jsonb_build_object(
            'kind', 'positive', 'source_binding', jsonb_build_object(
                'patient_id', 42, 'positive', true, 'test_name', 'influenza_a'))),
        'b_fact', jsonb_build_array(jsonb_build_object('patient_id', 42, 'support_count', 1)),
        'b_active', jsonb_build_array(jsonb_build_object(
            'kind', 'temperature', 'source_binding', jsonb_build_object(
                'patient_id', 42, 'temperature_c', 39.2))),
        'events', jsonb_build_array(
            jsonb_build_object('side', 'a', 'event', 'ACTIVATE', 'generation', 1),
            jsonb_build_object('side', 'b', 'event', 'ACTIVATE', 'generation', 1)));
    IF actual IS DISTINCT FROM expected THEN
        RAISE EXCEPTION 'first-removal output changed: %', actual;
    END IF;
END $$;

DELETE FROM order_a.positive_tests WHERE patient_id = 42;
DELETE FROM order_b.temperatures WHERE patient_id = 42;
SELECT pgreact.refresh_derived_relation(:'relation_a'::uuid);
SELECT pgreact.refresh_rule(:'observer_a'::uuid);
SELECT pgreact.refresh_derived_relation(:'relation_b'::uuid);
SELECT pgreact.refresh_rule(:'observer_b'::uuid);

DO $$
DECLARE actual jsonb; expected jsonb;
BEGIN
    SELECT jsonb_build_object(
        'facts', (SELECT COALESCE(jsonb_agg(jsonb_build_object(
            'relation', relation_name, 'fact', fact)), '[]'::jsonb)
            FROM pgreact.derived_facts
            WHERE relation_name IN ('order_a.patient_fever', 'order_b.patient_fever')),
        'events', (SELECT jsonb_agg(jsonb_build_object(
            'side', side, 'event', event_kind, 'generation', generation)
            ORDER BY side, event_id)
            FROM (
                SELECT 'a' AS side, event_id, event_kind, generation
                FROM pgreact_internal.lifecycle_events
                WHERE rule_version_id = current_setting('m7.observer_a')::uuid
                UNION ALL
                SELECT 'b', event_id, event_kind, generation
                FROM pgreact_internal.lifecycle_events
                WHERE rule_version_id = current_setting('m7.observer_b')::uuid
            ) events)
    ) INTO actual;
    expected := jsonb_build_object(
        'facts', '[]'::jsonb,
        'events', jsonb_build_array(
            jsonb_build_object('side', 'a', 'event', 'ACTIVATE', 'generation', 1),
            jsonb_build_object('side', 'a', 'event', 'DEACTIVATE', 'generation', 1),
            jsonb_build_object('side', 'b', 'event', 'ACTIVATE', 'generation', 1),
            jsonb_build_object('side', 'b', 'event', 'DEACTIVATE', 'generation', 1)));
    IF actual IS DISTINCT FROM expected THEN
        RAISE EXCEPTION 'last-removal output changed: %', actual;
    END IF;
END $$;

SELECT 'M7 arrival and removal order checks passed' AS result;
