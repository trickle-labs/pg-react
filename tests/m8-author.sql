\set ON_ERROR_STOP on

CREATE ROLE m8_author LOGIN;
DO $$
DECLARE actual jsonb; expected jsonb;
BEGIN
    actual := jsonb_build_object(
        'derivation_programs_select', has_table_privilege(
            'm8_author', 'pgreact.derivation_programs', 'SELECT'),
        'derivation_program_runs_select', has_table_privilege(
            'm8_author', 'pgreact.derivation_program_runs', 'SELECT'),
        'refresh_program_execute', has_function_privilege(
            'm8_author', 'pgreact.refresh_derivation_program(uuid)', 'EXECUTE'));
    expected := jsonb_build_object(
        'derivation_programs_select', false,
        'derivation_program_runs_select', false,
        'refresh_program_execute', false);
    IF actual IS DISTINCT FROM expected THEN
        RAISE EXCEPTION 'M8 private-by-default boundary changed: %', actual;
    END IF;
END $$;
SELECT format('GRANT CREATE ON DATABASE %I TO m8_author', current_database()) \gexec
GRANT USAGE ON SCHEMA pgreact TO m8_author;
GRANT USAGE ON SCHEMA pgtrickle TO m8_author;
GRANT ALL ON ALL TABLES IN SCHEMA pgtrickle TO m8_author;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA pgtrickle TO m8_author;
GRANT EXECUTE ON FUNCTION
    pgreact.validate_pack(jsonb, jsonb),
    pgreact.preview_pack(jsonb, jsonb),
    pgreact.deploy_pack(jsonb, text, jsonb),
    pgreact.pack_history(text),
    pgreact.explain_pack(text),
    pgreact.create_rule(text, regclass, name[], text, regprocedure, regprocedure,
                        regprocedure, text, name[], integer, text, name[], integer,
                        integer, numeric, integer),
    pgreact.validate_derivation_program(jsonb),
    pgreact.refresh_derivation_program(uuid),
    pgreact.explain_recursive_fact(uuid, uuid, bigint),
    pgreact.reconcile_derivation_program(uuid)
TO m8_author;
GRANT SELECT ON pgreact.derivation_programs, pgreact.derivation_components,
                pgreact.derivation_program_runs,
                pgreact.derived_relations, pgreact.derived_facts
TO m8_author;

SET SESSION AUTHORIZATION m8_author;
\ir /tmp/m8-setup.sql

CREATE SEQUENCE m8_ref.security_probe START WITH 1;
CREATE FUNCTION m8_ref.immutable_operator_trap(left_value bigint, right_value bigint)
RETURNS bigint
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
    PERFORM nextval('m8_ref.security_probe');
    RAISE EXCEPTION 'M8 malicious immutable operator function executed';
