-- M22 bounded support provenance.  Provenance is derived from the existing
-- support graph in the same transaction as truth maintenance.

CREATE TABLE pgreact_internal.support_provenance_bindings (
    support_id uuid NOT NULL REFERENCES pgreact_internal.derived_supports ON DELETE CASCADE,
    binding_order integer NOT NULL CHECK (binding_order > 0),
    relation_version_id uuid NOT NULL,
    relation_name text NOT NULL,
    binding_name name NOT NULL,
    pg_type_name text NOT NULL,
    canonical_value jsonb NOT NULL,
    semantic_key bigint NOT NULL,
    fact_id uuid NOT NULL,
    is_derived boolean NOT NULL,
    active boolean NOT NULL,
    first_frontier bigint NOT NULL,
    last_frontier bigint,
    invalidated_at timestamptz,
    PRIMARY KEY (support_id, binding_order)
);

CREATE INDEX support_provenance_bindings_lookup
    ON pgreact_internal.support_provenance_bindings
       (relation_version_id, semantic_key, binding_order);

CREATE FUNCTION pgreact_internal.rebuild_support_provenance(target_support_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE support_row record;
BEGIN
    SELECT s.*, v.source_view_oid, v.source_view_name
      INTO support_row
      FROM pgreact_internal.derived_supports s
      JOIN pgreact_internal.rule_versions v USING (rule_version_id)
     WHERE s.support_id = target_support_id;
    IF NOT FOUND THEN RETURN; END IF;

    DELETE FROM pgreact_internal.support_provenance_bindings
     WHERE support_id = target_support_id;

    INSERT INTO pgreact_internal.support_provenance_bindings(
        support_id, binding_order, relation_version_id, relation_name,
        binding_name, pg_type_name, canonical_value, semantic_key, fact_id,
        is_derived, active, first_frontier, last_frontier, invalidated_at)
    SELECT target_support_id, 1000000 + a.attnum, support_row.rule_version_id,
           support_row.source_view_name, a.attname,
           pg_catalog.format_type(a.atttypid, a.atttypmod),
           support_row.source_binding -> a.attname, support_row.semantic_key,
           support_row.fact_id, false, support_row.active,
           support_row.first_frontier, support_row.last_frontier,
           support_row.invalidated_at
      FROM pg_catalog.pg_attribute a
     WHERE a.attrelid = support_row.source_view_oid
       AND a.attnum > 0 AND NOT a.attisdropped
       AND support_row.source_binding ? a.attname::text;

    INSERT INTO pgreact_internal.support_provenance_bindings(
        support_id, binding_order, relation_version_id, relation_name,
        binding_name, pg_type_name, canonical_value, semantic_key, fact_id,
        is_derived, active, first_frontier, last_frontier, invalidated_at)
    SELECT target_support_id, input.input_order, input.relation_version_id,
           relation.relation_name || '@' || relation_version.version::text,
           ('input_' || input.input_order)::name, relation_version.row_type_name,
           COALESCE(fact.fact, jsonb_build_object(
               'semantic_key', input.semantic_key, 'fact_id', input.fact_id)),
           input.semantic_key, input.fact_id, true, support_row.active,
           support_row.first_frontier, support_row.last_frontier,
           support_row.invalidated_at
      FROM pgreact_internal.derived_support_inputs input
      JOIN pgreact_internal.derived_relation_versions relation_version
        USING (relation_version_id)
      JOIN pgreact_internal.derived_relations relation
        USING (relation_id)
      LEFT JOIN pgreact_internal.derived_facts fact
        ON fact.relation_version_id = input.relation_version_id
       AND fact.fact_id = input.fact_id
     WHERE input.support_id = target_support_id;

    IF NOT EXISTS (
        SELECT 1 FROM pgreact_internal.support_provenance_bindings
         WHERE support_id = target_support_id) THEN
        INSERT INTO pgreact_internal.support_provenance_bindings(
            support_id, binding_order, relation_version_id, relation_name,
            binding_name, pg_type_name, canonical_value, semantic_key, fact_id,
            is_derived, active, first_frontier, last_frontier, invalidated_at)
        VALUES (
            target_support_id, 1, support_row.rule_version_id,
            support_row.source_view_name, '_record', 'jsonb',
            support_row.source_binding, support_row.semantic_key,
            support_row.fact_id, false, support_row.active,
            support_row.first_frontier, support_row.last_frontier,
            support_row.invalidated_at);
    END IF;
END
$$;

CREATE FUNCTION pgreact_internal.sync_support_provenance()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    PERFORM pgreact_internal.rebuild_support_provenance(
        CASE WHEN TG_OP = 'DELETE' THEN OLD.support_id ELSE NEW.support_id END);
    RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END
$$;

CREATE TRIGGER pgreact_sync_support_provenance
AFTER INSERT OR UPDATE OF source_binding, fact, active, last_frontier, invalidated_at
ON pgreact_internal.derived_supports
FOR EACH ROW EXECUTE FUNCTION pgreact_internal.sync_support_provenance();

CREATE TRIGGER pgreact_sync_support_input_provenance
AFTER INSERT OR UPDATE OR DELETE ON pgreact_internal.derived_support_inputs
FOR EACH ROW EXECUTE FUNCTION pgreact_internal.sync_support_provenance();

DO $$
DECLARE target_support_id uuid;
BEGIN
    FOR target_support_id IN
        SELECT support_id FROM pgreact_internal.derived_supports ORDER BY support_id
    LOOP
        PERFORM pgreact_internal.rebuild_support_provenance(target_support_id);
    END LOOP;
END
$$;

CREATE FUNCTION pgreact_internal.assert_provenance_reader(target_relation uuid)
RETURNS pgreact_internal.derived_relation_versions
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE relation_row pgreact_internal.derived_relation_versions%ROWTYPE;
    caller_oid oid := (SELECT oid FROM pg_catalog.pg_roles WHERE rolname = session_user);
BEGIN
    SELECT * INTO STRICT relation_row
      FROM pgreact_internal.derived_relation_versions
     WHERE relation_version_id = target_relation;
    IF relation_row.owner_oid <> caller_oid
       AND NOT pgreact_internal.is_operator_admin()
       AND NOT EXISTS (
           SELECT 1 FROM pgreact_internal.application_roles role
            WHERE role.role_kind = 'reader'
              AND pg_catalog.pg_has_role(session_user, role.role_oid, 'member'))
       AND NOT EXISTS (
           SELECT 1 FROM pgreact_internal.advanced_readers role
            WHERE pg_catalog.pg_has_role(session_user, role.role_oid, 'member')) THEN
        RAISE EXCEPTION 'M22_PROVENANCE_FORBIDDEN: reader role required for %', target_relation;
    END IF;
    RETURN relation_row;
END
$$;

CREATE FUNCTION pgreact_internal.provenance_support_json(target_support_id uuid)
RETURNS jsonb
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT jsonb_build_object(
        'support_id', support.support_id,
        'rule_version_id', support.rule_version_id,
        'activation_id', support.activation_id,
        'activation_generation', support.activation_generation,
        'activation_revision', support.activation_revision,
        'logical_support_id', support.logical_support_id,
        'active', support.active,
        'first_frontier', support.first_frontier,
        'last_frontier', support.last_frontier,
        'grounded', support.grounded,
        'bindings', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                'binding_order', binding.binding_order,
                'relation_version_id', binding.relation_version_id,
                'relation', binding.relation_name,
                'name', binding.binding_name,
                'type', binding.pg_type_name,
                'canonical_value', binding.canonical_value,
                'semantic_key', binding.semantic_key,
                'fact_id', binding.fact_id,
                'derived', binding.is_derived)
                ORDER BY binding.binding_order)
              FROM pgreact_internal.support_provenance_bindings binding
             WHERE binding.support_id = support.support_id), '[]'::jsonb),
        'negative_evidence', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                'evidence_id', evidence.evidence_id,
                'relation', evidence.relation_name,
                'semantic_key', evidence.semantic_key,
                'source_stratum', evidence.source_stratum,
                'lower_frontier', evidence.lower_frontier)
                ORDER BY evidence.input_order)
              FROM pgreact_internal.negative_dependency_evidence evidence
             WHERE evidence.support_id = support.support_id AND evidence.active), '[]'::jsonb),
        'aggregate_evidence', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                'evidence_id', evidence.evidence_id,
                'relation', evidence.relation_name,
                'group_key', evidence.semantic_key,
                'count', evidence.exact_count,
                'comparison', evidence.comparison,
                'threshold', evidence.threshold,
                'source_stratum', evidence.source_stratum,
                'lower_frontier', evidence.lower_frontier)
                ORDER BY evidence.evidence_id)
              FROM pgreact_internal.aggregate_dependency_evidence evidence
             WHERE evidence.support_id = support.support_id AND evidence.active), '[]'::jsonb))
      FROM pgreact_internal.derived_supports support
     WHERE support.support_id = target_support_id
