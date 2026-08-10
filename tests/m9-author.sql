\set ON_ERROR_STOP on

CREATE ROLE m9_author LOGIN;
DO $$
DECLARE actual jsonb; expected jsonb;
BEGIN
    actual := jsonb_build_object(
        'graph_select', has_table_privilege(
            'm9_author', 'pgreact.derivation_dependency_graph', 'SELECT'),
        'strata_select', has_table_privilege(
            'm9_author', 'pgreact.derivation_strata', 'SELECT'),
        'evidence_select', has_table_privilege(
            'm9_author', 'pgreact.negative_dependency_evidence', 'SELECT'),
        'refresh_execute', has_function_privilege(
            'm9_author', 'pgreact.refresh_derivation_program(uuid)', 'EXECUTE'));
    expected := jsonb_build_object(
        'graph_select', false, 'strata_select', false,
        'evidence_select', false, 'refresh_execute', false);
    IF actual IS DISTINCT FROM expected THEN
        RAISE EXCEPTION 'M9 private-by-default boundary changed: %', actual;
    END IF;
END
$$;
SELECT format('GRANT CREATE ON DATABASE %I TO m9_author', current_database()) \gexec
GRANT USAGE ON SCHEMA pgreact, pgtrickle TO m9_author;
GRANT ALL ON ALL TABLES IN SCHEMA pgtrickle TO m9_author;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA pgtrickle TO m9_author;
GRANT EXECUTE ON FUNCTION
    pgreact.validate_pack(jsonb, jsonb),
    pgreact.preview_pack(jsonb, jsonb),
    pgreact.deploy_pack(jsonb, text, jsonb),
    pgreact.pack_history(text),
    pgreact.explain_pack(text),
    pgreact.refresh_derivation_program(uuid),
    pgreact.explain_recursive_fact(uuid, uuid, bigint),
    pgreact.reconcile_derivation_program(uuid)
TO m9_author;
GRANT SELECT ON pgreact.derivation_programs, pgreact.derived_relations,
                pgreact.derived_facts, pgreact.derivation_dependency_graph,
                pgreact.derivation_strata, pgreact.negative_dependency_evidence
TO m9_author;

SET SESSION AUTHORIZATION m9_author;
CREATE SCHEMA m9_author;
CREATE TYPE m9_author.fact_row AS (id bigint);
CREATE TABLE m9_author.candidate (id bigint PRIMARY KEY);
CREATE TABLE m9_author.blocked (id bigint);
CREATE VIEW m9_author.candidate_source AS SELECT id FROM m9_author.candidate;
INSERT INTO m9_author.candidate VALUES (7), (8);
INSERT INTO m9_author.blocked VALUES (8), (NULL);

CREATE FUNCTION m9_author.manifest(manifest_version integer)
RETURNS TABLE(definition jsonb, mappings jsonb)
LANGUAGE SQL
STABLE
AS $$
SELECT jsonb_build_object(
    'format_version', 1, 'pack', 'm9-author-pack',
    'version', manifest_version::text, 'owner', 'owner',
    'rules', '[]'::jsonb, 'remove', '[]'::jsonb,
    'derived_relations', jsonb_build_array(jsonb_build_object(
        'name', 'eligible', 'row_type', 'fact_row',
        'key', 'id', 'version', 1)),
    'derivations', '[]'::jsonb,
    'remove_derivations', '[]'::jsonb,
    'remove_derived_relations', '[]'::jsonb,
    'programs', jsonb_build_array(jsonb_build_object(
        'name', 'm9.author', 'version', manifest_version,
        'max_iterations', 8, 'max_facts', 16,
        'rules', jsonb_build_array(jsonb_build_object(
            'name', 'm9.author.eligible',
            'definition', 'candidate_source',
            'key', 'id', 'target', 'eligible', 'version', 1,
            'inputs', '[]'::jsonb,
            'negative_inputs', jsonb_build_array(jsonb_build_object(
                'relation', 'blocked', 'key', 'id')))))),
    'remove_programs', '[]'::jsonb
), jsonb_build_object(
    'roles', jsonb_build_object('owner', current_user),
    'objects', jsonb_build_object(
        'fact_row', 'm9_author.fact_row',
        'candidate_source', 'm9_author.candidate_source',
        'blocked', 'm9_author.blocked',
        'eligible', 'm9_author.eligible'))
