-- M27 decision coverage and conflict analysis.

CREATE TABLE pgreact_internal.decision_analyses (
    analysis_id uuid PRIMARY KEY,
    analysis_name text NOT NULL,
    program_id uuid NOT NULL REFERENCES pgreact_internal.decision_programs ON DELETE CASCADE,
    current_version_id uuid NOT NULL REFERENCES pgreact_internal.decision_program_versions,
    proposed_version_id uuid NOT NULL REFERENCES pgreact_internal.decision_program_versions,
    population_relation_oid oid NOT NULL,
    population_relation_name text NOT NULL,
    population_key_column name NOT NULL,
    candidate_catalog_oid oid NOT NULL,
    candidate_catalog_name text NOT NULL,
    catalog_candidate_column name NOT NULL,
    catalog_default_column name NOT NULL,
    require_default boolean NOT NULL,
    exclusive boolean NOT NULL,
    max_abs_distribution_delta bigint NOT NULL CHECK (max_abs_distribution_delta >= 0),
    max_relative_distribution_delta numeric
        CHECK (max_relative_distribution_delta IS NULL OR max_relative_distribution_delta >= 0),
    evidence_limit integer NOT NULL CHECK (evidence_limit > 0),
    population_limit integer NOT NULL CHECK (population_limit > 0),
    owner_oid oid NOT NULL,
    state text NOT NULL DEFAULT 'ACTIVE' CHECK (state IN ('ACTIVE', 'REMOVED')),
    last_frontier timestamptz,
    last_population_fingerprint bytea,
    last_catalog_fingerprint bytea,
    last_current_fingerprint bytea,
    last_proposed_fingerprint bytea,
    last_report jsonb,
    analyzed_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    UNIQUE (program_id, analysis_name)
);

CREATE INDEX decision_analysis_program_idx
    ON pgreact_internal.decision_analyses (program_id, proposed_version_id, state);

CREATE TABLE pgreact_internal.decision_analysis_history (
    event_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    analysis_id uuid NOT NULL REFERENCES pgreact_internal.decision_analyses ON DELETE CASCADE,
    event_kind text NOT NULL CHECK (event_kind IN ('ANALYZED', 'ADMITTED', 'REMOVED')),
    state text NOT NULL,
    frontier timestamptz,
    report jsonb NOT NULL DEFAULT '{}'::jsonb,
    occurred_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE FUNCTION pgreact_internal.m27_relation_fingerprint(source_relid oid)
RETURNS bytea
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m27$
DECLARE result bytea;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_class WHERE oid = source_relid) THEN
        RETURN NULL;
    END IF;
    EXECUTE format(
        'SELECT sha256(convert_to(COALESCE((SELECT string_agg(to_jsonb(r)::text, E''\n'' '
        'ORDER BY to_jsonb(r)::text) FROM %s r), ''''), ''UTF8''))',
        source_relid::regclass)
    INTO result;
    RETURN sha256(pgreact_internal.source_row_signature(source_relid) || result);
END
$m27$;

CREATE FUNCTION pgreact_internal.m27_version_fingerprint(target_version_id uuid)
RETURNS bytea
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m27$
DECLARE version_row record;
    result bytea;
BEGIN
    SELECT * INTO STRICT version_row
    FROM pgreact_internal.decision_program_versions
    WHERE version_id = target_version_id;
    EXECUTE format(
        'SELECT sha256(convert_to(COALESCE((SELECT string_agg(to_jsonb(r)::text, E''\n'' '
        'ORDER BY to_jsonb(r)::text) FROM %s r), ''''), ''UTF8''))',
        version_row.candidate_relation_oid::regclass)
    INTO result;
    RETURN sha256(version_row.source_signature || version_row.source_definition_digest || result);
END
$m27$;