END
$$;
CREATE OPERATOR m8_ref.#@# (
    FUNCTION = m8_ref.immutable_operator_trap,
    LEFTARG = bigint,
    RIGHTARG = bigint
);
CREATE VIEW m8_ref.negative_immutable_operator AS
SELECT id
FROM m8_ref.left_seed
WHERE (0::bigint OPERATOR(m8_ref.#@#) 0::bigint) = 0;

DO $$
DECLARE actual jsonb; expected jsonb; probe jsonb;
BEGIN
    SELECT to_jsonb(d) INTO STRICT actual
    FROM pgreact.validate_derivation_program(jsonb_build_object(
        'name', 'negative_immutable_operator', 'version', 1,
        'max_iterations', 16, 'max_facts', 64,
        'rules', jsonb_build_array(jsonb_build_object(
            'name', 'negative_immutable_operator.rule',
            'definition', 'm8_ref.negative_immutable_operator',
            'key', 'id', 'target', 'm8_ref.c',
            'version', 1, 'inputs', '[]'::jsonb)))) d;
    expected := jsonb_build_object(
        'contract_version', 3, 'code', 'PROGRAM_FUNCTION_UNSUPPORTED',
        'severity', 'ERROR', 'object_identity', 'negative_immutable_operator.rule',
        'message', 'program sources may use only immutable pg_catalog functions',
        'hint', 'Remove stable, volatile, or user-defined executable dependencies.',
        'details', '{}'::jsonb);
    SELECT jsonb_build_object('last_value', last_value, 'is_called', is_called)
    INTO STRICT probe FROM m8_ref.security_probe;
    IF actual IS DISTINCT FROM expected
       OR probe IS DISTINCT FROM jsonb_build_object(
            'last_value', 1, 'is_called', false) THEN
        RAISE EXCEPTION 'M8 immutable-operator security boundary changed: %, probe=%',
            actual, probe;
    END IF;
END $$;

SELECT min(plan_digest) AS plan_digest
FROM pgreact.preview_pack(
    (SELECT definition FROM m8_ref.manifests WHERE version = 2),
    (SELECT mappings FROM m8_ref.manifests WHERE version = 2)) \gset
SELECT pgreact.deploy_pack(
    (SELECT definition FROM m8_ref.manifests WHERE version = 2), :'plan_digest',
    (SELECT mappings FROM m8_ref.manifests WHERE version = 2));
SELECT program_version_id
FROM pgreact.derivation_programs
WHERE program_name = 'm8.reference' AND state = 'ACTIVE' \gset
SELECT set_config('m8.program', :'program_version_id', false);
SELECT pgreact.refresh_derivation_program(current_setting('m8.program')::uuid) = 1
       AS refresh_noop \gset
SELECT pgreact.reconcile_derivation_program(current_setting('m8.program')::uuid) = 0
       AS reconcile_noop \gset
\if :refresh_noop
\else
  SELECT 1 / 0;
\endif
\if :reconcile_noop
\else
  SELECT 1 / 0;
\endif

DELETE FROM m8_ref.right_seed WHERE id = 7;
DO $$
DECLARE refresh_result bigint;
BEGIN
    PERFORM set_config('pgreact.test_fail_program_phase', 'after_iteration', true);
    refresh_result := pgreact.refresh_derivation_program(
        current_setting('m8.program')::uuid);
    IF refresh_result IS NOT NULL THEN
        RAISE EXCEPTION 'non-superuser injected refresh unexpectedly returned %', refresh_result;
    END IF;
END $$;
DO $$
DECLARE actual jsonb; expected jsonb; internal_runs oid;
BEGIN
    SELECT c.oid INTO STRICT internal_runs
    FROM pg_catalog.pg_class c
    JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'pgreact_internal'
      AND c.relname = 'derivation_program_runs';
    SELECT jsonb_agg(jsonb_build_object(
        'program', program_name || '@' || program_version,
        'prior_frontier', prior_frontier,
        'committed_frontier', committed_frontier,
        'iterations', iterations, 'fact_count', fact_count,
        'support_count', support_count, 'status', status,
        'error_sqlstate', error_sqlstate, 'error_message', error_message,
        'error_detail', error_detail, 'error_hint', error_hint,
        'requested_by', requested_by) ORDER BY run_id)
    INTO actual
    FROM pgreact.derivation_program_runs
    WHERE program_version_id = current_setting('m8.program')::uuid
      AND status = 'FAILED';
    expected := jsonb_build_array(jsonb_build_object(
        'program', 'm8.reference@2',
        'prior_frontier', 1, 'committed_frontier', 1,
        'iterations', 0, 'fact_count', NULL, 'support_count', NULL,
        'status', 'FAILED', 'error_sqlstate', 'P0001',
        'error_message',
            'injected derivation-program failure after after_iteration phase',
        'error_detail', NULL, 'error_hint', NULL,
        'requested_by', 'm8_author'));
    IF actual IS DISTINCT FROM expected
       OR has_table_privilege(session_user, internal_runs, 'SELECT') THEN
        RAISE EXCEPTION 'M8 public FAILED-run boundary changed: %, internal=%',
            actual, has_table_privilege(session_user, internal_runs, 'SELECT');
    END IF;
END $$;
INSERT INTO m8_ref.right_seed VALUES (7);
SELECT pgreact.refresh_derivation_program(current_setting('m8.program')::uuid) = 1
       AS retry_noop \gset
\if :retry_noop
\else
  SELECT 1 / 0;
\endif

DO $$
DECLARE actual jsonb; expected jsonb; explanation jsonb;
BEGIN
    explanation := pgreact.explain_recursive_fact(
        current_setting('m8.program')::uuid,
        (SELECT relation_version_id FROM pgreact.derived_relations
         WHERE relation_name = 'm8_ref.c' AND state = 'ACTIVE'), 7)
        #- '{proof,supports,0,logical_support_id}'
        #- '{proof,supports,0,inputs,0,supports,0,logical_support_id}'
        #- '{proof,supports,0,inputs,0,supports,0,inputs,0,supports,0,logical_support_id}'
        #- '{proof,supports,0,inputs,0,supports,0,inputs,0,supports,1,logical_support_id}';
    SELECT jsonb_build_object(
        'session_user', session_user, 'current_user', current_user,
        'superuser', (SELECT rolsuper FROM pg_roles WHERE rolname = session_user),
        'pack', (SELECT version FROM pgreact.pack_history('m8-reference-pack')
                 WHERE status = 'ACTIVE'),
        'program', (SELECT jsonb_build_object(
            'name', program_name || '@' || program_version,
            'owner', owner, 'state', state, 'frontier', frontier)
            FROM pgreact.derivation_programs
            WHERE program_version_id = current_setting('m8.program')::uuid),
        'components', (SELECT jsonb_agg(format('[%s]', (SELECT string_agg(
            upper(regexp_replace(regexp_replace(name, '^.*\.', ''), '@.*$', '')),
            ',' ORDER BY name) FROM unnest(c.target_relations) AS name))
            ORDER BY component_order)
            FROM pgreact.derivation_components c
            WHERE program_version_id = current_setting('m8.program')::uuid),
        'facts', (SELECT jsonb_agg(format('%s(%s)', relation, id)
                                   ORDER BY relation, id)
            FROM (SELECT 'A' relation, id FROM m8_ref.a
                  UNION ALL SELECT 'B', id FROM m8_ref.b
                  UNION ALL SELECT 'C', id FROM m8_ref.c
                  UNION ALL SELECT 'D', id FROM m8_ref.d) facts),
        'support_counts', (SELECT jsonb_agg(format('%s(%s)=%s',
            upper(regexp_replace(relation_name, '^.*\.', '')), semantic_key, support_count)
            ORDER BY relation_name, semantic_key)
            FROM pgreact.derived_facts
            WHERE relation_name IN ('m8_ref.a', 'm8_ref.b', 'm8_ref.c', 'm8_ref.d')),
        'query_c', (SELECT jsonb_agg(to_jsonb(c) ORDER BY id) FROM m8_ref.c c),
        'explanation', explanation
    ) INTO actual;

    expected := jsonb_build_object(
        'session_user', 'm8_author', 'current_user', 'm8_author', 'superuser', false,
        'pack', '2',
        'program', jsonb_build_object(
            'name', 'm8.reference@2', 'owner', 'm8_author',
            'state', 'ACTIVE', 'frontier', 1),
        'components', jsonb_build_array('[A]', '[B]', '[C]', '[D]'),
        'facts', jsonb_build_array('A(7)', 'B(7)', 'C(7)', 'D(7)'),
        'support_counts', jsonb_build_array('A(7)=2', 'B(7)=1', 'C(7)=1', 'D(7)=1'),
        'query_c', jsonb_build_array(jsonb_build_object('id', 7)),
        'explanation', jsonb_build_object(
            'program', 'm8.reference@2', 'frontier', 1,
            'relation', 'm8_ref.c@1', 'fact', jsonb_build_object('id', 7),
            'proof', jsonb_build_object(
                'relation', 'm8_ref.c@1',
                'fact', jsonb_build_object('id', 7),
                'supports', jsonb_build_array(jsonb_build_object(
                    'rule', 'm8.b_to_c@1',
                    'source_binding', jsonb_build_object('id', 7),
                    'inputs', jsonb_build_array(jsonb_build_object(
                        'relation', 'm8_ref.b@1',
                        'fact', jsonb_build_object('id', 7),
                        'supports', jsonb_build_array(jsonb_build_object(
                            'rule', 'm8.a_to_b@1',
                            'source_binding', jsonb_build_object('id', 7),
                            'inputs', jsonb_build_array(jsonb_build_object(
                                'relation', 'm8_ref.a@1',
                                'fact', jsonb_build_object('id', 7),
                                'supports', jsonb_build_array(
                                    jsonb_build_object(
                                        'rule', 'm8.left_to_a@1',
                                        'source_binding', jsonb_build_object('id', 7),
                                        'inputs', '[]'::jsonb),
                                    jsonb_build_object(
                                        'rule', 'm8.right_to_a@1',
                                        'source_binding', jsonb_build_object('id', 7),
                                        'inputs', '[]'::jsonb)))))))))))));
    IF actual IS DISTINCT FROM expected THEN
        RAISE EXCEPTION 'M8 non-superuser workflow changed: %', actual;
    END IF;
END $$;

SELECT 'M8 explicitly granted non-superuser workflow passed' AS result;
