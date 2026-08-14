-- M19 selective immediate maintenance.  pg_trickle owns the source CDC and
-- immediate stream-table maintenance; pg-react only opts eligible versions in.

ALTER TABLE pgreact_internal.rule_versions
    ADD COLUMN maintenance_mode text NOT NULL DEFAULT 'SCHEDULED'
        CHECK (maintenance_mode IN ('SCHEDULED', 'IMMEDIATE'));

ALTER TABLE pgreact_internal.derivation_program_versions
    ADD COLUMN maintenance_mode text NOT NULL DEFAULT 'SCHEDULED'
        CHECK (maintenance_mode IN ('SCHEDULED', 'IMMEDIATE'));

CREATE TABLE pgreact_internal.immediate_audits (
    audit_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    object_identity text NOT NULL,
    operation text NOT NULL,
    details jsonb NOT NULL,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE FUNCTION pgreact_internal.finalize_match_delta_now(target_version_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m19$
DECLARE
    version_id uuid := target_version_id;
    version_row pgreact_internal.rule_versions%ROWTYPE;
    buffered record;
    current_count bigint;
    final_bindings jsonb;
    canonical bytea;
    digest bytea;
    activation uuid;
    prior pgreact_internal.activation_state%ROWTYPE;
    next_generation bigint;
    new_event_id bigint;
    event_key text;
BEGIN
    SELECT * INTO STRICT version_row
    FROM pgreact_internal.rule_versions
    WHERE rule_version_id = version_id;
    PERFORM pg_advisory_xact_lock(hashtextextended(version_id::text, 5788046901200002));

    FOR buffered IN
        DELETE FROM pgreact_internal.activation_delta_buffer
        WHERE rule_version_id = version_id
          AND xid = pg_catalog.pg_current_xact_id()
        RETURNING *
    LOOP
        EXECUTE format(
            'SELECT count(*), min(to_jsonb(m)::text)::jsonb FROM %s AS m '
            'WHERE (to_jsonb(m) ->> %L)::bigint = $1',
            version_row.match_relid::regclass, version_row.key_column::text
        ) INTO current_count, final_bindings USING buffered.semantic_key;

        IF current_count > 1 THEN
            RAISE EXCEPTION 'pg-react duplicate semantic key % in %',
                buffered.semantic_key, version_row.match_name;
        END IF;

        canonical := pgreact_internal.canonical_bigint_v1(buffered.semantic_key);
        digest := pgreact_internal.activation_digest(version_id, canonical);
        activation := pgreact_internal.activation_uuid(digest);
        SELECT * INTO prior
        FROM pgreact_internal.activation_state
        WHERE rule_version_id = version_id AND activation_id = activation
        FOR UPDATE;
        IF FOUND AND (prior.canonical_key <> canonical OR prior.canonical_key_digest <> digest) THEN
            RAISE EXCEPTION 'pg-react activation UUID collision for semantic key %',
                buffered.semantic_key;
        END IF;

        IF current_count = 1 AND (prior.activation_id IS NULL OR NOT prior.active) THEN
            next_generation := COALESCE(prior.generation, 0) + 1;
            INSERT INTO pgreact_internal.activation_state (
                rule_version_id, activation_id, semantic_key, canonical_key,
                canonical_key_digest, key_codec_version, active, generation,
                current_bindings, last_active_bindings, first_seen_at, last_seen_at
            ) VALUES (
                version_id, activation, buffered.semantic_key, canonical, digest, 1,
                true, next_generation, final_bindings, final_bindings,
                clock_timestamp(), clock_timestamp()
            )
            ON CONFLICT (rule_version_id, activation_id) DO UPDATE SET
                active = true, generation = EXCLUDED.generation,
                current_bindings = EXCLUDED.current_bindings,
                last_active_bindings = EXCLUDED.last_active_bindings,
                last_seen_at = EXCLUDED.last_seen_at, deactivated_at = NULL;
            event_key := encode(sha256(convert_to(
                version_id::text || ':' || activation::text || ':' || next_generation || ':ACTIVATE',
                'UTF8')), 'hex');
            INSERT INTO pgreact_internal.lifecycle_events (
                rule_id, rule_version_id, activation_id, generation, event_kind,
                new_bindings, idempotency_key
            ) VALUES (
                version_row.rule_id, version_id, activation, next_generation,
                'ACTIVATE', final_bindings, event_key
            ) RETURNING event_id INTO new_event_id;
            INSERT INTO pgreact_internal.agenda (
                event_id, rule_id, rule_version_id, activation_id,
                activation_generation, state, new_bindings, idempotency_key
            ) SELECT
                new_event_id, version_row.rule_id, version_id, activation,
                next_generation, 'PENDING', final_bindings, event_key
            WHERE version_row.consequence_oid IS NOT NULL;
        ELSIF current_count = 1 AND prior.active THEN
            UPDATE pgreact_internal.activation_state SET
                current_bindings = final_bindings,
                last_active_bindings = final_bindings,
                last_seen_at = clock_timestamp()
            WHERE rule_version_id = version_id AND activation_id = activation;
        ELSIF current_count = 0 AND prior.active THEN
            UPDATE pgreact_internal.activation_state SET
                active = false, current_bindings = NULL,
                deactivated_at = clock_timestamp(), last_seen_at = clock_timestamp()
            WHERE rule_version_id = version_id AND activation_id = activation;
            event_key := encode(sha256(convert_to(
                version_id::text || ':' || activation::text || ':' || prior.generation || ':DEACTIVATE',
                'UTF8')), 'hex');
            INSERT INTO pgreact_internal.lifecycle_events (
                rule_id, rule_version_id, activation_id, generation, event_kind,
                old_bindings, idempotency_key
            ) VALUES (
                version_row.rule_id, version_id, activation, prior.generation,
                'DEACTIVATE', prior.last_active_bindings, event_key);
        END IF;
    END LOOP;
END
$m19$;

CREATE FUNCTION pgreact_internal.finalize_immediate_match_delta()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m19$
BEGIN
    PERFORM pgreact_internal.finalize_match_delta_now(TG_ARGV[0]::uuid);
    RETURN NULL;
END
$m19$;

CREATE FUNCTION pgreact_internal.mark_immediate_rule(target_version_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m19$
DECLARE version_row pgreact_internal.rule_versions%ROWTYPE;
BEGIN
    SELECT * INTO STRICT version_row
    FROM pgreact_internal.rule_versions
    WHERE rule_version_id = target_version_id;
    UPDATE pgreact_internal.rule_versions
    SET maintenance_mode = 'IMMEDIATE'
    WHERE rule_version_id = target_version_id;
    EXECUTE format('DROP TRIGGER IF EXISTS pgreact_immediate_finalize ON %s', version_row.match_name);
    EXECUTE format(
        'CREATE TRIGGER pgreact_immediate_finalize AFTER INSERT OR UPDATE OR DELETE ON %s '
        'FOR EACH STATEMENT EXECUTE FUNCTION pgreact_internal.finalize_immediate_match_delta(%L)',
        version_row.match_name, version_row.rule_version_id::text);
    INSERT INTO pgreact_internal.immediate_audits(object_identity, operation, details)
    VALUES (version_row.rule_version_id::text, 'ENABLE_CLOSURE_MEMBER',
            jsonb_build_object('match', version_row.match_name,
                               'refresh', 'ordered pg-react closure refresh'));
END
$m19$;

CREATE FUNCTION pgreact_internal.capture_immediate_fact_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m19$
BEGIN
    CREATE TEMP TABLE IF NOT EXISTS m19_immediate_changed_relations (
        relation_version_id uuid PRIMARY KEY
    ) ON COMMIT DELETE ROWS;
    INSERT INTO m19_immediate_changed_relations(relation_version_id)
    VALUES (COALESCE(NEW.relation_version_id, OLD.relation_version_id))
    ON CONFLICT DO NOTHING;
    RETURN NULL;
END
$m19$;

CREATE FUNCTION pgreact_internal.propagate_immediate_facts_now()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m19$
DECLARE changed record;
    member record;
BEGIN
    CREATE TEMP TABLE IF NOT EXISTS m19_immediate_changed_relations (
        relation_version_id uuid PRIMARY KEY
    ) ON COMMIT DELETE ROWS;
    LOOP
        SELECT relation_version_id INTO changed
        FROM m19_immediate_changed_relations
        ORDER BY relation_version_id
        LIMIT 1;
        EXIT WHEN NOT FOUND;
        DELETE FROM m19_immediate_changed_relations
        WHERE relation_version_id = changed.relation_version_id;
        FOR member IN
            SELECT DISTINCT version.match_name
            FROM pgreact_internal.derivation_program_inputs input
            JOIN pgreact_internal.derivation_program_rules program_rule
              USING (program_version_id, rule_version_id)
            JOIN pgreact_internal.derivation_program_versions program
              USING (program_version_id)
            JOIN pgreact_internal.rule_versions version
              ON version.rule_version_id = program_rule.rule_version_id
            WHERE input.relation_version_id = changed.relation_version_id
              AND program.state = 'ACTIVE'
              AND program.maintenance_mode = 'IMMEDIATE'
            ORDER BY version.match_name
        LOOP
            PERFORM pgtrickle.refresh_stream_table(member.match_name);
        END LOOP;
    END LOOP;
    TRUNCATE m19_immediate_changed_relations;
END
$m19$;

CREATE FUNCTION pgreact_internal.propagate_immediate_facts()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m19$
BEGIN
    PERFORM pgreact_internal.propagate_immediate_facts_now();
    RETURN NULL;
END
$m19$;

CREATE TRIGGER pgreact_capture_immediate_facts
AFTER INSERT OR UPDATE OR DELETE ON pgreact_internal.derived_facts
FOR EACH ROW EXECUTE FUNCTION pgreact_internal.capture_immediate_fact_change();


CREATE FUNCTION pgreact_api.immediate_capabilities()
RETURNS jsonb
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m19$
    SELECT jsonb_build_object(
        'contract_version', 7,
        'postgresql', current_setting('server_version_num'),
        'pg_trickle', (SELECT extversion FROM pg_extension WHERE extname = 'pg_trickle'),
        'isolation', 'READ COMMITTED',
        'default', 'SCHEDULED',
        'supported', jsonb_build_object(
            'rules', jsonb_build_array('CONSTRAINT'),
            'queries', jsonb_build_array('one direct key over one base table'),
            'dml', jsonb_build_array('INSERT', 'UPDATE', 'DELETE'),
            'derivations', jsonb_build_array('finite', 'acyclic', 'positive', 'database-local')),
        'rejected', jsonb_build_array(
            'COMMAND', 'OUTBOX', 'MANUAL', 'EXTERNAL', 'JOIN', 'AGGREGATE',
            'WINDOW', 'DEADLINE', 'NEGATION', 'RECURSION', 'RLS',
            'non-READ-COMMITTED', 'unsupported pg_trickle tuple'))
$m19$;

CREATE OR REPLACE FUNCTION pgreact_api.infer_program(definition jsonb)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m19$
DECLARE
    rule_item record;
    inferred_inputs jsonb;
    source_oid oid;
    result jsonb := definition;
BEGIN
    IF jsonb_typeof(definition) IS DISTINCT FROM 'object'
       OR jsonb_typeof(definition -> 'rules') IS DISTINCT FROM 'array' THEN
        RETURN definition;
    END IF;
    FOR rule_item IN
        SELECT value, ordinal
        FROM jsonb_array_elements(definition -> 'rules')
             WITH ORDINALITY rules(value, ordinal)
        ORDER BY ordinal
    LOOP
        IF rule_item.value ? 'inputs' THEN
            RAISE EXCEPTION 'M14_EXPLICIT_INPUTS: inputs are inferred from the definition view'
                USING HINT = 'Remove inputs and reference each positive derived relation from the PostgreSQL view.';
        END IF;
        source_oid := to_regclass(rule_item.value ->> 'definition');
        IF source_oid IS NULL THEN
            CONTINUE;
        END IF;
        WITH RECURSIVE dependencies(relation_oid) AS (
            SELECT source_oid
            UNION
            SELECT dependency.refobjid
            FROM dependencies parent
            JOIN pg_rewrite rewrite ON rewrite.ev_class = parent.relation_oid
            JOIN pg_depend dependency
              ON dependency.classid = 'pg_rewrite'::regclass
             AND dependency.objid = rewrite.oid
             AND dependency.refclassid = 'pg_class'::regclass
             AND dependency.deptype = 'n'
        )
        SELECT COALESCE(jsonb_agg(jsonb_build_object(
                'relation', relation.relation_name,
                'key', version.key_column) ORDER BY relation.relation_name), '[]'::jsonb)
          INTO inferred_inputs
          FROM dependencies dependency
          JOIN pgreact_internal.derived_relation_versions version
            ON version.public_view_oid = dependency.relation_oid
           AND version.state = 'ACTIVE'
          JOIN pgreact_internal.derived_relations relation USING (relation_id);
        result := jsonb_set(result,
            ARRAY['rules', (rule_item.ordinal - 1)::text, 'inputs'], inferred_inputs, true);
    END LOOP;
    RETURN result;
END
$m19$;

CREATE FUNCTION pgreact_api.validate_immediate_rule(
    condition regclass,
    semantic_key name
)
RETURNS TABLE(
    contract_version integer, code text, severity text,
    object_identity text, message text, hint text, details jsonb
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m19$
DECLARE
    diagnostic record;
    query_tree text;
    key_attno smallint;
    source_oid oid;
    source_count integer;
BEGIN
    SELECT * INTO diagnostic
    FROM pgreact.validate_rule(condition, ARRAY[semantic_key]::name[], NULL::regprocedure) diagnostics
    WHERE diagnostics.severity = 'ERROR'
    ORDER BY diagnostics.code, diagnostics.object_identity
    LIMIT 1;
    IF FOUND THEN
        RETURN QUERY SELECT 7, diagnostic.code, diagnostic.severity,
            diagnostic.object_identity, diagnostic.message, diagnostic.hint,
            diagnostic.details;
        RETURN;
    END IF;

    SELECT attnum INTO key_attno
    FROM pg_attribute
    WHERE attrelid = condition AND attname = semantic_key
      AND attnum > 0 AND NOT attisdropped;
    IF key_attno IS NULL OR NOT pgreact_internal.view_key_is_direct(condition, key_attno) THEN
        RETURN QUERY SELECT 7, 'M19_KEY_NOT_DIRECT', 'ERROR', condition::text,
            'immediate rules require one direct semantic key projected from the source table',
            'Project one stored bigint key unchanged from the source table.',
            jsonb_build_object('semantic_key', semantic_key);
        RETURN;
    END IF;

    query_tree := pgreact_internal.relation_query_tree(condition);
    IF query_tree ~ E':has(Aggs|WindowFuncs|Recursive|SubLinks)[[:space:]]+true'
       OR query_tree ~ E':jointype[[:space:]]+[0-9]'
    THEN
        RETURN QUERY SELECT 7, 'M19_QUERY_UNSUPPORTED', 'ERROR', condition::text,
            'immediate rules require a finite single-table positive query',
            'Use a direct SELECT from one base table; joins, aggregates, windows, recursion, and subqueries remain scheduled.',
            '{}'::jsonb;
        RETURN;
    END IF;

    WITH RECURSIVE dependencies(relid) AS (
        SELECT condition::oid
        UNION
        SELECT dependency.refobjid
        FROM dependencies parent
        JOIN pg_rewrite rewrite ON rewrite.ev_class = parent.relid
        JOIN pg_depend dependency
          ON dependency.classid = 'pg_rewrite'::regclass
         AND dependency.objid = rewrite.oid
         AND dependency.refclassid = 'pg_class'::regclass
         AND dependency.deptype = 'n'
    )
    SELECT count(DISTINCT relation.oid) FILTER (WHERE relation.relkind IN ('r', 'p')),
           min(relation.oid) FILTER (WHERE relation.relkind IN ('r', 'p'))
    INTO source_count, source_oid
    FROM dependencies
    JOIN pg_class relation ON relation.oid = dependencies.relid
    WHERE relation.oid <> condition;
    IF source_count <> 1 THEN
        RETURN QUERY SELECT 7, 'M19_SOURCE_SHAPE', 'ERROR', condition::text,
            'immediate rules require exactly one ordinary base-table source',
            'Keep this version scheduled or replace it with a single-table positive condition.',
            jsonb_build_object('base_table_count', source_count);
        RETURN;
    END IF;

    IF EXISTS (SELECT 1 FROM pg_class WHERE oid = source_oid
               AND (relrowsecurity OR relforcerowsecurity)) THEN
        RETURN QUERY SELECT 7, 'M19_RLS_UNSUPPORTED', 'ERROR', source_oid::regclass::text,
            'RLS-protected sources are outside the immediate capability matrix',
            'Use a non-RLS source or keep this version scheduled.', '{}'::jsonb;
        RETURN;
    END IF;
    IF NOT has_table_privilege(session_user, source_oid, 'TRIGGER') THEN
        RETURN QUERY SELECT 7, 'M19_SOURCE_TRIGGER_PRIVILEGE', 'ERROR', source_oid::regclass::text,
            'the immediate author must be able to maintain the source table with PostgreSQL triggers',
            'Grant TRIGGER on the source table or keep this version scheduled.', '{}'::jsonb;
        RETURN;
    END IF;
    IF (SELECT extversion FROM pg_extension WHERE extname = 'pg_trickle') IS DISTINCT FROM '0.81.0' THEN
        RETURN QUERY SELECT 7, 'M19_TRICKLE_CAPABILITY', 'ERROR', 'pg_trickle',
            'the pinned pg_trickle immediate-maintenance capability is unavailable',
            'Install pg_trickle 0.81.0 on the supported PostgreSQL 18.3 tuple.', '{}'::jsonb;
        RETURN;
    END IF;
    IF current_setting('transaction_isolation') <> 'read committed' THEN
        RETURN QUERY SELECT 7, 'M19_ISOLATION_UNSUPPORTED', 'ERROR', current_setting('transaction_isolation'),
            'immediate maintenance requires READ COMMITTED',
            'Run the source transaction at READ COMMITTED.', '{}'::jsonb;
        RETURN;
    END IF;
    IF COALESCE(current_setting('pg_trickle.user_triggers', true), '') <> 'auto' THEN
        RETURN QUERY SELECT 7, 'M19_TRIGGER_CAPABILITY', 'ERROR', 'pg_trickle.user_triggers',
            'the pinned immediate-maintenance trigger capability is not enabled',
            'Set pg_trickle.user_triggers=auto and restart PostgreSQL.', '{}'::jsonb;
        RETURN;
    END IF;

    RETURN QUERY SELECT 7, 'OK', 'INFO', condition::text,
        'constraint rule is eligible for PostgreSQL-native immediate maintenance',
        'Call pgreact_api.author_immediate_rule to opt this version in.',
        jsonb_build_object('maintenance_mode', 'IMMEDIATE', 'source_table', source_oid::regclass::text,
                           'visibility', 'same transaction after each supported source statement',
                           'consequence_boundary', 'committed asynchronous agenda');
EXCEPTION WHEN OTHERS THEN
    RETURN QUERY SELECT 7, 'M19_IMMEDIATE_VALIDATION', 'ERROR', condition::text,
        SQLERRM, 'Correct the named object or keep this version scheduled.', '{}'::jsonb;
END
$m19$;

CREATE FUNCTION pgreact_internal.enable_immediate_rule(target_version_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m19$
DECLARE version_row pgreact_internal.rule_versions%ROWTYPE;
    source_oid oid;
BEGIN
    SELECT * INTO STRICT version_row
    FROM pgreact_internal.rule_versions
    WHERE rule_version_id = target_version_id;
    PERFORM pg_advisory_xact_lock(hashtextextended(version_row.rule_version_id::text, 5788046901200002));
    IF version_row.state <> 'ACTIVE' THEN
        RAISE EXCEPTION 'M19_IMMEDIATE_STATE: rule version % is not active', target_version_id;
    END IF;
    UPDATE pgreact_internal.rule_versions
    SET maintenance_mode = 'IMMEDIATE'
    WHERE rule_version_id = target_version_id;
    PERFORM pgtrickle.set_stream_table_refresh_policy(version_row.match_name, 'IMMEDIATE');
    EXECUTE format('DROP TRIGGER IF EXISTS pgreact_immediate_finalize ON %s', version_row.match_name);
    EXECUTE format(
        'CREATE TRIGGER pgreact_immediate_finalize AFTER INSERT OR UPDATE OR DELETE ON %s '
        'FOR EACH STATEMENT EXECUTE FUNCTION pgreact_internal.finalize_immediate_match_delta(%L)',
        version_row.match_name, version_row.rule_version_id::text);
    IF NOT EXISTS (
        SELECT 1 FROM pgtrickle.pgt_stream_tables stream
        WHERE stream.pgt_relid = version_row.match_relid
          AND stream.refresh_mode = 'IMMEDIATE'
    ) THEN
        RAISE EXCEPTION 'M19_IMMEDIATE_CAPABILITY: pg_trickle did not enable IMMEDIATE for %', version_row.match_name;
    END IF;
    WITH RECURSIVE dependencies(relid) AS (
        SELECT version_row.source_view_oid
        UNION
        SELECT dependency.refobjid
        FROM dependencies parent
        JOIN pg_rewrite rewrite ON rewrite.ev_class = parent.relid
        JOIN pg_depend dependency
          ON dependency.classid = 'pg_rewrite'::regclass
         AND dependency.objid = rewrite.oid
         AND dependency.refclassid = 'pg_class'::regclass
         AND dependency.deptype = 'n'
    )
    SELECT min(relation.oid) FILTER (WHERE relation.relkind IN ('r', 'p'))
    INTO source_oid
    FROM dependencies
    JOIN pg_class relation ON relation.oid = dependencies.relid;
    IF source_oid IS NOT NULL THEN
        EXECUTE format('DROP TRIGGER IF EXISTS zz_pgreact_immediate_propagate ON %s', source_oid::regclass);
        EXECUTE format(
            'CREATE TRIGGER zz_pgreact_immediate_propagate AFTER INSERT OR UPDATE OR DELETE ON %s '
            'FOR EACH STATEMENT EXECUTE FUNCTION pgreact_internal.propagate_immediate_facts()',
            source_oid::regclass);
    END IF;
    INSERT INTO pgreact_internal.immediate_audits(object_identity, operation, details)
    VALUES (version_row.rule_version_id::text, 'ENABLE_RULE',
            jsonb_build_object('rule', version_row.source_view_name,
                               'match', version_row.match_name,
                               'lock', 'rule-version advisory xact lock',
                               'visibility', 'READ COMMITTED same transaction'));
END
$m19$;

CREATE FUNCTION pgreact_api.author_immediate_rule(
    rule_name text,
    condition regclass,
    semantic_key name
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m19$
DECLARE target_version uuid;
    diagnostic record;
BEGIN
    SELECT * INTO diagnostic
    FROM pgreact_api.validate_immediate_rule(condition, semantic_key) diagnostics
    WHERE diagnostics.severity = 'ERROR'
    ORDER BY diagnostics.code, diagnostics.object_identity
    LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'M19_IMMEDIATE_INVALID: % for %: %', diagnostic.code,
            diagnostic.object_identity, diagnostic.message USING HINT = diagnostic.hint;
    END IF;
    target_version := pgreact_api.author_rule(
        rule_name => rule_name, condition => condition,
        semantic_key => semantic_key, kind => 'CONSTRAINT');
    PERFORM pgreact_internal.enable_immediate_rule(target_version);
    RETURN target_version;
END
$m19$;

CREATE FUNCTION pgreact_api.replace_immediate_rule(
    rule_name text,
    condition regclass,
    semantic_key name
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m19$
DECLARE target_version uuid;
    prior_version uuid;
    diagnostic record;
BEGIN
    SELECT * INTO diagnostic
    FROM pgreact_api.validate_immediate_rule(condition, semantic_key) diagnostics
    WHERE diagnostics.severity = 'ERROR'
    ORDER BY diagnostics.code, diagnostics.object_identity
    LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'M19_IMMEDIATE_INVALID: % for %: %', diagnostic.code,
            diagnostic.object_identity, diagnostic.message USING HINT = diagnostic.hint;
    END IF;
    SELECT version.rule_version_id INTO prior_version
    FROM pgreact_internal.rules rule
    JOIN pgreact_internal.rule_versions version USING (rule_id)
    WHERE rule.rule_name = replace_immediate_rule.rule_name
      AND version.state IN ('ACTIVE', 'PAUSED')
    ORDER BY version.created_at DESC
    LIMIT 1;
    IF prior_version IS NULL THEN
        RAISE EXCEPTION 'M19_IMMEDIATE_NOT_FOUND: %', rule_name;
    END IF;
    target_version := pgreact.replace_rule(
        prior_version, condition, ARRAY[semantic_key]::name[], NULL,
        'SEED_CURRENT', NULL, NULL, 'DRAIN_OLD');
    PERFORM pgreact_internal.enable_immediate_rule(target_version);
    RETURN target_version;
END
$m19$;

CREATE FUNCTION pgreact_api.validate_immediate_program(definition jsonb)
RETURNS TABLE(
    contract_version integer, code text, severity text,
    object_identity text, message text, hint text, details jsonb
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m19$
DECLARE diagnostic record;
    item jsonb;
BEGIN
    SELECT * INTO diagnostic
    FROM pgreact_api.validate_program(definition) diagnostics
    WHERE diagnostics.severity = 'ERROR'
    ORDER BY diagnostics.code, diagnostics.object_identity
    LIMIT 1;
    IF FOUND THEN
        RETURN QUERY SELECT 7, diagnostic.code, diagnostic.severity,
            diagnostic.object_identity, diagnostic.message, diagnostic.hint,
            diagnostic.details;
        RETURN;
    END IF;
    IF jsonb_typeof(definition -> 'rules') IS DISTINCT FROM 'array'
       OR jsonb_array_length(definition -> 'rules') = 0 THEN
        RETURN QUERY SELECT 7, 'M19_PROGRAM_EMPTY', 'ERROR',
            COALESCE(definition ->> 'name', 'program'),
            'an immediate derivation program must contain at least one rule',
            'Provide one or more positive finite derivation rules.', '{}'::jsonb;
        RETURN;
    END IF;
    FOR item IN SELECT value FROM jsonb_array_elements(definition -> 'rules') LOOP
        IF jsonb_array_length(COALESCE(item -> 'negative_inputs', '[]'::jsonb)) > 0 THEN
            RETURN QUERY SELECT 7, 'M19_NEGATION_UNSUPPORTED', 'ERROR', item ->> 'name',
                'immediate derivations are positive only',
                'Remove negative inputs or deploy the program in scheduled mode.', '{}'::jsonb;
            RETURN;
        END IF;
        IF item ? 'aggregate_input' THEN
            RETURN QUERY SELECT 7, 'M19_AGGREGATE_UNSUPPORTED', 'ERROR', item ->> 'name',
                'aggregates are outside the immediate derivation closure',
                'Keep aggregate rules scheduled.', '{}'::jsonb;
            RETURN;
        END IF;
        IF item ? 'window' OR item ? 'deadline' THEN
            RETURN QUERY SELECT 7, 'M19_TEMPORAL_UNSUPPORTED', 'ERROR', item ->> 'name',
                'temporal rules are outside the immediate derivation closure',
                'Keep window and deadline rules scheduled.', '{}'::jsonb;
            RETURN;
        END IF;
    END LOOP;
    IF (SELECT extversion FROM pg_extension WHERE extname = 'pg_trickle') IS DISTINCT FROM '0.81.0'
       OR current_setting('transaction_isolation') <> 'read committed'
       OR COALESCE(current_setting('pg_trickle.user_triggers', true), '') <> 'auto'
    THEN
        RETURN QUERY SELECT 7, 'M19_TRICKLE_CAPABILITY', 'ERROR', 'pg_trickle',
            'the pinned immediate-maintenance capability is unavailable',
            'Use PostgreSQL 18.3, pg_trickle 0.81.0, READ COMMITTED, and pg_trickle.user_triggers=auto.', '{}'::jsonb;
        RETURN;
    END IF;
    RETURN QUERY SELECT 7, 'OK', 'INFO', definition ->> 'name',
        'program is eligible for a finite positive immediate closure',
        'Call pgreact_api.deploy_immediate_program with the preview digest.',
        jsonb_build_object('maintenance_mode', 'IMMEDIATE', 'closure', 'finite acyclic positive',
                           'downstream_boundary', 'scheduled consumers remain asynchronous');
EXCEPTION WHEN OTHERS THEN
    RETURN QUERY SELECT 7, 'M19_PROGRAM_VALIDATION', 'ERROR',
        COALESCE(definition ->> 'name', 'program'), SQLERRM,
        'Correct the program or deploy it in scheduled mode.', '{}'::jsonb;
END
$m19$;

CREATE FUNCTION pgreact_api.preview_immediate_program(definition jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m19$
DECLARE diagnostic record;
    preview jsonb;
BEGIN
    SELECT * INTO diagnostic
    FROM pgreact_api.validate_immediate_program(definition) diagnostics
    WHERE diagnostics.severity = 'ERROR'
    ORDER BY diagnostics.code, diagnostics.object_identity
    LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'M19_PROGRAM_INVALID: % for %: %', diagnostic.code,
            diagnostic.object_identity, diagnostic.message USING HINT = diagnostic.hint;
    END IF;
    preview := pgreact_api.preview_program(definition);
    RETURN preview || jsonb_build_object(
        'contract_version', 7,
        'maintenance_mode', 'IMMEDIATE',
        'visibility', 'same transaction after each supported source statement',
        'consequence_boundary', 'committed asynchronous agenda');
END
$m19$;

CREATE FUNCTION pgreact_api.deploy_immediate_program(
    definition jsonb,
    expected_plan_digest text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m19$
DECLARE diagnostic record;
    target_program uuid;
    member record;
    program_name text := definition ->> 'name';
BEGIN
    SELECT * INTO diagnostic
    FROM pgreact_api.validate_immediate_program(definition) diagnostics
    WHERE diagnostics.severity = 'ERROR'
    ORDER BY diagnostics.code, diagnostics.object_identity
    LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'M19_PROGRAM_INVALID: % for %: %', diagnostic.code,
            diagnostic.object_identity, diagnostic.message USING HINT = diagnostic.hint;
    END IF;
    PERFORM pg_advisory_xact_lock(hashtextextended(program_name, 5788046901200003));
    target_program := pgreact_api.deploy_program(definition, expected_plan_digest);
    UPDATE pgreact_internal.derivation_program_versions
    SET maintenance_mode = 'IMMEDIATE'
    WHERE program_version_id = target_program;
    -- Convert the whole closure before re-enabling its triggers; otherwise a
    -- downstream full refresh can observe an upstream mode transition.
    PERFORM set_config('session_replication_role', 'replica', true);
    FOR member IN
        SELECT version.rule_version_id, version.match_name
        FROM pgreact_internal.derivation_program_rules program_rule
        JOIN pgreact_internal.rule_versions version
          ON version.rule_version_id = program_rule.rule_version_id
        WHERE program_rule.program_version_id = target_program
        ORDER BY program_rule.rule_order DESC
    LOOP
        IF NOT EXISTS (
            SELECT 1
            FROM pgreact_internal.derivation_program_inputs input
            WHERE input.program_version_id = target_program
              AND input.rule_version_id = member.rule_version_id
        ) THEN
            PERFORM pgreact_internal.enable_immediate_rule(member.rule_version_id);
        ELSE
            -- ponytail: pg_trickle 0.81 cannot nest IMMEDIATE stream refreshes;
            -- roots stay native, downstream members use ordered closure refresh.
            PERFORM pgreact_internal.mark_immediate_rule(member.rule_version_id);
        END IF;
    END LOOP;
    PERFORM set_config('session_replication_role', 'origin', true);
    INSERT INTO pgreact_internal.immediate_audits(object_identity, operation, details)
    VALUES (program_name, 'ENABLE_PROGRAM',
            jsonb_build_object('program_version_id', target_program,
                               'closure', 'finite acyclic positive',
                               'lock', 'program advisory xact lock'));
    RETURN target_program;
END
$m19$;

ALTER FUNCTION pgreact_api.status(text) SET SCHEMA pgreact_internal;
ALTER FUNCTION pgreact_internal.status(text) RENAME TO status_m18;

CREATE FUNCTION pgreact_api.status(name text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m19$
DECLARE result jsonb;
BEGIN
    result := pgreact_internal.status_m18(name);
    IF EXISTS (
        SELECT 1 FROM pgreact_internal.rule_versions version
        JOIN pgreact_internal.rules rule USING (rule_id)
        WHERE version.maintenance_mode = 'IMMEDIATE'
          AND (name IS NULL OR rule.rule_name = name)
    ) THEN
        result := jsonb_set(result, '{rules}', (
            SELECT jsonb_agg(
                CASE WHEN version.maintenance_mode = 'IMMEDIATE'
                     THEN item.value || jsonb_build_object('maintenance_mode', 'IMMEDIATE')
                     ELSE item.value END
                ORDER BY item.ordinality)
            FROM jsonb_array_elements(result -> 'rules') WITH ORDINALITY item
            LEFT JOIN pgreact_internal.rules rule ON rule.rule_name = item.value ->> 'rule'
            LEFT JOIN pgreact_internal.rule_versions version ON version.rule_id = rule.rule_id
                AND version.state <> 'REMOVED'
        ), true);
        result := jsonb_set(result, '{contract_version}', '7'::jsonb, true);
    END IF;
    IF name IS NOT NULL AND EXISTS (
        SELECT 1 FROM pgreact_internal.derivation_programs program
        JOIN pgreact_internal.derivation_program_versions version USING (program_id)
        WHERE program.program_name = name AND version.state = 'ACTIVE'
          AND version.maintenance_mode = 'IMMEDIATE'
    ) THEN
        result := jsonb_set(result, '{programs}', (
            SELECT jsonb_agg(
                CASE WHEN version.maintenance_mode = 'IMMEDIATE'
                     THEN item.value || jsonb_build_object('maintenance_mode', 'IMMEDIATE')
                     ELSE item.value END
                ORDER BY item.ordinality)
            FROM jsonb_array_elements(result -> 'programs') WITH ORDINALITY item
            LEFT JOIN pgreact_internal.derivation_programs program
              ON program.program_name = item.value ->> 'program'
            LEFT JOIN pgreact_internal.derivation_program_versions version
              ON version.program_id = program.program_id AND version.state = 'ACTIVE'
        ), true);
        result := jsonb_set(result, '{contract_version}', '7'::jsonb, true);
    END IF;
    RETURN result;
END
$m19$;

ALTER FUNCTION pgreact_api.matches(text) SET SCHEMA pgreact_internal;
ALTER FUNCTION pgreact_internal.matches(text) RENAME TO matches_m18;

CREATE FUNCTION pgreact_api.matches(name text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m19$
DECLARE result jsonb;
BEGIN
    result := pgreact_internal.matches_m18(name);
    IF EXISTS (
        SELECT 1 FROM pgreact_internal.rules rule
        JOIN pgreact_internal.rule_versions version USING (rule_id)
        WHERE version.maintenance_mode = 'IMMEDIATE'
          AND (name IS NULL OR rule.rule_name = name)
    ) THEN
        result := jsonb_set(result, '{matches}', (
            SELECT COALESCE(jsonb_agg(
                CASE WHEN EXISTS (
                    SELECT 1 FROM pgreact_internal.rules rule
                    JOIN pgreact_internal.rule_versions version USING (rule_id)
                    WHERE rule.rule_name = item.value ->> 'rule'
                      AND version.maintenance_mode = 'IMMEDIATE')
                    THEN item.value || jsonb_build_object('maintenance_mode', 'IMMEDIATE')
                    ELSE item.value END
                ORDER BY item.ordinality), '[]'::jsonb)
            FROM (
                SELECT DISTINCT ON (item.value ->> 'rule', item.value ->> 'key')
                    item.value, item.ordinality
                FROM jsonb_array_elements(result -> 'matches') WITH ORDINALITY item
                WHERE name IS NULL OR item.value ->> 'rule' = name
                ORDER BY item.value ->> 'rule', item.value ->> 'key', item.ordinality
            ) item), true);
        result := jsonb_set(result, '{contract_version}', '7'::jsonb, true);
    END IF;
    RETURN result;
END
$m19$;

ALTER FUNCTION pgreact_api.explain(text, jsonb) SET SCHEMA pgreact_internal;
ALTER FUNCTION pgreact_internal.explain(text, jsonb) RENAME TO explain_m18;

CREATE FUNCTION pgreact_api.explain(target text, semantic_key jsonb)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m19$
DECLARE result jsonb;
    immediate boolean;
BEGIN
    result := pgreact_internal.explain_m18(target, semantic_key);
    SELECT EXISTS (
        SELECT 1 FROM pgreact_internal.rules rule
        JOIN pgreact_internal.rule_versions version USING (rule_id)
        WHERE rule.rule_name = target AND version.maintenance_mode = 'IMMEDIATE'
    ) OR EXISTS (
        SELECT 1
        FROM pgreact_internal.keyed_derived_relations derived
        JOIN pgreact_internal.derivation_program_rules member
          ON member.target_relation_version_id = derived.relation_version_id
        JOIN pgreact_internal.derivation_program_versions program
          ON program.program_version_id = member.program_version_id
         AND program.state = 'ACTIVE' AND program.maintenance_mode = 'IMMEDIATE'
        WHERE derived.public_name = target
    ) INTO immediate;
    IF immediate THEN
        RETURN result || jsonb_build_object(
            'contract_version', 7,
            'maintenance_mode', 'IMMEDIATE',
            'visibility', 'same transaction after each supported source statement',
            'consequence_boundary', 'committed asynchronous agenda');
    END IF;
    RETURN result;
END
$m19$;

ALTER FUNCTION pgreact_api.doctor() SET SCHEMA pgreact_internal;
ALTER FUNCTION pgreact_internal.doctor() RENAME TO doctor_m18;

CREATE FUNCTION pgreact_api.doctor()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m19$
DECLARE result jsonb;
    diagnostics jsonb;
    immediate boolean;
BEGIN
    result := pgreact_internal.doctor_m18();
    SELECT EXISTS (SELECT 1 FROM pgreact_internal.rule_versions
                   WHERE maintenance_mode = 'IMMEDIATE')
        OR EXISTS (SELECT 1 FROM pgreact_internal.derivation_program_versions
                   WHERE maintenance_mode = 'IMMEDIATE' AND state = 'ACTIVE')
    INTO immediate;
    SELECT COALESCE(jsonb_agg(item.value ORDER BY item.ordinality), '[]'::jsonb)
    INTO diagnostics
    FROM jsonb_array_elements(COALESCE(result -> 'diagnostics', '[]'::jsonb))
         WITH ORDINALITY item
    WHERE item.value ->> 'code' <> 'M18_EXTENSION_VERSION';
    diagnostics := diagnostics || CASE WHEN EXISTS (
        SELECT 1 FROM pg_extension WHERE extname = 'pg_react' AND extversion = '0.16.0')
        THEN '[]'::jsonb ELSE jsonb_build_array(jsonb_build_object(
            'code', 'M19_EXTENSION_VERSION', 'severity', 'ERROR', 'object_identity', 'pg_react',
            'message', 'pg_react extension version is not 0.16.0',
            'hint', 'Install matching files and run ALTER EXTENSION pg_react UPDATE.')) END;
    diagnostics := diagnostics || CASE WHEN EXISTS (
        SELECT 1
        FROM pgreact_internal.rule_versions version
        LEFT JOIN pgtrickle.pgt_stream_tables stream ON stream.pgt_relid = version.match_relid
        WHERE version.maintenance_mode = 'IMMEDIATE'
          AND stream.refresh_mode IS DISTINCT FROM 'IMMEDIATE'
          AND NOT EXISTS (
              SELECT 1
              FROM pgreact_internal.derivation_program_rules program_rule
              JOIN pgreact_internal.derivation_program_versions program
                USING (program_version_id)
              JOIN pgreact_internal.derivation_program_inputs input
                USING (program_version_id, rule_version_id)
              WHERE program_rule.rule_version_id = version.rule_version_id
                AND program.state = 'ACTIVE'
                AND program.maintenance_mode = 'IMMEDIATE'))
        THEN jsonb_build_array(jsonb_build_object(
            'code', 'M19_IMMEDIATE_STREAM_MODE', 'severity', 'ERROR',
            'object_identity', 'pgreact',
            'message', 'an immediate rule is not backed by an IMMEDIATE pg_trickle stream',
            'hint', 'Reconcile or replace the immediate rule through the public API.'))
        ELSE '[]'::jsonb END;
    result := jsonb_set(result, '{diagnostics}', diagnostics, true);
    result := jsonb_set(result, '{contract_version}', CASE WHEN immediate THEN '7'::jsonb ELSE result -> 'contract_version' END, true);
    result := jsonb_set(result, '{status}', CASE WHEN EXISTS (
        SELECT 1 FROM jsonb_array_elements(diagnostics) item
        WHERE item ->> 'severity' = 'ERROR') THEN '"attention"'::jsonb ELSE '"ready"'::jsonb END, true);
    RETURN result;
END
$m19$;

ALTER FUNCTION pgreact_api.configure_roles(regrole, regrole, regrole, regrole, regrole)
    SET SCHEMA pgreact_internal;
ALTER FUNCTION pgreact_internal.configure_roles(regrole, regrole, regrole, regrole, regrole)
    RENAME TO configure_roles_m18;

CREATE FUNCTION pgreact_api.configure_roles(
    author_role regrole,
    operator_role regrole,
    worker_role regrole,
    reader_role regrole,
    advanced_reader_role regrole
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m19$
BEGIN
    PERFORM pgreact_internal.configure_roles_m18(
        author_role, operator_role, worker_role, reader_role, advanced_reader_role);
    EXECUTE format(
        'GRANT EXECUTE ON FUNCTION pgreact_api.immediate_capabilities(), '
        'pgreact_api.validate_immediate_rule(regclass,name), '
        'pgreact_api.author_immediate_rule(text,regclass,name), '
        'pgreact_api.replace_immediate_rule(text,regclass,name), '
        'pgreact_api.validate_immediate_program(jsonb), '
        'pgreact_api.preview_immediate_program(jsonb), '
        'pgreact_api.deploy_immediate_program(jsonb,text) TO %I', author_role::text);
    EXECUTE format(
        'GRANT EXECUTE ON FUNCTION pgreact_api.immediate_capabilities(), '
        'pgreact_api.status(text), pgreact_api.matches(text), '
        'pgreact_api.explain(text,jsonb), pgreact_api.doctor() TO %I', reader_role::text);
END
$m19$;

DO $m19$
DECLARE
    author_role regrole;
    operator_role regrole;
    worker_role regrole;
    reader_role regrole;
    advanced_reader_role regrole;
BEGIN
    SELECT role_oid::regrole INTO author_role
    FROM pgreact_internal.application_roles WHERE role_kind = 'author';
    SELECT role_oid::regrole INTO operator_role
    FROM pgreact_internal.application_roles WHERE role_kind = 'operator';
    SELECT role_oid::regrole INTO worker_role
    FROM pgreact_internal.application_roles WHERE role_kind = 'worker';
    SELECT role_oid::regrole INTO reader_role
    FROM pgreact_internal.application_roles WHERE role_kind = 'reader';
    SELECT role_oid::regrole INTO advanced_reader_role
    FROM pgreact_internal.advanced_readers;
    IF author_role IS NOT NULL AND operator_role IS NOT NULL
       AND worker_role IS NOT NULL AND reader_role IS NOT NULL
       AND advanced_reader_role IS NOT NULL THEN
        PERFORM pgreact_api.configure_roles(
            author_role, operator_role, worker_role, reader_role, advanced_reader_role);
    END IF;
END
$m19$;

REVOKE ALL ON ALL TABLES IN SCHEMA pgreact_internal FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA pgreact_internal FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA pgreact_api FROM PUBLIC;

COMMENT ON EXTENSION pg_react IS
    'M19 selective immediate maintenance over the scheduled durable rule engine';