CREATE FUNCTION pgreact_internal.validate_decision_analysis(
    target_program_name text,
    target_current_version uuid,
    target_proposed_version uuid,
    target_population regclass,
    target_population_key name,
    target_catalog regclass,
    target_catalog_key name,
    target_catalog_default name,
    target_require_default boolean DEFAULT true,
    target_exclusive boolean DEFAULT true,
    target_max_abs_delta bigint DEFAULT 0,
    target_max_relative_delta numeric DEFAULT NULL,
    target_evidence_limit integer DEFAULT 25,
    target_population_limit integer DEFAULT 100000
)
RETURNS TABLE(
    contract_version integer,
    code text,
    severity text,
    object_identity text,
    message text,
    hint text,
    details jsonb
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m27$
DECLARE relation_row record;
    column_row record;
    version_row record;
    duplicate_count bigint;
    null_count bigint;
    row_count bigint;
    invalid boolean := false;
BEGIN
    IF target_program_name IS NULL OR btrim(target_program_name) = '' THEN
        RETURN QUERY SELECT 15, 'M27_PROGRAM_NAME', 'ERROR', '<unnamed>',
            'decision analysis program name must not be empty',
            'Choose one stable decision-program identity.', '{}'::jsonb;
        RETURN;
    END IF;
    IF target_evidence_limit IS NULL OR target_evidence_limit < 1
       OR target_population_limit IS NULL OR target_population_limit < 1 THEN
        RETURN QUERY SELECT 15, 'M27_LIMIT', 'ERROR', target_program_name,
            'evidence and population limits must be positive',
            'Choose bounded positive limits before creating the analysis.', '{}'::jsonb;
        RETURN;
    END IF;
    IF target_max_abs_delta IS NULL OR target_max_abs_delta < 0
       OR (target_max_relative_delta IS NOT NULL AND target_max_relative_delta < 0) THEN
        RETURN QUERY SELECT 15, 'M27_DISTRIBUTION_LIMIT', 'ERROR', target_program_name,
            'winner-distribution limits must be non-negative',
            'Use zero for an exact no-change limit or a non-negative tolerance.', '{}'::jsonb;
        RETURN;
    END IF;
    SELECT p.program_id, p.owner_oid, v.version_id
    INTO version_row
    FROM pgreact_internal.decision_programs p
    JOIN pgreact_internal.decision_program_versions v ON v.program_id = p.program_id
    WHERE p.program_name = target_program_name
      AND v.version_id IN (target_current_version, target_proposed_version)
      AND p.state <> 'REMOVED';
    IF NOT FOUND THEN
        RETURN QUERY SELECT 15, 'M27_VERSION', 'ERROR', target_program_name,
            'the decision program or one declared version was not found',
            'Use two versions belonging to the named decision program.', '{}'::jsonb;
        RETURN;
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM pgreact_internal.decision_program_versions v
        WHERE v.version_id = target_current_version AND v.program_id = version_row.program_id)
       OR NOT EXISTS (
        SELECT 1 FROM pgreact_internal.decision_program_versions v
        WHERE v.version_id = target_proposed_version AND v.program_id = version_row.program_id) THEN
        RETURN QUERY SELECT 15, 'M27_VERSION_PROGRAM', 'ERROR', target_program_name,
            'current and proposed versions must belong to the same decision program',
            'Choose the current and proposed versions from one program.', '{}'::jsonb;
        RETURN;
    END IF;
    SELECT c.relkind, c.relowner, c.relrowsecurity
    INTO relation_row
    FROM pg_class c WHERE c.oid = target_population;
    IF NOT FOUND OR relation_row.relkind NOT IN ('r', 'p', 'v', 'm') THEN
        RETURN QUERY SELECT 15, 'M27_POPULATION_RELATION', 'ERROR', target_population::text,
            'population source must be a table, partitioned table, view, or materialized view',
            'Declare one finite PostgreSQL population relation.', '{}'::jsonb;
        RETURN;
    END IF;
    IF relation_row.relrowsecurity THEN
        RETURN QUERY SELECT 15, 'M27_POPULATION_RLS', 'ERROR', target_population::text,
            'row-level security is not supported for the population source',
            'Use ordinary grants on a source without row-level security.', '{}'::jsonb;
        invalid := true;
    END IF;
    IF NOT pg_has_role(session_user, relation_row.relowner, 'USAGE')
       AND NOT pgreact_internal.is_operator_admin() THEN
        RETURN QUERY SELECT 15, 'M27_POPULATION_OWNER', 'ERROR', target_population::text,
            'the population source must be owned by the author',
            'Use the relation owner or configured operator role.', '{}'::jsonb;
        invalid := true;
    END IF;
    SELECT a.atttypid, a.attnotnull, a.attgenerated
    INTO column_row FROM pg_attribute a
    WHERE a.attrelid = target_population AND a.attname = target_population_key
      AND a.attnum > 0 AND NOT a.attisdropped;
    IF NOT FOUND OR column_row.atttypid <> 'int8'::regtype
       OR (relation_row.relkind IN ('r', 'p') AND NOT column_row.attnotnull)
       OR column_row.attgenerated <> '' THEN
        RETURN QUERY SELECT 15, 'M27_POPULATION_KEY', 'ERROR', target_population::text,
            'population key must be a stored NOT NULL bigint column',
            'Declare one finite population key with type bigint.', '{}'::jsonb;
        invalid := true;
    END IF;
    IF NOT invalid THEN
        EXECUTE format('SELECT count(*) FROM %s r WHERE r.%I IS NULL',
                       target_population::text, target_population_key) INTO null_count;
        EXECUTE format('SELECT count(*) - count(DISTINCT r.%I) FROM %s r',
                       target_population_key, target_population::text) INTO duplicate_count;
        EXECUTE format('SELECT count(*) FROM %s', target_population::text) INTO row_count;
        IF null_count > 0 OR duplicate_count > 0 THEN
            RETURN QUERY SELECT 15, 'M27_POPULATION_UNIQUE', 'ERROR', target_population::text,
                'population keys must be non-null and unique',
                'Provide one row for each declared population key.',
                jsonb_build_object('null_keys', null_count, 'duplicate_rows', duplicate_count);
            invalid := true;
        ELSIF row_count > target_population_limit THEN
            RETURN QUERY SELECT 15, 'M27_POPULATION_LIMIT', 'ERROR', target_population::text,
                'population exceeds the declared analysis limit',
                'Reduce the population or raise the bounded admission limit.',
                jsonb_build_object('rows', row_count, 'limit', target_population_limit);
            invalid := true;
        END IF;
    END IF;
    SELECT c.relkind, c.relowner, c.relrowsecurity
    INTO relation_row FROM pg_class c WHERE c.oid = target_catalog;
    IF NOT FOUND OR relation_row.relkind NOT IN ('r', 'p', 'v', 'm') THEN
        RETURN QUERY SELECT 15, 'M27_CATALOG_RELATION', 'ERROR', target_catalog::text,
            'candidate catalog must be a table, partitioned table, view, or materialized view',
            'Declare one finite candidate catalog relation.', '{}'::jsonb;
        RETURN;
    END IF;
    IF relation_row.relrowsecurity THEN
        RETURN QUERY SELECT 15, 'M27_CATALOG_RLS', 'ERROR', target_catalog::text,
            'row-level security is not supported for the candidate catalog',
            'Use ordinary grants on a catalog without row-level security.', '{}'::jsonb;
        invalid := true;
    END IF;
    IF NOT pg_has_role(session_user, relation_row.relowner, 'USAGE')
       AND NOT pgreact_internal.is_operator_admin() THEN
        RETURN QUERY SELECT 15, 'M27_CATALOG_OWNER', 'ERROR', target_catalog::text,
            'the candidate catalog must be owned by the author',
            'Use the relation owner or configured operator role.', '{}'::jsonb;
        invalid := true;
    END IF;
    IF target_catalog_key = target_catalog_default THEN
        RETURN QUERY SELECT 15, 'M27_CATALOG_COLUMNS', 'ERROR', target_catalog::text,
            'candidate and required-default columns must be distinct',
            'Declare two separate catalog columns.', '{}'::jsonb;
        invalid := true;
    END IF;
    SELECT a.atttypid, a.attnotnull, a.attgenerated INTO column_row
    FROM pg_attribute a WHERE a.attrelid = target_catalog AND a.attname = target_catalog_key
      AND a.attnum > 0 AND NOT a.attisdropped;
    IF NOT FOUND OR column_row.atttypid <> 'int8'::regtype
       OR (relation_row.relkind IN ('r', 'p') AND NOT column_row.attnotnull)
       OR column_row.attgenerated <> '' THEN
        RETURN QUERY SELECT 15, 'M27_CATALOG_KEY', 'ERROR', target_catalog::text,
            'catalog candidate identity must be a stored NOT NULL bigint column',
            'Declare one bigint identity for each catalog candidate.', '{}'::jsonb;
        invalid := true;
    END IF;
    SELECT a.atttypid, a.attnotnull, a.attgenerated INTO column_row
    FROM pg_attribute a WHERE a.attrelid = target_catalog AND a.attname = target_catalog_default
      AND a.attnum > 0 AND NOT a.attisdropped;
    IF NOT FOUND OR column_row.atttypid <> 'bool'::regtype
       OR (relation_row.relkind IN ('r', 'p') AND NOT column_row.attnotnull)
       OR column_row.attgenerated <> '' THEN
        RETURN QUERY SELECT 15, 'M27_DEFAULT_COLUMN', 'ERROR', target_catalog::text,
            'required-default must be a stored NOT NULL boolean column',
            'Mark catalog candidates with true or false explicitly.', '{}'::jsonb;
        invalid := true;
    END IF;
    IF invalid THEN RETURN; END IF;
    EXECUTE format('SELECT count(*) - count(DISTINCT r.%I) FROM %s r',
                   target_catalog_key, target_catalog::text) INTO duplicate_count;
    EXECUTE format('SELECT count(*) FROM %s r WHERE r.%I IS NULL OR r.%I IS NULL',
                   target_catalog::text, target_catalog_key, target_catalog_default) INTO null_count;
    IF duplicate_count > 0 OR null_count > 0 THEN
        RETURN QUERY SELECT 15, 'M27_CATALOG_UNIQUE', 'ERROR', target_catalog::text,
            'candidate catalog identities and required-default values must be unique and non-null',
            'Provide one row per candidate identity with an explicit default flag.',
            jsonb_build_object('duplicate_rows', duplicate_count, 'invalid_rows', null_count);
        RETURN;
    END IF;
    EXECUTE format('SELECT count(*) FROM %s', target_catalog::text) INTO row_count;
    IF row_count > target_population_limit THEN
        RETURN QUERY SELECT 15, 'M27_CATALOG_LIMIT', 'ERROR', target_catalog::text,
            'candidate catalog exceeds the declared analysis limit',
            'Reduce the catalog or raise the bounded admission limit.',
            jsonb_build_object('rows', row_count, 'limit', target_population_limit);
        RETURN;
    END IF;
    RETURN QUERY SELECT 15, 'OK', 'INFO', target_program_name,
        'decision analysis declaration is valid',
        'Analyze the complete frontier before admitting the proposed version.',
        jsonb_build_object('population', target_population::text,
                           'candidate_catalog', target_catalog::text,
                           'exclusive', target_exclusive,
                           'required_default', target_require_default,
                           'max_abs_distribution_delta', target_max_abs_delta,
                           'max_relative_distribution_delta', target_max_relative_delta,
                           'evidence_limit', target_evidence_limit,
                           'population_limit', target_population_limit);
