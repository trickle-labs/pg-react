\set ON_ERROR_STOP on

DO $$
DECLARE actual jsonb; expected jsonb;
BEGIN
    SELECT jsonb_build_object(
        'facts', (SELECT jsonb_agg(jsonb_build_object(
            'id', semantic_key, 'support_count', support_count,
            'first_frontier', first_frontier, 'last_frontier', last_frontier)
            ORDER BY semantic_key)
            FROM pgreact.current_facts((SELECT relation_version_id FROM m7_concurrency.control))),
        'supports', (SELECT jsonb_agg(jsonb_build_object(
            'rule', rule_name || '@' || rule_version,
            'generation', activation_generation, 'source_binding', source_binding,
            'active', active, 'first_frontier', first_frontier,
            'last_frontier', last_frontier) ORDER BY rule_name, activation_generation)
            FROM pgreact.support_history
            WHERE relation_version_id = (SELECT relation_version_id FROM m7_concurrency.control)),
        'rules', (SELECT jsonb_agg(jsonb_build_object(
            'name', rule_name, 'state', state) ORDER BY rule_name)
            FROM pgreact.rules WHERE rule_name LIKE 'm7-concurrency-%'),
        'view_options', (SELECT jsonb_object_agg(c.relname, to_jsonb(c.reloptions) ORDER BY c.relname)
            FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = 'm7_concurrency'
              AND c.relname IN ('source_active', 'current_fact', 'observe_fact')),
        'derived_health', (SELECT COALESCE(jsonb_agg(to_jsonb(h) ORDER BY code), '[]'::jsonb)
            FROM pgreact.health_check() h WHERE code LIKE 'DERIVED_%'),
        'derived_agenda', (SELECT count(*) FROM pgreact.episodes
            WHERE rule_version_id = (SELECT derivation_version_id FROM m7_concurrency.control))
    ) INTO actual;
    expected := jsonb_build_object(
        'facts', jsonb_build_array(jsonb_build_object(
            'id', 1, 'support_count', 1, 'first_frontier', 1, 'last_frontier', 1)),
        'supports', jsonb_build_array(jsonb_build_object(
            'rule', 'm7-concurrency-derivation@1', 'generation', 1,
            'source_binding', jsonb_build_object('id', 1), 'active', true,
            'first_frontier', 1, 'last_frontier', NULL)),
        'rules', jsonb_build_array(
            jsonb_build_object('name', 'm7-concurrency-derivation', 'state', 'ACTIVE'),
            jsonb_build_object('name', 'm7-concurrency-observer', 'state', 'ACTIVE')),
        'view_options', jsonb_build_object(
            'current_fact', jsonb_build_array('security_barrier=true'),
            'observe_fact', NULL, 'source_active', NULL),
        'derived_health', jsonb_build_array(),
        'derived_agenda', 0);
    IF actual IS DISTINCT FROM expected THEN
        RAISE EXCEPTION 'M7 concurrent lifecycle changed the graph: %', actual;
    END IF;
END
$$;

SELECT 'M7 concurrent refresh and DDL serialization passed' AS result;