$$;

CREATE FUNCTION pgreact_internal.provenance_proof(
    target_relation uuid, target_key bigint, max_depth integer, max_nodes integer)
RETURNS jsonb
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
    WITH RECURSIVE proof(relation_version_id, semantic_key, depth, path, cycle) AS (
        SELECT $1, $2, 0,
               ARRAY[format('%s:%s', $1, $2)]::text[], false
        UNION ALL
        SELECT input.relation_version_id, input.semantic_key, proof.depth + 1,
               proof.path || format('%s:%s', input.relation_version_id, input.semantic_key),
               format('%s:%s', input.relation_version_id, input.semantic_key) = ANY(proof.path)
          FROM proof
          JOIN pgreact_internal.derived_supports support
            ON support.relation_version_id = proof.relation_version_id
           AND support.semantic_key = proof.semantic_key
           AND support.active
          JOIN pgreact_internal.derived_support_inputs input
            ON input.support_id = support.support_id
         WHERE NOT proof.cycle AND proof.depth < $3
    ), grouped AS (
        SELECT relation_version_id, semantic_key, min(depth) AS depth,
               bool_or(cycle) AS cycle, max(depth) AS deepest
          FROM proof
         GROUP BY relation_version_id, semantic_key
    ), classified AS (
        SELECT grouped.*,
               CASE
                 WHEN grouped.cycle THEN 'CYCLE'
                 WHEN NOT EXISTS (
                     SELECT 1
                       FROM pgreact_internal.derived_supports support
                       JOIN pgreact_internal.derived_support_inputs input
                         ON input.support_id = support.support_id
                      WHERE support.relation_version_id = grouped.relation_version_id
                        AND support.semantic_key = grouped.semantic_key
                        AND support.active) THEN 'GROUNDED'
                 WHEN grouped.deepest >= $3 THEN 'TRUNCATED'
                 ELSE 'DERIVED'
               END AS state
          FROM grouped
    ), ranked AS (
        SELECT classified.*, row_number() OVER (
            ORDER BY depth, relation_version_id, semantic_key) AS ordinal
          FROM classified
    )
    SELECT jsonb_build_object(
        'nodes', COALESCE(jsonb_agg(jsonb_build_object(
            'relation_version_id', relation_version_id,
            'semantic_key', semantic_key,
            'depth', depth, 'state', state)
            ORDER BY depth, relation_version_id, semantic_key)
            FILTER (WHERE ordinal <= $4), '[]'::jsonb),
        'total_nodes', count(*),
        'omitted_nodes', greatest(count(*) - $4, 0),
        'truncated', count(*) > $4,
        'max_depth', $3,
        'max_nodes', $4)
      FROM ranked