END
$m27$;

CREATE FUNCTION pgreact_api.validate_decision_analysis(
    program_name text, current_version_id uuid, proposed_version_id uuid,
    population_relation regclass, population_key_column name,
    candidate_catalog regclass, catalog_candidate_column name,
    catalog_default_column name, require_default boolean DEFAULT true,
    exclusive boolean DEFAULT true, max_abs_delta bigint DEFAULT 0,
    max_relative_delta numeric DEFAULT NULL, evidence_limit integer DEFAULT 25,
    population_limit integer DEFAULT 100000)
RETURNS TABLE(contract_version integer, code text, severity text,
              object_identity text, message text, hint text, details jsonb)
LANGUAGE SQL SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $m27$
    SELECT * FROM pgreact_internal.validate_decision_analysis(
        $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14)
$m27$;

CREATE FUNCTION pgreact_api.author_decision_analysis(
    analysis_name text, program_name text, current_version_id uuid,
    proposed_version_id uuid, population_relation regclass,
    population_key_column name, candidate_catalog regclass,
    catalog_candidate_column name, catalog_default_column name,
    require_default boolean DEFAULT true, exclusive boolean DEFAULT true,
    max_abs_delta bigint DEFAULT 0, max_relative_delta numeric DEFAULT NULL,
    evidence_limit integer DEFAULT 25, population_limit integer DEFAULT 100000)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $m27$
DECLARE diagnostic record;
    target_program_id uuid;
    analysis_id uuid := gen_random_uuid();
BEGIN
    IF analysis_name IS NULL OR btrim(analysis_name) = '' THEN
        RAISE EXCEPTION 'M27_ANALYSIS_NAME: analysis name must not be empty';
    END IF;
    SELECT * INTO diagnostic
    FROM pgreact_internal.validate_decision_analysis(
        program_name, current_version_id, proposed_version_id, population_relation,
        population_key_column, candidate_catalog, catalog_candidate_column,
        catalog_default_column, require_default, exclusive, max_abs_delta,
        max_relative_delta, evidence_limit, population_limit)
    WHERE severity = 'ERROR' ORDER BY code LIMIT 1;
    IF FOUND THEN RAISE EXCEPTION 'M27_VALIDATION:%: %', diagnostic.code, diagnostic.message; END IF;
    SELECT p.program_id INTO STRICT target_program_id
    FROM pgreact_internal.decision_programs p WHERE p.program_name = author_decision_analysis.program_name;
    IF NOT pg_has_role(session_user,
                       (SELECT owner_oid FROM pgreact_internal.decision_programs WHERE program_id = target_program_id),
                       'USAGE') AND NOT pgreact_internal.is_operator_admin() THEN
        RAISE EXCEPTION 'M27_OWNER: only the decision program owner or operator may create an analysis';
    END IF;
    IF EXISTS (SELECT 1 FROM pgreact_internal.decision_analyses
               WHERE decision_analyses.program_id = target_program_id
                 AND decision_analyses.state <> 'REMOVED'
                 AND decision_analyses.proposed_version_id = author_decision_analysis.proposed_version_id) THEN
        RAISE EXCEPTION 'M27_ANALYSIS_EXISTS: an active analysis already covers this proposed version';
    END IF;
    INSERT INTO pgreact_internal.decision_analyses(
        analysis_id, analysis_name, program_id, current_version_id, proposed_version_id,
        population_relation_oid, population_relation_name, population_key_column,
        candidate_catalog_oid, candidate_catalog_name, catalog_candidate_column,
        catalog_default_column, require_default, exclusive, max_abs_distribution_delta,
        max_relative_distribution_delta, evidence_limit, population_limit, owner_oid)
    VALUES (analysis_id, author_decision_analysis.analysis_name, target_program_id, current_version_id, proposed_version_id,
            population_relation, population_relation::text, population_key_column,
            candidate_catalog, candidate_catalog::text, catalog_candidate_column,
            catalog_default_column, require_default, exclusive, max_abs_delta,
            max_relative_delta, evidence_limit, population_limit, session_user::regrole::oid);
    RETURN analysis_id;
