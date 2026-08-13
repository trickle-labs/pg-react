\set ON_ERROR_STOP on
SET SESSION AUTHORIZATION m16_author;
SELECT pgreact_api.declare_derived_relation(
    'm16.sum_alert', 'm16.fact_row'::regtype, ARRAY['id']::name[]);
DO $$
DECLARE
    definition jsonb := jsonb_build_object(
        'name', 'm16.logical', 'version', 1, 'max_iterations', 4, 'max_facts', 4,
        'rules', jsonb_build_array(jsonb_build_object(
            'name', 'm16.logical.sum', 'definition', 'm16.group_source',
            'key', 'id', 'target', 'm16.sum_alert', 'version', 1,
            'aggregate_input', jsonb_build_object(
                'relation', 'm16.item_source', 'key', 'id', 'function', 'SUM',
                'expression', 'amount', 'comparison', '>=', 'threshold', 4))));
    preview jsonb;
BEGIN
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
        'source', (SELECT jsonb_agg(to_jsonb(item) ORDER BY item_id) FROM m16.items item),
        'facts', (SELECT jsonb_agg(to_jsonb(fact) ORDER BY id) FROM m16.sum_alert fact),
        'evidence', jsonb_agg(jsonb_build_object(
            'key', public_group_key, 'function', aggregate_function,
            'input_type', input_type_name, 'result_type', result_type_name,
            'value', exact_value, 'threshold', typed_threshold, 'truth', truth_result)
            ORDER BY public_group_key))
    INTO actual FROM pgreact.aggregate_dependency_evidence
    WHERE program_name = 'm16.logical';
    IF actual IS DISTINCT FROM jsonb_build_object(
        'source', jsonb_build_array(
            jsonb_build_object('item_id',1,'id',1,'units',NULL,'amount',4.25,
                'label','z','occurred_on','2026-01-01','overflow_value',NULL),
            jsonb_build_object('item_id',3,'id',1,'units',5,'amount',NULL,
                'label',NULL,'occurred_on','2026-03-01','overflow_value',NULL)),
        'facts', jsonb_build_array(jsonb_build_object('id',1)),
        'evidence', jsonb_build_array(
            jsonb_build_object('key',1,'function','SUM','input_type','numeric',
                'result_type','numeric','value','4.25','threshold','4','truth',true),
            jsonb_build_object('key',2,'function','SUM','input_type','numeric',
                'result_type','numeric','value',NULL,'threshold','4','truth',NULL))) THEN
        RAISE EXCEPTION 'M16 logical declaration replay changed typed aggregate state: %', actual;
    END IF;
END
$$;
SELECT 'M16 logical data restore and typed declaration replay passed';
