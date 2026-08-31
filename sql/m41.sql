-- M41 bounded end-to-end causal paths over installed public evidence.

CREATE OR REPLACE FUNCTION pgreact_internal.m41_finding(
    code text,
    severity text,
    target text,
    field text,
    message text,
    hint text,
    details jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE SQL
IMMUTABLE
STRICT
AS $m41$
    SELECT jsonb_build_object(
        'code', $1,
        'severity', $2,
        'blocking', $2 = 'ERROR',
        'target', $3,
        'field', $4,
        'message', $5,
        'hint', $6,
        'details', COALESCE($7, '{}'::jsonb))
$m41$;

CREATE OR REPLACE FUNCTION pgreact_internal.m41_finding_registry()
RETURNS jsonb
LANGUAGE SQL
IMMUTABLE
AS $m41$
SELECT jsonb_build_array(
    jsonb_build_object('code', 'M41_OPTIONS_INVALID', 'severity', 'ERROR'),
    jsonb_build_object('code', 'M41_ROOT_INVALID', 'severity', 'ERROR'),
    jsonb_build_object('code', 'M41_SUBJECT_INVALID', 'severity', 'ERROR'),
    jsonb_build_object('code', 'M41_TARGET_NOT_FOUND', 'severity', 'ERROR'),
    jsonb_build_object('code', 'M41_TARGET_AMBIGUOUS', 'severity', 'ERROR'),
    jsonb_build_object('code', 'M41_UNSUPPORTED_ROOT', 'severity', 'WARNING'),
    jsonb_build_object('code', 'M41_UNSUPPORTED_NODE', 'severity', 'WARNING'),
    jsonb_build_object('code', 'M41_ROOT_NOT_FOUND', 'severity', 'WARNING'),
    jsonb_build_object('code', 'M41_SCHEMA_DRIFT', 'severity', 'WARNING'),
    jsonb_build_object('code', 'M41_UNAUTHORIZED', 'severity', 'WARNING'),
    jsonb_build_object('code', 'M41_RLS_REJECTED', 'severity', 'WARNING'),
    jsonb_build_object('code', 'M41_EVIDENCE_MISSING', 'severity', 'WARNING'),
    jsonb_build_object('code', 'M41_EVIDENCE_PRUNED', 'severity', 'WARNING'),
    jsonb_build_object('code', 'M41_STALE_FRONTIER', 'severity', 'WARNING'),
    jsonb_build_object('code', 'M41_CHANGED_STATE', 'severity', 'WARNING'),
    jsonb_build_object('code', 'M41_CYCLE', 'severity', 'WARNING'),
    jsonb_build_object('code', 'M41_RESOURCE_LIMIT', 'severity', 'WARNING'),
    jsonb_build_object('code', 'M41_NO_EFFECT', 'severity', 'INFO'))
$m41$;

CREATE OR REPLACE FUNCTION pgreact_internal.m41_requested(options jsonb)
RETURNS boolean
LANGUAGE plpgsql
IMMUTABLE
AS $m41$
BEGIN
    IF options IS NULL OR jsonb_typeof(options) IS DISTINCT FROM 'object'
       OR NOT options ? 'causal_path' THEN
        RETURN false;
    END IF;
    IF jsonb_typeof(options -> 'causal_path') = 'boolean'
       AND (options ->> 'causal_path')::boolean = false THEN
        RETURN false;
    END IF;
    RETURN true;
END
$m41$;

CREATE OR REPLACE FUNCTION pgreact_internal.m41_strip_options(options jsonb)
RETURNS jsonb
LANGUAGE SQL
IMMUTABLE
AS $m41$
    SELECT CASE WHEN jsonb_typeof($1) = 'object' THEN $1 - 'causal_path' ELSE $1 END
$m41$;

CREATE OR REPLACE FUNCTION pgreact_internal.m41_digest(value jsonb)
RETURNS text
LANGUAGE SQL
IMMUTABLE
STRICT
AS $m41$
    SELECT encode(sha256(convert_to($1::text, 'UTF8')), 'hex')
$m41$;

CREATE OR REPLACE FUNCTION pgreact_internal.m41_array_union(left_value jsonb, right_value jsonb)
RETURNS jsonb
LANGUAGE SQL
IMMUTABLE
AS $m41$
    SELECT COALESCE(jsonb_agg(item.value ORDER BY item.value::text), '[]'::jsonb)
    FROM (
        SELECT DISTINCT value
        FROM jsonb_array_elements(COALESCE($1, '[]'::jsonb) || COALESCE($2, '[]'::jsonb))
    ) item
$m41$;

CREATE OR REPLACE FUNCTION pgreact_internal.m41_edge(
    kind text,
    from_identity text,
    to_identity text,
    evidence jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE SQL
IMMUTABLE
AS $m41$
    SELECT jsonb_build_object(
        'kind', $1,
        'identity', $1 || ':' || $2 || '>' || $3,
        'from', $2,
        'to', $3,
        'evidence', COALESCE($4, '{}'::jsonb))
$m41$;

CREATE OR REPLACE FUNCTION pgreact_internal.m41_path(
    nodes jsonb,
    edges jsonb,
    state text DEFAULT 'complete'
)
RETURNS jsonb
LANGUAGE SQL
IMMUTABLE
AS $m41$
    SELECT jsonb_build_object(
        'path_id', pgreact_internal.m41_digest(
            jsonb_build_object('nodes', $1, 'edges', $2)),
        'nodes', $1,
        'edges', $2,
        'state', $3)
$m41$;

CREATE OR REPLACE FUNCTION pgreact_internal.m41_cost(
    started_at timestamptz,
    roots bigint,
    nodes bigint,
    edges bigint,
    paths bigint,
    support_expansion bigint,
    depth bigint,
    fanout bigint,
    boundary_checks bigint
)
RETURNS jsonb
LANGUAGE SQL
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m41$
    SELECT jsonb_build_object(
        'roots', $2,
        'nodes', $3,
        'edges', $4,
        'paths', $5,
        'support_expansion', $6,
        'depth', $7,
        'fanout', $8,
        'boundary_checks', $9,
        'elapsed_ms', extract(epoch FROM clock_timestamp() - $1) * 1000)
$m41$;

CREATE OR REPLACE FUNCTION pgreact_internal.m41_result(
    target_kind text,
    target_name text,
    target_version text,
    state text,
    subject jsonb,
    request_root jsonb,
    sampled_time timestamptz,
    authoritative_frontier timestamptz,
    root jsonb,
    nodes jsonb,
    edges jsonb,
    paths jsonb,
    boundaries jsonb,
    findings jsonb,
    limits jsonb,
    cost jsonb,
    digests jsonb
)
RETURNS jsonb
LANGUAGE SQL
IMMUTABLE
AS $m41$
    SELECT jsonb_build_object(
        'contract_version', 27,
        'operation', 'explain',
        'target', jsonb_build_object(
            'kind', COALESCE($1, '<unknown>'),
            'name', COALESCE($2, '<unknown>'),
            'version', $3),
        'state', $4,
        'request', jsonb_build_object('causal_path', true, 'root', COALESCE($6, '{}'::jsonb)),
        'subject', $5,
        'sampled_time', $7,
        'authoritative_frontier', $8,
        'root', $9,
        'nodes', COALESCE($10, '[]'::jsonb),
        'edges', COALESCE($11, '[]'::jsonb),
        'paths', COALESCE($12, '[]'::jsonb),
        'boundaries', COALESCE($13, '[]'::jsonb),
        'completeness', jsonb_build_object(
            'state', $4,
            'paths_exact', $4 = 'complete',
            'public_evidence', true),
        'limits', COALESCE($15, '{}'::jsonb),
        'cost', COALESCE($16, '{}'::jsonb),
        'digests', COALESCE($17, '{}'::jsonb),
        'findings', COALESCE($14, '[]'::jsonb),
        'diagnostics', '[]'::jsonb,
        'read_only', true,
        'truncated', $4 = 'partial')
$m41$;

CREATE OR REPLACE FUNCTION pgreact_internal.m41_source_evidence(
    source_oid oid,
    source_name text,
    key_column name,
    subject_key bigint
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m41$
<<m41_rule_source_block>>
DECLARE
    relation_kind "char";
    rls_enabled boolean;
    row_data jsonb;
BEGIN
    IF source_oid IS NULL THEN
        RETURN jsonb_build_object('state', 'schema_drift', 'source', source_name);
    END IF;
    SELECT c.relkind, c.relrowsecurity
    INTO relation_kind, rls_enabled
    FROM pg_class c WHERE c.oid = source_oid;
    IF relation_kind IS NULL THEN
        RETURN jsonb_build_object('state', 'schema_drift', 'source', source_name);
    ELSIF rls_enabled THEN
        RETURN jsonb_build_object('state', 'rls', 'source', source_name);
    ELSIF NOT has_table_privilege(session_user, source_oid, 'SELECT') THEN
        RETURN jsonb_build_object('state', 'unauthorized', 'source', source_name);
    ELSIF NOT EXISTS (
        SELECT 1 FROM pg_attribute
        WHERE attrelid = source_oid AND attname = key_column
          AND attnum > 0 AND NOT attisdropped) THEN
        RETURN jsonb_build_object('state', 'schema_drift', 'source', source_name);
    END IF;
    EXECUTE format('SELECT to_jsonb(s) FROM %s s WHERE s.%I = $1 LIMIT 1',
                   source_oid::regclass, key_column)
    INTO row_data USING subject_key;
    IF row_data IS NULL THEN
        RETURN jsonb_build_object('state', 'missing', 'source', source_name,
                                  'key', subject_key);
    END IF;
    RETURN jsonb_build_object('state', 'ok', 'source', source_name,
                              'key', subject_key, 'row', row_data);
END
$m41$;

CREATE OR REPLACE FUNCTION pgreact_internal.m41_rule_source_fragment(
    rule_version_id uuid,
    subject_key bigint,
    parent_id text DEFAULT NULL,
    requested_activation_id uuid DEFAULT NULL,
    requested_generation bigint DEFAULT NULL,
    requested_revision bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m41$
DECLARE
    rule_row record;
    activation_row record;
    source jsonb;
    match_id text;
    source_id text;
    boundary_id text;
    nodes jsonb := '[]'::jsonb;
    edges jsonb := '[]'::jsonb;
    paths jsonb := '[]'::jsonb;
    boundaries jsonb := '[]'::jsonb;
    findings jsonb := '[]'::jsonb;
    path_nodes jsonb;
    path_edges jsonb := '[]'::jsonb;
    state text := 'complete';
    actual_generation bigint;
    actual_revision bigint;
    boundary_kind text;
    boundary_code text;
BEGIN
    SELECT r.rule_name, v.source_view_oid, v.source_view_name, v.key_column, v.state
    INTO rule_row
    FROM pgreact_internal.rule_versions v
    JOIN pgreact_internal.rules r USING (rule_id)
    WHERE v.rule_version_id = m41_rule_source_fragment.rule_version_id;
    IF NOT FOUND THEN
        boundary_id := 'boundary:missing:rule';
        boundaries := jsonb_build_array(jsonb_build_object(
            'kind', 'missing', 'identity', boundary_id));
        IF parent_id IS NULL THEN
            path_nodes := jsonb_build_array(boundary_id);
        ELSE
            path_nodes := jsonb_build_array(parent_id, boundary_id);
            edges := jsonb_build_array(pgreact_internal.m41_edge(
                'lifecycle_predecessor', parent_id, boundary_id));
            path_edges := jsonb_build_array(edges -> 0 ->> 'identity');
        END IF;
        findings := jsonb_build_array(pgreact_internal.m41_finding(
            'M41_EVIDENCE_MISSING', 'WARNING', '<unknown>', 'rule',
            'the modeled rule version is no longer available',
            'Restore the deployed rule evidence before retrying.'));
        RETURN jsonb_build_object('state', 'unavailable', 'nodes', nodes,
            'edges', edges, 'paths', jsonb_build_array(
                pgreact_internal.m41_path(path_nodes, path_edges, 'unavailable')),
            'boundaries', boundaries, 'findings', findings);
    END IF;

    SELECT a.activation_id, a.active, a.generation, a.revision,
           a.current_bindings, a.last_active_bindings
    INTO activation_row
    FROM pgreact_internal.activation_state a
    WHERE a.rule_version_id = m41_rule_source_fragment.rule_version_id
      AND a.semantic_key = subject_key
      AND (requested_activation_id IS NULL OR a.activation_id = requested_activation_id)
    ORDER BY a.revision DESC, a.generation DESC
    LIMIT 1;
    IF NOT FOUND THEN
        boundary_id := 'boundary:missing:rule-match';
        boundaries := jsonb_build_array(jsonb_build_object(
            'kind', 'missing', 'identity', boundary_id));
        IF parent_id IS NULL THEN
            path_nodes := jsonb_build_array(boundary_id);
        ELSE
            path_nodes := jsonb_build_array(parent_id, boundary_id);
            edges := jsonb_build_array(pgreact_internal.m41_edge(
                'lifecycle_predecessor', parent_id, boundary_id));
            path_edges := jsonb_build_array(edges -> 0 ->> 'identity');
        END IF;
        findings := jsonb_build_array(pgreact_internal.m41_finding(
            'M41_ROOT_NOT_FOUND', 'WARNING', rule_row.rule_name, 'rule_match',
            'the requested lifecycle event has no retained rule match state',
            'Use a retained generation and revision.'));
        RETURN jsonb_build_object('state', 'unavailable', 'nodes', nodes,
            'edges', edges, 'paths', jsonb_build_array(
                pgreact_internal.m41_path(path_nodes, path_edges, 'unavailable')),
            'boundaries', boundaries, 'findings', findings);
    END IF;
    actual_generation := activation_row.generation;
    actual_revision := activation_row.revision;
    match_id := format('rule_match:%s@1:subject=%s:generation=%s:revision=%s',
                       rule_row.rule_name, subject_key, actual_generation, actual_revision);
    nodes := jsonb_build_array(jsonb_build_object(
        'kind', 'rule_match', 'identity', match_id,
        'evidence', jsonb_build_object(
            'target', rule_row.rule_name, 'version', '1', 'subject_key', subject_key,
            'generation', actual_generation, 'revision', actual_revision,
            'active', activation_row.active,
            'bindings', COALESCE(activation_row.current_bindings,
                                 activation_row.last_active_bindings, '{}'::jsonb))));
    IF parent_id IS NOT NULL THEN
        edges := edges || jsonb_build_array(pgreact_internal.m41_edge(
            'lifecycle_match', parent_id, match_id,
            jsonb_build_object('generation', actual_generation,
                               'revision', actual_revision)));
        path_nodes := jsonb_build_array(parent_id, match_id);
        path_edges := jsonb_build_array(edges -> 0 ->> 'identity');
    ELSE
        path_nodes := jsonb_build_array(match_id);
    END IF;
    IF requested_generation IS NOT NULL AND requested_generation <> actual_generation THEN
        state := 'unavailable';
        findings := findings || jsonb_build_array(pgreact_internal.m41_finding(
            'M41_CHANGED_STATE', 'WARNING', rule_row.rule_name, 'root.generation',
            'the retained rule generation does not match the requested root',
            'Retry with the generation returned by the public work evidence.'));
    END IF;
    IF requested_revision IS NOT NULL AND requested_revision <> actual_revision THEN
        state := 'unavailable';
        findings := findings || jsonb_build_array(pgreact_internal.m41_finding(
            'M41_CHANGED_STATE', 'WARNING', rule_row.rule_name, 'root.revision',
            'the retained rule revision does not match the requested root',
            'Retry with the revision returned by the public match evidence.'));
    END IF;

    source := pgreact_internal.m41_source_evidence(
        rule_row.source_view_oid, rule_row.source_view_name, rule_row.key_column, subject_key);
    IF source ->> 'state' = 'ok' THEN
        source_id := format('authoritative:%s:%s=%s', rule_row.source_view_name,
                            rule_row.key_column, subject_key);
        nodes := nodes || jsonb_build_array(jsonb_build_object(
            'kind', 'authoritative_fact', 'identity', source_id,
            'evidence', source - 'state'));
        edges := edges || jsonb_build_array(pgreact_internal.m41_edge(
            'rule_source', match_id, source_id,
            jsonb_build_object('source_definition', rule_row.source_view_name)));
        path_nodes := path_nodes || jsonb_build_array(source_id);
        path_edges := path_edges || jsonb_build_array(
            edges -> (jsonb_array_length(edges) - 1) ->> 'identity');
    ELSE
        boundary_kind := CASE source ->> 'state'
            WHEN 'unauthorized' THEN 'inaccessible'
            WHEN 'rls' THEN 'inaccessible'
            WHEN 'schema_drift' THEN 'schema_drift'
            WHEN 'missing' THEN 'missing'
            ELSE 'unsupported' END;
        boundary_id := 'boundary:' || boundary_kind || ':' ||
            pgreact_internal.m41_digest(jsonb_build_object('parent', match_id));
        boundaries := boundaries || jsonb_build_array(jsonb_build_object(
            'kind', boundary_kind, 'identity', boundary_id));
        edges := edges || jsonb_build_array(pgreact_internal.m41_edge(
            'rule_source', match_id, boundary_id));
        path_nodes := path_nodes || jsonb_build_array(boundary_id);
        path_edges := path_edges || jsonb_build_array(
            edges -> (jsonb_array_length(edges) - 1) ->> 'identity');
        state := CASE WHEN source ->> 'state' IN ('missing') THEN 'partial' ELSE 'unavailable' END;
        boundary_code := CASE source ->> 'state'
            WHEN 'unauthorized' THEN 'M41_UNAUTHORIZED'
            WHEN 'rls' THEN 'M41_RLS_REJECTED'
            WHEN 'schema_drift' THEN 'M41_SCHEMA_DRIFT'
            WHEN 'missing' THEN 'M41_EVIDENCE_MISSING'
            ELSE 'M41_UNSUPPORTED_NODE' END;
        findings := findings || jsonb_build_array(pgreact_internal.m41_finding(
            boundary_code, 'WARNING', rule_row.rule_name, 'source',
            'the rule predecessor ends at an explicit evidence boundary',
            'Restore access and retained source evidence before retrying.'));
    END IF;
    paths := jsonb_build_array(pgreact_internal.m41_path(path_nodes, path_edges, state));
    RETURN jsonb_build_object('state', state, 'nodes', nodes, 'edges', edges,
                              'paths', paths, 'boundaries', boundaries,
                              'findings', findings);
END
$m41$;

CREATE OR REPLACE FUNCTION pgreact_internal.m41_derived_fragment(
    relation_version_id uuid,
    subject_key bigint,
    parent_id text DEFAULT NULL,
    depth integer DEFAULT 0,
    depth_limit integer DEFAULT 16,
    fanout_limit integer DEFAULT 64,
    path_limit integer DEFAULT 64,
    visited text[] DEFAULT ARRAY[]::text[]
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m41$
<<m41_derived_block>>
DECLARE
    relation_row record;
    fact_row record;
    support_row record;
    input_row record;
    child jsonb;
    child_path jsonb;
    source_fragment jsonb;
    relation_identity text;
    fact_identity text;
    support_identity text;
    boundary_id text;
    path_nodes jsonb;
    path_edges jsonb;
    combined_nodes jsonb;
    combined_edges jsonb;
    support_edge jsonb;
    child_edge jsonb;
    nodes jsonb := '[]'::jsonb;
    edges jsonb := '[]'::jsonb;
    paths jsonb := '[]'::jsonb;
    boundaries jsonb := '[]'::jsonb;
    findings jsonb := '[]'::jsonb;
    state text := 'complete';
    support_number integer := 0;
    input_count bigint;
    support_count bigint;
BEGIN
    SELECT relation.relation_name, version.version, version.public_view_name
    INTO relation_row
    FROM pgreact_internal.derived_relation_versions version
    JOIN pgreact_internal.derived_relations relation USING (relation_id)
    WHERE version.relation_version_id = m41_derived_fragment.relation_version_id;
    IF NOT FOUND THEN
        boundary_id := 'boundary:missing:derived-relation';
        boundaries := jsonb_build_array(jsonb_build_object(
            'kind', 'missing', 'identity', boundary_id));
        IF parent_id IS NULL THEN
            path_nodes := jsonb_build_array(boundary_id);
        ELSE
            path_nodes := jsonb_build_array(parent_id, boundary_id);
            child_edge := pgreact_internal.m41_edge('derived_predecessor', parent_id, boundary_id);
            edges := jsonb_build_array(child_edge);
            path_edges := jsonb_build_array(child_edge ->> 'identity');
        END IF;
        RETURN jsonb_build_object('state', 'unavailable', 'nodes', nodes, 'edges', edges,
            'paths', jsonb_build_array(pgreact_internal.m41_path(
                path_nodes, COALESCE(path_edges, '[]'::jsonb), 'unavailable')),
            'boundaries', boundaries,
            'findings', jsonb_build_array(pgreact_internal.m41_finding(
                'M41_EVIDENCE_MISSING', 'WARNING', '<unknown>', 'derived_relation',
                'the modeled derived relation version is unavailable',
                'Restore the derived relation evidence before retrying.')));
    END IF;
    relation_identity := relation_row.relation_name || '@' || relation_row.version;
    IF relation_identity = ANY (visited) THEN
        boundary_id := 'boundary:cyclic:' || pgreact_internal.m41_digest(
            jsonb_build_object('relation', relation_identity, 'subject_key', subject_key));
        boundaries := jsonb_build_array(jsonb_build_object('kind', 'cyclic', 'identity', boundary_id));
        IF parent_id IS NULL THEN
            path_nodes := jsonb_build_array(boundary_id);
        ELSE
            path_nodes := jsonb_build_array(parent_id, boundary_id);
            child_edge := pgreact_internal.m41_edge('cycle', parent_id, boundary_id);
            edges := jsonb_build_array(child_edge);
            path_edges := jsonb_build_array(child_edge ->> 'identity');
        END IF;
        RETURN jsonb_build_object('state', 'partial', 'nodes', nodes, 'edges', edges,
            'paths', jsonb_build_array(pgreact_internal.m41_path(
                path_nodes, COALESCE(path_edges, '[]'::jsonb), 'partial')),
            'boundaries', boundaries,
            'findings', jsonb_build_array(pgreact_internal.m41_finding(
                'M41_CYCLE', 'WARNING', relation_row.relation_name, 'support',
                'derived support contains a cycle',
                'Inspect the recursive support definition.')));
    END IF;
    IF depth >= depth_limit THEN
        boundary_id := 'boundary:over_limit:' || pgreact_internal.m41_digest(
            jsonb_build_object('relation', relation_identity, 'subject_key', subject_key));
        boundaries := jsonb_build_array(jsonb_build_object('kind', 'over_limit', 'identity', boundary_id));
        IF parent_id IS NULL THEN
            path_nodes := jsonb_build_array(boundary_id);
        ELSE
            path_nodes := jsonb_build_array(parent_id, boundary_id);
            child_edge := pgreact_internal.m41_edge('depth_limit', parent_id, boundary_id);
            edges := jsonb_build_array(child_edge);
            path_edges := jsonb_build_array(child_edge ->> 'identity');
        END IF;
        RETURN jsonb_build_object('state', 'partial', 'nodes', nodes, 'edges', edges,
            'paths', jsonb_build_array(pgreact_internal.m41_path(
                path_nodes, COALESCE(path_edges, '[]'::jsonb), 'partial')),
            'boundaries', boundaries,
            'findings', jsonb_build_array(pgreact_internal.m41_finding(
                'M41_RESOURCE_LIMIT', 'WARNING', relation_row.relation_name, 'depth',
                'the causal path reached the depth limit',
                'Increase depth_limit only when the workload needs it.')));
    END IF;

    SELECT f.fact, f.support_count, f.first_frontier, f.last_frontier
    INTO fact_row
    FROM pgreact_internal.derived_facts f
    WHERE f.relation_version_id = m41_derived_fragment.relation_version_id
      AND f.semantic_key = m41_derived_fragment.subject_key;
    fact_identity := 'derived_fact:' || relation_identity || ':subject=' || subject_key;
    IF NOT FOUND THEN
        boundary_id := 'boundary:missing:' || pgreact_internal.m41_digest(
            jsonb_build_object('parent', COALESCE(parent_id, relation_identity), 'subject_key', subject_key));
        boundaries := jsonb_build_array(jsonb_build_object('kind', 'missing', 'identity', boundary_id));
        IF parent_id IS NULL THEN
            path_nodes := jsonb_build_array(boundary_id);
        ELSE
            path_nodes := jsonb_build_array(parent_id, boundary_id);
            child_edge := pgreact_internal.m41_edge('derived_fact', parent_id, boundary_id);
            edges := jsonb_build_array(child_edge);
            path_edges := jsonb_build_array(child_edge ->> 'identity');
        END IF;
        RETURN jsonb_build_object('state', 'partial', 'nodes', nodes, 'edges', edges,
            'paths', jsonb_build_array(pgreact_internal.m41_path(
                path_nodes, COALESCE(path_edges, '[]'::jsonb), 'partial')),
            'boundaries', boundaries,
            'findings', jsonb_build_array(pgreact_internal.m41_finding(
                'M41_EVIDENCE_MISSING', 'WARNING', relation_row.relation_name, 'fact',
                'the derived fact is not retained at the sampled frontier',
                'Reconcile or restore the derived evidence before retrying.')));
    END IF;
    nodes := jsonb_build_array(jsonb_build_object(
        'kind', 'derived_fact', 'identity', fact_identity,
        'evidence', jsonb_build_object(
            'relation', relation_row.relation_name, 'version', relation_row.version,
            'subject_key', subject_key, 'fact', fact_row.fact,
            'support_count', fact_row.support_count,
            'first_frontier', fact_row.first_frontier, 'last_frontier', fact_row.last_frontier)));
    IF parent_id IS NULL THEN
        path_nodes := jsonb_build_array(fact_identity);
        path_edges := '[]'::jsonb;
    ELSE
        child_edge := pgreact_internal.m41_edge('derived_predecessor', parent_id, fact_identity);
        edges := edges || jsonb_build_array(child_edge);
        path_nodes := jsonb_build_array(parent_id, fact_identity);
        path_edges := jsonb_build_array(child_edge ->> 'identity');
    END IF;

    SELECT count(*) INTO support_count
    FROM pgreact_internal.derived_supports support
    WHERE support.relation_version_id = m41_derived_fragment.relation_version_id
      AND support.semantic_key = m41_derived_fragment.subject_key AND support.active;
    IF support_count = 0 THEN
        boundary_id := 'boundary:missing:support:' || pgreact_internal.m41_digest(
            jsonb_build_object('relation', relation_identity, 'subject_key', subject_key));
        boundaries := boundaries || jsonb_build_array(jsonb_build_object(
            'kind', 'missing', 'identity', boundary_id));
        child_edge := pgreact_internal.m41_edge('derived_support', fact_identity, boundary_id);
        edges := edges || jsonb_build_array(child_edge);
        paths := paths || jsonb_build_array(pgreact_internal.m41_path(
            path_nodes || jsonb_build_array(boundary_id),
            path_edges || jsonb_build_array(child_edge ->> 'identity'), 'partial'));
        RETURN jsonb_build_object('state', 'partial', 'nodes', nodes, 'edges', edges,
            'paths', paths, 'boundaries', boundaries,
            'findings', jsonb_build_array(pgreact_internal.m41_finding(
                'M41_EVIDENCE_MISSING', 'WARNING', relation_row.relation_name, 'support',
                'the derived fact has no active modeled support',
                'Reconcile the derived relation before retrying.')));
    END IF;
    IF support_count > fanout_limit THEN
        state := 'partial';
        findings := findings || jsonb_build_array(pgreact_internal.m41_finding(
            'M41_RESOURCE_LIMIT', 'WARNING', relation_row.relation_name, 'fanout',
            'the causal path reached the support fan-out limit',
            'Increase fanout_limit only for a bounded workload.'));
    END IF;
    FOR support_row IN
        SELECT support.rule_version_id, support.activation_id, support.semantic_key AS source_key,
               support.activation_generation, support.activation_revision,
               support.source_binding, rule.rule_name, derivation.version AS rule_version
        FROM pgreact_internal.derived_supports support
        JOIN pgreact_internal.derivation_rule_versions derivation
          ON derivation.rule_version_id = support.rule_version_id
        JOIN pgreact_internal.rules rule ON rule.rule_id = derivation.rule_id
        WHERE support.relation_version_id = m41_derived_fragment.relation_version_id
          AND support.semantic_key = m41_derived_fragment.subject_key AND support.active
        ORDER BY rule.rule_name, derivation.version,
                 support.activation_generation, support.activation_revision
        LIMIT fanout_limit
    LOOP
        support_number := support_number + 1;
        support_identity := format('derived_support:%s:subject=%s:rule=%s@%s:generation=%s:revision=%s:ordinal=%s',
            relation_identity, subject_key, support_row.rule_name, support_row.rule_version,
            support_row.activation_generation, support_row.activation_revision, support_number);
        nodes := nodes || jsonb_build_array(jsonb_build_object(
            'kind', 'derived_support', 'identity', support_identity,
            'evidence', jsonb_build_object(
                'relation', relation_row.relation_name, 'version', relation_row.version,
                'subject_key', subject_key, 'rule', support_row.rule_name,
                'rule_version', support_row.rule_version,
                'generation', support_row.activation_generation,
                'revision', support_row.activation_revision,
                'source_binding', support_row.source_binding)));
        support_edge := pgreact_internal.m41_edge('derived_support', fact_identity, support_identity);
        edges := edges || jsonb_build_array(support_edge);
        SELECT count(*) INTO input_count
        FROM pgreact_internal.derived_support_inputs input
        WHERE input.support_id = (
            SELECT support_id FROM pgreact_internal.derived_supports candidate
            WHERE candidate.relation_version_id = m41_derived_fragment.relation_version_id
              AND candidate.semantic_key = m41_derived_fragment.subject_key
              AND candidate.rule_version_id = support_row.rule_version_id
              AND candidate.activation_id = support_row.activation_id
              AND candidate.activation_generation = support_row.activation_generation
              AND candidate.activation_revision = support_row.activation_revision
            LIMIT 1);
        IF input_count = 0 THEN
            source_fragment := pgreact_internal.m41_rule_source_fragment(
                support_row.rule_version_id, support_row.source_key,
                NULL, support_row.activation_id, support_row.activation_generation,
                support_row.activation_revision);
            nodes := pgreact_internal.m41_array_union(nodes, source_fragment -> 'nodes');
            edges := pgreact_internal.m41_array_union(edges, source_fragment -> 'edges');
            boundaries := pgreact_internal.m41_array_union(boundaries, source_fragment -> 'boundaries');
            findings := pgreact_internal.m41_array_union(findings, source_fragment -> 'findings');
            IF source_fragment -> 'paths' IS NOT NULL
               AND jsonb_array_length(source_fragment -> 'paths') > 0 THEN
                FOR child_path IN SELECT value FROM jsonb_array_elements(source_fragment -> 'paths') item(value) LOOP
                    child_edge := pgreact_internal.m41_edge(
                        'support_rule', support_identity,
                        child_path -> 'nodes' ->> 0);
                    edges := edges || jsonb_build_array(child_edge);
                    combined_nodes := path_nodes || jsonb_build_array(support_identity) || child_path -> 'nodes';
                    combined_edges := path_edges || jsonb_build_array(support_edge ->> 'identity')
                        || jsonb_build_array(child_edge ->> 'identity') || child_path -> 'edges';
                    paths := paths || jsonb_build_array(pgreact_internal.m41_path(
                        combined_nodes, combined_edges,
                        CASE WHEN source_fragment ->> 'state' = 'complete' THEN state ELSE source_fragment ->> 'state' END));
                END LOOP;
            END IF;
        ELSE
            FOR input_row IN
                SELECT input.relation_version_id, input.semantic_key,
                       relation.relation_name, version.version
                FROM pgreact_internal.derived_support_inputs input
                JOIN pgreact_internal.derived_relation_versions version
                  ON version.relation_version_id = input.relation_version_id
                JOIN pgreact_internal.derived_relations relation USING (relation_id)
                WHERE input.support_id = (
                    SELECT support_id FROM pgreact_internal.derived_supports candidate
                    WHERE candidate.relation_version_id = m41_derived_fragment.relation_version_id
                      AND candidate.semantic_key = m41_derived_fragment.subject_key
                      AND candidate.rule_version_id = support_row.rule_version_id
                      AND candidate.activation_id = support_row.activation_id
                      AND candidate.activation_generation = support_row.activation_generation
                      AND candidate.activation_revision = support_row.activation_revision
                    LIMIT 1)
                ORDER BY input.input_order
            LOOP
                child := pgreact_internal.m41_derived_fragment(
                    input_row.relation_version_id, input_row.semantic_key, NULL,
                    depth + 1, depth_limit, fanout_limit, path_limit,
                    visited || relation_identity);
                nodes := pgreact_internal.m41_array_union(nodes, child -> 'nodes');
                edges := pgreact_internal.m41_array_union(edges, child -> 'edges');
                boundaries := pgreact_internal.m41_array_union(boundaries, child -> 'boundaries');
                findings := pgreact_internal.m41_array_union(findings, child -> 'findings');
                IF child ->> 'state' = 'unavailable' THEN state := 'unavailable';
                ELSIF child ->> 'state' = 'partial' AND state = 'complete' THEN state := 'partial'; END IF;
                FOR child_path IN SELECT value FROM jsonb_array_elements(child -> 'paths') item(value) LOOP
                    child_edge := pgreact_internal.m41_edge(
                        'support_input', support_identity, child_path -> 'nodes' ->> 0,
                        jsonb_build_object('input_relation', input_row.relation_name,
                                           'input_version', input_row.version));
                    edges := edges || jsonb_build_array(child_edge);
                    combined_nodes := path_nodes || jsonb_build_array(support_identity) || child_path -> 'nodes';
                    combined_edges := path_edges || jsonb_build_array(support_edge ->> 'identity')
                        || jsonb_build_array(child_edge ->> 'identity') || child_path -> 'edges';
                    paths := paths || jsonb_build_array(pgreact_internal.m41_path(
                        combined_nodes, combined_edges,
                        CASE WHEN child ->> 'state' = 'complete' THEN state ELSE child ->> 'state' END));
                END LOOP;
            END LOOP;
        END IF;
    END LOOP;
    paths := pgreact_internal.m41_array_union(paths, '[]'::jsonb);
    IF jsonb_array_length(paths) > path_limit THEN
        SELECT COALESCE(jsonb_agg(value ORDER BY ordinal) FILTER (WHERE ordinal <= path_limit), '[]'::jsonb)
        INTO paths FROM jsonb_array_elements(paths) WITH ORDINALITY item(value, ordinal);
        state := 'partial';
        findings := findings || jsonb_build_array(pgreact_internal.m41_finding(
            'M41_RESOURCE_LIMIT', 'WARNING', relation_row.relation_name, 'paths',
            'the causal path reached the returned-path limit',
            'Increase path_limit only for a bounded workload.'));
    END IF;
    RETURN jsonb_build_object('state', state, 'nodes', nodes, 'edges', edges,
                              'paths', paths, 'boundaries', boundaries,
                              'findings', findings);
END
$m41$;

CREATE OR REPLACE FUNCTION pgreact_internal.m41_member_fragment(
    member_kind text,
    member_name text,
    member_version text,
    subject_key bigint,
    parent_id text,
    sampled_time timestamptz,
    depth_limit integer,
    fanout_limit integer,
    path_limit integer
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m41$
<<m41_policy_block>>
DECLARE
    target_id uuid;
    child jsonb;
    boundary_id text;
    edge jsonb;
BEGIN
    IF member_kind = 'rule' THEN
        SELECT version.rule_version_id INTO target_id
        FROM pgreact_internal.api_declarations declaration
        JOIN pgreact_internal.rule_versions version
          ON version.rule_version_id = declaration.delegated_id
        WHERE declaration.kind = 'rule'
          AND declaration.object_name = member_name
          AND declaration.state = 'DEPLOYED'
          AND (member_version IN ('', '1') OR version.rule_version_id::text = member_version)
        ORDER BY version.created_at DESC LIMIT 1;
        IF target_id IS NULL THEN
            boundary_id := 'boundary:unsupported:rule-member:' ||
                pgreact_internal.m41_digest(jsonb_build_object('name', member_name));
            edge := pgreact_internal.m41_edge('policy_member', parent_id, boundary_id);
            RETURN jsonb_build_object('state', 'unsupported', 'nodes', '[]'::jsonb,
                'edges', jsonb_build_array(edge), 'paths', jsonb_build_array(
                    pgreact_internal.m41_path(jsonb_build_array(parent_id, boundary_id),
                                               jsonb_build_array(edge ->> 'identity'), 'unsupported')),
                'boundaries', jsonb_build_array(jsonb_build_object(
                    'kind', 'unsupported', 'identity', boundary_id)),
                'findings', jsonb_build_array(pgreact_internal.m41_finding(
                    'M41_UNSUPPORTED_NODE', 'WARNING', member_name, 'policy_member',
                    'the policy member rule is not available as modeled evidence',
                    'Deploy the member rule before retrying.')));
        END IF;
        RETURN pgreact_internal.m41_rule_source_fragment(target_id, subject_key, parent_id);
    ELSIF member_kind = 'derived_relation' THEN
        SELECT version.relation_version_id INTO target_id
        FROM pgreact_internal.derived_relations relation
        JOIN pgreact_internal.derived_relation_versions version USING (relation_id)
        WHERE relation.relation_name = member_name
          AND version.state = 'ACTIVE'
          AND (member_version = '' OR version.version::text = member_version)
        ORDER BY version.version DESC LIMIT 1;
        IF target_id IS NULL THEN
            boundary_id := 'boundary:unsupported:derived-member:' ||
                pgreact_internal.m41_digest(jsonb_build_object('name', member_name));
            edge := pgreact_internal.m41_edge('policy_member', parent_id, boundary_id);
            RETURN jsonb_build_object('state', 'unsupported', 'nodes', '[]'::jsonb,
                'edges', jsonb_build_array(edge), 'paths', jsonb_build_array(
                    pgreact_internal.m41_path(jsonb_build_array(parent_id, boundary_id),
                                               jsonb_build_array(edge ->> 'identity'), 'unsupported')),
                'boundaries', jsonb_build_array(jsonb_build_object(
                    'kind', 'unsupported', 'identity', boundary_id)),
                'findings', jsonb_build_array(pgreact_internal.m41_finding(
                    'M41_UNSUPPORTED_NODE', 'WARNING', member_name, 'policy_member',
                    'the policy member derived relation is not available as modeled evidence',
                    'Restore the active derived relation before retrying.')));
        END IF;
        RETURN pgreact_internal.m41_derived_fragment(
            target_id, subject_key, parent_id, 0, depth_limit, fanout_limit, path_limit);
    END IF;
    boundary_id := 'boundary:unsupported:member:' ||
        pgreact_internal.m41_digest(jsonb_build_object('kind', member_kind, 'name', member_name));
    edge := pgreact_internal.m41_edge('policy_member', parent_id, boundary_id);
    RETURN jsonb_build_object('state', 'unsupported', 'nodes', '[]'::jsonb,
        'edges', jsonb_build_array(edge), 'paths', jsonb_build_array(
            pgreact_internal.m41_path(jsonb_build_array(parent_id, boundary_id),
                                       jsonb_build_array(edge ->> 'identity'), 'unsupported')),
        'boundaries', jsonb_build_array(jsonb_build_object(
            'kind', 'unsupported', 'identity', boundary_id)),
        'findings', jsonb_build_array(pgreact_internal.m41_finding(
            'M41_UNSUPPORTED_NODE', 'WARNING', member_name, 'policy_member',
            'this policy member kind has no bounded M41 adapter',
            'Use a rule or derived relation member.')));
END
$m41$;

CREATE OR REPLACE FUNCTION pgreact_internal.m41_policy_fragment(
    policy_set_version_id uuid,
    subject_key bigint,
    parent_id text,
    sampled_time timestamptz,
    depth_limit integer,
    fanout_limit integer,
    path_limit integer
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m41$
DECLARE
    policy_row record;
    member_row record;
    source jsonb;
    child jsonb;
    policy_id text;
    applicability_id text;
    source_id text;
    boundary_id text;
    edge jsonb;
    path_nodes jsonb;
    path_edges jsonb := '[]'::jsonb;
    nodes jsonb := '[]'::jsonb;
    edges jsonb := '[]'::jsonb;
    paths jsonb := '[]'::jsonb;
    boundaries jsonb := '[]'::jsonb;
    findings jsonb := '[]'::jsonb;
    state text := 'complete';
    policy_target pgreact_api.target;
BEGIN
    SELECT set.set_name, version.version, version.applicability_kind,
           version.applicability_source, version.applicability_source_oid,
           version.subject_key, version.subject_type, version.valid_from, version.valid_to,
           version.complete_frontier, version.policy_set_id
    INTO policy_row
    FROM pgreact_internal.policy_set_versions version
    JOIN pgreact_internal.policy_sets set USING (policy_set_id)
    WHERE version.policy_set_version_id = m41_policy_fragment.policy_set_version_id;
    IF NOT FOUND THEN
        boundary_id := 'boundary:missing:policy-set';
        edge := pgreact_internal.m41_edge('policy_predecessor', parent_id, boundary_id);
        RETURN jsonb_build_object('state', 'unavailable', 'nodes', '[]'::jsonb,
            'edges', jsonb_build_array(edge), 'paths', jsonb_build_array(
                pgreact_internal.m41_path(jsonb_build_array(parent_id, boundary_id),
                                           jsonb_build_array(edge ->> 'identity'), 'unavailable')),
            'boundaries', jsonb_build_array(jsonb_build_object('kind', 'missing', 'identity', boundary_id)),
            'findings', jsonb_build_array(pgreact_internal.m41_finding(
                'M41_EVIDENCE_MISSING', 'WARNING', '<unknown>', 'policy_set',
                'the policy-set version is no longer available',
                'Restore the policy-set evidence before retrying.')));
    END IF;
    policy_id := format('policy_set:%s@%s:subject=%s', policy_row.set_name,
                        policy_row.version, subject_key);
    applicability_id := policy_id || ':applicability';
    nodes := jsonb_build_array(
        jsonb_build_object('kind', 'policy_set', 'identity', policy_id,
            'evidence', jsonb_build_object(
                'name', policy_row.set_name, 'version', policy_row.version,
                'valid_from', policy_row.valid_from, 'valid_to', policy_row.valid_to)),
        jsonb_build_object('kind', 'policy_applicability', 'identity', applicability_id,
            'evidence', jsonb_build_object(
                'source', policy_row.applicability_source,
                'subject_key', subject_key, 'sampled_time', sampled_time)));
    edge := pgreact_internal.m41_edge('policy_applicability', parent_id, policy_id);
    edges := edges || jsonb_build_array(edge);
    edge := pgreact_internal.m41_edge('policy_evaluation', policy_id, applicability_id);
    edges := edges || jsonb_build_array(edge);
    path_nodes := jsonb_build_array(parent_id, policy_id, applicability_id);
    path_edges := jsonb_build_array(edges -> 0 ->> 'identity', edges -> 1 ->> 'identity');

    policy_target := pgreact_api.target('policy_set', policy_row.set_name, policy_row.version);
    IF sampled_time < policy_row.valid_from
       OR (policy_row.valid_to IS NOT NULL AND sampled_time >= policy_row.valid_to) THEN
        state := 'partial';
        boundary_id := 'boundary:inactive_time:' || pgreact_internal.m41_digest(
            jsonb_build_object('policy', policy_id));
        boundaries := boundaries || jsonb_build_array(jsonb_build_object(
            'kind', 'inactive_time', 'identity', boundary_id));
        edge := pgreact_internal.m41_edge('policy_time', applicability_id, boundary_id);
        edges := edges || jsonb_build_array(edge);
        paths := paths || jsonb_build_array(pgreact_internal.m41_path(
            path_nodes || jsonb_build_array(boundary_id),
            path_edges || jsonb_build_array(edge ->> 'identity'), 'partial'));
        findings := findings || jsonb_build_array(pgreact_internal.m41_finding(
            'M41_STALE_FRONTIER', 'WARNING', policy_row.set_name, 'validity',
            'the policy applicability interval is inactive at the sampled time',
            'Use the policy version active at the requested evaluation point.'));
    ELSIF policy_row.applicability_kind <> 'relation'
          OR policy_row.subject_type::text NOT IN ('bigint', 'integer', 'smallint') THEN
        state := 'unsupported';
        boundary_id := 'boundary:unsupported:policy-applicability:' ||
            pgreact_internal.m41_digest(jsonb_build_object('policy', policy_id));
        boundaries := boundaries || jsonb_build_array(jsonb_build_object(
            'kind', 'unsupported', 'identity', boundary_id));
        edge := pgreact_internal.m41_edge('policy_evaluation', applicability_id, boundary_id);
        edges := edges || jsonb_build_array(edge);
        paths := paths || jsonb_build_array(pgreact_internal.m41_path(
            path_nodes || jsonb_build_array(boundary_id),
            path_edges || jsonb_build_array(edge ->> 'identity'), 'unsupported'));
        findings := findings || jsonb_build_array(pgreact_internal.m41_finding(
            'M41_UNSUPPORTED_NODE', 'WARNING', policy_row.set_name, 'applicability',
            'only relational bigint policy applicability is in the qualified adapter',
            'Use a supported relation-backed policy set.'));
    ELSE
        source := pgreact_internal.m41_source_evidence(
            policy_row.applicability_source_oid, policy_row.applicability_source,
            policy_row.subject_key, subject_key);
        IF source ->> 'state' = 'ok'
           AND pgreact_internal.m30_subject_eligible(policy_target, to_jsonb(subject_key)) THEN
            source_id := 'authoritative:' || policy_row.applicability_source || ':' ||
                policy_row.subject_key || '=' || subject_key;
            nodes := nodes || jsonb_build_array(jsonb_build_object(
                'kind', 'authoritative_fact', 'identity', source_id,
                'evidence', source - 'state'));
            edge := pgreact_internal.m41_edge('policy_source', applicability_id, source_id);
            edges := edges || jsonb_build_array(edge);
            path_nodes := path_nodes || jsonb_build_array(source_id);
            path_edges := path_edges || jsonb_build_array(edge ->> 'identity');
        ELSE
            state := CASE source ->> 'state'
                WHEN 'unauthorized' THEN 'unavailable'
                WHEN 'rls' THEN 'unavailable'
                WHEN 'schema_drift' THEN 'unavailable'
                ELSE 'partial' END;
            boundary_id := 'boundary:' || CASE source ->> 'state'
                WHEN 'unauthorized' THEN 'inaccessible'
                WHEN 'rls' THEN 'inaccessible'
                WHEN 'schema_drift' THEN 'schema_drift'
                WHEN 'missing' THEN 'missing'
                ELSE 'ineligible' END || ':' ||
                pgreact_internal.m41_digest(jsonb_build_object('parent', applicability_id));
            boundaries := boundaries || jsonb_build_array(jsonb_build_object(
                'kind', split_part(boundary_id, ':', 2), 'identity', boundary_id));
            edge := pgreact_internal.m41_edge('policy_source', applicability_id, boundary_id);
            edges := edges || jsonb_build_array(edge);
            path_nodes := path_nodes || jsonb_build_array(boundary_id);
            path_edges := path_edges || jsonb_build_array(edge ->> 'identity');
            findings := findings || jsonb_build_array(pgreact_internal.m41_finding(
                CASE source ->> 'state'
                    WHEN 'unauthorized' THEN 'M41_UNAUTHORIZED'
                    WHEN 'rls' THEN 'M41_RLS_REJECTED'
                    WHEN 'schema_drift' THEN 'M41_SCHEMA_DRIFT'
                    WHEN 'missing' THEN 'M41_EVIDENCE_MISSING'
                    ELSE 'M41_EVIDENCE_MISSING' END,
                'WARNING', policy_row.set_name, 'applicability',
                'policy applicability ends at an explicit evidence boundary',
                'Restore the source and retry the causal path.'));
        END IF;
        IF policy_row.complete_frontier < sampled_time AND state = 'complete' THEN
            state := 'partial';
            findings := findings || jsonb_build_array(pgreact_internal.m41_finding(
                'M41_STALE_FRONTIER', 'WARNING', policy_row.set_name, 'complete_frontier',
                'policy applicability evidence is older than the sampled time',
                'Refresh the policy set and retry the request.'));
        END IF;
        paths := paths || jsonb_build_array(pgreact_internal.m41_path(path_nodes, path_edges, state));
    END IF;

    FOR member_row IN
        SELECT member.member_kind, member.member_name, member.member_version
        FROM pgreact_internal.policy_set_members member
        WHERE member.policy_set_version_id = m41_policy_fragment.policy_set_version_id
          AND member.member_kind <> 'decision_program'
        ORDER BY member.ordinal
    LOOP
        child := pgreact_internal.m41_member_fragment(
            member_row.member_kind, member_row.member_name, member_row.member_version,
            subject_key, policy_id, sampled_time, depth_limit, fanout_limit, path_limit);
        nodes := pgreact_internal.m41_array_union(nodes, child -> 'nodes');
        edges := pgreact_internal.m41_array_union(edges, child -> 'edges');
        paths := pgreact_internal.m41_array_union(paths, child -> 'paths');
        boundaries := pgreact_internal.m41_array_union(boundaries, child -> 'boundaries');
        findings := pgreact_internal.m41_array_union(findings, child -> 'findings');
        IF child ->> 'state' = 'unavailable' THEN state := 'unavailable';
        ELSIF child ->> 'state' = 'partial' AND state = 'complete' THEN state := 'partial';
        ELSIF child ->> 'state' = 'unsupported' AND state = 'complete' THEN state := 'unsupported'; END IF;
    END LOOP;
    RETURN jsonb_build_object('state', state, 'nodes', nodes, 'edges', edges,
                              'paths', paths, 'boundaries', boundaries,
                              'findings', findings);
END
$m41$;

CREATE OR REPLACE FUNCTION pgreact_internal.m41_decision_fragment(
    target_name text,
    subject_key bigint,
    result_key bigint DEFAULT NULL,
    parent_id text DEFAULT NULL,
    sampled_time timestamptz DEFAULT statement_timestamp(),
    depth_limit integer DEFAULT 16,
    fanout_limit integer DEFAULT 64,
    path_limit integer DEFAULT 64
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m41$
<<m41_decision_block>>
DECLARE
    version_row record;
    winner_row record;
    candidate_row jsonb;
    policy_row record;
    child jsonb;
    source_id text;
    result_id text;
    selection_id text;
    candidate_id text;
    boundary_id text;
    edge jsonb;
    nodes jsonb := '[]'::jsonb;
    edges jsonb := '[]'::jsonb;
    paths jsonb := '[]'::jsonb;
    boundaries jsonb := '[]'::jsonb;
    findings jsonb := '[]'::jsonb;
    path_nodes jsonb;
    path_edges jsonb;
    source_state text;
    relation_kind "char";
    rls_enabled boolean;
    candidate_value bigint;
    priority_value bigint;
    effective_result_key bigint;
    state text := 'complete';
BEGIN
    SELECT version.* INTO version_row
    FROM pgreact_internal.decision_programs program
    JOIN pgreact_internal.decision_program_versions version USING (program_id)
    WHERE program.program_name = target_name AND program.state <> 'REMOVED'
      AND version.state = 'DEPLOYED'
    ORDER BY version.valid_from DESC, version.version_no DESC LIMIT 1;
    IF NOT FOUND THEN
        boundary_id := 'boundary:missing:decision';
        edge := pgreact_internal.m41_edge('decision_predecessor', parent_id, boundary_id);
        RETURN jsonb_build_object('state', 'unavailable', 'nodes', nodes,
            'edges', jsonb_build_array(edge), 'paths', jsonb_build_array(
                pgreact_internal.m41_path(jsonb_build_array(parent_id, boundary_id),
                                           jsonb_build_array(edge ->> 'identity'), 'unavailable')),
            'boundaries', jsonb_build_array(jsonb_build_object('kind', 'missing', 'identity', boundary_id)),
            'findings', jsonb_build_array(pgreact_internal.m41_finding(
                'M41_EVIDENCE_MISSING', 'WARNING', target_name, 'decision',
                'the deployed decision version is unavailable',
                'Deploy or restore the decision evidence before retrying.')));
    END IF;
    SELECT state.* INTO winner_row
    FROM pgreact_internal.decision_subject_state state
    WHERE state.program_id = version_row.program_id
      AND state.subject_key = m41_decision_fragment.subject_key;
    IF NOT FOUND THEN
        boundary_id := 'boundary:missing:decision-result';
        edge := pgreact_internal.m41_edge('decision_predecessor', parent_id, boundary_id);
        RETURN jsonb_build_object('state', 'unavailable', 'nodes', nodes,
            'edges', jsonb_build_array(edge), 'paths', jsonb_build_array(
                pgreact_internal.m41_path(jsonb_build_array(parent_id, boundary_id),
                                           jsonb_build_array(edge ->> 'identity'), 'unavailable')),
            'boundaries', jsonb_build_array(jsonb_build_object('kind', 'missing', 'identity', boundary_id)),
            'findings', jsonb_build_array(pgreact_internal.m41_finding(
                'M41_ROOT_NOT_FOUND', 'WARNING', target_name, 'decision_result',
                'the requested decision result is not retained',
                'Use a current decision result identity.')));
    END IF;
    effective_result_key := COALESCE(result_key, winner_row.winner_candidate);
    result_id := format('decision_result:%s@%s:subject=%s:candidate=%s:revision=%s',
                        target_name, version_row.version_no, subject_key,
                        COALESCE(effective_result_key::text, '<none>'), winner_row.revision);
    nodes := jsonb_build_array(jsonb_build_object(
        'kind', 'decision_result', 'identity', result_id,
        'evidence', jsonb_build_object(
            'target', target_name, 'version', version_row.version_no,
            'subject_key', subject_key, 'state', winner_row.state,
            'candidate_key', winner_row.winner_candidate,
            'priority', winner_row.winner_priority, 'result', winner_row.winner_result,
            'generation', winner_row.generation, 'revision', winner_row.revision)));
    IF parent_id IS NOT NULL THEN
        edge := pgreact_internal.m41_edge('decision_work', parent_id, result_id);
        edges := edges || jsonb_build_array(edge);
        path_nodes := jsonb_build_array(parent_id, result_id);
        path_edges := jsonb_build_array(edge ->> 'identity');
    ELSE
        path_nodes := jsonb_build_array(result_id);
        path_edges := '[]'::jsonb;
    END IF;
    IF winner_row.state <> 'WINNER' OR winner_row.winner_candidate IS NULL
       OR effective_result_key <> winner_row.winner_candidate THEN
        state := 'unavailable';
        boundary_id := 'boundary:missing:decision-selection:' ||
            pgreact_internal.m41_digest(jsonb_build_object('target', target_name, 'subject_key', subject_key));
        boundaries := jsonb_build_array(jsonb_build_object('kind', 'missing', 'identity', boundary_id));
        edge := pgreact_internal.m41_edge('decision_selection', result_id, boundary_id);
        edges := edges || jsonb_build_array(edge);
        paths := jsonb_build_array(pgreact_internal.m41_path(
            path_nodes || jsonb_build_array(boundary_id),
            path_edges || jsonb_build_array(edge ->> 'identity'), state));
        findings := jsonb_build_array(pgreact_internal.m41_finding(
            'M41_ROOT_NOT_FOUND', 'WARNING', target_name, 'decision_result',
            'the requested candidate is not the retained decision winner',
            'Use the current winner candidate and revision.'));
        RETURN jsonb_build_object('state', state, 'nodes', nodes, 'edges', edges,
            'paths', paths, 'boundaries', boundaries, 'findings', findings);
    END IF;
    selection_id := format('decision_selection:%s@%s:subject=%s:revision=%s',
                           target_name, version_row.version_no, subject_key, winner_row.revision);
    candidate_id := format('decision_candidate:%s@%s:subject=%s:candidate=%s',
                           target_name, version_row.version_no, subject_key, effective_result_key);
    nodes := nodes || jsonb_build_array(
        jsonb_build_object('kind', 'decision_selection', 'identity', selection_id,
            'evidence', jsonb_build_object(
                'state', winner_row.state, 'winner_candidate', winner_row.winner_candidate,
                'winner_priority', winner_row.winner_priority, 'revision', winner_row.revision)),
        jsonb_build_object('kind', 'decision_candidate', 'identity', candidate_id,
            'evidence', jsonb_build_object('candidate_key', effective_result_key,
                'priority', winner_row.winner_priority, 'result', winner_row.winner_result)));
    edge := pgreact_internal.m41_edge('decision_selection', result_id, selection_id);
    edges := edges || jsonb_build_array(edge);
    edge := pgreact_internal.m41_edge('decision_candidate', selection_id, candidate_id);
    edges := edges || jsonb_build_array(edge);
    path_nodes := path_nodes || jsonb_build_array(selection_id, candidate_id);
    path_edges := path_edges || jsonb_build_array(
        edges -> (jsonb_array_length(edges) - 2) ->> 'identity',
        edges -> (jsonb_array_length(edges) - 1) ->> 'identity');

    SELECT c.relkind, c.relrowsecurity INTO relation_kind, rls_enabled
    FROM pg_class c WHERE c.oid = version_row.candidate_relation_oid;
    IF relation_kind IS NULL THEN source_state := 'schema_drift';
    ELSIF rls_enabled THEN source_state := 'rls';
    ELSIF NOT has_table_privilege(session_user, version_row.candidate_relation_oid, 'SELECT') THEN source_state := 'unauthorized';
    ELSIF NOT EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = version_row.candidate_relation_oid
                      AND attname = version_row.subject_key_column AND attnum > 0 AND NOT attisdropped)
       OR NOT EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = version_row.candidate_relation_oid
                      AND attname = version_row.candidate_key_column AND attnum > 0 AND NOT attisdropped)
       OR NOT EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = version_row.candidate_relation_oid
                      AND attname = version_row.priority_column AND attnum > 0 AND NOT attisdropped)
    THEN source_state := 'schema_drift';
    ELSE
        EXECUTE format('SELECT to_jsonb(s) FROM %s s WHERE s.%I = $1 AND s.%I = $2 LIMIT 1',
                       version_row.candidate_relation_oid::regclass,
                       version_row.subject_key_column, version_row.candidate_key_column)
        INTO candidate_row USING subject_key, effective_result_key;
        source_state := CASE WHEN candidate_row IS NULL THEN 'missing' ELSE 'ok' END;
    END IF;
    IF source_state = 'ok' THEN
        source_id := format('authoritative:%s:subject=%s:candidate=%s',
                            version_row.candidate_relation_name, subject_key, effective_result_key);
        nodes := nodes || jsonb_build_array(jsonb_build_object(
            'kind', 'authoritative_fact', 'identity', source_id,
            'evidence', jsonb_build_object('source', version_row.candidate_relation_name,
                                            'subject_key', subject_key,
                                            'candidate_key', effective_result_key,
                                            'row', candidate_row)));
        edge := pgreact_internal.m41_edge('candidate_source', candidate_id, source_id);
        edges := edges || jsonb_build_array(edge);
        path_nodes := path_nodes || jsonb_build_array(source_id);
        path_edges := path_edges || jsonb_build_array(edge ->> 'identity');
    ELSE
        state := CASE WHEN source_state = 'missing' THEN 'partial' ELSE 'unavailable' END;
        boundary_id := 'boundary:' || CASE source_state
            WHEN 'unauthorized' THEN 'inaccessible'
            WHEN 'rls' THEN 'inaccessible'
            WHEN 'schema_drift' THEN 'schema_drift'
            WHEN 'missing' THEN 'missing'
            ELSE 'unsupported' END || ':' || pgreact_internal.m41_digest(
                jsonb_build_object('parent', candidate_id));
        boundaries := boundaries || jsonb_build_array(jsonb_build_object(
            'kind', split_part(boundary_id, ':', 2), 'identity', boundary_id));
        edge := pgreact_internal.m41_edge('candidate_source', candidate_id, boundary_id);
        edges := edges || jsonb_build_array(edge);
        path_nodes := path_nodes || jsonb_build_array(boundary_id);
        path_edges := path_edges || jsonb_build_array(edge ->> 'identity');
        findings := findings || jsonb_build_array(pgreact_internal.m41_finding(
            CASE source_state
                WHEN 'unauthorized' THEN 'M41_UNAUTHORIZED'
                WHEN 'rls' THEN 'M41_RLS_REJECTED'
                WHEN 'schema_drift' THEN 'M41_SCHEMA_DRIFT'
                WHEN 'missing' THEN 'M41_EVIDENCE_MISSING'
                ELSE 'M41_UNSUPPORTED_NODE' END,
            'WARNING', target_name, 'candidate_source',
            'the decision candidate ends at an explicit evidence boundary',
            'Restore the candidate source and retry the request.'));
    END IF;
    paths := jsonb_build_array(pgreact_internal.m41_path(path_nodes, path_edges, state));

    FOR policy_row IN
        SELECT version.policy_set_version_id
        FROM pgreact_internal.policy_set_members member
        JOIN pgreact_internal.policy_set_versions version
          USING (policy_set_version_id)
        WHERE member.member_kind = 'decision_program'
          AND member.member_name = target_name
          AND version.state = 'DEPLOYED'
          AND version.valid_from <= sampled_time
          AND (version.valid_to IS NULL OR sampled_time < version.valid_to)
        ORDER BY version.valid_from, version.version
    LOOP
        child := pgreact_internal.m41_policy_fragment(
            policy_row.policy_set_version_id, subject_key, result_id, sampled_time,
            depth_limit, fanout_limit, path_limit);
        nodes := pgreact_internal.m41_array_union(nodes, child -> 'nodes');
        edges := pgreact_internal.m41_array_union(edges, child -> 'edges');
        paths := pgreact_internal.m41_array_union(paths, child -> 'paths');
        boundaries := pgreact_internal.m41_array_union(boundaries, child -> 'boundaries');
        findings := pgreact_internal.m41_array_union(findings, child -> 'findings');
        IF child ->> 'state' = 'unavailable' THEN state := 'unavailable';
        ELSIF child ->> 'state' = 'partial' AND state = 'complete' THEN state := 'partial';
        ELSIF child ->> 'state' = 'unsupported' AND state = 'complete' THEN state := 'unsupported'; END IF;
    END LOOP;
    RETURN jsonb_build_object('state', state, 'nodes', nodes, 'edges', edges,
                              'paths', paths, 'boundaries', boundaries, 'findings', findings);
END
$m41$;

CREATE OR REPLACE FUNCTION pgreact_internal.m41_explain(
    target_name text,
    subject jsonb,
    options jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m41$
<<m41_explain_block>>
DECLARE
    started_at timestamptz := clock_timestamp();
    sampled_time timestamptz := statement_timestamp();
    authoritative_frontier timestamptz;
    cp jsonb;
    root_kind text;
    result_key text;
    work_id text;
    event_kind text;
    consequence_identity text;
    target_kind text;
    target_version text;
    target_count bigint;
    explain_subject_key bigint;
    result_key_numeric bigint;
    generation bigint;
    explain_revision bigint;
    limit_text text;
    option_name text;
    unknown_option text;
    node_limit integer := 256;
    edge_limit integer := 512;
    path_limit integer := 64;
    depth_limit integer := 16;
    fanout_limit integer := 64;
    payload_limit integer := 65536;
    root jsonb;
    root_id text;
    fragment jsonb;
    edge jsonb;
    nodes jsonb := '[]'::jsonb;
    edges jsonb := '[]'::jsonb;
    paths jsonb := '[]'::jsonb;
    boundaries jsonb := '[]'::jsonb;
    findings jsonb := '[]'::jsonb;
    state text := 'complete';
    limits jsonb;
    declaration_digest text;
    semantic_digest text;
    source_digest text;
    decision_row record;
    work_row record;
    event_row record;
    activation_row record;
    root_request jsonb;
    policy_limit integer;
BEGIN
    SELECT frontier INTO authoritative_frontier
    FROM pgreact_internal.clock_frontier WHERE singleton;
    cp := options -> 'causal_path';
    limits := jsonb_build_object(
        'node_limit', node_limit, 'edge_limit', edge_limit, 'path_limit', path_limit,
        'depth_limit', depth_limit, 'fanout_limit', fanout_limit,
        'payload_limit', payload_limit);
    IF jsonb_typeof(options) IS DISTINCT FROM 'object'
       OR jsonb_typeof(cp) IS DISTINCT FROM 'object' THEN
        RETURN pgreact_internal.m41_result(NULL, target_name, NULL, 'unsupported', subject,
            cp, sampled_time, authoritative_frontier, NULL, nodes, edges, paths, boundaries,
            jsonb_build_array(pgreact_internal.m41_finding(
                'M41_OPTIONS_INVALID', 'ERROR', COALESCE(target_name, '<unknown>'),
                'options.causal_path', 'causal_path must be an object',
                'Pass a root_kind and its public identity fields.')),
            limits, pgreact_internal.m41_cost(started_at, 0, 0, 0, 0, 0, 0, 0, 0), '{}');
    END IF;
    SELECT key INTO unknown_option
    FROM jsonb_object_keys(cp) key
    WHERE key <> ALL (ARRAY[
        'root_kind', 'result_key', 'work_id', 'generation', 'revision',
        'consequence_identity', 'event_kind', 'node_limit', 'edge_limit',
        'path_limit', 'depth_limit', 'fanout_limit', 'payload_limit'])
    ORDER BY key LIMIT 1;
    IF unknown_option IS NOT NULL THEN
        RETURN pgreact_internal.m41_result(NULL, target_name, NULL, 'unsupported', subject,
            cp, sampled_time, authoritative_frontier, NULL, nodes, edges, paths, boundaries,
            jsonb_build_array(pgreact_internal.m41_finding(
                'M41_OPTIONS_INVALID', 'ERROR', COALESCE(target_name, '<unknown>'),
                'options.causal_path.' || unknown_option, 'causal_path contains an unknown field',
                'Use only fields listed in the M41 causal-path contract.')),
            limits, pgreact_internal.m41_cost(started_at, 0, 0, 0, 0, 0, 0, 0, 0), '{}');
    END IF;
    FOREACH option_name IN ARRAY ARRAY['node_limit', 'edge_limit', 'path_limit',
                                      'depth_limit', 'fanout_limit', 'payload_limit'] LOOP
        IF cp ? option_name THEN
            limit_text := cp ->> option_name;
            IF jsonb_typeof(cp -> option_name) <> 'number'
               OR limit_text !~ '^[1-9][0-9]*$'
               OR length(limit_text) > 6 THEN
                RETURN pgreact_internal.m41_result(NULL, target_name, NULL, 'unsupported', subject,
                    cp, sampled_time, authoritative_frontier, NULL, nodes, edges, paths, boundaries,
                    jsonb_build_array(pgreact_internal.m41_finding(
                        'M41_OPTIONS_INVALID', 'ERROR', COALESCE(target_name, '<unknown>'),
                        'options.causal_path.' || option_name,
                        'causal-path limits must be positive bounded integers',
                        'Use positive values within the published M41 limits.')),
                    limits, pgreact_internal.m41_cost(started_at, 0, 0, 0, 0, 0, 0, 0, 0), '{}');
            END IF;
            IF option_name = 'node_limit' THEN node_limit := limit_text::integer;
            ELSIF option_name = 'edge_limit' THEN edge_limit := limit_text::integer;
            ELSIF option_name = 'path_limit' THEN path_limit := limit_text::integer;
            ELSIF option_name = 'depth_limit' THEN depth_limit := limit_text::integer;
            ELSIF option_name = 'fanout_limit' THEN fanout_limit := limit_text::integer;
            ELSE payload_limit := limit_text::integer; END IF;
        END IF;
    END LOOP;
    limits := jsonb_build_object(
        'node_limit', node_limit, 'edge_limit', edge_limit, 'path_limit', path_limit,
        'depth_limit', depth_limit, 'fanout_limit', fanout_limit,
        'payload_limit', payload_limit);
    root_kind := cp ->> 'root_kind';
    IF root_kind NOT IN ('decision_result', 'rule_work', 'decision_work') THEN
        RETURN pgreact_internal.m41_result(NULL, target_name, NULL, 'unsupported', subject,
            cp, sampled_time, authoritative_frontier, NULL, nodes, edges, paths, boundaries,
            jsonb_build_array(pgreact_internal.m41_finding(
                'M41_UNSUPPORTED_ROOT', 'WARNING', COALESCE(target_name, '<unknown>'),
                'options.causal_path.root_kind', 'this root kind is outside the bounded adapter',
                'Use decision_result, rule_work, or decision_work.')),
            limits, pgreact_internal.m41_cost(started_at, 0, 0, 0, 0, 0, 0, 0, 0), '{}');
    END IF;
    IF root_kind = 'decision_result' THEN
        result_key := cp ->> 'result_key';
        IF result_key IS NULL OR result_key = '' THEN
            RETURN pgreact_internal.m41_result(NULL, target_name, NULL, 'unsupported', subject,
                cp, sampled_time, authoritative_frontier, NULL, nodes, edges, paths, boundaries,
                jsonb_build_array(pgreact_internal.m41_finding(
                    'M41_ROOT_INVALID', 'ERROR', target_name, 'options.causal_path.result_key',
                    'a decision-result root requires one result key',
                    'Pass the public candidate key as result_key.')),
                limits, pgreact_internal.m41_cost(started_at, 0, 0, 0, 0, 0, 0, 0, 0), '{}');
        END IF;
        result_key_numeric := pgreact_internal.m40_subject_key(to_jsonb(result_key));
        IF result_key_numeric IS NULL THEN
            RETURN pgreact_internal.m41_result(NULL, target_name, NULL, 'unsupported', subject,
                cp, sampled_time, authoritative_frontier, NULL, nodes, edges, paths, boundaries,
                jsonb_build_array(pgreact_internal.m41_finding(
                    'M41_ROOT_INVALID', 'ERROR', target_name, 'options.causal_path.result_key',
                    'result_key must be a bigint public candidate key',
                    'Pass a decimal candidate key.')),
                limits, pgreact_internal.m41_cost(started_at, 0, 0, 0, 0, 0, 0, 0, 0), '{}');
        END IF;
    ELSE
        work_id := cp ->> 'work_id';
        IF work_id IS NULL OR work_id = '' OR cp ->> 'generation' IS NULL THEN
            RETURN pgreact_internal.m41_result(NULL, target_name, NULL, 'unsupported', subject,
                cp, sampled_time, authoritative_frontier, NULL, nodes, edges, paths, boundaries,
                jsonb_build_array(pgreact_internal.m41_finding(
                    'M41_ROOT_INVALID', 'ERROR', target_name, 'options.causal_path',
                    'work roots require work_id and generation',
                    'Use the public work identity and retained generation.')),
                limits, pgreact_internal.m41_cost(started_at, 0, 0, 0, 0, 0, 0, 0, 0), '{}');
        END IF;
        IF work_id !~ '^-?[0-9]+$' THEN
            RETURN pgreact_internal.m41_result(NULL, target_name, NULL, 'unsupported', subject,
                cp, sampled_time, authoritative_frontier, NULL, nodes, edges, paths, boundaries,
                jsonb_build_array(pgreact_internal.m41_finding(
                    'M41_ROOT_INVALID', 'ERROR', target_name, 'options.causal_path.work_id',
                    'work_id must be the public decimal work identity',
                    'Pass the work_id returned by pgreact.work.')),
                limits, pgreact_internal.m41_cost(started_at, 0, 0, 0, 0, 0, 0, 0, 0), '{}');
        END IF;
        IF cp ->> 'generation' !~ '^[0-9]+$'
           OR (root_kind = 'decision_work' AND (cp ->> 'revision') !~ '^[0-9]+$')
           OR (root_kind = 'rule_work' AND (cp ? 'revision')
               AND (cp ->> 'revision') !~ '^[0-9]+$') THEN
            RETURN pgreact_internal.m41_result(NULL, target_name, NULL, 'unsupported', subject,
                cp, sampled_time, authoritative_frontier, NULL, nodes, edges, paths, boundaries,
                jsonb_build_array(pgreact_internal.m41_finding(
                    'M41_ROOT_INVALID', 'ERROR', target_name, 'options.causal_path.generation',
                    'generation and revision must be non-negative integers',
                    'Use the generation and revision from public evidence.')),
                limits, pgreact_internal.m41_cost(started_at, 0, 0, 0, 0, 0, 0, 0, 0), '{}');
        END IF;
        generation := (cp ->> 'generation')::bigint;
        IF cp ? 'revision' THEN explain_revision := (cp ->> 'revision')::bigint; END IF;
        event_kind := cp ->> 'event_kind';
        IF root_kind = 'rule_work' AND event_kind NOT IN ('ACTIVATE', 'DEACTIVATE') THEN
            RETURN pgreact_internal.m41_result(NULL, target_name, NULL, 'unsupported', subject,
                cp, sampled_time, authoritative_frontier, NULL, nodes, edges, paths, boundaries,
                jsonb_build_array(pgreact_internal.m41_finding(
                    'M41_ROOT_INVALID', 'ERROR', target_name, 'options.causal_path.event_kind',
                    'rule work requires ACTIVATE or DEACTIVATE event_kind',
                    'Use the lifecycle event kind attached to the work item.')),
                limits, pgreact_internal.m41_cost(started_at, 0, 0, 0, 0, 0, 0, 0, 0), '{}');
        END IF;
    END IF;
    explain_subject_key := pgreact_internal.m40_subject_key(subject);
    IF explain_subject_key IS NULL THEN
        RETURN pgreact_internal.m41_result(NULL, target_name, NULL, 'unsupported', subject,
            cp, sampled_time, authoritative_frontier, NULL, nodes, edges, paths, boundaries,
            jsonb_build_array(pgreact_internal.m41_finding(
                'M41_SUBJECT_INVALID', 'ERROR', COALESCE(target_name, '<unknown>'), 'subject',
                'causal-path adapters require one bigint business subject key',
                'Pass a JSON number or {"key": number}.')),
            limits, pgreact_internal.m41_cost(started_at, 0, 0, 0, 0, 0, 0, 0, 0), '{}');
    END IF;

    SELECT count(*) INTO target_count
    FROM (
        SELECT declaration.kind, declaration.object_name
        FROM pgreact_internal.api_declarations declaration
        WHERE declaration.state = 'DEPLOYED'
        UNION
        SELECT 'policy_set', set.set_name
        FROM pgreact_internal.policy_set_versions version
        JOIN pgreact_internal.policy_sets set USING (policy_set_id)
        WHERE version.state = 'DEPLOYED'
        UNION
        SELECT 'derived_relation', relation.relation_name
        FROM pgreact_internal.derived_relations relation
        JOIN pgreact_internal.derived_relation_versions version USING (relation_id)
        WHERE version.state = 'ACTIVE'
    ) targets WHERE object_name = target_name;
    IF target_count = 0 THEN
        RETURN pgreact_internal.m41_result(NULL, target_name, NULL, 'unsupported', subject,
            cp, sampled_time, authoritative_frontier, NULL, nodes, edges, paths, boundaries,
            jsonb_build_array(pgreact_internal.m41_finding(
                'M41_TARGET_NOT_FOUND', 'ERROR', COALESCE(target_name, '<unknown>'), 'target',
                'no deployed target with this public name exists',
                'Use the stable name of a deployed decision or rule.')),
            limits, pgreact_internal.m41_cost(started_at, 0, 0, 0, 0, 0, 0, 0, 0), '{}');
    ELSIF target_count > 1 THEN
        RETURN pgreact_internal.m41_result(NULL, target_name, NULL, 'unsupported', subject,
            cp, sampled_time, authoritative_frontier, NULL, nodes, edges, paths, boundaries,
            jsonb_build_array(pgreact_internal.m41_finding(
                'M41_TARGET_AMBIGUOUS', 'ERROR', target_name, 'target',
                'more than one deployed target has this public name',
                'Use a unique public target name.')),
            limits, pgreact_internal.m41_cost(started_at, 0, 0, 0, 0, 0, 0, 0, 0), '{}');
    END IF;
    SELECT kind INTO target_kind
    FROM (
        SELECT declaration.kind, declaration.object_name
        FROM pgreact_internal.api_declarations declaration
        WHERE declaration.state = 'DEPLOYED'
        UNION
        SELECT 'policy_set', set.set_name
        FROM pgreact_internal.policy_set_versions version
        JOIN pgreact_internal.policy_sets set USING (policy_set_id)
        WHERE version.state = 'DEPLOYED'
        UNION
        SELECT 'derived_relation', relation.relation_name
        FROM pgreact_internal.derived_relations relation
        JOIN pgreact_internal.derived_relation_versions version USING (relation_id)
        WHERE version.state = 'ACTIVE'
    ) targets WHERE object_name = target_name LIMIT 1;
    IF (root_kind = 'decision_result' AND target_kind <> 'decision_program')
       OR (root_kind = 'decision_work' AND target_kind <> 'decision_program')
       OR (root_kind = 'rule_work' AND target_kind <> 'rule') THEN
        RETURN pgreact_internal.m41_result(target_kind, target_name, NULL, 'unsupported', subject,
            cp, sampled_time, authoritative_frontier, NULL, nodes, edges, paths, boundaries,
            jsonb_build_array(pgreact_internal.m41_finding(
                'M41_UNSUPPORTED_ROOT', 'WARNING', target_name, 'root_kind',
                'the requested root kind does not match the deployed target kind',
                'Use decision roots for decisions and rule work roots for rules.')),
            limits, pgreact_internal.m41_cost(started_at, 0, 0, 0, 0, 0, 0, 0, 0), '{}');
    END IF;

    IF root_kind = 'decision_result' AND NOT EXISTS (
        SELECT 1
        FROM pgreact_internal.decision_programs program
        JOIN pgreact_internal.decision_program_versions version USING (program_id)
        JOIN pgreact_internal.decision_subject_state decision USING (program_id)
        WHERE program.program_name = target_name
          AND version.state = 'DEPLOYED'
          AND decision.subject_key = explain_subject_key
          AND decision.state = 'WINNER'
          AND decision.winner_candidate = result_key_numeric
    ) THEN
        RETURN pgreact_internal.m41_result(target_kind, target_name, NULL, 'unavailable', subject,
            cp, sampled_time, authoritative_frontier, NULL, nodes, edges, paths, boundaries,
            jsonb_build_array(pgreact_internal.m41_finding(
                'M41_ROOT_NOT_FOUND', 'WARNING', target_name, 'result_key',
                'the requested decision result is absent or no longer authoritative',
                'Use a current public decision result identity.')),
            limits, pgreact_internal.m41_cost(started_at, 1, 0, 0, 0, 0, 0, 0, 1), '{}');
    END IF;

    IF root_kind = 'decision_result' THEN
        fragment := pgreact_internal.m41_decision_fragment(
            target_name, explain_subject_key, result_key_numeric, NULL, sampled_time,
            depth_limit, fanout_limit, path_limit);
        SELECT version_no::text, encode(source_definition_digest, 'hex')
        INTO target_version, source_digest
        FROM pgreact_internal.decision_programs program
        JOIN pgreact_internal.decision_program_versions version USING (program_id)
        WHERE program.program_name = target_name AND version.state = 'DEPLOYED'
        ORDER BY version.valid_from DESC, version.version_no DESC LIMIT 1;
        root_id := format('decision_result:%s@%s:subject=%s:candidate=%s',
                          target_name, target_version, explain_subject_key, result_key_numeric);
        root := jsonb_build_object('kind', root_kind, 'identity', root_id,
            'target', target_name, 'version', target_version,
            'subject_key', explain_subject_key, 'result_key', result_key_numeric);
    ELSIF root_kind = 'decision_work' THEN
        SELECT work.*, state.version_id, state.generation, state.revision, state.winner_candidate,
               state.winner_result, state.state AS decision_state, version.version_no
        INTO work_row
        FROM pgreact_internal.decision_work work
        JOIN pgreact_internal.decision_programs program USING (program_id)
        JOIN pgreact_internal.decision_subject_state state
          USING (program_id, subject_key)
        JOIN pgreact_internal.decision_program_versions version
          ON version.version_id = state.version_id
        WHERE program.program_name = target_name
          AND work.subject_key = work_id::bigint;
        IF NOT FOUND OR work_row.generation <> generation
           OR work_row.revision <> explain_revision THEN
            RETURN pgreact_internal.m41_result(target_kind, target_name, NULL, 'unavailable', subject,
                cp, sampled_time, authoritative_frontier, NULL, nodes, edges, paths, boundaries,
                jsonb_build_array(pgreact_internal.m41_finding(
                    'M41_ROOT_NOT_FOUND', 'WARNING', target_name, 'work_id',
                    'the requested decision work identity is not retained',
                    'Use work_id, generation, and revision from pgreact.work evidence.')),
                limits, pgreact_internal.m41_cost(started_at, 1, 0, 0, 0, 0, 0, 0, 1), '{}');
        END IF;
        target_version := work_row.version_no::text;
        root_id := format('decision_work:%s@%s:subject=%s:generation=%s:revision=%s',
                          target_name, target_version, work_row.subject_key,
                          generation, explain_revision);
        root := jsonb_build_object('kind', root_kind, 'identity', root_id,
            'target', target_name, 'version', target_version,
            'subject_key', work_row.subject_key, 'work_id', work_id,
            'generation', generation, 'revision', explain_revision);
        nodes := jsonb_build_array(jsonb_build_object(
            'kind', 'decision_work', 'identity', root_id,
            'evidence', jsonb_build_object('state', work_row.state,
                'claimable', work_row.claimable, 'updated_at', work_row.updated_at,
                'subject_key', work_row.subject_key, 'generation', generation,
                'revision', explain_revision)));
        IF work_row.decision_state = 'WINNER' THEN
            fragment := pgreact_internal.m41_decision_fragment(
                target_name, work_row.subject_key, work_row.winner_candidate,
                root_id, sampled_time, depth_limit, fanout_limit, path_limit);
        ELSE
            fragment := jsonb_build_object('state', 'complete', 'nodes', '[]'::jsonb,
                'edges', '[]'::jsonb,
                'paths', jsonb_build_array(pgreact_internal.m41_path(
                    jsonb_build_array(root_id), '[]'::jsonb, 'complete')),
                'boundaries', '[]'::jsonb,
                'findings', '[]'::jsonb);
        END IF;
        SELECT version_no::text, encode(source_definition_digest, 'hex')
        INTO target_version, source_digest
        FROM pgreact_internal.decision_program_versions
        WHERE version_id = work_row.version_id;
    ELSE
        SELECT episode.episode_id, episode.rule_id, episode.rule_version_id,
               episode.activation_id, episode.activation_generation, episode.activation_revision,
               episode.state, event.event_kind, event.generation,
               event.transitioned_at, event.old_bindings, event.new_bindings,
               version.consequence_identity, version.source_definition_digest,
               rule.rule_name, version.source_view_name
        INTO work_row
        FROM pgreact_internal.agenda episode
        JOIN pgreact_internal.lifecycle_events event ON event.event_id = episode.event_id
        JOIN pgreact_internal.rule_versions version
          ON version.rule_version_id = episode.rule_version_id
        JOIN pgreact_internal.rules rule ON rule.rule_id = episode.rule_id
        WHERE rule.rule_name = target_name AND episode.episode_id::text = work_id;
        IF NOT FOUND OR work_row.generation <> generation OR work_row.event_kind <> event_kind
           OR (explain_revision IS NOT NULL AND NOT EXISTS (
               SELECT 1 FROM pgreact_internal.activation_state activation
               WHERE activation.rule_version_id = work_row.rule_version_id
                 AND activation.activation_id = work_row.activation_id
                 AND activation.revision = explain_revision)) THEN
            RETURN pgreact_internal.m41_result(target_kind, target_name, NULL, 'unavailable', subject,
                cp, sampled_time, authoritative_frontier, NULL, nodes, edges, paths, boundaries,
                jsonb_build_array(pgreact_internal.m41_finding(
                    'M41_ROOT_NOT_FOUND', 'WARNING', target_name, 'work_id',
                    'the requested rule work identity is not retained',
                    'Use work_id, generation, event_kind, and revision from public evidence.')),
                limits, pgreact_internal.m41_cost(started_at, 1, 0, 0, 0, 0, 0, 0, 1), '{}');
        END IF;
        target_version := '1';
        IF cp ? 'consequence_identity'
           AND cp ->> 'consequence_identity' IS DISTINCT FROM work_row.consequence_identity THEN
            RETURN pgreact_internal.m41_result(target_kind, target_name, target_version, 'unavailable', subject,
                cp, sampled_time, authoritative_frontier, NULL, nodes, edges, paths, boundaries,
                jsonb_build_array(pgreact_internal.m41_finding(
                    'M41_CHANGED_STATE', 'WARNING', target_name, 'consequence_identity',
                    'the requested consequence does not match the retained work',
                    'Retry with the public consequence identity.')),
                limits, pgreact_internal.m41_cost(started_at, 1, 0, 0, 0, 0, 0, 0, 1), '{}');
        END IF;
        SELECT a.revision INTO explain_revision
        FROM pgreact_internal.activation_state a
        WHERE a.rule_version_id = work_row.rule_version_id
          AND a.activation_id = work_row.activation_id
        ORDER BY a.revision DESC LIMIT 1;
        root_id := format('rule_work:%s@1:subject=%s:work_id=%s:generation=%s:revision=%s:event=%s',
                          target_name, explain_subject_key, work_id, generation, explain_revision, event_kind);
        root := jsonb_build_object('kind', root_kind, 'identity', root_id,
            'target', target_name, 'version', target_version,
            'subject_key', explain_subject_key, 'work_id', work_id,
            'generation', generation, 'revision', explain_revision,
            'consequence_identity', work_row.consequence_identity,
            'event_kind', event_kind);
        nodes := jsonb_build_array(
            jsonb_build_object('kind', 'rule_work', 'identity', root_id,
                'evidence', jsonb_build_object('work_id', work_id, 'state', work_row.state,
                    'generation', generation, 'revision', explain_revision)),
            jsonb_build_object('kind', 'lifecycle_event',
                'identity', format('lifecycle:%s@1:subject=%s:generation=%s:event=%s',
                    target_name, explain_subject_key, generation, event_kind),
                'evidence', jsonb_build_object('event_kind', event_kind,
                    'transitioned_at', work_row.transitioned_at,
                    'old_bindings', work_row.old_bindings, 'new_bindings', work_row.new_bindings)));
        root_id := root ->> 'identity';
        edge := pgreact_internal.m41_edge('work_lifecycle', root_id,
            nodes -> 1 ->> 'identity');
        edges := jsonb_build_array(edge);
        fragment := pgreact_internal.m41_rule_source_fragment(
            work_row.rule_version_id, explain_subject_key, nodes -> 1 ->> 'identity',
            work_row.activation_id, generation, explain_revision);
    END IF;
    nodes := pgreact_internal.m41_array_union(nodes, fragment -> 'nodes');
    edges := pgreact_internal.m41_array_union(edges, fragment -> 'edges');
    paths := pgreact_internal.m41_array_union(paths, fragment -> 'paths');
    boundaries := pgreact_internal.m41_array_union(boundaries, fragment -> 'boundaries');
    findings := pgreact_internal.m41_array_union(findings, fragment -> 'findings');
    state := fragment ->> 'state';
    IF jsonb_array_length(nodes) > node_limit THEN
        SELECT COALESCE(jsonb_agg(value ORDER BY ordinal) FILTER (WHERE ordinal <= node_limit), '[]'::jsonb)
        INTO nodes FROM jsonb_array_elements(nodes) WITH ORDINALITY item(value, ordinal);
        state := 'partial';
        findings := findings || jsonb_build_array(pgreact_internal.m41_finding(
            'M41_RESOURCE_LIMIT', 'WARNING', target_name, 'nodes',
            'the causal path reached the node limit', 'Increase node_limit only for a bounded workload.'));
    END IF;
    IF jsonb_array_length(edges) > edge_limit THEN
        SELECT COALESCE(jsonb_agg(value ORDER BY ordinal) FILTER (WHERE ordinal <= edge_limit), '[]'::jsonb)
        INTO edges FROM jsonb_array_elements(edges) WITH ORDINALITY item(value, ordinal);
        state := 'partial';
        findings := findings || jsonb_build_array(pgreact_internal.m41_finding(
            'M41_RESOURCE_LIMIT', 'WARNING', target_name, 'edges',
            'the causal path reached the edge limit', 'Increase edge_limit only for a bounded workload.'));
    END IF;
    IF jsonb_array_length(paths) > path_limit THEN
        SELECT COALESCE(jsonb_agg(value ORDER BY ordinal) FILTER (WHERE ordinal <= path_limit), '[]'::jsonb)
        INTO paths FROM jsonb_array_elements(paths) WITH ORDINALITY item(value, ordinal);
        state := 'partial';
        findings := findings || jsonb_build_array(pgreact_internal.m41_finding(
            'M41_RESOURCE_LIMIT', 'WARNING', target_name, 'paths',
            'the causal path reached the returned-path limit', 'Increase path_limit only for a bounded workload.'));
    END IF;
    nodes := pgreact_internal.m41_array_union(nodes, '[]'::jsonb);
    edges := pgreact_internal.m41_array_union(edges, '[]'::jsonb);
    paths := pgreact_internal.m41_array_union(paths, '[]'::jsonb);
    boundaries := pgreact_internal.m41_array_union(boundaries, '[]'::jsonb);
    findings := pgreact_internal.m41_array_union(findings, '[]'::jsonb);
    SELECT encode(declaration.declaration_digest, 'hex')
    INTO declaration_digest
    FROM pgreact_internal.api_declarations declaration
    WHERE declaration.object_name = target_name AND declaration.state = 'DEPLOYED'
    ORDER BY declaration.created_at DESC LIMIT 1;
    semantic_digest := pgreact_internal.m41_digest(jsonb_build_object(
        'root', root, 'nodes', nodes, 'edges', edges, 'paths', paths,
        'boundaries', boundaries, 'findings', findings, 'limits', limits));
    RETURN pgreact_internal.m41_result(
        target_kind, target_name, target_version, state, subject, cp, sampled_time,
        authoritative_frontier, root, nodes, edges, paths, boundaries, findings, limits,
        pgreact_internal.m41_cost(started_at, 1, jsonb_array_length(nodes),
            jsonb_array_length(edges), jsonb_array_length(paths),
            (SELECT count(*) FROM jsonb_array_elements(nodes) item WHERE item.value ->> 'kind' = 'derived_support'),
            depth_limit, fanout_limit, jsonb_array_length(boundaries)),
        jsonb_build_object('semantic', semantic_digest,
            'declaration', COALESCE(declaration_digest, source_digest),
            'source_definition', source_digest,
            'authoritative_frontier', authoritative_frontier));
END
$m41$;

CREATE OR REPLACE FUNCTION pgreact.explain(
    name text,
    subject jsonb DEFAULT NULL,
    options jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m41$
    SELECT CASE WHEN pgreact_internal.m41_requested($3)
        THEN pgreact_internal.m41_explain($1, $2, $3)
        WHEN pgreact_internal.m40_requested($3)
        THEN pgreact_internal.m40_explain($1, $2, $3)
        ELSE pgreact_internal.m32_result(pgreact_api.explain_m31(
            pgreact_internal.m32_target($1), $2,
            pgreact_internal.m40_strip_options(pgreact_internal.m41_strip_options($3))))
    END
$m41$;

REVOKE ALL ON FUNCTION pgreact_internal.m41_finding(text, text, text, text, text, text, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact_internal.m41_finding_registry() FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact_internal.m41_requested(jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact_internal.m41_strip_options(jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact_internal.m41_digest(jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact_internal.m41_array_union(jsonb, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact_internal.m41_edge(text, text, text, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact_internal.m41_path(jsonb, jsonb, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact_internal.m41_cost(timestamptz, bigint, bigint, bigint, bigint, bigint, bigint, bigint, bigint) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact_internal.m41_result(text, text, text, text, jsonb, jsonb, timestamptz, timestamptz, jsonb, jsonb, jsonb, jsonb, jsonb, jsonb, jsonb, jsonb, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact_internal.m41_source_evidence(oid, text, name, bigint) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact_internal.m41_rule_source_fragment(uuid, bigint, text, uuid, bigint, bigint) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact_internal.m41_derived_fragment(uuid, bigint, text, integer, integer, integer, integer, text[]) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact_internal.m41_member_fragment(text, text, text, bigint, text, timestamptz, integer, integer, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact_internal.m41_policy_fragment(uuid, bigint, text, timestamptz, integer, integer, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact_internal.m41_decision_fragment(text, bigint, bigint, text, timestamptz, integer, integer, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact_internal.m41_explain(text, jsonb, jsonb) FROM PUBLIC;

COMMENT ON FUNCTION pgreact.explain(text, jsonb, jsonb) IS
    'M41 bounded causal paths with opt-in causal_path evidence; legacy and why-not output stay unchanged';
COMMENT ON EXTENSION pg_react IS
    'M41 bounded end-to-end causal paths over installed public evidence';