END
$m27$;

CREATE FUNCTION pgreact_internal.analyze_decision_analysis(target_analysis_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $m27$
DECLARE analysis_row pgreact_internal.decision_analyses%ROWTYPE;
    program_row pgreact_internal.decision_programs%ROWTYPE;
    frontier timestamptz;
    population_fingerprint bytea;
    catalog_fingerprint bytea;
    current_fingerprint bytea;
    proposed_fingerprint bytea;
    report jsonb;
    findings jsonb;
    distribution jsonb;
    state text;
    blocker_count bigint;
BEGIN
    SELECT * INTO STRICT analysis_row FROM pgreact_internal.decision_analyses
    WHERE decision_analyses.analysis_id = target_analysis_id
      AND decision_analyses.state <> 'REMOVED' FOR UPDATE;
    SELECT * INTO STRICT program_row FROM pgreact_internal.decision_programs
    WHERE decision_programs.program_id = analysis_row.program_id
      AND decision_programs.state <> 'REMOVED';
    IF NOT pg_has_role(session_user, program_row.owner_oid, 'USAGE')
       AND NOT pgreact_internal.is_operator_admin() THEN
        RAISE EXCEPTION 'M27_OWNER: only the decision program owner or operator may analyze this declaration';
    END IF;
    SELECT cf.frontier INTO frontier FROM pgreact_internal.clock_frontier cf;
    population_fingerprint := pgreact_internal.m27_relation_fingerprint(analysis_row.population_relation_oid);
    catalog_fingerprint := pgreact_internal.m27_relation_fingerprint(analysis_row.candidate_catalog_oid);
    current_fingerprint := pgreact_internal.m27_version_fingerprint(analysis_row.current_version_id);
    proposed_fingerprint := pgreact_internal.m27_version_fingerprint(analysis_row.proposed_version_id);
    DROP TABLE IF EXISTS pg_temp.m27_population;
    DROP TABLE IF EXISTS pg_temp.m27_catalog;
    DROP TABLE IF EXISTS pg_temp.m27_current_candidates;
    DROP TABLE IF EXISTS pg_temp.m27_proposed_candidates;
    DROP TABLE IF EXISTS pg_temp.m27_findings;
    DROP TABLE IF EXISTS pg_temp.m27_distribution;
    CREATE TEMP TABLE pg_temp.m27_population(subject_key bigint PRIMARY KEY) ON COMMIT DROP;
    CREATE TEMP TABLE pg_temp.m27_catalog(candidate_key bigint PRIMARY KEY, required_default boolean NOT NULL) ON COMMIT DROP;
    CREATE TEMP TABLE pg_temp.m27_findings(
        code text NOT NULL, severity text NOT NULL, blocker boolean NOT NULL,
        affected_count bigint NOT NULL, evidence jsonb NOT NULL,
        truncated boolean NOT NULL, message text NOT NULL, hint text NOT NULL) ON COMMIT DROP;
    EXECUTE format('INSERT INTO pg_temp.m27_population SELECT r.%I FROM %s r',
                   analysis_row.population_key_column, analysis_row.population_relation_oid::regclass);
    EXECUTE format('INSERT INTO pg_temp.m27_catalog SELECT r.%I, r.%I FROM %s r',
                   analysis_row.catalog_candidate_column, analysis_row.catalog_default_column,
                   analysis_row.candidate_catalog_oid::regclass);
    PERFORM pgreact_internal.load_decision_candidates(analysis_row.current_version_id);
    CREATE TEMP TABLE pg_temp.m27_current_candidates ON COMMIT DROP AS
        SELECT subject_key, candidate_key, priority FROM pg_temp.m26_decision_candidates;
    PERFORM pgreact_internal.load_decision_candidates(analysis_row.proposed_version_id);
    CREATE TEMP TABLE pg_temp.m27_proposed_candidates ON COMMIT DROP AS
        SELECT subject_key, candidate_key, priority FROM pg_temp.m26_decision_candidates;
    INSERT INTO pg_temp.m27_findings
    SELECT 'M27_MISSING_REQUIRED_DEFAULT', 'ERROR', true, 1,
           COALESCE((SELECT jsonb_agg(jsonb_build_object('candidate', candidate_key) ORDER BY candidate_key)
                     FROM pg_temp.m27_catalog WHERE required_default), '[]'::jsonb), false,
           'the candidate catalog has no required default',
           'Mark one catalog candidate as the required default or disable that requirement.'
    WHERE analysis_row.require_default
      AND NOT EXISTS (SELECT 1 FROM pg_temp.m27_catalog WHERE required_default);
    INSERT INTO pg_temp.m27_findings
    SELECT 'M27_UNCOVERED_POPULATION', 'ERROR', true, count(*),
           COALESCE(jsonb_agg(jsonb_build_object('subject', subject_key) ORDER BY subject_key)
                    FILTER (WHERE evidence_order <= analysis_row.evidence_limit), '[]'::jsonb),
           count(*) > analysis_row.evidence_limit,
           'declared population subjects have no proposed candidate',
           'Add candidates covering every required population key or change the population.'
    FROM (
        SELECT p.subject_key, row_number() OVER (ORDER BY p.subject_key) AS evidence_order
        FROM pg_temp.m27_population p
        WHERE NOT EXISTS (SELECT 1 FROM pg_temp.m27_proposed_candidates c
                          WHERE c.subject_key = p.subject_key)
    ) uncovered
    HAVING count(*) > 0;
    INSERT INTO pg_temp.m27_findings
    SELECT 'M27_UNREACHABLE_CANDIDATE', 'ERROR', true, count(*),
           COALESCE(jsonb_agg(jsonb_build_object('candidate', candidate_key) ORDER BY candidate_key)
                    FILTER (WHERE evidence_order <= analysis_row.evidence_limit), '[]'::jsonb),
           count(*) > analysis_row.evidence_limit,
           'catalog candidates produce no proposed candidate',
           'Remove unreachable catalog rows or make the candidate reachable in the proposed relation.'
    FROM (
        SELECT c.candidate_key, row_number() OVER (ORDER BY c.candidate_key) AS evidence_order
        FROM pg_temp.m27_catalog c
        WHERE NOT EXISTS (SELECT 1 FROM pg_temp.m27_proposed_candidates p
                          WHERE p.candidate_key = c.candidate_key)
    ) unreachable
    HAVING count(*) > 0;
    INSERT INTO pg_temp.m27_findings
    SELECT 'M27_FORBIDDEN_OVERLAP', 'ERROR', true, count(*),
           COALESCE(jsonb_agg(jsonb_build_object(
               'subject', subject_key, 'candidates', candidates) ORDER BY subject_key)
                    FILTER (WHERE evidence_order <= analysis_row.evidence_limit), '[]'::jsonb),
           count(*) > analysis_row.evidence_limit,
           'a subject has more than one proposed candidate under an exclusive requirement',
           'Remove the overlap or declare a non-exclusive analysis.'
    FROM (
        SELECT p.subject_key,
               jsonb_agg(p.candidate_key ORDER BY p.candidate_key) AS candidates,
               row_number() OVER (ORDER BY p.subject_key) AS evidence_order
        FROM pg_temp.m27_proposed_candidates p
        GROUP BY p.subject_key HAVING analysis_row.exclusive AND count(*) > 1
    ) overlap_rows
    HAVING count(*) > 0;
    INSERT INTO pg_temp.m27_findings
    SELECT 'M27_TIED_BEST_CANDIDATE', 'ERROR', true, count(*),
           COALESCE(jsonb_agg(jsonb_build_object(
               'subject', subject_key, 'priority', top_priority,
               'candidates', candidates) ORDER BY subject_key)
                    FILTER (WHERE evidence_order <= analysis_row.evidence_limit), '[]'::jsonb),
           count(*) > analysis_row.evidence_limit,
           'a subject has tied candidates at the best priority',
           'Give the candidates distinct priorities or remove one of the tied candidates.'
    FROM (
        SELECT p.subject_key, min(p.priority) AS top_priority,
               jsonb_agg(p.candidate_key ORDER BY p.candidate_key) AS candidates,
               row_number() OVER (ORDER BY p.subject_key) AS evidence_order
        FROM pg_temp.m27_proposed_candidates p
        GROUP BY p.subject_key
        HAVING count(*) FILTER (WHERE p.priority = (SELECT min(q.priority)
               FROM pg_temp.m27_proposed_candidates q WHERE q.subject_key = p.subject_key)) > 1
    ) tied
    HAVING count(*) > 0;
    CREATE TEMP TABLE pg_temp.m27_distribution ON COMMIT DROP AS
    WITH current_top AS (
        SELECT subject_key, min(priority) AS priority, count(*) FILTER (WHERE priority =
            (SELECT min(q.priority) FROM pg_temp.m27_current_candidates q
             WHERE q.subject_key = c.subject_key)) AS top_count
        FROM pg_temp.m27_current_candidates c GROUP BY subject_key
    ), proposed_top AS (
        SELECT subject_key, min(priority) AS priority, count(*) FILTER (WHERE priority =
            (SELECT min(q.priority) FROM pg_temp.m27_proposed_candidates q
             WHERE q.subject_key = c.subject_key)) AS top_count
        FROM pg_temp.m27_proposed_candidates c GROUP BY subject_key
    ), current_winners AS (
        SELECT c.candidate_key, count(*)::bigint AS winner_count
        FROM pg_temp.m27_current_candidates c JOIN current_top t USING (subject_key)
        WHERE t.top_count = 1 AND c.priority = t.priority GROUP BY c.candidate_key
    ), proposed_winners AS (
        SELECT c.candidate_key, count(*)::bigint AS winner_count
        FROM pg_temp.m27_proposed_candidates c JOIN proposed_top t USING (subject_key)
        WHERE t.top_count = 1 AND c.priority = t.priority GROUP BY c.candidate_key
    ), keys AS (
        SELECT candidate_key FROM pg_temp.m27_catalog
        UNION SELECT candidate_key FROM pg_temp.m27_current_candidates
        UNION SELECT candidate_key FROM pg_temp.m27_proposed_candidates
    )
    SELECT k.candidate_key, COALESCE(c.winner_count, 0)::bigint AS current_count,
           COALESCE(p.winner_count, 0)::bigint AS proposed_count
    FROM keys k LEFT JOIN current_winners c USING (candidate_key)
                LEFT JOIN proposed_winners p USING (candidate_key);
    INSERT INTO pg_temp.m27_findings
    SELECT 'M27_WINNER_DISTRIBUTION', 'ERROR', true, count(*),
           COALESCE(jsonb_agg(jsonb_build_object(
               'candidate', candidate_key, 'current', current_count,
               'proposed', proposed_count, 'delta', proposed_count - current_count)
               ORDER BY candidate_key) FILTER (WHERE evidence_order <= analysis_row.evidence_limit), '[]'::jsonb),
           count(*) > analysis_row.evidence_limit,
           'winner distribution exceeds a configured materiality limit',
           'Adjust the proposed candidates or review the configured absolute and relative limits.'
    FROM (
        SELECT d.*, row_number() OVER (ORDER BY d.candidate_key) AS evidence_order
        FROM pg_temp.m27_distribution d
        WHERE abs(d.proposed_count - d.current_count) > analysis_row.max_abs_distribution_delta
           OR (analysis_row.max_relative_distribution_delta IS NOT NULL AND
               CASE WHEN d.current_count = 0 THEN d.proposed_count > 0
                    ELSE abs(d.proposed_count - d.current_count)::numeric / d.current_count
                         > analysis_row.max_relative_distribution_delta END)
    ) distribution_over_limit
    HAVING count(*) > 0;
    SELECT count(*) FILTER (WHERE blocker),
           COALESCE(jsonb_agg(jsonb_build_object(
               'code', code, 'severity', severity, 'blocker', blocker,
               'affected_count', affected_count, 'evidence', evidence,
               'truncated', truncated, 'message', message, 'hint', hint)
               ORDER BY code), '[]'::jsonb)
    INTO blocker_count, findings FROM pg_temp.m27_findings;
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'candidate', candidate_key, 'current', current_count,
               'proposed', proposed_count, 'delta', proposed_count - current_count)
               ORDER BY candidate_key), '[]'::jsonb)
    INTO distribution FROM pg_temp.m27_distribution;
    state := CASE WHEN blocker_count > 0 THEN 'BLOCKED' ELSE 'PASS' END;
    report := jsonb_build_object(
        'contract_version', 15, 'analysis_id', analysis_row.analysis_id,
        'program', program_row.program_name,
        'current_version_id', analysis_row.current_version_id,
        'proposed_version_id', analysis_row.proposed_version_id,
        'state', state, 'frontier', frontier,
        'fingerprints', jsonb_build_object(
            'population', encode(population_fingerprint, 'hex'),
            'candidate_catalog', encode(catalog_fingerprint, 'hex'),
            'current', encode(current_fingerprint, 'hex'),
            'proposed', encode(proposed_fingerprint, 'hex')),
        'requirements', jsonb_build_object(
            'required_default', analysis_row.require_default,
            'exclusive', analysis_row.exclusive,
            'max_abs_distribution_delta', analysis_row.max_abs_distribution_delta,
            'max_relative_distribution_delta', analysis_row.max_relative_distribution_delta),
        'findings', findings, 'blocker_count', blocker_count,
        'distribution', distribution,
        'support', jsonb_build_object(
            'population_rows', (SELECT count(*) FROM pg_temp.m27_population),
            'catalog_candidates', (SELECT count(*) FROM pg_temp.m27_catalog),
            'current_candidates', (SELECT count(*) FROM pg_temp.m27_current_candidates),
            'proposed_candidates', (SELECT count(*) FROM pg_temp.m27_proposed_candidates)),
        'provenance', jsonb_build_object(
            'complete_frontier', true, 'side_effect_free', true,
            'predicate_text_interpreted', false),
        'diagnostics', '[]'::jsonb,
        'authorization', jsonb_build_object('owner', pg_get_userbyid(program_row.owner_oid)),
        'remediation', CASE WHEN state = 'PASS'
            THEN 'The proposed version may be admitted if fingerprints remain unchanged.'
            ELSE 'Resolve every blocking finding, analyze again, then admit the proposed version.' END);
    UPDATE pgreact_internal.decision_analyses
    SET last_frontier = frontier, last_population_fingerprint = population_fingerprint,
        last_catalog_fingerprint = catalog_fingerprint, last_current_fingerprint = current_fingerprint,
        last_proposed_fingerprint = proposed_fingerprint, last_report = report,
        analyzed_at = clock_timestamp()
    WHERE analysis_id = target_analysis_id;
    INSERT INTO pgreact_internal.decision_analysis_history(analysis_id, event_kind, state, frontier, report)
    VALUES (target_analysis_id, 'ANALYZED', state, frontier, report);
    RETURN report;