$$;

DO $$
DECLARE diagnostics jsonb;
BEGIN
    SELECT COALESCE(jsonb_agg(to_jsonb(row)), '[]'::jsonb) INTO diagnostics
    FROM m9_author.manifest(1) manifest,
         LATERAL pgreact.validate_pack(manifest.definition, manifest.mappings) row;
    IF diagnostics IS DISTINCT FROM jsonb_build_array(jsonb_build_object(
        'contract_version', 3, 'code', 'OK', 'severity', 'INFO',
        'object_identity', 'm9-author-pack',
        'message', 'M8 pack and derivation programs are valid',
        'hint', 'Preview and deploy with the exact plan digest.',
        'details', jsonb_build_object('programs', 1, 'remove_programs', 0))) THEN
        RAISE EXCEPTION 'M9 author validation changed: %', diagnostics;
    END IF;
END
$$;

SELECT min(plan_digest) AS plan_digest
FROM m9_author.manifest(1) manifest,
     LATERAL pgreact.preview_pack(manifest.definition, manifest.mappings) \gset
SELECT pgreact.deploy_pack(definition, :'plan_digest', mappings)
FROM m9_author.manifest(1);
SELECT program_version_id
FROM pgreact.derivation_programs
WHERE program_name = 'm9.author' AND state = 'ACTIVE' \gset
SELECT set_config('m9.author_program', :'program_version_id', false);

DO $$
DECLARE actual jsonb; expected jsonb;
BEGIN
    SELECT jsonb_build_object(
        'program', (SELECT jsonb_build_object(
            'name', program_name, 'version', program_version,
            'state', state, 'frontier', frontier, 'owner', owner)
            FROM pgreact.derivation_programs
            WHERE program_version_id = current_setting('m9.author_program')::uuid),
        'graph', (SELECT jsonb_agg(jsonb_build_object(
            'rule', rule_name, 'polarity', polarity,
            'source', source_relation, 'target', target_relation,
            'source_stratum', source_stratum, 'target_stratum', target_stratum))
            FROM pgreact.derivation_dependency_graph
            WHERE program_version_id = current_setting('m9.author_program')::uuid),
        'facts', (SELECT jsonb_agg(fact ORDER BY semantic_key)
                  FROM pgreact.derived_facts
                  WHERE relation_name = 'm9_author.eligible'),
        'evidence', (SELECT jsonb_agg(
            to_jsonb(evidence) - 'evidence_id' - 'program_version_id'
            - 'rule_version_id' - 'support_id')
            FROM pgreact.negative_dependency_evidence evidence
            WHERE program_version_id = current_setting('m9.author_program')::uuid),
        'explanation', pgreact.explain_recursive_fact(
            current_setting('m9.author_program')::uuid,
            (SELECT relation_version_id FROM pgreact.derived_relations
             WHERE relation_name = 'm9_author.eligible' AND state = 'ACTIVE'), 7)
            #- '{proof,supports,0,logical_support_id}'
            #- '{proof,supports,0,negative_checks,0,evidence_id}'
    ) INTO actual;
    expected := jsonb_build_object(
        'program', jsonb_build_object(
            'name', 'm9.author', 'version', 1, 'state', 'ACTIVE',
            'frontier', 1, 'owner', 'm9_author'),
        'graph', jsonb_build_array(jsonb_build_object(
            'rule', 'm9.author.eligible', 'polarity', 'NEGATIVE',
            'source', 'm9_author.blocked', 'target', 'm9_author.eligible',
            'source_stratum', 0, 'target_stratum', 1)),
        'facts', jsonb_build_array(jsonb_build_object('id', 7)),
        'evidence', jsonb_build_array(jsonb_build_object(
            'program_name', 'm9.author', 'program_version', 1,
            'rule_name', 'm9.author.eligible', 'input_order', 1,
            'semantic_key', 7, 'checked_relation', 'm9_author.blocked',
            'source_stratum', 0, 'target_stratum', 1, 'lower_frontier', 1)),
        'explanation', jsonb_build_object(
            'program', 'm9.author@1', 'frontier', 1,
            'relation', 'm9_author.eligible@1',
            'fact', jsonb_build_object('id', 7),
            'proof', jsonb_build_object(
                'relation', 'm9_author.eligible@1',
                'fact', jsonb_build_object('id', 7),
                'supports', jsonb_build_array(jsonb_build_object(
                    'rule', 'm9.author.eligible@1',
                    'source_binding', jsonb_build_object('id', 7),
                    'inputs', '[]'::jsonb,
                    'negative_checks', jsonb_build_array(jsonb_build_object(
                        'relation', 'm9_author.blocked', 'semantic_key', 7,
                        'source_stratum', 0, 'lower_frontier', 1)))))));
    IF actual IS DISTINCT FROM expected THEN
        RAISE EXCEPTION 'M9 author initial workflow changed: %', actual;
    END IF;