$$;

CREATE FUNCTION pgreact_api.explain_provenance(
    target_relation uuid, target_key bigint,
    max_supports integer DEFAULT 100,
    continuation_token text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE relation_row pgreact_internal.derived_relation_versions%ROWTYPE;
    fact_value jsonb; support_total bigint; remaining_count bigint; returned_count integer;
    support_rows jsonb; proof jsonb; token jsonb; after_support uuid;
    support_digest bytea; continuation text; result jsonb;
    program_id uuid; inherited_proof jsonb;
BEGIN
    relation_row := pgreact_internal.assert_provenance_reader(target_relation);
    IF max_supports NOT BETWEEN 1 AND 1000 THEN
        RAISE EXCEPTION 'M22_PROVENANCE_LIMIT: max_supports must be between 1 and 1000';
    END IF;
    SELECT fact INTO fact_value
      FROM pgreact_internal.derived_facts
     WHERE relation_version_id = target_relation AND semantic_key = target_key;
    IF NOT FOUND THEN
        RETURN jsonb_build_object(
            'contract_version', 10, 'status', 'UNAVAILABLE',
            'relation', relation_row.public_view_name || '@' || relation_row.version,
            'semantic_key', target_key,
            'diagnostic', jsonb_build_object(
                'code', 'M22_PROVENANCE_UNAVAILABLE',
                'message', 'the requested derived fact has no retained current proof',
                'remediation', 'reconcile the relation or restore retained history'));
    END IF;

    SELECT count(*), sha256(convert_to(COALESCE(string_agg(
        support_id::text, ',' ORDER BY support_id), ''), 'UTF8'))
      INTO support_total, support_digest
      FROM pgreact_internal.derived_supports
     WHERE relation_version_id = target_relation
       AND semantic_key = target_key AND active;
    IF continuation_token IS NOT NULL THEN
        BEGIN
            token := convert_from(decode(continuation_token, 'base64'), 'UTF8')::jsonb;
            IF token ->> 'relation' <> target_relation::text
               OR (token ->> 'semantic_key')::bigint <> target_key
               OR token ->> 'digest' <> encode(support_digest, 'hex') THEN
                RAISE EXCEPTION 'M22_PROVENANCE_SNAPSHOT_CHANGED';
            END IF;
            after_support := (token ->> 'after_support_id')::uuid;
        EXCEPTION WHEN SQLSTATE 'P0001' THEN RAISE;
                WHEN OTHERS THEN
            RAISE EXCEPTION 'M22_PROVENANCE_CONTINUATION_INVALID: token is expired or malformed';
        END;
    END IF;

    SELECT COALESCE(jsonb_agg(row_json ORDER BY support_id), '[]'::jsonb)
      INTO support_rows
      FROM (
          SELECT support.support_id,
                 pgreact_internal.provenance_support_json(support.support_id) AS row_json
            FROM pgreact_internal.derived_supports support
           WHERE support.relation_version_id = target_relation
             AND support.semantic_key = target_key AND support.active
             AND (after_support IS NULL OR support.support_id > after_support)
           ORDER BY support.support_id
           LIMIT max_supports
      ) page;
    returned_count := jsonb_array_length(support_rows);
    IF after_support IS NULL THEN
        remaining_count := support_total;
    ELSE
        SELECT count(*) INTO remaining_count
          FROM pgreact_internal.derived_supports support
         WHERE support.relation_version_id = target_relation
           AND support.semantic_key = target_key AND support.active
           AND support.support_id > after_support;
    END IF;
    IF returned_count > 0 AND returned_count < remaining_count THEN
        continuation := encode(convert_to(jsonb_build_object(
            'relation', target_relation, 'semantic_key', target_key,
            'digest', encode(support_digest, 'hex'),
            'after_support_id', (support_rows -> (returned_count - 1)) ->> 'support_id'
        )::text, 'UTF8'), 'base64');
    END IF;
    proof := pgreact_internal.provenance_proof(target_relation, target_key, 32, 1000);
    SELECT support.program_version_id INTO program_id
      FROM pgreact_internal.derived_supports support
     WHERE support.relation_version_id = target_relation
       AND support.semantic_key = target_key AND support.active
       AND support.program_version_id IS NOT NULL
     ORDER BY support.program_version_id LIMIT 1;
    inherited_proof := CASE WHEN program_id IS NULL THEN
        jsonb_build_object('relation_version_id', target_relation, 'semantic_key', target_key,
                           'supports', '[]'::jsonb)
      ELSE pgreact_internal.recursive_fact_proof(
          program_id, target_relation, target_key, '{}'::uuid[]) END;
    result := jsonb_build_object(
        'contract_version', 10, 'status', 'GROUNDED',
        'relation', relation_row.public_view_name || '@' || relation_row.version,
        'relation_version_id', target_relation, 'semantic_key', target_key,
        'fact', fact_value,
        'supports', support_rows,
        'total_supports', support_total,
        'returned_supports', returned_count,
        'omitted_supports', remaining_count - returned_count,
        'continuation', continuation,
        'proof', proof,
        'inherited_proof', inherited_proof,
        'bounds', jsonb_build_object(
            'max_supports', max_supports, 'max_depth', 32,
            'max_nodes', 1000, 'max_payload_bytes', 1048576));
    RETURN result || jsonb_build_object('payload_bytes', pg_column_size(result));
END
$$;

CREATE FUNCTION pgreact_api.explain_provenance_advanced(
    target_relation uuid, target_key bigint,
    max_supports integer DEFAULT 100,
    continuation_token text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    IF NOT pgreact_internal.is_operator_admin()
       AND NOT EXISTS (
           SELECT 1 FROM pgreact_internal.advanced_readers role
            WHERE pg_catalog.pg_has_role(session_user, role.role_oid, 'member')) THEN
        RAISE EXCEPTION 'M22_PROVENANCE_FORBIDDEN: advanced-reader role required';
    END IF;
    RETURN pgreact_api.explain_provenance(
        target_relation, target_key, max_supports, continuation_token)
        || jsonb_build_object('reader_class', 'advanced');
END
$$;

CREATE FUNCTION pgreact_api.provenance_validate(target_relation uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE relation_row pgreact_internal.derived_relation_versions%ROWTYPE;
    active_supports bigint; missing_bindings bigint; over_bound bigint;
BEGIN
    relation_row := pgreact_internal.assert_provenance_reader(target_relation);
    SELECT count(*), count(*) FILTER (WHERE NOT EXISTS (
        SELECT 1 FROM pgreact_internal.support_provenance_bindings binding
         WHERE binding.support_id = support.support_id)), count(*) FILTER (WHERE EXISTS (
        SELECT 1 FROM pgreact_internal.support_provenance_bindings binding
         WHERE binding.support_id = support.support_id
         GROUP BY binding.support_id HAVING count(*) > 1000))
      INTO active_supports, missing_bindings, over_bound
      FROM pgreact_internal.derived_supports support
     WHERE support.relation_version_id = target_relation AND support.active;
    RETURN jsonb_build_object(
        'contract_version', 10,
        'relation', relation_row.public_view_name || '@' || relation_row.version,
        'status', CASE WHEN missing_bindings = 0 AND over_bound = 0 THEN 'ready' ELSE 'attention' END,
        'diagnostics', jsonb_build_array(
            CASE WHEN missing_bindings > 0 THEN jsonb_build_object(
                'code', 'M22_PROVENANCE_MISSING', 'severity', 'ERROR',
                'count', missing_bindings, 'remediation', 'reconcile the derived relation') END,
            CASE WHEN over_bound > 0 THEN jsonb_build_object(
                'code', 'M22_PROVENANCE_BOUND', 'severity', 'ERROR',
                'count', over_bound, 'remediation', 'reduce support fan-out or raise the frozen contract bound') END),
        'active_supports', active_supports,
        'missing_bindings', missing_bindings, 'over_bound_supports', over_bound,
        'limits', jsonb_build_object('max_bindings_per_support', 1000));
END
$$;

CREATE FUNCTION pgreact_api.provenance_preview(
    target_relation uuid, target_key bigint DEFAULT NULL, max_facts integer DEFAULT 100)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE relation_row pgreact_internal.derived_relation_versions%ROWTYPE;
    facts jsonb;
BEGIN
    relation_row := pgreact_internal.assert_provenance_reader(target_relation);
    IF max_facts NOT BETWEEN 1 AND 1000 THEN
        RAISE EXCEPTION 'M22_PROVENANCE_LIMIT: max_facts must be between 1 and 1000';
    END IF;
    IF target_key IS NOT NULL THEN
        RETURN pgreact_api.explain_provenance(target_relation, target_key, max_facts, NULL)
            || jsonb_build_object('mode', 'preview');
    END IF;
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'semantic_key', fact.semantic_key, 'fact', fact.fact,
        'support_count', fact.support_count)
        ORDER BY fact.semantic_key), '[]'::jsonb)
      INTO facts
      FROM (
          SELECT * FROM pgreact_internal.derived_facts
           WHERE relation_version_id = target_relation
           ORDER BY semantic_key LIMIT max_facts
      ) fact;
    RETURN jsonb_build_object(
        'contract_version', 10, 'mode', 'preview',
        'relation', relation_row.public_view_name || '@' || relation_row.version,
        'relation_version_id', target_relation, 'facts', facts,
        'returned_facts', jsonb_array_length(facts), 'max_facts', max_facts);