END
$m27$;

CREATE FUNCTION pgreact_api.analyze_decision_analysis(analysis_id uuid)
RETURNS jsonb LANGUAGE SQL SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $m27$ SELECT pgreact_internal.analyze_decision_analysis($1) $m27$;

CREATE FUNCTION pgreact_internal.decision_analysis_is_fresh(target_analysis_id uuid)
RETURNS boolean
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $m27$
DECLARE row_data pgreact_internal.decision_analyses%ROWTYPE;
BEGIN
    SELECT * INTO row_data FROM pgreact_internal.decision_analyses
    WHERE decision_analyses.analysis_id = target_analysis_id
      AND decision_analyses.state <> 'REMOVED';
    RETURN FOUND AND row_data.last_report IS NOT NULL
        AND row_data.last_frontier IS NOT DISTINCT FROM (SELECT frontier FROM pgreact_internal.clock_frontier)
        AND row_data.last_population_fingerprint IS NOT DISTINCT FROM
            pgreact_internal.m27_relation_fingerprint(row_data.population_relation_oid)
        AND row_data.last_catalog_fingerprint IS NOT DISTINCT FROM
            pgreact_internal.m27_relation_fingerprint(row_data.candidate_catalog_oid)
        AND row_data.last_current_fingerprint IS NOT DISTINCT FROM
            pgreact_internal.m27_version_fingerprint(row_data.current_version_id)
        AND row_data.last_proposed_fingerprint IS NOT DISTINCT FROM
            pgreact_internal.m27_version_fingerprint(row_data.proposed_version_id);