END
$$;

INSERT INTO m9_author.blocked VALUES (7);
DO $$
DECLARE result bigint;
BEGIN
    PERFORM set_config('pgreact.test_fail_program_phase', 'after_iteration', true);
    result := pgreact.refresh_derivation_program(
        current_setting('m9.author_program')::uuid);
    IF result IS NOT NULL THEN
        RAISE EXCEPTION 'M9 author injected refresh returned %', result;
    END IF;
END
$$;
SELECT pgreact.refresh_derivation_program(
    current_setting('m9.author_program')::uuid) = 2 AS blocked \gset
\if :blocked
\else
  SELECT 1 / 0;
\endif
DELETE FROM m9_author.blocked WHERE id = 7;
SELECT pgreact.refresh_derivation_program(
    current_setting('m9.author_program')::uuid) = 3 AS restored \gset
SELECT pgreact.reconcile_derivation_program(
    current_setting('m9.author_program')::uuid) = 0 AS reconciled \gset
\if :restored
\else
  SELECT 1 / 0;
\endif
\if :reconciled
\else
  SELECT 1 / 0;
\endif

SELECT min(plan_digest) AS plan_digest
FROM m9_author.manifest(2) manifest,
     LATERAL pgreact.preview_pack(manifest.definition, manifest.mappings) \gset
SELECT pgreact.deploy_pack(definition, :'plan_digest', mappings)
FROM m9_author.manifest(2);

DO $$
DECLARE actual jsonb; expected jsonb;
BEGIN
    SELECT jsonb_build_object(
        'session_user', session_user,
        'superuser', (SELECT rolsuper FROM pg_roles WHERE rolname = session_user),
        'programs', (SELECT jsonb_agg(jsonb_build_object(
            'version', program_version, 'state', state, 'frontier', frontier)
            ORDER BY program_version)
            FROM pgreact.derivation_programs WHERE program_name = 'm9.author'),
        'facts', (SELECT jsonb_agg(fact ORDER BY semantic_key)
                  FROM pgreact.derived_facts
                  WHERE relation_name = 'm9_author.eligible'),
        'evidence', (SELECT jsonb_agg(jsonb_build_object(
            'program_version', program_version, 'rule', rule_name,
            'key', semantic_key, 'relation', checked_relation,
            'source_stratum', source_stratum, 'target_stratum', target_stratum,
            'lower_frontier', lower_frontier))
            FROM pgreact.negative_dependency_evidence)
    ) INTO actual;
    expected := jsonb_build_object(
        'session_user', 'm9_author', 'superuser', false,
        'programs', jsonb_build_array(
            jsonb_build_object('version', 1, 'state', 'REMOVED', 'frontier', 3),
            jsonb_build_object('version', 2, 'state', 'ACTIVE', 'frontier', 1)),
        'facts', jsonb_build_array(jsonb_build_object('id', 7)),
        'evidence', jsonb_build_array(jsonb_build_object(
            'program_version', 2, 'rule', 'm9.author.eligible', 'key', 7,
            'relation', 'm9_author.blocked', 'source_stratum', 0,
            'target_stratum', 1, 'lower_frontier', 1)));
    IF actual IS DISTINCT FROM expected THEN
        RAISE EXCEPTION 'M9 author replacement workflow changed: %', actual;
    END IF;
END
$$;

SELECT 'M9 explicitly granted public author workflow passed' AS result;
