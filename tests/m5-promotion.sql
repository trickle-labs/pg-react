\set ON_ERROR_STOP on

DO $$
DECLARE
    manifest jsonb;
    environment_mappings jsonb;
    actual jsonb;
    expected jsonb;
    digest text;
BEGIN
    SELECT definition, mappings INTO manifest, environment_mappings
    FROM m5_fixture.manifests WHERE version = '1';
    SELECT jsonb_agg(to_jsonb(v) ORDER BY code, object_identity) INTO actual
    FROM pgreact.validate_pack(manifest, environment_mappings) v;
    expected := jsonb_build_array(jsonb_build_object(
        'contract_version', 1,
        'code', 'OK',
        'severity', 'INFO',
        'object_identity', 'risk-pack',
        'message', 'rule pack is valid for this environment',
        'hint', 'Preview the atomic plan before deployment.',
        'details', jsonb_build_object(
            'version', '1',
            'mapped_owner', current_user,
            'rule_count', 3,
            'removal_count', 0
        )
    ));
    IF actual IS DISTINCT FROM expected THEN
        RAISE EXCEPTION 'unexpected validation output: %', actual;
    END IF;

    SELECT min(plan_digest) INTO digest
    FROM pgreact.preview_pack(manifest, environment_mappings);
    IF digest !~ '^[0-9a-f]{64}$' OR EXISTS (
        SELECT 1 FROM pgreact.preview_pack(manifest, environment_mappings)
        WHERE plan_digest <> digest
    ) THEN
        RAISE EXCEPTION 'preview did not return one stable SHA-256 plan digest';
    END IF;
    PERFORM pgreact.deploy_pack(manifest, digest, environment_mappings);

    SELECT jsonb_agg(jsonb_build_object(
        'version', version,
        'status', status,
        'actions', (
            SELECT jsonb_agg(value - 'old_rule_version_id' - 'new_rule_version_id' ORDER BY value ->> 'order')
            FROM jsonb_array_elements(actions) AS a(value)
        )
    ) ORDER BY deployed_at) INTO actual
    FROM pgreact.pack_history('risk-pack');
    expected := jsonb_build_array(jsonb_build_object(
        'version', '1',
        'status', 'ACTIVE',
        'actions', jsonb_build_array(
            jsonb_build_object('order', 1, 'action', 'ADD', 'rule', 'risk-base',
                'old_work_policy', 'DRAIN_OLD', 'details', jsonb_build_object(
                    'source', 'logical.base', 'dependencies', jsonb_build_array())),
            jsonb_build_object('order', 2, 'action', 'ADD', 'rule', 'risk-command',
                'old_work_policy', 'DRAIN_OLD', 'details', jsonb_build_object(
                    'source', 'logical.command', 'dependencies', jsonb_build_array('risk-base'))),
            jsonb_build_object('order', 3, 'action', 'ADD', 'rule', 'risk-outbox',
                'old_work_policy', 'DRAIN_OLD', 'details', jsonb_build_object(
                    'source', 'logical.command', 'dependencies', jsonb_build_array('risk-command')))
        )
    ));
    IF actual IS DISTINCT FROM expected THEN
        RAISE EXCEPTION 'unexpected deployment history: %', actual;
    END IF;
END
$$;

SELECT 'M5 portable promotion checks passed' AS result;