END
$$;

CREATE FUNCTION pgreact_api.provenance_status(target_relation uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT jsonb_build_object(
        'contract_version', 10,
        'relations', COALESCE(jsonb_agg(jsonb_build_object(
            'relation_version_id', relation_version_id,
            'relation', public_view_name || '@' || version,
            'active_supports', active_supports,
            'bindings', binding_count,
            'missing_supports', missing_supports,
            'storage_bytes', storage_bytes)
            ORDER BY public_view_name, version), '[]'::jsonb),
        'limits', jsonb_build_object(
            'max_bindings_per_support', 1000, 'max_depth', 32,
            'max_nodes', 1000, 'max_payload_bytes', 1048576))
      FROM (
          SELECT relation_version.relation_version_id,
                 relation_version.public_view_name, relation_version.version,
                 count(DISTINCT support.support_id) FILTER (WHERE support.active) AS active_supports,
                 count(binding.support_id) FILTER (WHERE support.active) AS binding_count,
                 count(DISTINCT support.support_id) FILTER (WHERE support.active
                     AND binding.support_id IS NULL) AS missing_supports,
                 pg_total_relation_size('pgreact_internal.support_provenance_bindings'::regclass) AS storage_bytes
            FROM pgreact_internal.derived_relation_versions relation_version
            LEFT JOIN pgreact_internal.derived_supports support
              ON support.relation_version_id = relation_version.relation_version_id
            LEFT JOIN pgreact_internal.support_provenance_bindings binding
              ON binding.support_id = support.support_id
           WHERE relation_version.state = 'ACTIVE'
             AND ($1 IS NULL OR relation_version.relation_version_id = $1)
           GROUP BY relation_version.relation_version_id,
                    relation_version.public_view_name, relation_version.version
      ) status
$$;

CREATE FUNCTION pgreact_api.provenance_doctor()
RETURNS jsonb
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT jsonb_build_object(
        'contract_version', 10,
        'status', CASE WHEN EXISTS (
            SELECT 1 FROM pgreact_internal.derived_supports support
             WHERE support.active AND NOT EXISTS (
                 SELECT 1 FROM pgreact_internal.support_provenance_bindings binding
                  WHERE binding.support_id = support.support_id)) THEN 'attention' ELSE 'ready' END,
        'diagnostics', COALESCE((SELECT jsonb_agg(jsonb_build_object(
            'code', 'M22_PROVENANCE_MISSING', 'severity', 'ERROR',
            'support_id', support.support_id,
            'message', 'an active support has no typed provenance binding',
            'remediation', 'run provenance reconciliation before relying on explanation')
            ORDER BY support.support_id)
          FROM pgreact_internal.derived_supports support
         WHERE support.active AND NOT EXISTS (
             SELECT 1 FROM pgreact_internal.support_provenance_bindings binding
              WHERE binding.support_id = support.support_id)), '[]'::jsonb),
        'extension_version', (SELECT extversion FROM pg_catalog.pg_extension WHERE extname = 'pg_react'))
$$;

CREATE OR REPLACE FUNCTION pgreact_api.retention_doctor()
RETURNS jsonb
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
    WITH diagnostics AS (
        SELECT jsonb_build_object('code','M21_EXTENSION_VERSION','severity','ERROR',
            'message','pg_react extension version is not 0.19.0',
            'hint','Install matching extension files and run ALTER EXTENSION UPDATE.') diagnostic
        WHERE NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname='pg_react' AND extversion='0.19.0')
        UNION ALL
        SELECT jsonb_build_object('code','M21_RETENTION_BATCH_FAILED','severity','ERROR',
            'message','a retention batch failed','hint','Inspect retention_audit and retry after resolving the recorded error.')
        WHERE EXISTS (SELECT 1 FROM pgreact_internal.retention_batches WHERE state='FAILED')
        UNION ALL
        SELECT jsonb_build_object('code','M21_RETENTION_DISABLED','severity','INFO',
            'message','retention is disabled by default','hint','Configure and enable one operator-owned retention policy before pruning.')
        WHERE NOT (SELECT enabled FROM pgreact_internal.retention_policies WHERE singleton)
    )
    SELECT jsonb_build_object('contract_version',9,
        'status',CASE WHEN EXISTS (SELECT 1 FROM diagnostics WHERE diagnostic->>'severity'='ERROR') THEN 'attention' ELSE 'ready' END,
        'diagnostics',COALESCE((SELECT jsonb_agg(diagnostic) FROM diagnostics),'[]'::jsonb))
