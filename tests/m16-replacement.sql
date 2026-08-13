\set ON_ERROR_STOP on
SET statement_timeout = '3min';
SET SESSION AUTHORIZATION m16_author;
SELECT pgreact_api.declare_derived_relation(
    'm16.replace_alert', 'm16.fact_row'::regtype, ARRAY['id']::name[]);
CREATE TEMP TABLE m16_replace_definition AS
SELECT jsonb_build_object(
    'name', 'm16.replace', 'version', 1, 'max_iterations', 4, 'max_facts', 4,
    'rules', jsonb_build_array(jsonb_build_object(
        'name', 'm16.replace.sum', 'definition', 'm16.group_source',
        'key', 'id', 'target', 'm16.replace_alert', 'version', 1,
        'aggregate_input', jsonb_build_object(
            'relation', 'm16.item_source', 'key', 'id', 'function', 'SUM',
            'expression', 'amount', 'comparison', '>=', 'threshold', 100)))) AS definition;
DO $$
DECLARE definition jsonb; preview jsonb;
BEGIN
    SELECT m16_replace_definition.definition INTO definition FROM m16_replace_definition;
    preview := pgreact_api.preview_program(definition);
    PERFORM pgreact_api.deploy_program(definition, preview ->> 'plan_digest');
END
$$;
RESET SESSION AUTHORIZATION;
SET SESSION AUTHORIZATION m16_operator;
SELECT pgreact_api.run();
RESET SESSION AUTHORIZATION;

SET SESSION AUTHORIZATION m16_author;
DO $$
DECLARE definition jsonb; preview jsonb;
BEGIN
    SELECT jsonb_set(jsonb_set(m16_replace_definition.definition, '{version}', '2'),
                     '{rules,0,version}', '2')
    INTO definition FROM m16_replace_definition;
    definition := jsonb_set(definition, '{rules,0,aggregate_input,threshold}', '4');
    preview := pgreact_api.preview_program(definition);
    PERFORM pgreact_api.deploy_program(definition, preview ->> 'plan_digest');
END
$$;
RESET SESSION AUTHORIZATION;
SET SESSION AUTHORIZATION m16_operator;
SELECT pgreact_api.run();
RESET SESSION AUTHORIZATION;

DO $$
DECLARE actual jsonb;
BEGIN
    SELECT jsonb_build_object(
        'programs', jsonb_agg(DISTINCT jsonb_build_object(
            'version', evidence.program_version, 'state', state)),
        'facts', (SELECT jsonb_agg(to_jsonb(row_value) ORDER BY id)
                  FROM m16.replace_alert row_value),
        'evidence', jsonb_agg(jsonb_build_object(
            'key', public_group_key, 'version', evidence.program_version, 'value', exact_value,
            'threshold', typed_threshold, 'truth', truth_result)
            ORDER BY public_group_key))
    INTO actual
    FROM pgreact.aggregate_dependency_evidence evidence
    JOIN pgreact.derivation_programs program USING (program_version_id)
    WHERE evidence.program_name = 'm16.replace';
    IF actual IS DISTINCT FROM jsonb_build_object(
        'programs', jsonb_build_array(jsonb_build_object('version', 2, 'state', 'ACTIVE')),
        'facts', jsonb_build_array(jsonb_build_object('id', 1)),
        'evidence', jsonb_build_array(
            jsonb_build_object('key', 1, 'version', 2, 'value', '4.25',
                'threshold', '4', 'truth', true),
            jsonb_build_object('key', 2, 'version', 2, 'value', NULL,
                'threshold', '4', 'truth', NULL))) THEN
        RAISE EXCEPTION 'M16 typed aggregate replacement changed: %', actual;
    END IF;
END
$$;

SET SESSION AUTHORIZATION m16_author;
SELECT pgreact_api.remove_program('m16.replace', 2);
RESET SESSION AUTHORIZATION;
DO $$
DECLARE actual jsonb;
BEGIN
    SELECT jsonb_build_object(
        'active_programs', COALESCE(jsonb_agg(jsonb_build_object(
            'version', program_version, 'state', state) ORDER BY program_version)
            FILTER (WHERE state = 'ACTIVE'), '[]'::jsonb),
        'facts', (SELECT COALESCE(jsonb_agg(to_jsonb(row_value)), '[]'::jsonb)
                  FROM m16.replace_alert row_value),
        'evidence', (SELECT COALESCE(jsonb_agg(jsonb_build_object(
            'key', public_group_key, 'version', program_version,
            'value', exact_value, 'truth', truth_result)
            ORDER BY public_group_key), '[]'::jsonb)
            FROM pgreact.aggregate_dependency_evidence
            WHERE program_name = 'm16.replace'))
    INTO actual FROM pgreact.derivation_programs WHERE program_name = 'm16.replace';
    IF actual IS DISTINCT FROM jsonb_build_object(
        'active_programs', '[]'::jsonb, 'facts', '[]'::jsonb,
        'evidence', '[]'::jsonb) THEN
        RAISE EXCEPTION 'M16 typed aggregate removal changed: %', actual;
    END IF;
END
$$;
SELECT 'M16 typed aggregate replacement and removal gate passed';
