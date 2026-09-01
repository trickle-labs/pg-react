\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';

DO $m53$
DECLARE
    member pgreact_api.declaration;
    decision pgreact_api.declaration;
    support pgreact_api.declaration;
    parameter pgreact_api.declaration;
    package pgreact_api.declaration;
    invalid pgreact_api.declaration;
    validation jsonb;
    semantic jsonb;
    comparison jsonb;
    doctor jsonb;
    preview jsonb;
    deployed jsonb;
    status jsonb;
    exported jsonb;
    removed jsonb;
    findings jsonb;
    expected jsonb;
    contents jsonb;
    dependencies jsonb;
    expected_differences jsonb;
BEGIN
    IF to_regprocedure('pgreact.shared_condition(text,regclass,name[],text)') IS NULL
       OR to_regprocedure('pgreact.parameter_family(text,regclass,name,name[])') IS NULL
       OR to_regprocedure('pgreact.policy_set(text,text,pgreact_api.declaration[],regclass,name[],pgreact_api.declaration[],jsonb,timestamptz,timestamptz,integer)') IS NULL
       OR to_regclass('pgreact.policy_set_contents') IS NULL
       OR to_regclass('pgreact.policy_set_dependencies') IS NULL THEN
        RAISE EXCEPTION 'M53 public package inventory is incomplete';
    END IF;

    member := pgreact_api.declaration('rule', 'm53-package-rule', jsonb_build_object(
        'condition', 'm43_reference.account_conditions', 'semantic_key', 'account_id',
        'kind', 'CONSTRAINT', 'salience', 10));
    decision := pgreact_api.declaration('decision_program', 'm53-package-decision', jsonb_build_object(
        'candidate_relation', 'm43_reference.routes', 'subject_key', 'account_id',
        'candidate_key', 'route_id', 'priority', 'priority',
        'results', jsonb_build_array('result'),
        'valid_from', '2026-09-01 00:00:00+00'));
    support := pgreact.shared_condition(
        'm53-package-condition', 'm43_reference.account_conditions'::regclass,
        ARRAY['account_id'::name]);
    parameter := pgreact.parameter_family(
        'm53-package-parameters', 'm43_reference.accounts'::regclass,
        'account_id'::name, ARRAY['account_id'::name]);
    package := pgreact.policy_set(
        'm53-package', '2026-09', ARRAY[member, decision], 'm43_reference.accounts'::regclass,
        ARRAY['account_id'::name], ARRAY[support, parameter],
        jsonb_build_array(jsonb_build_object(
            'from', jsonb_build_object('kind', 'rule', 'name', 'm53-package-rule', 'version', '1'),
            'on', jsonb_build_object('kind', 'shared_condition', 'name',
                                     'm53-package-condition', 'version', '1')),
        jsonb_build_object(
            'from', jsonb_build_object('kind', 'decision_program', 'name',
                                       'm53-package-decision', 'version', '1'),
            'on', jsonb_build_object('kind', 'parameter_family', 'name',
                                     'm53-package-parameters', 'version', '1'))),
        '2026-09-01 00:00:00+00', '2026-12-31 00:00:00+00', 100);
    preview := pgreact.preview(package);
    expected := jsonb_build_array(
        jsonb_build_object('action', 'ADD', 'kind', 'parameter_family', 'name',
                           'm53-package-parameters', 'version', '1'),
        jsonb_build_object('action', 'ADD', 'kind', 'shared_condition',
                           'name', 'm53-package-condition', 'version', '1'),
        jsonb_build_object('action', 'ADD', 'kind', 'decision_program', 'name',
                           'm53-package-decision', 'version', '1'),
        jsonb_build_object('action', 'ADD', 'kind', 'rule', 'name', 'm53-package-rule', 'version', '1'),
        jsonb_build_object('action', 'ADD', 'kind', 'policy_set',
                           'name', 'm53-package', 'version', '2026-09'));
    IF preview ->> 'contract_version' <> '53'
       OR preview ->> 'operation' <> 'preview'
       OR preview ->> 'state' <> 'ready'
       OR preview -> 'summary' ->> 'read_only' <> 'true'
       OR preview -> 'summary' -> 'action_plan' IS DISTINCT FROM expected
       OR preview -> 'summary' ->> 'definition_digest' IS DISTINCT FROM
          pgreact_internal.m53_package_digest(preview -> 'evidence' -> 'normalized_declaration')
       OR length(preview -> 'summary' ->> 'plan_digest') <> 64
       OR preview -> 'summary' -> 'blockers' IS DISTINCT FROM '[]'::jsonb
       OR preview -> 'findings' IS DISTINCT FROM '[]'::jsonb
       OR preview ->> 'truncated' <> 'false' THEN
        RAISE EXCEPTION 'M53 package preview mismatch: %', preview;
    END IF;

    INSERT INTO m43_reference.accounts VALUES (11);
    BEGIN
        PERFORM pgreact.deploy(package, jsonb_build_object(
            'plan_digest', preview -> 'summary' ->> 'plan_digest'));
        RAISE EXCEPTION 'M53 deployment accepted a stale source fingerprint';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE 'M53_STALE_PREVIEW:%' THEN
            RAISE;
        END IF;
    END;
    DELETE FROM m43_reference.accounts WHERE account_id = 11;

    validation := pgreact.validate(package);
    expected := jsonb_build_object(
        'contract_version', 53, 'operation', 'validate', 'state', 'valid',
        'target', jsonb_build_object('kind', 'policy_set', 'name', 'm53-package',
                                     'version', '2026-09'), 'complete', true,
        'normalized_declaration', preview -> 'evidence' -> 'normalized_declaration',
        'limits', jsonb_build_object('members', 2, 'support', 2, 'dependencies', 2),
        'findings', '[]'::jsonb, 'read_only', true, 'truncated', false);
    IF validation IS DISTINCT FROM expected THEN
        RAISE EXCEPTION 'M53 package validation mismatch: %', validation;
    END IF;

    deployed := pgreact.deploy(package, jsonb_build_object(
        'plan_digest', preview -> 'summary' ->> 'plan_digest'));
    IF deployed ->> 'contract_version' <> '53'
       OR deployed ->> 'operation' <> 'deploy'
       OR deployed ->> 'state' <> 'deployed'
       OR deployed -> 'package' ->> 'complete' <> 'true'
       OR deployed -> 'package' ->> 'definition_digest' IS DISTINCT FROM
          preview -> 'summary' ->> 'definition_digest'
       OR deployed -> 'package' ->> 'plan_digest' IS DISTINCT FROM
          preview -> 'summary' ->> 'plan_digest'
       OR deployed -> 'findings' IS DISTINCT FROM '[]'::jsonb THEN
        RAISE EXCEPTION 'M53 package deployment mismatch: %', deployed;
    END IF;

    status := pgreact.status('m53-package');
    IF status ->> 'contract_version' <> '53'
       OR status -> 'package' ->> 'complete' <> 'true'
       OR status -> 'package' ->> 'format_version' <> '1'
       OR status -> 'package' ->> 'definition_digest' IS DISTINCT FROM
          preview -> 'summary' ->> 'definition_digest'
       OR status -> 'package' -> 'dependencies' IS DISTINCT FROM
          preview -> 'evidence' -> 'normalized_declaration' -> 'spec' -> 'dependencies'
       OR status -> 'package' -> 'supports' IS DISTINCT FROM
          preview -> 'evidence' -> 'normalized_declaration' -> 'spec' -> 'support' THEN
        RAISE EXCEPTION 'M53 package status mismatch: %', status;
    END IF;

    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'kind', node ->> 'kind', 'name', node ->> 'name',
               'version', COALESCE(node ->> 'version', '1'),
               'change_kind', 'unchanged', 'before', node, 'after', node)
               ORDER BY group_order, node ->> 'kind', node ->> 'name'), '[]'::jsonb)
    INTO expected_differences
    FROM (
        SELECT 0 AS group_order, value AS node
        FROM jsonb_array_elements(preview -> 'evidence' -> 'normalized_declaration' -> 'spec' -> 'members') value
        UNION ALL
        SELECT 1 AS group_order, value AS node
        FROM jsonb_array_elements(preview -> 'evidence' -> 'normalized_declaration' -> 'spec' -> 'support') value
    ) nodes;
    semantic := pgreact.semantic_diff(package);
    expected := jsonb_build_object(
        'contract_version', 53, 'operation', 'semantic_diff', 'state', 'complete',
        'target', jsonb_build_object('kind', 'policy_set', 'name', 'm53-package',
                                     'version', '2026-09'),
        'proposed_declaration_digest', preview -> 'summary' ->> 'definition_digest',
        'deployed_declaration_digest', preview -> 'summary' ->> 'definition_digest',
        'differences', expected_differences, 'opaque', '[]'::jsonb,
        'completeness', jsonb_build_object('complete', true),
        'limits', jsonb_build_object('reached', '[]'::jsonb), 'findings', '[]'::jsonb,
        'semantic_digest', pgreact_internal.m53_package_digest(jsonb_build_object(
            'target', jsonb_build_object('kind', 'policy_set', 'name', 'm53-package',
                                         'version', '2026-09'),
            'differences', expected_differences)),
        'read_only', true, 'truncated', false);
    IF semantic IS DISTINCT FROM expected THEN
        RAISE EXCEPTION 'M53 package semantic diff mismatch: %', semantic;
    END IF;
    comparison := pgreact.compare(package);
    IF comparison IS DISTINCT FROM semantic || jsonb_build_object(
        'operation', 'compare', 'package', true) THEN
        RAISE EXCEPTION 'M53 package compare mismatch: %', comparison;
    END IF;
    doctor := pgreact.doctor('m53-package');
    expected := jsonb_build_object(
        'contract_version', 53, 'operation', 'doctor', 'state', 'ready',
        'target', status -> 'target', 'package', status -> 'package',
        'diagnostics', status -> 'findings', 'read_only', true, 'truncated', false);
    IF doctor IS DISTINCT FROM expected THEN
        RAISE EXCEPTION 'M53 package doctor mismatch: %', doctor;
    END IF;

    SELECT jsonb_agg(to_jsonb(row_data) ORDER BY row_data.role, row_data.kind, row_data.object_name)
    INTO contents
    FROM pgreact.policy_set_contents row_data
    WHERE row_data.name = 'm53-package' AND row_data.version = '2026-09';
    expected := jsonb_build_array(
        jsonb_build_object('name', 'm53-package', 'version', '2026-09', 'role', 'member',
                           'kind', 'decision_program', 'object_name', 'm53-package-decision',
                           'object_version', '1', 'definition_digest',
                           preview -> 'summary' ->> 'definition_digest', 'state', 'DEPLOYED'),
        jsonb_build_object('name', 'm53-package', 'version', '2026-09', 'role', 'member',
                           'kind', 'rule', 'object_name', 'm53-package-rule',
                           'object_version', '1', 'definition_digest',
                           preview -> 'summary' ->> 'definition_digest', 'state', 'DEPLOYED'),
        jsonb_build_object('name', 'm53-package', 'version', '2026-09', 'role', 'support',
                           'kind', 'parameter_family', 'object_name', 'm53-package-parameters',
                           'object_version', '1', 'definition_digest',
                           pgreact_internal.m53_package_digest(
                               preview -> 'evidence' -> 'normalized_declaration' -> 'spec' -> 'support' -> 0 -> 'declaration'),
                           'state', 'DEPLOYED'),
        jsonb_build_object('name', 'm53-package', 'version', '2026-09', 'role', 'support',
                           'kind', 'shared_condition', 'object_name', 'm53-package-condition',
                           'object_version', '1', 'definition_digest',
                           pgreact_internal.m53_package_digest(
                               preview -> 'evidence' -> 'normalized_declaration' -> 'spec' -> 'support' -> 1 -> 'declaration'),
                           'state', 'DEPLOYED'));
    IF contents IS DISTINCT FROM expected THEN
        RAISE EXCEPTION 'M53 package contents mismatch: %', contents;
    END IF;

    SELECT jsonb_agg(to_jsonb(row_data) ORDER BY row_data.ordinal)
    INTO dependencies
    FROM pgreact.policy_set_dependencies row_data
    WHERE row_data.name = 'm53-package' AND row_data.version = '2026-09';
    expected := jsonb_build_array(
        jsonb_build_object('name', 'm53-package', 'version', '2026-09', 'ordinal', 1,
                           'from_kind', 'decision_program', 'from_name', 'm53-package-decision',
                           'from_version', '1', 'on_kind', 'parameter_family',
                           'on_name', 'm53-package-parameters', 'on_version', '1',
                           'definition_digest', preview -> 'summary' ->> 'definition_digest', 'state', 'DEPLOYED'),
        jsonb_build_object('name', 'm53-package', 'version', '2026-09', 'ordinal', 2,
                           'from_kind', 'rule', 'from_name', 'm53-package-rule', 'from_version', '1',
                           'on_kind', 'shared_condition', 'on_name', 'm53-package-condition',
                           'on_version', '1', 'definition_digest',
                           preview -> 'summary' ->> 'definition_digest', 'state', 'DEPLOYED'));
    IF dependencies IS DISTINCT FROM expected THEN
        RAISE EXCEPTION 'M53 package dependencies mismatch: %', dependencies;
    END IF;

    exported := pgreact.export('m53-package', 'policy_set', '2026-09');
    IF exported IS DISTINCT FROM jsonb_build_object(
        'api_version', '1', 'kind', 'policy_set', 'name', 'm53-package',
        'format_version', 1,
        'spec', preview -> 'evidence' -> 'normalized_declaration' -> 'spec',
        'definition_digest', preview -> 'summary' ->> 'definition_digest',
        'digest', preview -> 'summary' ->> 'definition_digest') THEN
        RAISE EXCEPTION 'M53 package export mismatch: %', exported;
    END IF;

    BEGIN
        PERFORM pgreact.import(jsonb_set(exported, '{definition_digest}', '"bad"'::jsonb));
        RAISE EXCEPTION 'M53 import accepted a bad digest';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE 'M53_IMPORT_DIGEST:%' THEN
            RAISE;
        END IF;
    END;

    removed := pgreact.remove('m53-package');
    IF removed ->> 'contract_version' <> '53'
       OR removed ->> 'operation' <> 'remove'
       OR removed ->> 'state' <> 'removed' THEN
        RAISE EXCEPTION 'M53 package removal mismatch: %', removed;
    END IF;
    IF EXISTS (SELECT 1 FROM pgreact_internal.api_declarations row_data
               WHERE row_data.object_name IN ('m53-package-rule', 'm53-package-decision')
                 AND row_data.state = 'DEPLOYED') THEN
        RAISE EXCEPTION 'M53 package removal left a deployed child';
    END IF;

    member := pgreact_api.declaration('rule', 'm53-adopt-rule', jsonb_build_object(
        'condition', 'm43_reference.account_conditions', 'semantic_key', 'account_id',
        'kind', 'CONSTRAINT', 'salience', 10));
    PERFORM pgreact_api.deploy(member);
    package := pgreact.policy_set(
        'm53-adopt', '2026-09', ARRAY[member], 'm43_reference.accounts'::regclass,
        ARRAY['account_id'::name], ARRAY[]::pgreact_api.declaration[], '[]'::jsonb,
        '2026-09-01 00:00:00+00', NULL, 100);
    preview := pgreact.preview(package);
    expected := jsonb_build_array(
        jsonb_build_object('action', 'ADOPT', 'kind', 'rule', 'name', 'm53-adopt-rule', 'version', '1'),
        jsonb_build_object('action', 'ADD', 'kind', 'policy_set', 'name', 'm53-adopt', 'version', '2026-09'));
    IF preview -> 'summary' -> 'action_plan' IS DISTINCT FROM expected THEN
        RAISE EXCEPTION 'M53 adoption preview mismatch: %', preview;
    END IF;
    BEGIN
        PERFORM pgreact.deploy(package, jsonb_build_object(
            'plan_digest', preview -> 'summary' ->> 'plan_digest'));
        RAISE EXCEPTION 'M53 deployment adopted a child without consent';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE 'M53_POLICY_ADOPTION_REQUIRED:%' THEN
            RAISE;
        END IF;
    END;
    deployed := pgreact.deploy(package, jsonb_build_object(
        'plan_digest', preview -> 'summary' ->> 'plan_digest',
        'adopt', jsonb_build_array(jsonb_build_object(
            'kind', 'rule', 'name', 'm53-adopt-rule', 'version', '1'))));
    IF deployed ->> 'state' <> 'deployed' OR deployed -> 'package' ->> 'complete' <> 'true' THEN
        RAISE EXCEPTION 'M53 adoption deployment mismatch: %', deployed;
    END IF;
    removed := pgreact.remove('m53-adopt');
    IF removed ->> 'state' <> 'removed'
       OR EXISTS (SELECT 1 FROM pgreact_internal.api_declarations row_data
                  WHERE row_data.object_name = 'm53-adopt-rule'
                    AND row_data.state = 'DEPLOYED') THEN
        RAISE EXCEPTION 'M53 adopted child removal mismatch: %', removed;
    END IF;

    invalid := pgreact_api.declaration('policy_set', 'm53-invalid', jsonb_build_object(
        'version', '2026-09', 'members', jsonb_build_array(), 'support', jsonb_build_array(),
        'dependencies', jsonb_build_array(),
        'applicability', jsonb_build_object('source_kind', 'relation',
                                            'relation', 'm43_reference.accounts',
                                            'subject_keys', jsonb_build_array('account_id')),
        'valid_from', '2026-09-01 00:00:00+00'));
    preview := pgreact.preview(invalid);
    findings := jsonb_build_array(pgreact_internal.m53_finding(
        'M53_POLICY_MEMBERS', 'ERROR', 'spec.members',
        'a complete policy set needs at least one member',
        'Add a rule or decision declaration.'));
    expected := jsonb_build_object(
        'contract_version', 53, 'operation', 'preview',
        'target', jsonb_build_object('kind', 'policy_set', 'name', 'm53-invalid'),
        'state', 'attention', 'summary', jsonb_build_object(
            'read_only', true,
            'definition_digest', pgreact_internal.m53_package_digest(
                preview -> 'evidence' -> 'normalized_declaration'),
            'action_plan', '[]'::jsonb, 'plan_digest', NULL, 'blockers', findings),
        'findings', findings,
        'evidence', jsonb_build_object('normalized_declaration', preview -> 'evidence' -> 'normalized_declaration'),
        'truncated', false);
    IF preview IS DISTINCT FROM expected THEN
        RAISE EXCEPTION 'M53 invalid package output mismatch: %', preview;
    END IF;
END
$m53$;
