\set ON_ERROR_STOP on
CREATE TEMP TABLE m17_before_upgrade AS SELECT jsonb_build_object(
    'programs',(SELECT jsonb_agg(to_jsonb(value) ORDER BY program_version_id)
                FROM pgreact_internal.derivation_program_versions value),
    'inputs',(SELECT jsonb_agg(to_jsonb(value) ORDER BY program_version_id,rule_version_id)
              FROM pgreact_internal.derivation_program_aggregate_inputs value),
    'facts',(SELECT jsonb_agg(to_jsonb(value) ORDER BY relation_version_id,semantic_key)
             FROM pgreact_internal.derived_facts value),
    'supports',(SELECT jsonb_agg(to_jsonb(value) ORDER BY support_id)
                FROM pgreact_internal.derived_supports value),
    'evidence',(SELECT jsonb_agg(to_jsonb(value) ORDER BY evidence_id)
                FROM pgreact_internal.aggregate_dependency_evidence value),
    'agenda',(SELECT jsonb_agg(to_jsonb(value) ORDER BY episode_id)
              FROM pgreact_internal.agenda value)) AS state;

ALTER EXTENSION pg_react UPDATE TO '0.14.0';

DO $$
DECLARE actual jsonb;
BEGIN
    SELECT jsonb_build_object(
        'programs',(SELECT jsonb_agg(to_jsonb(value) ORDER BY program_version_id)
                    FROM pgreact_internal.derivation_program_versions value),
        'inputs',(SELECT jsonb_agg(to_jsonb(value) ORDER BY program_version_id,rule_version_id)
                  FROM pgreact_internal.derivation_program_aggregate_inputs value),
        'facts',(SELECT jsonb_agg(to_jsonb(value) ORDER BY relation_version_id,semantic_key)
                 FROM pgreact_internal.derived_facts value),
        'supports',(SELECT jsonb_agg(to_jsonb(value) ORDER BY support_id)
                    FROM pgreact_internal.derived_supports value),
        'evidence',(SELECT jsonb_agg(to_jsonb(value) ORDER BY evidence_id)
                    FROM pgreact_internal.aggregate_dependency_evidence value),
        'agenda',(SELECT jsonb_agg(to_jsonb(value) ORDER BY episode_id)
                  FROM pgreact_internal.agenda value))
    INTO actual;
    IF (SELECT extversion FROM pg_extension WHERE extname='pg_react') <> '0.14.0'
       OR actual IS DISTINCT FROM (SELECT state FROM m17_before_upgrade)
       OR EXISTS (SELECT 1 FROM pgreact_internal.window_programs)
       OR to_regprocedure('pgreact_api.request_watermark(text,text,name,timestamptz)') IS NULL THEN
        RAISE EXCEPTION 'M17 populated 0.13.0 to 0.14.0 upgrade changed inherited state: %',actual;
    END IF;
END
$$;

INSERT INTO m16_upgrade.items VALUES (3,7);
SELECT pgreact_api.run();
DO $$
DECLARE actual jsonb;
BEGIN
    SELECT jsonb_build_object(
        'facts',(SELECT jsonb_agg(to_jsonb(fact) ORDER BY id) FROM m16_upgrade.alert fact),
        'evidence',(SELECT jsonb_agg(jsonb_build_object(
            'function',aggregate_function,'value',exact_value,
            'threshold',typed_threshold,'truth',truth_result)
            ORDER BY rule_name,public_group_key)
            FROM pgreact.aggregate_dependency_evidence WHERE program_name='m16.upgrade'),
        'windows',(SELECT COALESCE(jsonb_agg(to_jsonb(value)),'[]'::jsonb)
                   FROM pgreact_internal.window_programs value))
    INTO actual;
    IF actual IS DISTINCT FROM jsonb_build_object(
        'facts',jsonb_build_array(jsonb_build_object('id',7)),
        'evidence',jsonb_build_array(jsonb_build_object(
            'function','COUNT_STAR','value','3','threshold','2','truth',true)),
        'windows','[]'::jsonb) THEN
        RAISE EXCEPTION 'M17 upgraded M16 program did not continue exactly: %',actual;
    END IF;
END
$$;
SELECT 'M17 populated 0.13.0 to 0.14.0 upgrade and continued execution passed';