$$;

CREATE OR REPLACE FUNCTION pgreact_api.configure_roles(
    author_role regrole, operator_role regrole, worker_role regrole,
    reader_role regrole, advanced_reader_role regrole)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE previous name;
BEGIN
    PERFORM pgreact_api.configure_roles(author_role, operator_role, worker_role, reader_role);
    SELECT role_oid::regrole::text INTO previous FROM pgreact_internal.advanced_readers;
    IF previous IS NOT NULL THEN
        EXECUTE format('REVOKE ALL ON FUNCTION pgreact_api.explain_provenance_advanced(uuid,bigint,integer,text) FROM %I', previous);
    END IF;
    DELETE FROM pgreact_internal.advanced_readers;
    INSERT INTO pgreact_internal.advanced_readers VALUES (advanced_reader_role);
    EXECUTE format('GRANT USAGE ON SCHEMA pgreact_api TO %I', advanced_reader_role::text);
    EXECUTE format('GRANT EXECUTE ON FUNCTION pgreact_api.explain_provenance_advanced(uuid,bigint,integer,text) TO %I', advanced_reader_role::text);
    EXECUTE format('GRANT EXECUTE ON FUNCTION pgreact_api.provenance_validate(uuid), pgreact_api.provenance_preview(uuid,bigint,integer) TO %I', author_role::text);
    EXECUTE format('GRANT EXECUTE ON FUNCTION pgreact_api.provenance_status(uuid), pgreact_api.provenance_preview(uuid,bigint,integer), pgreact_api.explain_provenance(uuid,bigint,integer,text), pgreact_api.provenance_doctor() TO %I', reader_role::text);
    EXECUTE format('GRANT EXECUTE ON FUNCTION pgreact_api.provenance_status(uuid), pgreact_api.provenance_preview(uuid,bigint,integer), pgreact_api.explain_provenance(uuid,bigint,integer,text), pgreact_api.provenance_doctor() TO %I', operator_role::text);
END
$$;

REVOKE ALL ON ALL TABLES IN SCHEMA pgreact_internal FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA pgreact_internal FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA pgreact_api FROM PUBLIC;

COMMENT ON EXTENSION pg_react IS
    'M22 bounded typed support provenance over the M21 retention and catalog-scale platform';
