\set ON_ERROR_STOP on

CREATE SCHEMA boundary;
CREATE TYPE boundary.diagnosis_row AS (patient_id bigint, diagnosis text);
CREATE TABLE boundary.source_a (patient_id bigint PRIMARY KEY, diagnosis text NOT NULL);
CREATE TABLE boundary.source_b (patient_id bigint PRIMARY KEY, diagnosis text NOT NULL);
CREATE VIEW boundary.derivation_a AS SELECT patient_id, diagnosis FROM boundary.source_a;
CREATE VIEW boundary.derivation_b AS SELECT patient_id, diagnosis FROM boundary.source_b;

SELECT pgreact.create_derived_relation(
    'boundary.current_diagnosis', 'boundary.diagnosis_row'::regtype,
    ARRAY['patient_id'], 1) AS relation_version \gset
SELECT pgreact.create_derivation_rule(
    'boundary.derivation_a', 'boundary.derivation_a'::regclass,
    ARRAY['patient_id'], :'relation_version'::uuid, 1) AS rule_a \gset
SELECT pgreact.create_derivation_rule(
    'boundary.derivation_b', 'boundary.derivation_b'::regclass,
    ARRAY['patient_id'], :'relation_version'::uuid, 1) AS rule_b \gset
SELECT set_config('m7.boundary_relation', :'relation_version', false);

INSERT INTO boundary.source_a VALUES (7, 'influenza');
SELECT pgreact.refresh_derived_relation(:'relation_version'::uuid);

CREATE VIEW boundary.chain_source AS
SELECT patient_id, diagnosis FROM boundary.current_diagnosis;
DO $$
DECLARE actual text[];
BEGIN
    SELECT array_agg(code ORDER BY code) INTO actual
    FROM pgreact.validate_derivation_rule(
        'boundary.chain_source'::regclass,
        current_setting('m7.boundary_relation')::uuid,
        ARRAY['patient_id'], 1)
    WHERE severity = 'ERROR';
    IF actual IS DISTINCT FROM ARRAY['DERIVATION_CHAIN_UNSUPPORTED'] THEN
        RAISE EXCEPTION 'derivation-chain diagnostics changed: %', actual;
    END IF;
END $$;

DO $$
BEGIN
    BEGIN
        INSERT INTO boundary.current_diagnosis VALUES (8, 'manual');
        RAISE EXCEPTION 'public derived view unexpectedly accepted mutation';
    EXCEPTION WHEN object_not_in_prerequisite_state THEN NULL;
    END;
END $$;

DO $$
DECLARE before_value jsonb; after_value jsonb;
BEGIN
    before_value := pgreact.explain_fact(
        current_setting('m7.boundary_relation')::uuid, 7);
    PERFORM * FROM pgreact.prune_payloads(clock_timestamp() - interval '1 second');
    after_value := pgreact.explain_fact(
        current_setting('m7.boundary_relation')::uuid, 7);
    IF jsonb_build_object('before', before_value, 'after', after_value)
       IS DISTINCT FROM jsonb_build_object('before', jsonb_build_object(
            'relation', 'boundary.current_diagnosis@1',
            'fact', jsonb_build_object('patient_id', 7, 'diagnosis', 'influenza'),
            'active_supports', jsonb_build_array(jsonb_build_object(
                'rule', 'boundary.derivation_a@1', 'activation_generation', 1,
                'source_binding', jsonb_build_object(
                    'patient_id', 7, 'diagnosis', 'influenza')))),
          'after', jsonb_build_object(
            'relation', 'boundary.current_diagnosis@1',
            'fact', jsonb_build_object('patient_id', 7, 'diagnosis', 'influenza'),
            'active_supports', jsonb_build_array(jsonb_build_object(
                'rule', 'boundary.derivation_a@1', 'activation_generation', 1,
                'source_binding', jsonb_build_object(
                    'patient_id', 7, 'diagnosis', 'influenza'))))) THEN
        RAISE EXCEPTION 'retention changed current explanation: before %, after %',
            before_value, after_value;
    END IF;
END $$;

CREATE ROLE boundary_intruder;
GRANT USAGE ON SCHEMA pgreact TO boundary_intruder;
GRANT EXECUTE ON FUNCTION pgreact.reconcile_derived_relation(uuid) TO boundary_intruder;
SET SESSION AUTHORIZATION boundary_intruder;
DO $$
BEGIN
    BEGIN
        PERFORM pgreact.reconcile_derived_relation(
            current_setting('m7.boundary_relation')::uuid);
        RAISE EXCEPTION 'intruder unexpectedly reconciled derived state';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE 'only the derived-relation owner or pgreact_admin may manage %' THEN
            RAISE;
        END IF;
    END;
END $$;
RESET SESSION AUTHORIZATION;

DO $$
DECLARE actual jsonb;
BEGIN
    SELECT jsonb_build_object(
        'fact', (SELECT fact FROM pgreact.derived_facts
                 WHERE relation_version_id = current_setting('m7.boundary_relation')::uuid),
        'support', (SELECT source_binding FROM pgreact.support_history
                    WHERE relation_version_id = current_setting('m7.boundary_relation')::uuid
                      AND active),
        'derived_agenda', COALESCE((SELECT jsonb_agg(to_jsonb(a))
            FROM pgreact_internal.agenda a
            WHERE a.rule_version_id IN (
                SELECT rule_version_id FROM pgreact_internal.derivation_rule_versions)), '[]'::jsonb)
    ) INTO actual;
    IF actual IS DISTINCT FROM jsonb_build_object(
        'fact', jsonb_build_object('patient_id', 7, 'diagnosis', 'influenza'),
        'support', jsonb_build_object('patient_id', 7, 'diagnosis', 'influenza'),
        'derived_agenda', '[]'::jsonb) THEN
        RAISE EXCEPTION 'M7 boundary output changed: %', actual;
    END IF;
END $$;

SELECT 'M7 non-recursion, retention, mutation, and authorization checks passed' AS result;