END
$m27$;

CREATE FUNCTION pgreact_internal.assert_decision_admission(target_version_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $m27$
DECLARE analysis_row record;
BEGIN
    SELECT * INTO analysis_row FROM pgreact_internal.decision_analyses
    WHERE decision_analyses.proposed_version_id = target_version_id
      AND decision_analyses.state <> 'REMOVED'
    ORDER BY analyzed_at DESC NULLS LAST, created_at DESC LIMIT 1;
    IF FOUND THEN
        IF NOT pgreact_internal.decision_analysis_is_fresh(analysis_row.analysis_id) THEN
            RAISE EXCEPTION 'M27_ANALYSIS_STALE: decision analysis fingerprints or complete frontier changed';
        END IF;
        IF analysis_row.last_report ->> 'state' <> 'PASS' THEN
            RAISE EXCEPTION 'M27_ANALYSIS_BLOCKED: proposed decision version has blocking analysis findings';
        END IF;
    END IF;
END
$m27$;

CREATE OR REPLACE FUNCTION pgreact_api.deploy_decision_program(program_name text, version_id uuid)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $m27$
DECLARE target_program uuid;
    owner_oid oid;
BEGIN
    SELECT p.program_id, p.owner_oid INTO target_program, owner_oid
    FROM pgreact_internal.decision_programs p
    JOIN pgreact_internal.decision_program_versions v USING (program_id)
    WHERE p.program_name = deploy_decision_program.program_name
      AND v.version_id = deploy_decision_program.version_id AND p.state <> 'REMOVED';
    IF NOT FOUND THEN RAISE EXCEPTION 'M26_VERSION: decision program version was not found'; END IF;
    IF NOT pg_has_role(session_user, owner_oid, 'USAGE')
       AND NOT pgreact_internal.is_operator_admin() THEN
        RAISE EXCEPTION 'M26_CANDIDATE_OWNER: only the decision program owner or operator may deploy a version';
    END IF;
    PERFORM pgreact_internal.assert_decision_admission(version_id);
    UPDATE pgreact_internal.decision_program_versions SET state = 'DEPLOYED'
    WHERE decision_program_versions.version_id = deploy_decision_program.version_id;
    RETURN deploy_decision_program.version_id;
END
$m27$;

CREATE FUNCTION pgreact_api.admit_decision_version(program_name text, version_id uuid, analysis_id uuid)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $m27$
DECLARE analysis_row record;
BEGIN
    SELECT a.* INTO STRICT analysis_row
    FROM pgreact_internal.decision_analyses a
    JOIN pgreact_internal.decision_programs p USING (program_id)
    WHERE a.analysis_id = admit_decision_version.analysis_id
      AND a.proposed_version_id = admit_decision_version.version_id
      AND p.program_name = admit_decision_version.program_name AND a.state <> 'REMOVED';
    PERFORM pgreact_internal.assert_decision_admission(version_id);
    IF NOT pg_has_role(session_user, analysis_row.owner_oid, 'USAGE')
       AND NOT pgreact_internal.is_operator_admin() THEN
        RAISE EXCEPTION 'M27_OWNER: only the decision program owner or operator may admit an analysis';
    END IF;
    INSERT INTO pgreact_internal.decision_analysis_history(analysis_id, event_kind, state, frontier, report)
    VALUES (analysis_id, 'ADMITTED', analysis_row.last_report ->> 'state',
            analysis_row.last_frontier, analysis_row.last_report);
    RETURN pgreact_api.deploy_decision_program(program_name, version_id);
END
$m27$;

CREATE FUNCTION pgreact_api.decision_analysis_status(target_program_name text DEFAULT NULL)
RETURNS jsonb LANGUAGE SQL STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $m27$
    SELECT jsonb_build_object(
        'contract_version', 15,
        'analyses', COALESCE((SELECT jsonb_agg(to_jsonb(a) ORDER BY a.program_name, a.analysis_id)
                              FROM pgreact.decision_analyses a
                              WHERE $1 IS NULL OR a.program_name = $1), '[]'::jsonb),
        'frontier', (SELECT frontier FROM pgreact_internal.clock_frontier))
$m27$;

CREATE FUNCTION pgreact_api.decision_analysis_history(analysis_id uuid)
RETURNS jsonb LANGUAGE SQL STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $m27$
    SELECT jsonb_build_object('contract_version', 15, 'analysis_id', $1,
        'events', COALESCE((SELECT jsonb_agg(to_jsonb(h) ORDER BY h.event_id)
            FROM pgreact_internal.decision_analysis_history h WHERE h.analysis_id = $1), '[]'::jsonb))
$m27$;

CREATE FUNCTION pgreact_api.remove_decision_analysis(analysis_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $m27$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pgreact_internal.decision_analyses a
                   WHERE a.analysis_id = remove_decision_analysis.analysis_id
                     AND pg_has_role(session_user, a.owner_oid, 'USAGE'))
       AND NOT pgreact_internal.is_operator_admin() THEN
        RAISE EXCEPTION 'M27_OWNER: only the analysis owner or operator may remove an analysis';
    END IF;
    UPDATE pgreact_internal.decision_analyses a SET state = 'REMOVED'
    WHERE a.analysis_id = remove_decision_analysis.analysis_id AND a.state <> 'REMOVED';
END
$m27$;

CREATE VIEW pgreact.decision_analyses AS
SELECT a.analysis_id, a.analysis_name, p.program_name,
       a.current_version_id, a.proposed_version_id,
       a.population_relation_name AS population_relation,
       a.population_key_column, a.candidate_catalog_name AS candidate_catalog,
       a.catalog_candidate_column, a.catalog_default_column,
       a.require_default, a.exclusive, a.max_abs_distribution_delta,
       a.max_relative_distribution_delta, a.evidence_limit, a.population_limit,
       pg_get_userbyid(a.owner_oid) AS owner, a.state, a.last_frontier,
       encode(a.last_population_fingerprint, 'hex') AS population_fingerprint,
       encode(a.last_catalog_fingerprint, 'hex') AS catalog_fingerprint,
       encode(a.last_current_fingerprint, 'hex') AS current_fingerprint,
       encode(a.last_proposed_fingerprint, 'hex') AS proposed_fingerprint,
       a.last_report, a.analyzed_at, a.created_at
FROM pgreact_internal.decision_analyses a
JOIN pgreact_internal.decision_programs p USING (program_id)
WHERE a.state <> 'REMOVED' AND p.state <> 'REMOVED';

CREATE VIEW pgreact.decision_analysis_findings AS
SELECT a.analysis_id, p.program_name,
       finding ->> 'code' AS code, finding ->> 'severity' AS severity,
       (finding ->> 'blocker')::boolean AS blocker,
       (finding ->> 'affected_count')::bigint AS affected_count,
       finding -> 'evidence' AS evidence, (finding ->> 'truncated')::boolean AS truncated,
       finding ->> 'message' AS message, finding ->> 'hint' AS hint
FROM pgreact_internal.decision_analyses a
JOIN pgreact_internal.decision_programs p USING (program_id)
CROSS JOIN LATERAL jsonb_array_elements(COALESCE(a.last_report -> 'findings', '[]'::jsonb)) finding
WHERE a.state <> 'REMOVED' AND p.state <> 'REMOVED';

CREATE FUNCTION pgreact_api.decision_analysis_doctor()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $m27$
DECLARE diagnostics jsonb := '[]'::jsonb;
    analysis_row record;
BEGIN
    FOR analysis_row IN SELECT a.*, p.program_name
        FROM pgreact_internal.decision_analyses a
        JOIN pgreact_internal.decision_programs p USING (program_id)
        WHERE a.state <> 'REMOVED' AND p.state <> 'REMOVED' LOOP
        IF analysis_row.last_report IS NULL THEN
            diagnostics := diagnostics || jsonb_build_array(jsonb_build_object(
                'code', 'M27_ANALYSIS_MISSING', 'severity', 'ERROR',
                'object_identity', analysis_row.program_name,
                'message', 'decision analysis has not been run',
                'hint', 'Run pgreact_api.analyze_decision_analysis before admission.'));
        ELSIF NOT pgreact_internal.decision_analysis_is_fresh(analysis_row.analysis_id) THEN
            diagnostics := diagnostics || jsonb_build_array(jsonb_build_object(
                'code', 'M27_ANALYSIS_STALE', 'severity', 'ERROR',
                'object_identity', analysis_row.program_name,
                'message', 'decision analysis no longer matches its complete frontier or relations',
                'hint', 'Run the analysis again before admission.'));
        END IF;
    END LOOP;
    RETURN jsonb_build_object('contract_version', 15,
        'status', CASE WHEN EXISTS (SELECT 1 FROM jsonb_array_elements(diagnostics) d
                                    WHERE d ->> 'severity' = 'ERROR') THEN 'attention' ELSE 'ready' END,
        'diagnostics', diagnostics);
END
$m27$;

CREATE OR REPLACE FUNCTION pgreact_api.decision_doctor()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $m27$
DECLARE diagnostics jsonb := '[]'::jsonb;
    version_row record;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_react' AND extversion = '0.24.0') THEN
        diagnostics := diagnostics || jsonb_build_array(jsonb_build_object(
            'code', 'M27_EXTENSION_VERSION', 'severity', 'ERROR', 'object_identity', 'pg_react',
            'message', 'pg_react extension version is not 0.24.0',
            'hint', 'Install the matching extension files and run ALTER EXTENSION pg_react UPDATE TO ''0.24.0''.'));
    END IF;
    FOR version_row IN
        SELECT v.*, p.program_name FROM pgreact_internal.decision_program_versions v
        JOIN pgreact_internal.decision_programs p USING (program_id)
        WHERE p.state <> 'REMOVED' AND v.state = 'DEPLOYED' LOOP
        IF version_row.source_signature IS DISTINCT FROM pgreact_internal.source_row_signature(version_row.candidate_relation_oid)
           OR version_row.source_definition_digest IS DISTINCT FROM pgreact_internal.decision_source_digest(version_row.candidate_relation_oid) THEN
            diagnostics := diagnostics || jsonb_build_array(jsonb_build_object(
                'code', 'M26_DECISION_DRIFT', 'severity', 'ERROR', 'object_identity', version_row.program_name,
                'message', 'the candidate relation definition changed after declaration',
                'hint', 'Restore the declared relation shape or replace the decision-program version.'));
        END IF;
    END LOOP;
    diagnostics := diagnostics || COALESCE(pgreact_api.decision_analysis_doctor() -> 'diagnostics', '[]'::jsonb);
    RETURN jsonb_build_object('contract_version', 15,
        'status', CASE WHEN EXISTS (SELECT 1 FROM jsonb_array_elements(diagnostics) d
                                    WHERE d ->> 'severity' = 'ERROR') THEN 'attention' ELSE 'ready' END,
        'diagnostics', diagnostics);
END
$m27$;

CREATE OR REPLACE FUNCTION pgreact_api.run(sampled_time timestamptz DEFAULT clock_timestamp())
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $m27$
DECLARE result jsonb;
    program_row record;
BEGIN
    result := pgreact_internal.run_m25(sampled_time);
    FOR program_row IN SELECT program_id FROM pgreact_internal.decision_programs WHERE state = 'ACTIVE' LOOP
        PERFORM pgreact_internal.refresh_decision_program(program_row.program_id, sampled_time);
    END LOOP;
    RETURN jsonb_set(result || jsonb_build_object(
        'decision_programs', pgreact_api.decision_status(),
        'decision_analyses', pgreact_api.decision_analysis_status()),
        '{contract_version}', '15'::jsonb, true);
END
$m27$;

CREATE OR REPLACE FUNCTION pgreact_api.status(target_name text DEFAULT NULL)
RETURNS jsonb LANGUAGE SQL STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $m27$
    SELECT pgreact_internal.status_m25($1)
        || jsonb_build_object('decision_programs', pgreact_api.decision_status($1),
                              'decision_analyses', pgreact_api.decision_analysis_status($1),
                              'contract_version', 15)
$m27$;

ALTER FUNCTION pgreact_api.configure_roles(regrole, regrole, regrole, regrole, regrole)
    SET SCHEMA pgreact_internal;
ALTER FUNCTION pgreact_internal.configure_roles(regrole, regrole, regrole, regrole, regrole)
    RENAME TO configure_roles_m26;

CREATE FUNCTION pgreact_api.configure_roles(
    author_role regrole, operator_role regrole, worker_role regrole,
    reader_role regrole, advanced_reader_role regrole)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $m27$
BEGIN
    PERFORM pgreact_internal.configure_roles_m26(
        author_role, operator_role, worker_role, reader_role, advanced_reader_role);
    EXECUTE format('GRANT SELECT ON pgreact.decision_analyses, pgreact.decision_analysis_findings TO %I, %I',
                   reader_role::text, operator_role::text);
    EXECUTE format('GRANT EXECUTE ON FUNCTION '
        'pgreact_api.validate_decision_analysis(text,uuid,uuid,regclass,name,regclass,name,name,boolean,boolean,bigint,numeric,integer,integer), '
        'pgreact_api.author_decision_analysis(text,text,uuid,uuid,regclass,name,regclass,name,name,boolean,boolean,bigint,numeric,integer,integer), '
        'pgreact_api.analyze_decision_analysis(uuid), pgreact_api.admit_decision_version(text,uuid,uuid), '
        'pgreact_api.remove_decision_analysis(uuid) TO %I', author_role::text);
    EXECUTE format('GRANT EXECUTE ON FUNCTION pgreact_api.decision_analysis_status(text), '
        'pgreact_api.decision_analysis_history(uuid), pgreact_api.decision_analysis_doctor() TO %I, %I',
        reader_role::text, operator_role::text);
END
$m27$;

DO $m27$
DECLARE author_role regrole;
    operator_role regrole;
    worker_role regrole;
    reader_role regrole;
    advanced_reader_role regrole;
BEGIN
    SELECT role_oid::regrole INTO author_role FROM pgreact_internal.application_roles WHERE role_kind = 'author';
    SELECT role_oid::regrole INTO operator_role FROM pgreact_internal.application_roles WHERE role_kind = 'operator';
    SELECT role_oid::regrole INTO worker_role FROM pgreact_internal.application_roles WHERE role_kind = 'worker';
    SELECT role_oid::regrole INTO reader_role FROM pgreact_internal.application_roles WHERE role_kind = 'reader';
    SELECT role_oid::regrole INTO advanced_reader_role FROM pgreact_internal.advanced_readers;
    IF author_role IS NOT NULL AND operator_role IS NOT NULL AND worker_role IS NOT NULL
       AND reader_role IS NOT NULL AND advanced_reader_role IS NOT NULL THEN
        PERFORM pgreact_api.configure_roles(author_role, operator_role, worker_role,
                                            reader_role, advanced_reader_role);
    END IF;
END
$m27$;

REVOKE ALL ON ALL TABLES IN SCHEMA pgreact_internal FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA pgreact_internal FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA pgreact_api FROM PUBLIC;

COMMENT ON EXTENSION pg_react IS
    'M27 deterministic decision coverage and conflict analysis over the M26 decision platform';
