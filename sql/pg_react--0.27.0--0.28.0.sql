-- M31 authoritative runtime: make M30 eligibility control effective rule
-- activations, lifecycle events, and executable work.
-- Lock order: coordinator (5788046901200000), applicability (5788046901200004),
-- then member/program locks; execution takes the coordinator shared lock before
-- the member lock.  The coordinator lock is transaction-scoped.

ALTER TABLE pgreact_internal.policy_set_scope_supports
    ADD COLUMN IF NOT EXISTS activation_id uuid;

ALTER TABLE pgreact_internal.policy_set_versions
    ADD COLUMN IF NOT EXISTS applicability_source_definition_digest text;

ALTER TABLE pgreact_internal.policy_set_history
    DROP CONSTRAINT IF EXISTS policy_set_history_event_kind_check;
ALTER TABLE pgreact_internal.policy_set_history
    ADD CONSTRAINT policy_set_history_event_kind_check
    CHECK (event_kind IN ('DEPLOYED', 'REFRESHED', 'REMOVED', 'EXPIRED'));

CREATE INDEX IF NOT EXISTS policy_set_scope_support_activation_idx
    ON pgreact_internal.policy_set_scope_supports (activation_id);

CREATE FUNCTION pgreact_internal.m31_source_definition_digest(
    source_oid oid, key_names name[])
RETURNS text
LANGUAGE SQL STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $m31$
    SELECT encode(sha256(convert_to(
        COALESCE((SELECT relkind::text || ':' || relrowsecurity::text || ':'
                         || relforcerowsecurity::text || ':' || relowner::text
                  FROM pg_class WHERE oid = $1), '') || ':' ||
        COALESCE((SELECT string_agg(format('%s:%s:%s:%s:%s:%s:%s',
                                  attribute.attnum, attribute.attname,
                                  attribute.atttypid::oid, attribute.atttypmod,
                                  attribute.attcollation::oid, attribute.attnotnull,
                                  COALESCE(pg_get_expr(default_value.adbin,
                                                       default_value.adrelid), ''))
                              , ','
                              ORDER BY attribute.attnum)
                  FROM pg_attribute attribute
                  LEFT JOIN pg_attrdef default_value
                    ON default_value.adrelid = attribute.attrelid
                   AND default_value.adnum = attribute.attnum
                  WHERE attribute.attrelid = $1
                    AND attribute.attnum > 0
                    AND NOT attribute.attisdropped), '') || ':'
        || COALESCE((SELECT CASE WHEN relation.relkind IN ('v', 'm')
                                  THEN pg_get_viewdef(relation.oid, true) ELSE '' END
                     FROM pg_class relation WHERE relation.oid = $1), '') || ':'
        || COALESCE(array_to_string($2, ','), ''), 'UTF8')), 'hex')
$m31$;

CREATE FUNCTION pgreact_internal.m31_key_types(source_oid oid, key_names name[])
RETURNS text[]
LANGUAGE SQL STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
    SELECT array_agg(a.atttypid::regtype::text ORDER BY requested.ordinal)
    FROM unnest($2) WITH ORDINALITY requested(key_name, ordinal)
    JOIN pg_attribute a ON a.attrelid = $1
                       AND a.attname = requested.key_name
                       AND a.attnum > 0 AND NOT a.attisdropped
$$;

CREATE FUNCTION pgreact_internal.m31_binding_values(bindings jsonb, key_names name[])
RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE STRICT SET search_path = pg_catalog, pg_temp AS $m31$
DECLARE key_name name;
    values jsonb := '[]'::jsonb;
BEGIN
    FOREACH key_name IN ARRAY key_names LOOP
        IF NOT (bindings ? key_name::text)
           OR bindings -> key_name::text IS NULL
           OR jsonb_typeof(bindings -> key_name::text) = 'null' THEN
            RAISE EXCEPTION 'M31_BINDING_KEY: binding does not contain non-null key %', key_name;
        END IF;
        values := values || jsonb_build_array(bindings -> key_name::text);
    END LOOP;
    RETURN values;
END
$m31$;


CREATE FUNCTION pgreact_internal.m31_remove_support(target_support_id uuid, reason text)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $m31$
DECLARE support_row pgreact_internal.policy_set_scope_supports%ROWTYPE;
BEGIN
    SELECT * INTO support_row
    FROM pgreact_internal.policy_set_scope_supports
    WHERE scope_support_id = target_support_id
    FOR UPDATE;
    IF NOT FOUND THEN RETURN; END IF;
    DELETE FROM pgreact_internal.policy_set_scope_supports
    WHERE scope_support_id = target_support_id;
    INSERT INTO pgreact_internal.policy_set_scope_support_history(
        scope_support_id, policy_set_version_id, member_kind, member_name,
        member_version, match_identity, subject_identity, event_kind,
        complete_frontier, details)
    VALUES (support_row.scope_support_id, support_row.policy_set_version_id,
        support_row.member_kind, support_row.member_name, support_row.member_version,
        support_row.match_identity, support_row.subject_identity, 'REMOVED',
        support_row.complete_frontier, jsonb_build_object('reason', reason));
END
$m31$;

CREATE FUNCTION pgreact_internal.m31_upsert_support(
    target_set_version uuid,
    target_kind text,
    target_name text,
    target_version text,
    target_activation uuid,
    target_match_identity bytea,
    target_subject_identity bytea,
    target_subject_values jsonb,
    target_frontier timestamptz
)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $m31$
DECLARE prior pgreact_internal.policy_set_scope_supports%ROWTYPE;
    support_id uuid;
BEGIN
    SELECT * INTO prior
    FROM pgreact_internal.policy_set_scope_supports
    WHERE policy_set_version_id = target_set_version
      AND member_kind = target_kind AND member_name = target_name
      AND member_version = target_version AND match_identity = target_match_identity
    FOR UPDATE;
    IF NOT FOUND THEN
        INSERT INTO pgreact_internal.policy_set_scope_supports(
            policy_set_version_id, member_kind, member_name, member_version,
            activation_id, match_identity, subject_identity, subject_values,
            complete_frontier)
        VALUES (target_set_version, target_kind, target_name, target_version,
                target_activation, target_match_identity, target_subject_identity,
                target_subject_values, target_frontier)
        RETURNING scope_support_id INTO support_id;
        INSERT INTO pgreact_internal.policy_set_scope_support_history(
            scope_support_id, policy_set_version_id, member_kind, member_name,
            member_version, match_identity, subject_identity, event_kind,
            complete_frontier, details)
        VALUES (support_id, target_set_version, target_kind, target_name,
                target_version, target_match_identity, target_subject_identity,
                'ADDED', target_frontier, '{}'::jsonb);
    ELSIF prior.subject_identity IS DISTINCT FROM target_subject_identity THEN
        UPDATE pgreact_internal.policy_set_scope_supports
        SET activation_id = target_activation, subject_identity = target_subject_identity,
            subject_values = target_subject_values,
            support_generation = support_generation + 1,
            complete_frontier = target_frontier
        WHERE scope_support_id = prior.scope_support_id;
        INSERT INTO pgreact_internal.policy_set_scope_support_history(
            scope_support_id, policy_set_version_id, member_kind, member_name,
            member_version, match_identity, subject_identity, event_kind,
            complete_frontier, details)
        VALUES (prior.scope_support_id, target_set_version, target_kind, target_name,
                target_version, target_match_identity, target_subject_identity,
                'ADDED', target_frontier, jsonb_build_object('reentry', true));
    ELSE
        UPDATE pgreact_internal.policy_set_scope_supports
        SET activation_id = target_activation, complete_frontier = target_frontier
        WHERE scope_support_id = prior.scope_support_id;
    END IF;
END
$m31$;

CREATE FUNCTION pgreact_internal.m31_refresh_policy_set(
    target_set_version uuid, sampled_time timestamptz)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $m31$
DECLARE version_row pgreact_internal.policy_set_versions%ROWTYPE;
    snapshot jsonb;
    source_schema text;
    source_kind "char";
    source_rls boolean;
    source_details jsonb;
    source_definition_digest text;
    key_names name[];
BEGIN
    PERFORM pg_advisory_xact_lock(5788046901200000);
    PERFORM pg_advisory_xact_lock(5788046901200004);
    SELECT version.* INTO version_row
    FROM pgreact_internal.policy_set_versions version
    WHERE version.policy_set_version_id = target_set_version
      AND version.state = 'DEPLOYED'
      AND version.valid_from <= sampled_time
      AND (version.valid_to IS NULL OR sampled_time < version.valid_to)
    FOR UPDATE;
    IF NOT FOUND THEN
        INSERT INTO pgreact_internal.policy_set_runtime_barriers(
            policy_set_version_id, code, details, cleared_at)
        VALUES (target_set_version, 'M31_SET_NOT_EFFECTIVE',
                jsonb_build_object('sampled_time', sampled_time), NULL)
        ON CONFLICT (policy_set_version_id) DO UPDATE SET
            code = EXCLUDED.code, details = EXCLUDED.details,
            created_at = clock_timestamp(), cleared_at = NULL;
        RETURN false;
    END IF;
    BEGIN
        IF version_row.applicability_source_oid IS NULL THEN
            RAISE EXCEPTION 'M31_SOURCE_UNAVAILABLE: applicability source is not relational';
        END IF;
        SELECT namespace.nspname, relation.relkind, relation.relrowsecurity
        INTO source_schema, source_kind, source_rls
        FROM pg_namespace namespace
        JOIN pg_class relation ON relation.relnamespace = namespace.oid
        WHERE relation.oid = version_row.applicability_source_oid;
        IF source_schema IS NULL THEN
            RAISE EXCEPTION 'M31_SOURCE_UNAVAILABLE: applicability relation no longer exists';
        END IF;
        IF source_kind NOT IN ('r', 'p', 'v', 'm', 'f') THEN
            RAISE EXCEPTION 'M31_SOURCE_INVALID: applicability relation kind is unsupported';
        END IF;
        IF source_rls THEN
            RAISE EXCEPTION 'M31_SOURCE_RLS_PROTECTED: applicability relation uses row-level security';
        END IF;
        IF NOT has_table_privilege(session_user,
                                   version_row.applicability_source_oid, 'SELECT') THEN
            RAISE EXCEPTION 'M31_SOURCE_UNAUTHORIZED: applicability source is not readable';
        END IF;
        PERFORM set_config(
            'search_path', format('pg_catalog,pg_temp,%I', source_schema), true);
        key_names := ARRAY(SELECT jsonb_array_elements_text(
            version_row.normalized -> 'spec' -> 'applicability' -> 'subject_keys'))::name[];
        source_details := pgreact_internal.m30_relation_details(
            version_row.applicability_source_oid, key_names);
        IF (source_details ->> 'null_count')::bigint > 0 THEN
            RAISE EXCEPTION 'M31_SOURCE_INCOMPLETE: applicability subjects contain null keys';
        END IF;
        IF (source_details ->> 'distinct_count')::bigint
           <> (source_details ->> 'row_count')::bigint THEN
            RAISE EXCEPTION 'M31_SOURCE_DUPLICATE: applicability subjects are duplicated';
        END IF;
        IF (source_details ->> 'row_count')::bigint > 100000 THEN
            RAISE EXCEPTION 'M31_SOURCE_OVER_LIMIT: applicability source exceeds the row limit';
        END IF;
        source_definition_digest := pgreact_internal.m31_source_definition_digest(
            version_row.applicability_source_oid, key_names);
        IF version_row.applicability_source_definition_digest IS NOT NULL
           AND version_row.applicability_source_definition_digest
               IS DISTINCT FROM source_definition_digest THEN
            RAISE EXCEPTION 'M31_SOURCE_DRIFT: applicability relation definition changed';
        END IF;
        snapshot := pgreact_internal.m30_snapshot(jsonb_set(
            version_row.normalized, '{spec,applicability,relation_oid}',
            to_jsonb(version_row.applicability_source_oid::text), true));
    EXCEPTION WHEN OTHERS THEN
        INSERT INTO pgreact_internal.policy_set_runtime_barriers(
            policy_set_version_id, code, details, cleared_at)
        VALUES (target_set_version,
                CASE
                    WHEN SQLERRM LIKE 'M31_SOURCE_UNAUTHORIZED:%'
                        THEN 'M31_SOURCE_UNAUTHORIZED'
                    WHEN SQLERRM LIKE 'M31_SOURCE_RLS_PROTECTED:%'
                        THEN 'M31_SOURCE_RLS_PROTECTED'
                    WHEN SQLERRM LIKE 'M31_SOURCE_INCOMPLETE:%'
                        THEN 'M31_SOURCE_INCOMPLETE'
                    WHEN SQLERRM LIKE 'M31_SOURCE_DUPLICATE:%'
                        THEN 'M31_SOURCE_DUPLICATE'
                    WHEN SQLERRM LIKE 'M31_SOURCE_OVER_LIMIT:%'
                        THEN 'M31_SOURCE_OVER_LIMIT'
                    WHEN SQLERRM LIKE 'M31_SOURCE_DRIFT:%'
                        THEN 'M31_SOURCE_DRIFT'
                    WHEN SQLERRM LIKE 'M31_SOURCE_INVALID:%'
                        THEN 'M31_SOURCE_INVALID'
                    WHEN SQLERRM LIKE 'M30_SOURCE_KEY:%'
                        OR SQLERRM LIKE 'M31_MEMBER_KEY:%'
                        THEN 'M31_SOURCE_INCOMPLETE'
                    WHEN SQLERRM LIKE 'M30_KEY_%'
                        THEN 'M31_SOURCE_MALFORMED'
                    WHEN SQLSTATE IN ('22P02', '22023')
                        THEN 'M31_SOURCE_MALFORMED'
                    ELSE 'M31_SOURCE_UNAVAILABLE'
                END,
                jsonb_build_object('message', SQLERRM), NULL)
        ON CONFLICT (policy_set_version_id) DO UPDATE SET
            code = EXCLUDED.code, details = EXCLUDED.details,
            created_at = clock_timestamp(), cleared_at = NULL;
        RETURN false;
    END;
    UPDATE pgreact_internal.policy_set_versions
    SET complete_frontier = (snapshot ->> 'complete_frontier')::timestamptz,
        applicability_fingerprint = snapshot ->> 'applicability_fingerprint',
        applicability_source_definition_digest = source_definition_digest,
        eligible_subjects = snapshot -> 'eligible_subjects',
        eligible_subject_count = (snapshot ->> 'eligible_subject_count')::bigint
    WHERE policy_set_version_id = target_set_version;
    DELETE FROM pgreact_internal.policy_set_eligibility
    WHERE policy_set_version_id = target_set_version;
    INSERT INTO pgreact_internal.policy_set_eligibility(
        policy_set_version_id, subject_identity, subject_values, key_types,
        key_codec_version, complete_frontier, source_fingerprint)
    SELECT target_set_version, decode(row_data ->> 'subject_identity', 'hex'),
           row_data -> 'subject_values',
           ARRAY(SELECT jsonb_array_elements_text(row_data -> 'key_types'))::text[],
           2, (snapshot ->> 'complete_frontier')::timestamptz,
           snapshot ->> 'applicability_fingerprint'
    FROM jsonb_array_elements(snapshot -> 'eligibility_rows') row_data;
    DELETE FROM pgreact_internal.policy_set_runtime_barriers
    WHERE policy_set_version_id = target_set_version;
    INSERT INTO pgreact_internal.policy_set_history(
        policy_set_version_id, event_kind, frontier, details)
    VALUES (target_set_version, 'REFRESHED',
        (snapshot ->> 'complete_frontier')::timestamptz,
        jsonb_build_object('runtime_state', 'AUTHORITATIVE',
                           'eligible_subject_count', snapshot -> 'eligible_subject_count'));
    RETURN true;
END
$m31$;

CREATE FUNCTION pgreact_internal.m31_reconcile_rule(
    target_rule_version uuid,
    sampled_time timestamptz DEFAULT clock_timestamp(),
    target_set_version uuid DEFAULT NULL)
RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $m31$
DECLARE version_row pgreact_internal.rule_versions%ROWTYPE;
    member_row record;
    match_row record;
    state_row pgreact_internal.activation_state%ROWTYPE;
    support_row pgreact_internal.policy_set_scope_supports%ROWTYPE;
    match_types text[];
    subject_types text[];
    match_values jsonb;
    subject_values jsonb;
    computed_match_identity bytea;
    computed_subject_identity bytea;
    canonical bytea;
    digest bytea;
    activation uuid;
    support_count bigint;
    transitioned bigint := 0;
    scoped boolean;
    seen_activations uuid[] := ARRAY[]::uuid[];
BEGIN
    PERFORM pg_advisory_xact_lock(5788046901200000);
    PERFORM pg_advisory_xact_lock(5788046901200004);
    SELECT * INTO STRICT version_row
    FROM pgreact_internal.rule_versions
    WHERE rule_version_id = target_rule_version AND state <> 'REMOVED'
    FOR UPDATE;
    PERFORM pg_advisory_xact_lock(hashtextextended(
        'm31:rule:' || target_rule_version::text, 5788046901200005));
    SELECT EXISTS (
        SELECT 1 FROM pgreact_internal.policy_set_members member
        JOIN pgreact_internal.policy_set_versions version
          USING (policy_set_version_id)
        WHERE member.member_kind = 'rule'
          AND member.member_name = (SELECT rule_name FROM pgreact_internal.rules
                                    WHERE rule_id = version_row.rule_id)
          AND member.scope_mode = 'POLICY_SET_REQUIRED'
          AND version.state = 'DEPLOYED'
          AND (target_set_version IS NULL
               OR version.policy_set_version_id = target_set_version)
    ) INTO scoped;

    IF NOT scoped AND target_set_version IS NULL THEN
        PERFORM pgreact_api.run_rule(
            (SELECT rule_name FROM pgreact_internal.rules
             WHERE rule_id = version_row.rule_id));
        RETURN 0;
    END IF;

    FOR member_row IN
        SELECT member.*, version.policy_set_version_id, version.complete_frontier,
               version.subject_keys AS set_subject_keys
        FROM pgreact_internal.policy_set_members member
        JOIN pgreact_internal.policy_set_versions version
          USING (policy_set_version_id)
        JOIN pgreact_internal.rules rule
          ON rule.rule_name = member.member_name
        JOIN pgreact_internal.rule_versions rule_version
          ON rule_version.rule_id = rule.rule_id
         AND rule_version.rule_version_id = target_rule_version
        JOIN pgreact_internal.api_declarations declaration
          ON declaration.kind = 'rule'
         AND declaration.object_name = member.member_name
         AND declaration.state = 'DEPLOYED'
         AND declaration.delegated_id = rule_version.rule_version_id
        WHERE member.member_kind = 'rule'
          AND member.member_name = (SELECT rule_name FROM pgreact_internal.rules
                                    WHERE rule_id = version_row.rule_id)
          AND version.state = 'DEPLOYED'
          AND version.valid_from <= sampled_time
          AND (version.valid_to IS NULL OR sampled_time < version.valid_to)
          AND member.scope_mode = 'POLICY_SET_REQUIRED'
          AND (target_set_version IS NULL
               OR version.policy_set_version_id = target_set_version)
          AND member.member_version IN ('1', rule_version.rule_version_id::text)
    LOOP
        match_types := pgreact_internal.m31_key_types(version_row.source_view_oid,
                                                       member_row.match_keys);
        subject_types := pgreact_internal.m31_key_types(version_row.source_view_oid,
                                                         COALESCE(member_row.subject_keys,
                                                                  member_row.set_subject_keys));
        IF cardinality(match_types) <> cardinality(member_row.match_keys)
           OR cardinality(subject_types) <> cardinality(COALESCE(member_row.subject_keys,
                                                                  member_row.set_subject_keys)) THEN
            RAISE EXCEPTION 'M31_MEMBER_KEY: rule % does not project the declared identity columns',
                member_row.member_name;
        END IF;
        FOR match_row IN EXECUTE format(
            'SELECT %1$I::bigint AS semantic_key, to_jsonb(m) AS bindings FROM %2$s m',
            version_row.key_column, version_row.match_relid::regclass)
        LOOP
            canonical := pgreact_internal.canonical_bigint_v1(match_row.semantic_key);
            digest := pgreact_internal.activation_digest(target_rule_version, canonical);
            activation := pgreact_internal.activation_uuid(digest);
            SELECT * INTO state_row
            FROM pgreact_internal.activation_state
            WHERE rule_version_id = target_rule_version AND activation_id = activation
            FOR UPDATE;
            IF NOT FOUND THEN
                INSERT INTO pgreact_internal.activation_state(
                    rule_version_id, activation_id, semantic_key, canonical_key,
                    canonical_key_digest, key_codec_version, active, generation,
                    current_bindings, last_active_bindings, first_seen_at, last_seen_at)
                VALUES (target_rule_version, activation, match_row.semantic_key,
                        canonical, digest, 1, false, 1, match_row.bindings,
                        NULL, clock_timestamp(), clock_timestamp())
                RETURNING * INTO state_row;
            ELSE
                UPDATE pgreact_internal.activation_state
                SET current_bindings = match_row.bindings,
                    last_seen_at = clock_timestamp()
                WHERE rule_version_id = target_rule_version
                  AND activation_id = activation;
                state_row.current_bindings := match_row.bindings;
            END IF;
            match_values := pgreact_internal.m31_binding_values(
                match_row.bindings, member_row.match_keys);
            subject_values := pgreact_internal.m31_binding_values(
                match_row.bindings, COALESCE(member_row.subject_keys,
                                             member_row.set_subject_keys));
            seen_activations := array_append(seen_activations, activation);
            computed_match_identity := pgreact_internal.m30_key_identity(match_types, match_values);
            computed_subject_identity := pgreact_internal.m30_key_identity(subject_types, subject_values);
            IF EXISTS (
                SELECT 1 FROM pgreact_internal.policy_set_runtime_barriers barrier
                WHERE barrier.policy_set_version_id = member_row.policy_set_version_id
                  AND barrier.cleared_at IS NULL)
            THEN
                NULL;
            ELSIF NOT EXISTS (
                SELECT 1 FROM pgreact_internal.policy_set_eligibility eligibility
                WHERE eligibility.policy_set_version_id = member_row.policy_set_version_id
                  AND eligibility.subject_identity = computed_subject_identity)
            THEN
                FOR support_row IN SELECT *
                    FROM pgreact_internal.policy_set_scope_supports
                    WHERE policy_set_version_id = member_row.policy_set_version_id
                      AND member_kind = member_row.member_kind
                      AND member_name = member_row.member_name
                      AND member_version = member_row.member_version
                      AND match_identity = computed_match_identity
                FOR UPDATE LOOP
                    PERFORM pgreact_internal.m31_remove_support(
                        support_row.scope_support_id, 'subject_not_eligible');
                END LOOP;
            ELSE
                PERFORM pgreact_internal.m31_upsert_support(
                    member_row.policy_set_version_id, member_row.member_kind,
                    member_row.member_name, member_row.member_version, activation,
                    computed_match_identity, computed_subject_identity, subject_values,
                    member_row.complete_frontier);
            END IF;
        END LOOP;
    END LOOP;

    UPDATE pgreact_internal.activation_state
    SET current_bindings = NULL, last_seen_at = clock_timestamp()
    WHERE rule_version_id = target_rule_version
      AND current_bindings IS NOT NULL
      AND NOT (activation_id = ANY(seen_activations));

    FOR support_row IN
        SELECT support.*
        FROM pgreact_internal.policy_set_scope_supports support
        WHERE support.member_kind = 'rule'
          AND support.member_name = (SELECT rule_name FROM pgreact_internal.rules
                                     WHERE rule_id = version_row.rule_id)
          AND support.member_version IN ('1', target_rule_version::text)
          AND (target_set_version IS NULL
               OR support.policy_set_version_id = target_set_version)
          AND EXISTS (
              SELECT 1
              FROM pgreact_internal.policy_set_members member
              WHERE member.policy_set_version_id = support.policy_set_version_id
                AND member.member_kind = 'rule'
                AND member.member_name = support.member_name
                AND member.member_version = support.member_version
                AND member.scope_mode = 'POLICY_SET_REQUIRED')
          AND NOT EXISTS (
              SELECT 1
              FROM pgreact_internal.policy_set_runtime_barriers barrier
              WHERE barrier.policy_set_version_id = support.policy_set_version_id
                AND barrier.cleared_at IS NULL)
          AND NOT EXISTS (
              SELECT 1 FROM pgreact_internal.activation_state state
              WHERE state.rule_version_id = target_rule_version
                AND state.activation_id = support.activation_id
                AND state.current_bindings IS NOT NULL)
    LOOP
        PERFORM pgreact_internal.m31_remove_support(
            support_row.scope_support_id, 'match_removed');
    END LOOP;

    FOR state_row IN
        SELECT * FROM pgreact_internal.activation_state
        WHERE rule_version_id = target_rule_version
          AND (current_bindings IS NOT NULL OR active)
        FOR UPDATE
    LOOP
        SELECT count(*) INTO support_count
        FROM pgreact_internal.policy_set_scope_supports
        WHERE activation_id = state_row.activation_id;
        IF state_row.current_bindings IS NOT NULL AND support_count > 0
           AND NOT state_row.active THEN
            UPDATE pgreact_internal.activation_state
            SET active = true, generation = generation + 1,
                last_active_bindings = current_bindings,
                last_seen_at = clock_timestamp(), deactivated_at = NULL
            WHERE rule_version_id = target_rule_version
              AND activation_id = state_row.activation_id;
            PERFORM pgreact_internal.emit_event(
                version_row, state_row.activation_id, state_row.generation + 1,
                0, 'ACTIVATE', NULL, state_row.current_bindings);
            transitioned := transitioned + 1;
        ELSIF support_count = 0 AND state_row.active THEN
            UPDATE pgreact_internal.activation_state
            SET active = false, current_bindings = NULL,
                deactivated_at = clock_timestamp(), last_seen_at = clock_timestamp()
            WHERE rule_version_id = target_rule_version
              AND activation_id = state_row.activation_id;
            UPDATE pgreact_internal.agenda
            SET state = 'WITHDRAWN', completed_at = clock_timestamp(),
                lease_token = NULL, worker_id = NULL, lease_expires_at = NULL
            WHERE rule_version_id = target_rule_version
              AND activation_id = state_row.activation_id
              AND activation_generation = state_row.generation
              AND state IN ('PENDING', 'RETRY_WAIT', 'LEASED');
            PERFORM pgreact_internal.emit_event(
                version_row, state_row.activation_id, state_row.generation,
                0, 'DEACTIVATE', state_row.last_active_bindings, NULL);
            transitioned := transitioned + 1;
        END IF;
    END LOOP;
    RETURN transitioned;
END
$m31$;

CREATE FUNCTION pgreact_internal.m31_reconcile_decision_program(
    target_set_version uuid,
    target_member_name text,
    target_member_version text,
    sampled_time timestamptz)
RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $m31$
DECLARE target_program_id uuid;
    decision_version pgreact_internal.decision_program_versions%ROWTYPE;
    state_row pgreact_internal.decision_subject_state%ROWTYPE;
    support_row pgreact_internal.policy_set_scope_supports%ROWTYPE;
    eligible_row record;
    match_identity bytea;
    set_effective boolean := false;
    changed bigint := 0;
BEGIN
    PERFORM pg_advisory_xact_lock(5788046901200000);
    PERFORM pg_advisory_xact_lock(5788046901200004);
    SELECT program_id INTO target_program_id
    FROM pgreact_internal.decision_programs
    WHERE program_name = target_member_name AND state <> 'REMOVED';
    IF NOT FOUND THEN RETURN 0; END IF;
    PERFORM pg_advisory_xact_lock(hashtextextended(
        'm31:decision:' || target_program_id::text, 5788046901200005));

    SELECT state = 'DEPLOYED'
       AND valid_from <= sampled_time
       AND (valid_to IS NULL OR sampled_time < valid_to)
    INTO set_effective
    FROM pgreact_internal.policy_set_versions
    WHERE policy_set_version_id = target_set_version;

    BEGIN
        PERFORM pgreact_internal.refresh_decision_program(target_program_id, sampled_time);
    EXCEPTION WHEN OTHERS THEN
        INSERT INTO pgreact_internal.policy_set_runtime_barriers(
            policy_set_version_id, code, details, cleared_at)
        VALUES (target_set_version, 'M31_DECISION_UNAVAILABLE',
                jsonb_build_object('message', SQLERRM,
                                   'member_name', target_member_name), NULL)
        ON CONFLICT (policy_set_version_id) DO UPDATE SET
            code = EXCLUDED.code, details = EXCLUDED.details,
            created_at = clock_timestamp(), cleared_at = NULL;
        UPDATE pgreact_internal.decision_work work
        SET claimable = state.state = 'WINNER' AND EXISTS (
                SELECT 1
                FROM pgreact_internal.decision_subject_state state
                JOIN pgreact_internal.policy_set_scope_supports support
                  ON support.activation_id = state.activation_id
                 AND support.member_kind = 'decision_program'
                 AND support.member_name = target_member_name
                WHERE state.program_id = target_program_id
                  AND support.member_version = target_member_version
                  AND NOT EXISTS (
                      SELECT 1
                      FROM pgreact_internal.policy_set_runtime_barriers barrier
                      WHERE barrier.policy_set_version_id = support.policy_set_version_id
                        AND barrier.cleared_at IS NULL)),
            updated_at = clock_timestamp()
        FROM pgreact_internal.decision_subject_state state
        WHERE work.program_id = target_program_id
          AND work.subject_key = state.subject_key;
        RETURN 0;
    END;

    SELECT version.* INTO decision_version
    FROM pgreact_internal.decision_program_versions version
    WHERE version.program_id = target_program_id
      AND version.state = 'DEPLOYED'
      AND version.valid_from <= sampled_time
      AND (version.valid_to IS NULL OR sampled_time < version.valid_to)
      AND (target_member_version IS NULL
           OR target_member_version IN (version.version_id::text,
                                        version.version_no::text))
    ORDER BY version.valid_from DESC, version.version_no DESC
    LIMIT 1;

    IF NOT FOUND THEN
        FOR support_row IN
            SELECT support.*
            FROM pgreact_internal.policy_set_scope_supports support
            WHERE support.policy_set_version_id = target_set_version
              AND support.member_kind = 'decision_program'
              AND support.member_name = target_member_name
              AND support.member_version = target_member_version
            FOR UPDATE
        LOOP
            PERFORM pgreact_internal.m31_remove_support(
                support_row.scope_support_id, 'decision_version_not_effective');
        END LOOP;
    ELSE
        IF set_effective AND NOT EXISTS (
            SELECT 1 FROM pgreact_internal.policy_set_runtime_barriers barrier
            WHERE barrier.policy_set_version_id = target_set_version
              AND barrier.cleared_at IS NULL) THEN
            FOR state_row IN
            SELECT state.*
            FROM pgreact_internal.decision_subject_state state
            WHERE state.program_id = target_program_id
            FOR UPDATE
        LOOP
            IF state_row.state = 'WINNER'
               AND state_row.version_id = decision_version.version_id
               AND state_row.activation_id IS NOT NULL THEN
                SELECT eligibility.subject_identity, eligibility.subject_values
                INTO eligible_row
                FROM pgreact_internal.policy_set_eligibility eligibility
                WHERE eligibility.policy_set_version_id = target_set_version
                  AND eligibility.subject_values = jsonb_build_array(state_row.subject_key)
                LIMIT 1;
                IF FOUND THEN
                    match_identity := pgreact_internal.m30_key_identity(
                        ARRAY['bigint']::text[],
                        jsonb_build_array(state_row.winner_candidate));
                    PERFORM pgreact_internal.m31_upsert_support(
                        target_set_version, 'decision_program', target_member_name,
                        target_member_version, state_row.activation_id, match_identity,
                        eligible_row.subject_identity, eligible_row.subject_values,
                        (SELECT complete_frontier
                         FROM pgreact_internal.policy_set_versions
                         WHERE policy_set_version_id = target_set_version));
                END IF;
            END IF;
            END LOOP;
        END IF;
    END IF;

    FOR support_row IN
        SELECT support.*
        FROM pgreact_internal.policy_set_scope_supports support
        WHERE support.policy_set_version_id = target_set_version
          AND support.member_kind = 'decision_program'
          AND support.member_name = target_member_name
          AND support.member_version = target_member_version
          AND NOT EXISTS (
              SELECT 1
              FROM pgreact_internal.policy_set_runtime_barriers barrier
              WHERE barrier.policy_set_version_id = target_set_version
                AND barrier.cleared_at IS NULL)
          AND NOT EXISTS (
              SELECT 1
              FROM pgreact_internal.decision_subject_state state
              JOIN pgreact_internal.policy_set_eligibility eligibility
                ON eligibility.policy_set_version_id = target_set_version
               AND eligibility.subject_values = jsonb_build_array(state.subject_key)
              WHERE state.program_id = target_program_id
                AND state.version_id = decision_version.version_id
                AND state.state = 'WINNER'
                AND state.activation_id = support.activation_id
                AND eligibility.subject_identity = support.subject_identity)
        FOR UPDATE
    LOOP
        PERFORM pgreact_internal.m31_remove_support(
            support_row.scope_support_id, 'decision_winner_or_subject_removed');
    END LOOP;

    UPDATE pgreact_internal.decision_work work
    SET activation_id = state.activation_id,
        claimable = state.state = 'WINNER'
                    AND EXISTS (
                        SELECT 1
                        FROM pgreact_internal.policy_set_scope_supports support
                        WHERE support.activation_id = state.activation_id
                          AND support.member_kind = 'decision_program'
                          AND support.member_name = target_member_name
                          AND NOT EXISTS (
                              SELECT 1
                              FROM pgreact_internal.policy_set_runtime_barriers barrier
                              WHERE barrier.policy_set_version_id = support.policy_set_version_id
                                AND barrier.cleared_at IS NULL)),
        state = state.state,
        updated_at = clock_timestamp()
    FROM pgreact_internal.decision_subject_state state
    WHERE work.program_id = target_program_id
      AND work.subject_key = state.subject_key;
    GET DIAGNOSTICS changed = ROW_COUNT;
    RETURN changed;
END
$m31$;

CREATE FUNCTION pgreact_internal.m31_reconcile_policy_set(
    target_set_version uuid, sampled_time timestamptz)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $m31$
DECLARE refreshed boolean;
    member_row record;
    support_row record;
    rule_row record;
    changed bigint := 0;
BEGIN
    PERFORM pg_advisory_xact_lock(5788046901200000);
    refreshed := pgreact_internal.m31_refresh_policy_set(target_set_version, sampled_time);
    IF NOT refreshed THEN
        FOR member_row IN
            SELECT DISTINCT member.member_name, member.member_version
            FROM pgreact_internal.policy_set_members member
            WHERE member.policy_set_version_id = target_set_version
              AND member.member_kind = 'rule'
              AND member.scope_mode = 'POLICY_SET_REQUIRED'
        LOOP
            FOR rule_row IN
                SELECT version.rule_version_id
                FROM pgreact_internal.rule_versions version
                JOIN pgreact_internal.rules rule USING (rule_id)
                JOIN pgreact_internal.api_declarations declaration
                  ON declaration.kind = 'rule'
                 AND declaration.object_name = rule.rule_name
                 AND declaration.state = 'DEPLOYED'
                 AND declaration.delegated_id = version.rule_version_id
                WHERE rule.rule_name = member_row.member_name
                  AND version.state <> 'REMOVED'
                  AND member_row.member_version IN ('1', version.rule_version_id::text)
            LOOP
                changed := changed + pgreact_internal.m31_reconcile_rule(
                    rule_row.rule_version_id, sampled_time, target_set_version);
            END LOOP;
        END LOOP;
        FOR member_row IN
            SELECT DISTINCT member.member_name, member.member_version
            FROM pgreact_internal.policy_set_members member
            WHERE member.policy_set_version_id = target_set_version
              AND member.member_kind = 'decision_program'
              AND member.scope_mode = 'POLICY_SET_REQUIRED'
        LOOP
            changed := changed + pgreact_internal.m31_reconcile_decision_program(
                target_set_version, member_row.member_name, member_row.member_version,
                sampled_time);
        END LOOP;
        RETURN jsonb_build_object('runtime_state', 'BLOCKED', 'changed', 0);
    END IF;
    FOR member_row IN
        SELECT DISTINCT version.rule_version_id
        FROM pgreact_internal.policy_set_members member
        JOIN pgreact_internal.rules rule
          ON member.member_kind = 'rule' AND rule.rule_name = member.member_name
        JOIN pgreact_internal.rule_versions version
          ON version.rule_id = rule.rule_id
         AND version.state <> 'REMOVED'
        JOIN pgreact_internal.api_declarations declaration
          ON declaration.kind = 'rule'
         AND declaration.object_name = rule.rule_name
         AND declaration.state = 'DEPLOYED'
         AND declaration.delegated_id = version.rule_version_id
        WHERE member.policy_set_version_id = target_set_version
          AND member.scope_mode = 'POLICY_SET_REQUIRED'
          AND member.member_version IN ('1', version.rule_version_id::text)
    LOOP
        changed := changed + pgreact_internal.m31_reconcile_rule(
            member_row.rule_version_id, sampled_time, target_set_version);
    END LOOP;
    FOR member_row IN
        SELECT member.member_name, member.member_version
        FROM pgreact_internal.policy_set_members member
        WHERE member.policy_set_version_id = target_set_version
          AND member.member_kind = 'decision_program'
          AND member.scope_mode = 'POLICY_SET_REQUIRED'
    LOOP
        changed := changed + pgreact_internal.m31_reconcile_decision_program(
            target_set_version, member_row.member_name, member_row.member_version,
            sampled_time);
    END LOOP;
    IF EXISTS (
        SELECT 1 FROM pgreact_internal.policy_set_runtime_barriers barrier
        WHERE barrier.policy_set_version_id = target_set_version
          AND barrier.cleared_at IS NULL) THEN
        RETURN jsonb_build_object('runtime_state', 'BLOCKED', 'changed', changed);
    END IF;
    RETURN jsonb_build_object('runtime_state', 'AUTHORITATIVE', 'changed', changed);
END
$m31$;

CREATE FUNCTION pgreact_internal.m31_expire_policy_set(
    target_set_version uuid, sampled_time timestamptz)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $m31$
DECLARE member_row record;
    version_row pgreact_internal.policy_set_versions%ROWTYPE;
    support_row record;
    changed bigint := 0;
    removed_count bigint := 0;
BEGIN
    PERFORM pg_advisory_xact_lock(5788046901200000);
    PERFORM pg_advisory_xact_lock(5788046901200004);
    SELECT version.* INTO version_row
    FROM pgreact_internal.policy_set_versions version
    WHERE version.policy_set_version_id = target_set_version
      AND version.state = 'DEPLOYED'
      AND version.valid_to IS NOT NULL
      AND version.valid_to <= sampled_time
    FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('runtime_state', 'BLOCKED', 'changed', 0,
                                  'effective_at', sampled_time,
                                  'reason', 'expiry_not_due');
    END IF;
    FOR support_row IN DELETE FROM pgreact_internal.policy_set_scope_supports
        WHERE policy_set_version_id = target_set_version RETURNING * LOOP
        removed_count := removed_count + 1;
        INSERT INTO pgreact_internal.policy_set_scope_support_history(
            scope_support_id, policy_set_version_id, member_kind, member_name,
            member_version, match_identity, subject_identity, event_kind,
            complete_frontier, details)
        VALUES (support_row.scope_support_id, support_row.policy_set_version_id,
                support_row.member_kind, support_row.member_name,
                support_row.member_version, support_row.match_identity,
                support_row.subject_identity, 'REMOVED', support_row.complete_frontier,
                jsonb_build_object('reason', 'set_not_effective_at_sampled_time'));
    END LOOP;
    FOR member_row IN SELECT DISTINCT member_name, member_version
        FROM pgreact_internal.policy_set_members
        WHERE policy_set_version_id = target_set_version
          AND member_kind = 'rule'
          AND scope_mode = 'POLICY_SET_REQUIRED' LOOP
        FOR support_row IN SELECT version.rule_version_id
            FROM pgreact_internal.rule_versions version
            JOIN pgreact_internal.rules rule USING (rule_id)
            JOIN pgreact_internal.api_declarations declaration
              ON declaration.kind = 'rule'
             AND declaration.object_name = rule.rule_name
             AND declaration.state = 'DEPLOYED'
             AND declaration.delegated_id = version.rule_version_id
            WHERE rule.rule_name = member_row.member_name AND version.state <> 'REMOVED'
              AND member_row.member_version IN ('1', version.rule_version_id::text)
    LOOP
        changed := changed + pgreact_internal.m31_reconcile_rule(
            support_row.rule_version_id, sampled_time, target_set_version);
    END LOOP;
    END LOOP;
    FOR member_row IN SELECT DISTINCT member_name, member_version
        FROM pgreact_internal.policy_set_members
        WHERE policy_set_version_id = target_set_version
          AND member_kind = 'decision_program'
          AND scope_mode = 'POLICY_SET_REQUIRED' LOOP
        changed := changed + pgreact_internal.m31_reconcile_decision_program(
            target_set_version, member_row.member_name, member_row.member_version,
            sampled_time);
    END LOOP;
    IF removed_count > 0 OR changed > 0 THEN
        INSERT INTO pgreact_internal.policy_set_history(
            policy_set_version_id, event_kind, frontier, details)
        VALUES (target_set_version, 'EXPIRED',
                (SELECT frontier FROM pgreact_internal.clock_frontier WHERE singleton),
                jsonb_build_object('sampled_time', sampled_time, 'changed', changed));
    END IF;
    RETURN jsonb_build_object('runtime_state', 'AUTHORITATIVE', 'changed', changed,
                              'effective_at', sampled_time);
END
$m31$;

CREATE FUNCTION pgreact_internal.m31_policy_status(target pgreact_api.target)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $m31$
DECLARE result jsonb := pgreact_internal.m30_status(target);
    version_id uuid;
    support_count bigint;
    barrier_count bigint;
BEGIN
    version_id := NULLIF(result -> 'summary' ->> 'policy_set_version_id', '')::uuid;
    SELECT count(*) INTO support_count FROM pgreact_internal.policy_set_scope_supports
    WHERE policy_set_version_id = version_id;
    SELECT count(*) INTO barrier_count FROM pgreact_internal.policy_set_runtime_barriers
    WHERE policy_set_version_id = version_id AND cleared_at IS NULL;
    RETURN result || jsonb_build_object(
        'summary', (result -> 'summary') || jsonb_build_object(
            'runtime_state', CASE WHEN barrier_count > 0 THEN 'BLOCKED' ELSE 'AUTHORITATIVE' END,
            'scope_support_count', support_count,
            'runtime_barrier_count', barrier_count),
        'evidence', (result -> 'evidence') || jsonb_build_object(
            'effective_truth', jsonb_build_object('scope_supports', support_count),
            'work_recheck', jsonb_build_object(
                'state', CASE WHEN barrier_count > 0 THEN 'BLOCKED' ELSE 'AUTHORITATIVE' END)));
END
$m31$;

CREATE FUNCTION pgreact_internal.m31_rule_status(target pgreact_api.target)
RETURNS jsonb
LANGUAGE SQL STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $m31$
    SELECT pgreact_internal.m30_envelope(
        'status', declaration.normalized,
        CASE version.state WHEN 'ACTIVE' THEN 'deployed' WHEN 'PAUSED' THEN 'paused'
                           ELSE lower(version.state) END,
        jsonb_build_object(
            'read_only', true,
            'runtime_state', CASE WHEN EXISTS (
                SELECT 1
                FROM pgreact_internal.policy_set_members member
                JOIN pgreact_internal.policy_set_versions set_version
                  USING (policy_set_version_id)
                JOIN pgreact_internal.policy_set_runtime_barriers barrier
                  ON barrier.policy_set_version_id = set_version.policy_set_version_id
                 AND barrier.cleared_at IS NULL
                WHERE member.member_kind = 'rule'
                  AND member.member_name = declaration.object_name
                  AND member.member_version IN ('1', version.rule_version_id::text)
                  AND member.scope_mode = 'POLICY_SET_REQUIRED'
                  AND set_version.state = 'DEPLOYED'
                  AND set_version.valid_from <= clock_timestamp()
                  AND (set_version.valid_to IS NULL
                       OR clock_timestamp() < set_version.valid_to))
                THEN 'BLOCKED' ELSE 'AUTHORITATIVE' END,
            'delegated_id', version.rule_version_id,
            'source_view', version.source_view_name,
            'active_activation_count', (SELECT count(*)
                FROM pgreact_internal.activation_state state
                WHERE state.rule_version_id = version.rule_version_id
                  AND state.active
                  AND (
                      NOT EXISTS (
                          SELECT 1
                          FROM pgreact_internal.policy_set_members member
                          JOIN pgreact_internal.policy_set_versions set_version
                            USING (policy_set_version_id)
                          WHERE member.member_kind = 'rule'
                            AND member.member_name = declaration.object_name
                            AND member.member_version IN ('1', version.rule_version_id::text)
                            AND member.scope_mode = 'POLICY_SET_REQUIRED'
                            AND set_version.state = 'DEPLOYED'
                            AND set_version.valid_from <= clock_timestamp()
                            AND (set_version.valid_to IS NULL
                                 OR clock_timestamp() < set_version.valid_to))
                      OR EXISTS (
                          SELECT 1
                          FROM pgreact_internal.policy_set_scope_supports support
                          JOIN pgreact_internal.policy_set_members member
                            ON member.policy_set_version_id = support.policy_set_version_id
                           AND member.member_kind = 'rule'
                           AND member.member_name = declaration.object_name
                           AND member.member_version IN ('1', version.rule_version_id::text)
                           AND member.scope_mode = 'POLICY_SET_REQUIRED'
                          JOIN pgreact_internal.policy_set_versions set_version
                            ON set_version.policy_set_version_id = support.policy_set_version_id
                           AND set_version.state = 'DEPLOYED'
                           AND set_version.valid_from <= clock_timestamp()
                           AND (set_version.valid_to IS NULL
                                OR clock_timestamp() < set_version.valid_to)
                          WHERE support.activation_id = state.activation_id
                            AND NOT EXISTS (
                                SELECT 1
                                FROM pgreact_internal.policy_set_runtime_barriers barrier
                                WHERE barrier.policy_set_version_id = support.policy_set_version_id
                                  AND barrier.cleared_at IS NULL)
                      )
                  )),
            'raw_active_activation_count', (SELECT count(*)
                FROM pgreact_internal.activation_state state
                WHERE state.rule_version_id = version.rule_version_id
                  AND state.active)),
        '[]'::jsonb,
        jsonb_build_object('normalized_declaration', declaration.normalized,
                           'runtime', to_jsonb(version)))
    FROM pgreact_internal.api_declarations declaration
    JOIN pgreact_internal.rule_versions version
      ON version.rule_version_id = declaration.delegated_id
    WHERE declaration.kind = 'rule' AND declaration.object_name = ($1).name
      AND (($1).version IS NULL OR ($1).version IN ('1', version.rule_version_id::text))
      AND declaration.state = 'DEPLOYED'
    ORDER BY version.created_at DESC LIMIT 1
$m31$;

CREATE FUNCTION pgreact_internal.m31_decision_status(target pgreact_api.target)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $m31$
DECLARE result jsonb := pgreact_api.decision_status((target).name);
    support_count bigint;
    barrier_count bigint;
    policy_set_count bigint;
    barriers jsonb;
BEGIN
    SELECT count(DISTINCT version.policy_set_version_id),
           count(DISTINCT barrier.policy_set_version_id)
    INTO policy_set_count, barrier_count
    FROM pgreact_internal.policy_set_members member
    JOIN pgreact_internal.policy_set_versions version USING (policy_set_version_id)
    LEFT JOIN pgreact_internal.policy_set_runtime_barriers barrier
      ON barrier.policy_set_version_id = version.policy_set_version_id
     AND barrier.cleared_at IS NULL
    WHERE member.member_kind = 'decision_program'
      AND member.member_name = (target).name
      AND member.scope_mode = 'POLICY_SET_REQUIRED'
      AND version.state = 'DEPLOYED'
      AND ((target).version IS NULL OR version.version = (target).version);
    SELECT count(*) INTO support_count
    FROM pgreact_internal.policy_set_scope_supports support
    WHERE support.member_kind = 'decision_program'
      AND support.member_name = (target).name;
    SELECT COALESCE(jsonb_agg(to_jsonb(barrier) ORDER BY barrier.created_at), '[]'::jsonb)
    INTO barriers
    FROM pgreact_internal.policy_set_runtime_barriers barrier
    JOIN pgreact_internal.policy_set_members member
      ON member.policy_set_version_id = barrier.policy_set_version_id
     AND member.member_kind = 'decision_program'
     AND member.member_name = (target).name
     AND member.scope_mode = 'POLICY_SET_REQUIRED'
    WHERE barrier.cleared_at IS NULL;
    RETURN result || jsonb_build_object(
        'operation', 'status',
        'target', jsonb_build_object('kind', (target).kind, 'name', (target).name,
                                     'version', (target).version),
        'summary', jsonb_build_object(
            'runtime_state', CASE WHEN barrier_count > 0 THEN 'BLOCKED'
                                  ELSE 'AUTHORITATIVE' END,
            'policy_set_count', policy_set_count,
            'scope_support_count', support_count,
            'runtime_barrier_count', barrier_count),
        'evidence', jsonb_build_object(
            'effective_truth', jsonb_build_object('scope_supports', support_count),
            'work_recheck', jsonb_build_object(
                'state', CASE WHEN barrier_count > 0 THEN 'BLOCKED'
                              ELSE 'AUTHORITATIVE' END),
            'runtime_barriers', barriers));
END
$m31$;

CREATE FUNCTION pgreact_internal.m31_decision_explain(
    target pgreact_api.target, subject jsonb DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $m31$
DECLARE result jsonb;
    subject_key bigint;
    runtime_status jsonb;
BEGIN
    runtime_status := pgreact_internal.m31_decision_status(target);
    IF subject IS NULL THEN
        RETURN runtime_status || jsonb_build_object('operation', 'explain');
    END IF;
    IF jsonb_typeof(subject) = 'object' THEN
        subject_key := (subject ->> 'subject')::bigint;
    ELSE
        subject_key := (subject #>> '{}')::bigint;
    END IF;
    result := pgreact_api.decision_explain((target).name, subject_key);
    RETURN result || jsonb_build_object(
        'operation', 'explain',
        'target', jsonb_build_object('kind', (target).kind, 'name', (target).name,
                                     'version', (target).version),
        'runtime', runtime_status -> 'summary');
END
$m31$;

CREATE FUNCTION pgreact_internal.m31_decision_doctor(target pgreact_api.target)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $m31$
DECLARE result jsonb := pgreact_api.decision_doctor();
    status jsonb := pgreact_internal.m31_decision_status(target);
    diagnostics jsonb;
BEGIN
    diagnostics := COALESCE((
        SELECT jsonb_agg(diagnostic ORDER BY ordinal)
        FROM jsonb_array_elements(COALESCE(result -> 'diagnostics', '[]'::jsonb))
             WITH ORDINALITY rows(diagnostic, ordinal)
        WHERE diagnostic ->> 'code' <> 'M26_EXTENSION_VERSION'), '[]'::jsonb);
    IF status -> 'summary' ->> 'runtime_state' = 'BLOCKED' THEN
        diagnostics := diagnostics || jsonb_build_array(jsonb_build_object(
            'code', 'M31_RUNTIME_BLOCKED', 'severity', 'ERROR', 'blocker', true,
            'object_identity', (target).name,
            'message', 'decision runtime is blocked by a policy-set barrier',
            'hint', 'Repair the policy-set source and run the policy set again.',
            'details', status -> 'evidence' -> 'runtime_barriers'));
    END IF;
    RETURN result || jsonb_build_object(
        'status', CASE WHEN status -> 'summary' ->> 'runtime_state' = 'BLOCKED'
                       THEN 'attention' ELSE result ->> 'status' END,
        'diagnostics', diagnostics,
        'operation', 'doctor',
        'target', jsonb_build_object('kind', (target).kind, 'name', (target).name,
                                     'version', (target).version),
        'runtime', status -> 'summary');
END
$m31$;

CREATE FUNCTION pgreact_internal.m31_rule_explain(
    target pgreact_api.target, subject jsonb, options jsonb)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $m31$
DECLARE result jsonb := pgreact_api.explain_m30(target, subject, options);
    status jsonb := pgreact_internal.m31_rule_status(target);
BEGIN
    RETURN result || jsonb_build_object(
        'operation', 'explain',
        'runtime', status -> 'summary',
        'evidence', COALESCE(result -> 'evidence', '{}'::jsonb) ||
            jsonb_build_object('runtime_state', status -> 'summary' ->> 'runtime_state'));
END
$m31$;

CREATE FUNCTION pgreact_internal.m31_rule_doctor(target pgreact_api.target)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $m31$
DECLARE result jsonb := pgreact_api.doctor_m30(target, '{}'::jsonb);
    status jsonb := pgreact_internal.m31_rule_status(target);
    diagnostics jsonb := COALESCE(result -> 'diagnostics', '[]'::jsonb);
BEGIN
    IF status -> 'summary' ->> 'runtime_state' = 'BLOCKED' THEN
        diagnostics := diagnostics || jsonb_build_array(jsonb_build_object(
            'code', 'M31_RUNTIME_BLOCKED', 'severity', 'ERROR', 'blocker', true,
            'object_identity', (target).name,
            'message', 'rule runtime is blocked by a policy-set barrier',
            'hint', 'Repair the policy-set source and run the policy set again.'));
    END IF;
    RETURN result || jsonb_build_object(
        'operation', 'doctor',
        'target', jsonb_build_object('kind', (target).kind, 'name', (target).name,
                                     'version', (target).version),
        'runtime', status -> 'summary',
        'diagnostics', diagnostics);
END
$m31$;

CREATE FUNCTION pgreact_internal.m31_doctor(target pgreact_api.target)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $m31$
DECLARE result jsonb := pgreact_internal.m31_policy_status(target);
    base_result jsonb := pgreact_internal.m30_doctor(target);
    version_id uuid;
    diagnostics jsonb;
    barrier_count bigint;
BEGIN
    version_id := NULLIF(result -> 'summary' ->> 'policy_set_version_id', '')::uuid;
    diagnostics := COALESCE(base_result -> 'diagnostics', '[]'::jsonb);
    SELECT count(*) INTO barrier_count FROM pgreact_internal.policy_set_runtime_barriers
    WHERE policy_set_version_id = version_id AND cleared_at IS NULL;
    IF barrier_count > 0 THEN
        diagnostics := diagnostics || jsonb_build_array(jsonb_build_object(
                'code', 'M31_RUNTIME_BLOCKED', 'severity', 'ERROR', 'blocker', true,
                'object_identity', (target).name,
                'message', 'runtime authority is blocked by an applicability barrier',
                'hint', 'Repair the source and run the policy set again.',
                'details', (SELECT jsonb_agg(to_jsonb(barrier))
                            FROM pgreact_internal.policy_set_runtime_barriers barrier
                            WHERE barrier.policy_set_version_id = version_id
                              AND barrier.cleared_at IS NULL)));
    END IF;
    IF barrier_count = 0 AND NOT EXISTS (
        SELECT 1
        FROM jsonb_array_elements(diagnostics) diagnostic
        WHERE diagnostic ->> 'severity' = 'ERROR') THEN
        diagnostics := jsonb_build_array(jsonb_build_object(
            'code', 'M31_RUNTIME_READY', 'severity', 'INFO', 'blocker', false,
            'object_identity', (target).name,
            'message', 'eligibility and effective runtime state agree',
            'hint', 'Use run after an applicability change.'));
    END IF;
    RETURN result || jsonb_build_object(
        'operation', 'doctor', 'diagnostics', diagnostics);
END
$m31$;

ALTER FUNCTION pgreact_api.validate(pgreact_api.declaration) RENAME TO validate_m30;
ALTER FUNCTION pgreact_api.preview(pgreact_api.declaration, jsonb) RENAME TO preview_m30;
ALTER FUNCTION pgreact_api.deploy(pgreact_api.declaration, jsonb) RENAME TO deploy_m30;
ALTER FUNCTION pgreact_api.status(pgreact_api.target, jsonb) RENAME TO status_m30;
ALTER FUNCTION pgreact_api.explain(pgreact_api.target, jsonb, jsonb) RENAME TO explain_m30;
ALTER FUNCTION pgreact_api.doctor(pgreact_api.target, jsonb) RENAME TO doctor_m30;
ALTER FUNCTION pgreact_api.run(pgreact_api.target, timestamptz) RENAME TO run_m30;
ALTER FUNCTION pgreact_api.remove(pgreact_api.target, jsonb) RENAME TO remove_m30;

CREATE FUNCTION pgreact_api.validate(declaration pgreact_api.declaration)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $m31$
DECLARE result jsonb := pgreact_api.validate_m30(declaration);
BEGIN
    IF (declaration).kind NOT IN ('rule', 'decision_program', 'policy_set') THEN
        result := result || jsonb_build_object(
            'state', 'attention',
            'findings', COALESCE(result -> 'findings', '[]'::jsonb) || jsonb_build_array(
                pgreact_internal.m30_finding('M31_UNSUPPORTED_KIND', 'ERROR',
                    COALESCE((declaration).name, '<unnamed>'), 'kind',
                    'generic M31 runtime has no authoritative adapter for this kind',
                    'Use the specialized API or wait for the documented adapter.')));
    ELSIF COALESCE((declaration).spec ->> 'delegate', 'true') = 'false'
          AND (declaration).kind IN ('rule', 'decision_program') THEN
        result := result || jsonb_build_object(
            'state', 'attention',
            'findings', COALESCE(result -> 'findings', '[]'::jsonb) || jsonb_build_array(
                pgreact_internal.m30_finding('M31_ADAPTER_REQUIRED', 'ERROR',
                    (declaration).name, 'spec.delegate',
                    'authoritative runtime delegation is required',
                    'Deploy with delegate true or use the specialized API.')));
    END IF;
    RETURN result;
END
$m31$;

CREATE FUNCTION pgreact_api.preview(
    declaration pgreact_api.declaration, options jsonb DEFAULT '{}'::jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $m31$
DECLARE result jsonb := pgreact_api.preview_m30(declaration, options);
    validation jsonb;
BEGIN
    validation := pgreact_api.validate(declaration);
    IF validation -> 'findings' IS DISTINCT FROM '[]'::jsonb THEN
        result := result || jsonb_build_object('state', 'attention',
            'findings', validation -> 'findings');
    END IF;
    RETURN result;
END
$m31$;

CREATE FUNCTION pgreact_api.deploy(
    declaration pgreact_api.declaration, preconditions jsonb DEFAULT '{}'::jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $m31$
DECLARE result jsonb;
    runtime jsonb;
    set_row record;
    runtimes jsonb := '[]'::jsonb;
BEGIN
    PERFORM pg_advisory_xact_lock(5788046901200000);
    IF (declaration).kind NOT IN ('rule', 'decision_program', 'policy_set') THEN
        RAISE EXCEPTION 'M31_UNSUPPORTED_KIND: generic deployment has no authoritative adapter for %',
            (declaration).kind;
    END IF;
    IF COALESCE((declaration).spec ->> 'delegate', 'true') = 'false'
       AND (declaration).kind IN ('rule', 'decision_program') THEN
        RAISE EXCEPTION 'M31_ADAPTER_REQUIRED: generic deployment requires an authoritative adapter';
    END IF;
    result := pgreact_api.deploy_m30(declaration, preconditions);
    IF (declaration).kind = 'policy_set' THEN
        SELECT pgreact_internal.m31_reconcile_policy_set(version.policy_set_version_id,
                                                          clock_timestamp())
        INTO runtime
        FROM pgreact_internal.policy_set_versions version
        JOIN pgreact_internal.policy_sets set USING (policy_set_id)
        WHERE set.set_name = (declaration).name
          AND version.version = (declaration).spec ->> 'version'
          AND version.state = 'DEPLOYED';
        result := result || jsonb_build_object(
            'summary', (result -> 'summary') ||
                jsonb_build_object('runtime_state',
                    COALESCE(runtime ->> 'runtime_state', 'BLOCKED')),
            'runtime', COALESCE(runtime, '{}'::jsonb));
    ELSE
        FOR set_row IN
            SELECT DISTINCT version.policy_set_version_id
            FROM pgreact_internal.policy_set_members member
            JOIN pgreact_internal.policy_set_versions version
              USING (policy_set_version_id)
            LEFT JOIN pgreact_internal.api_declarations rule_declaration
              ON (declaration).kind = 'rule'
             AND rule_declaration.kind = 'rule'
             AND rule_declaration.object_name = member.member_name
             AND rule_declaration.state = 'DEPLOYED'
            LEFT JOIN pgreact_internal.decision_programs program
              ON (declaration).kind = 'decision_program'
             AND program.program_name = member.member_name
            LEFT JOIN pgreact_internal.decision_program_versions decision_version
              ON decision_version.program_id = program.program_id
             AND decision_version.state = 'DEPLOYED'
            WHERE version.state = 'DEPLOYED'
              AND member.member_name = (declaration).name
              AND (((declaration).kind = 'rule'
                    AND member.member_kind = 'rule'
                    AND member.member_version IN ('1', rule_declaration.delegated_id::text))
                OR ((declaration).kind = 'decision_program'
                    AND member.member_kind = 'decision_program'
                    AND member.member_version IN (decision_version.version_id::text,
                                                   decision_version.version_no::text)))
        LOOP
            runtime := pgreact_internal.m31_reconcile_policy_set(
                set_row.policy_set_version_id, clock_timestamp());
            runtimes := runtimes || jsonb_build_array(runtime);
        END LOOP;
        result := result || jsonb_build_object('runtime', runtimes);
    END IF;
    RETURN result;
END
$m31$;

CREATE FUNCTION pgreact_api.status(target pgreact_api.target, options jsonb DEFAULT '{}'::jsonb)
RETURNS jsonb LANGUAGE SQL STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
    SELECT CASE
        WHEN ($1).kind = 'policy_set' THEN pgreact_internal.m31_policy_status($1)
        WHEN ($1).kind = 'rule' AND pgreact_internal.m31_rule_status($1) IS NOT NULL
            THEN pgreact_internal.m31_rule_status($1)
        WHEN ($1).kind = 'decision_program' THEN
            pgreact_internal.m31_decision_status($1)
        WHEN ($1).kind NOT IN ('rule', 'decision_program', 'policy_set') THEN
            jsonb_build_object('contract_version', 18, 'operation', 'status',
                'target', jsonb_build_object('kind', ($1).kind, 'name', ($1).name),
                'state', 'attention', 'findings', jsonb_build_array(
                    pgreact_internal.m30_finding('M31_UNSUPPORTED_KIND', 'ERROR',
                        ($1).name, 'kind',
                        'generic M31 runtime has no authoritative adapter for this kind',
                        'Use a supported M31 kind.')),
                'truncated', false)
        ELSE pgreact_api.status_m30($1, $2)
    END
$$;

CREATE FUNCTION pgreact_api.explain(
    target pgreact_api.target, subject jsonb DEFAULT NULL, options jsonb DEFAULT '{}'::jsonb)
RETURNS jsonb LANGUAGE SQL STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
    SELECT CASE WHEN ($1).kind = 'policy_set' THEN
        pgreact_internal.m31_policy_status($1) || jsonb_build_object(
            'operation', 'explain', 'evidence', jsonb_build_object(
                'subject', $2,
                'eligible', CASE WHEN $2 IS NULL THEN NULL
                    ELSE pgreact_internal.m30_subject_eligible($1, $2) END,
                'effective_match', CASE WHEN $2 IS NULL THEN NULL
                    ELSE EXISTS (SELECT 1
                        FROM pgreact_internal.policy_set_scope_supports support
                        JOIN pgreact_internal.policy_set_versions version
                          USING (policy_set_version_id)
                        JOIN pgreact_internal.policy_sets set USING (policy_set_id)
                        WHERE set.set_name = ($1).name
                          AND (($1).version IS NULL OR version.version = ($1).version)
                          AND version.state = 'DEPLOYED'
                          AND version.valid_from <= clock_timestamp()
                          AND (version.valid_to IS NULL OR clock_timestamp() < version.valid_to)
                          AND NOT EXISTS (
                              SELECT 1
                              FROM pgreact_internal.policy_set_runtime_barriers barrier
                              WHERE barrier.policy_set_version_id = version.policy_set_version_id
                                AND barrier.cleared_at IS NULL)
                          AND support.subject_identity = (
                              SELECT eligibility.subject_identity
                              FROM pgreact_internal.policy_set_eligibility eligibility
                              WHERE eligibility.policy_set_version_id = version.policy_set_version_id
                                AND eligibility.subject_values = (
                                    SELECT jsonb_agg(
                                        CASE WHEN jsonb_typeof($2) = 'object'
                                             THEN $2 -> requested.key_name::text
                                             ELSE $2 -> ((requested.ordinal - 1)::integer) END
                                        ORDER BY requested.ordinal)
                                    FROM unnest(version.subject_keys)
                                         WITH ORDINALITY requested(key_name, ordinal)))) END,
                'options', $3))
    WHEN ($1).kind = 'decision_program' THEN
        pgreact_internal.m31_decision_explain($1, $2)
    WHEN ($1).kind = 'rule' THEN
        pgreact_internal.m31_rule_explain($1, $2, $3)
    WHEN ($1).kind NOT IN ('rule', 'decision_program', 'policy_set') THEN
        jsonb_build_object('contract_version', 18, 'operation', 'explain',
            'target', jsonb_build_object('kind', ($1).kind, 'name', ($1).name),
            'state', 'attention', 'findings', jsonb_build_array(
                pgreact_internal.m30_finding('M31_UNSUPPORTED_KIND', 'ERROR',
                    ($1).name, 'kind',
                    'generic M31 runtime has no authoritative adapter for this kind',
                    'Use a supported M31 kind.')),
            'truncated', false)
    ELSE pgreact_api.explain_m30($1, $2, $3) END
$$;

CREATE FUNCTION pgreact_api.doctor(target pgreact_api.target, options jsonb DEFAULT '{}'::jsonb)
RETURNS jsonb LANGUAGE SQL STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
    SELECT CASE WHEN ($1).kind = 'policy_set' THEN pgreact_internal.m31_doctor($1)
                WHEN ($1).kind = 'decision_program' THEN pgreact_internal.m31_decision_doctor($1)
                WHEN ($1).kind = 'rule' THEN pgreact_internal.m31_rule_doctor($1)
                WHEN ($1).kind NOT IN ('rule', 'decision_program', 'policy_set') THEN
                    jsonb_build_object('contract_version', 18, 'operation', 'doctor',
                        'target', jsonb_build_object('kind', ($1).kind, 'name', ($1).name),
                        'state', 'attention', 'diagnostics', jsonb_build_array(
                            pgreact_internal.m30_finding('M31_UNSUPPORTED_KIND', 'ERROR',
                                ($1).name, 'kind',
                                'generic M31 runtime has no authoritative adapter for this kind',
                                'Use a supported M31 kind.')),
                        'truncated', false)
                ELSE pgreact_api.doctor_m30($1, $2) END
$$;

CREATE FUNCTION pgreact_api.run(
    target pgreact_api.target, sampled_time timestamptz DEFAULT clock_timestamp())
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $m31$
DECLARE global_result jsonb;
    target_status jsonb;
    target_runtime text;
    target_exists boolean;
BEGIN
    IF (target).kind NOT IN ('rule', 'decision_program', 'policy_set') THEN
        RAISE EXCEPTION 'M31_UNSUPPORTED_KIND: run has no authoritative adapter for %',
            (target).kind;
    END IF;
    target_exists := CASE
        WHEN (target).kind = 'policy_set' THEN EXISTS (
            SELECT 1
            FROM pgreact_internal.policy_set_versions version
            JOIN pgreact_internal.policy_sets set USING (policy_set_id)
            WHERE set.set_name = (target).name
              AND version.state = 'DEPLOYED'
              AND ((target).version IS NULL OR version.version = (target).version))
        WHEN (target).kind = 'rule' THEN EXISTS (
            SELECT 1
            FROM pgreact_internal.api_declarations declaration
            WHERE declaration.kind = 'rule'
              AND declaration.object_name = (target).name
              AND declaration.state = 'DEPLOYED'
              AND ((target).version IS NULL OR (target).version = '1'
                   OR declaration.delegated_id::text = (target).version))
        ELSE EXISTS (
            SELECT 1
            FROM pgreact_internal.decision_programs program
            JOIN pgreact_internal.decision_program_versions version
              USING (program_id)
            WHERE program.program_name = (target).name
              AND program.state <> 'REMOVED'
              AND version.state = 'DEPLOYED'
              AND ((target).version IS NULL
                   OR version.version_id::text = (target).version
                   OR version.version_no::text = (target).version))
    END;
    IF NOT target_exists THEN
        RAISE EXCEPTION 'M31_TARGET_NOT_FOUND: deployed target % is unavailable',
            (target).name;
    END IF;
    global_result := pgreact_api.run(sampled_time);
    target_status := CASE
        WHEN (target).kind = 'policy_set' THEN pgreact_internal.m31_policy_status(target)
        WHEN (target).kind = 'decision_program' THEN
            pgreact_internal.m31_decision_status(target)
        ELSE COALESCE(pgreact_internal.m31_rule_status(target),
                       pgreact_api.status_m30(target, '{}'::jsonb))
    END;
    target_runtime := COALESCE(
        target_status -> 'summary' ->> 'runtime_state', 'AUTHORITATIVE');
    RETURN global_result || jsonb_build_object(
        'operation', 'run',
        'scope', 'global',
        'target', jsonb_build_object(
            'kind', (target).kind, 'name', (target).name, 'version', (target).version),
        'runtime', jsonb_build_object('runtime_state', target_runtime),
        'target_status', target_status);
END
$m31$;

ALTER FUNCTION pgreact_api.run(timestamptz) RENAME TO run_m30_global;

CREATE FUNCTION pgreact_internal.m31_run_m30_global(sampled_time timestamptz)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $m31$
BEGIN
    RETURN pgreact_api.run_m30_global(sampled_time);
END
$m31$;

CREATE FUNCTION pgreact_api.run(sampled_time timestamptz DEFAULT clock_timestamp())
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $m31$
DECLARE result jsonb;
    set_row record;
    runtime jsonb;
    global_frontier timestamptz;
    runtimes jsonb := '[]'::jsonb;
BEGIN
    PERFORM pg_advisory_xact_lock(5788046901200000);
    BEGIN
        result := pgreact_internal.m31_run_m30_global(sampled_time);
    EXCEPTION WHEN OTHERS THEN
        result := jsonb_build_object(
            'runtime_state', 'BLOCKED',
            'error', SQLERRM,
            'sampled_time', sampled_time);
    END;
    SELECT frontier INTO global_frontier
    FROM pgreact_internal.clock_frontier
    WHERE singleton;
    FOR set_row IN
        SELECT version.policy_set_version_id, set.set_name, version.version,
               version.valid_from, version.valid_to
        FROM pgreact_internal.policy_set_versions version
        JOIN pgreact_internal.policy_sets set USING (policy_set_id)
        WHERE version.state = 'DEPLOYED'
        ORDER BY set.set_name, version.version
    LOOP
        runtime := CASE WHEN set_row.valid_from <= sampled_time
                              AND (set_row.valid_to IS NULL OR sampled_time < set_row.valid_to)
                        THEN pgreact_internal.m31_reconcile_policy_set(
                            set_row.policy_set_version_id, sampled_time)
                        ELSE pgreact_internal.m31_expire_policy_set(
                            set_row.policy_set_version_id, sampled_time)
                   END;
        runtimes := runtimes || jsonb_build_array(jsonb_build_object(
            'target', set_row.set_name || '@' || set_row.version,
            'runtime', runtime));
    END LOOP;
    IF EXISTS (
        SELECT 1
        FROM pgreact_internal.policy_set_versions version
        WHERE version.state = 'DEPLOYED'
          AND version.valid_from <= sampled_time
          AND (version.valid_to IS NULL OR sampled_time < version.valid_to)
          AND version.complete_frontier IS DISTINCT FROM global_frontier
          AND NOT EXISTS (
              SELECT 1
              FROM pgreact_internal.policy_set_runtime_barriers barrier
              WHERE barrier.policy_set_version_id = version.policy_set_version_id
                AND barrier.cleared_at IS NULL)
    ) THEN
        RAISE EXCEPTION 'M31_GLOBAL_FRONTIER: authoritative policy-set frontiers disagree with the global frontier %',
            global_frontier;
    END IF;
    RETURN result || jsonb_build_object(
        'policy_sets', runtimes,
        'frontier', global_frontier,
        'frontier_invariant', jsonb_build_object(
            'sampled_time', sampled_time, 'frontier', global_frontier));
END
$m31$;

CREATE FUNCTION pgreact_api.remove(
    target pgreact_api.target, preconditions jsonb DEFAULT '{}'::jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $m31$
DECLARE version_row pgreact_internal.policy_set_versions%ROWTYPE;
    owner_id oid;
    rule_version_id uuid;
    rule_row pgreact_internal.rule_versions%ROWTYPE;
    decision_program_id uuid;
    member_row record;
    result jsonb;
BEGIN
    PERFORM pg_advisory_xact_lock(5788046901200000);
    PERFORM pg_advisory_xact_lock(5788046901200004);
    IF (target).kind <> 'policy_set' THEN
        IF (target).kind = 'rule' THEN
            SELECT delegated_id INTO rule_version_id FROM pgreact_internal.api_declarations
            WHERE kind = 'rule' AND object_name = (target).name AND state = 'DEPLOYED';
            IF (target).version IS NOT NULL
               AND (target).version NOT IN ('1', rule_version_id::text) THEN
                RETURN pgreact_api.remove_m30(target, preconditions);
            END IF;
            IF rule_version_id IS NULL THEN RETURN pgreact_api.remove_m30(target, preconditions); END IF;
            FOR member_row IN
                SELECT support.scope_support_id
                FROM pgreact_internal.policy_set_scope_supports support
                WHERE support.member_kind = 'rule'
                  AND support.member_name = (target).name
                  AND EXISTS (
                      SELECT 1
                      FROM pgreact_internal.policy_set_members member
                      WHERE member.policy_set_version_id = support.policy_set_version_id
                        AND member.member_kind = 'rule'
                        AND member.member_name = support.member_name
                        AND member.member_version IN ('1', rule_version_id::text)
                        AND member.scope_mode = 'POLICY_SET_REQUIRED')
            LOOP
                PERFORM pgreact_internal.m31_remove_support(
                    member_row.scope_support_id, 'rule_removed');
            END LOOP;
            PERFORM pgreact.pause_rule(rule_version_id);
            PERFORM pgreact.remove_rule(rule_version_id);
        ELSIF (target).kind = 'decision_program' THEN
            SELECT program_id, owner_oid INTO decision_program_id, owner_id
            FROM pgreact_internal.decision_programs
            WHERE program_name = (target).name AND state <> 'REMOVED'
            FOR UPDATE;
            IF decision_program_id IS NULL THEN
                RETURN pgreact_api.remove_m30(target, preconditions);
            END IF;
            IF NOT pg_has_role(session_user, owner_id, 'USAGE')
               AND NOT pgreact_internal.is_operator_admin() THEN
                RAISE EXCEPTION 'M31_OWNER: only the decision-program owner or operator may remove this target';
            END IF;
            PERFORM pgreact_api.pause_decision_program((target).name);
            PERFORM pgreact_api.remove_decision_program((target).name);
            FOR member_row IN
                SELECT support.scope_support_id
                FROM pgreact_internal.policy_set_scope_supports support
                WHERE support.member_kind = 'decision_program'
                  AND support.member_name = (target).name
                  AND EXISTS (
                      SELECT 1
                      FROM pgreact_internal.policy_set_members member
                      JOIN pgreact_internal.decision_program_versions version
                        ON version.program_id = decision_program_id
                       AND version.state = 'DEPLOYED'
                      WHERE member.policy_set_version_id = support.policy_set_version_id
                        AND member.member_kind = 'decision_program'
                        AND member.member_name = support.member_name
                        AND member.member_version IN (version.version_id::text,
                                                       version.version_no::text)
                        AND member.scope_mode = 'POLICY_SET_REQUIRED')
            LOOP
                PERFORM pgreact_internal.m31_remove_support(
                    member_row.scope_support_id, 'decision_program_removed');
            END LOOP;
            IF decision_program_id IS NOT NULL THEN
                DELETE FROM pgreact_internal.decision_work
                WHERE program_id = decision_program_id;
            END IF;
        ELSE
            RAISE EXCEPTION 'M31_UNSUPPORTED_KIND: generic removal has no authoritative adapter for %',
                (target).kind;
        END IF;
        RETURN pgreact_api.remove_m30(target, preconditions);
    END IF;
    SELECT version.* INTO version_row
    FROM pgreact_internal.policy_set_versions version
    JOIN pgreact_internal.policy_sets set USING (policy_set_id)
    WHERE set.set_name = (target).name
      AND (($1).version IS NULL OR version.version = ($1).version)
    ORDER BY version.valid_from DESC LIMIT 1 FOR UPDATE;
    IF NOT FOUND THEN RETURN pgreact_internal.m31_policy_status(target); END IF;
    SELECT set.owner_oid INTO owner_id FROM pgreact_internal.policy_sets set
    WHERE set.policy_set_id = version_row.policy_set_id;
    IF NOT pg_has_role(session_user, owner_id, 'USAGE')
       AND NOT pgreact_internal.is_operator_admin() THEN
        RAISE EXCEPTION 'M31_OWNER: only the policy-set owner or operator may remove this target';
    END IF;
    UPDATE pgreact_internal.policy_set_versions
    SET state = 'REMOVED', removed_at = clock_timestamp()
    WHERE policy_set_version_id = version_row.policy_set_version_id;
    FOR member_row IN DELETE FROM pgreact_internal.policy_set_scope_supports
        WHERE policy_set_version_id = version_row.policy_set_version_id RETURNING * LOOP
        INSERT INTO pgreact_internal.policy_set_scope_support_history(
            scope_support_id, policy_set_version_id, member_kind, member_name,
            member_version, match_identity, subject_identity, event_kind,
            complete_frontier, details)
        VALUES (member_row.scope_support_id, member_row.policy_set_version_id,
                member_row.member_kind, member_row.member_name, member_row.member_version,
                member_row.match_identity, member_row.subject_identity, 'REMOVED',
                member_row.complete_frontier, jsonb_build_object('reason', 'set_removed'));
    END LOOP;
    UPDATE pgreact_internal.decision_work work
    SET claimable = state.state = 'WINNER' AND EXISTS (
            SELECT 1
            FROM pgreact_internal.policy_set_scope_supports support
            JOIN pgreact_internal.decision_programs program
              ON program.program_name = support.member_name
             AND support.member_kind = 'decision_program'
            WHERE program.program_id = state.program_id
              AND support.activation_id = state.activation_id
              AND NOT EXISTS (
                  SELECT 1 FROM pgreact_internal.policy_set_runtime_barriers barrier
                  WHERE barrier.policy_set_version_id = support.policy_set_version_id
                    AND barrier.cleared_at IS NULL)),
        updated_at = clock_timestamp()
    FROM pgreact_internal.decision_subject_state state
    WHERE work.program_id = state.program_id AND work.subject_key = state.subject_key;
    INSERT INTO pgreact_internal.policy_set_history(
        policy_set_version_id, event_kind, frontier, details)
    VALUES (version_row.policy_set_version_id, 'REMOVED',
            (SELECT frontier FROM pgreact_internal.clock_frontier WHERE singleton),
            jsonb_build_object('runtime_state', 'AUTHORITATIVE'));
    result := pgreact_internal.m30_envelope('remove', version_row.normalized, 'removed',
        jsonb_build_object('read_only', false,
                           'policy_set_version_id', version_row.policy_set_version_id,
                           'runtime_state', 'AUTHORITATIVE'));
    RETURN result;
END
$m31$;

CREATE OR REPLACE VIEW pgreact.policy_set_scope_supports AS
SELECT support.scope_support_id, set.set_name, version.version,
       support.member_kind, support.member_name, support.member_version,
       encode(support.match_identity, 'hex') AS match_identity,
       encode(support.subject_identity, 'hex') AS subject_identity,
       support.subject_values, support.support_generation,
       support.complete_frontier, support.created_at, support.activation_id
FROM pgreact_internal.policy_set_scope_supports support
JOIN pgreact_internal.policy_set_versions version USING (policy_set_version_id)
JOIN pgreact_internal.policy_sets set USING (policy_set_id);

CREATE OR REPLACE VIEW pgreact.activations AS
SELECT activation.rule_version_id, activation.activation_id, activation.semantic_key,
       activation.current_bindings, activation.active, activation.generation,
       activation.first_seen_at, activation.last_seen_at, activation.deactivated_at,
       activation.revision
FROM pgreact_internal.activation_state activation
JOIN pgreact_internal.rule_versions rule_version
  ON rule_version.rule_version_id = activation.rule_version_id
JOIN pgreact_internal.rules rule USING (rule_id);

CREATE OR REPLACE VIEW pgreact.decision_winners AS
SELECT state.program_id, program.program_name, state.subject_key, state.version_id,
       state.state, state.winner_candidate, state.winner_priority, state.winner_result,
       state.activation_id, state.generation, state.revision, state.competitors,
       state.competitors_truncated, work.claimable, state.first_seen_at,
       state.last_seen_at
FROM pgreact_internal.decision_subject_state state
JOIN pgreact_internal.decision_programs program USING (program_id)
LEFT JOIN pgreact_internal.decision_work work USING (program_id, subject_key)
WHERE program.state <> 'REMOVED';

COMMENT ON EXTENSION pg_react IS
    'M31 authoritative runtime: fail-closed eligibility, scope supports, lifecycle, and work agreement';

CREATE FUNCTION pgreact_internal.m31_has_effective_rule_support(
    target_activation_id uuid, target_rule_name text, target_rule_version uuid,
    execution_time timestamptz)
RETURNS boolean
LANGUAGE SQL STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $m31$
    SELECT EXISTS (
        SELECT 1
        FROM pgreact_internal.policy_set_scope_supports support
        JOIN pgreact_internal.policy_set_members member
          ON member.policy_set_version_id = support.policy_set_version_id
         AND member.member_kind = 'rule'
         AND member.member_name = target_rule_name
         AND member.member_version IN ('1', target_rule_version::text)
         AND member.scope_mode = 'POLICY_SET_REQUIRED'
        JOIN pgreact_internal.policy_set_versions version
          ON version.policy_set_version_id = support.policy_set_version_id
         AND version.state = 'DEPLOYED'
         AND version.valid_from <= execution_time
         AND (version.valid_to IS NULL OR execution_time < version.valid_to)
        WHERE support.activation_id = target_activation_id
          AND support.member_kind = 'rule'
          AND support.member_name = target_rule_name
          AND support.member_version IN ('1', target_rule_version::text)
          AND NOT EXISTS (
              SELECT 1
              FROM pgreact_internal.policy_set_runtime_barriers barrier
              WHERE barrier.policy_set_version_id = support.policy_set_version_id
                AND barrier.cleared_at IS NULL)
    )
$m31$;

ALTER FUNCTION pgreact.execute_claimed_episode(bigint, text, uuid)
    RENAME TO execute_claimed_episode_m31_base;

CREATE FUNCTION pgreact.execute_claimed_episode(
    target_episode_id bigint, expected_worker_id text, expected_lease_token uuid)
RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $m31$
DECLARE episode pgreact_internal.agenda%ROWTYPE;
    rule_name text;
    scoped boolean;
    target_rule_version uuid;
    execution_time timestamptz;
BEGIN
    PERFORM pg_advisory_xact_lock_shared(5788046901200000);
    SELECT agenda.rule_version_id INTO target_rule_version
    FROM pgreact_internal.agenda agenda
    WHERE agenda.episode_id = target_episode_id;
    IF target_rule_version IS NOT NULL THEN
        PERFORM pg_advisory_xact_lock(hashtextextended(
            'm31:rule:' || target_rule_version::text, 5788046901200005));
    END IF;
    SELECT agenda.* INTO STRICT episode
    FROM pgreact_internal.agenda agenda
    WHERE agenda.episode_id = target_episode_id
    FOR UPDATE;
    SELECT rule.rule_name INTO rule_name
    FROM pgreact_internal.rules rule
    JOIN pgreact_internal.rule_versions version USING (rule_id)
    WHERE version.rule_version_id = episode.rule_version_id;
    PERFORM pgreact_internal.assert_not_active_program_member(
        episode.rule_version_id, 'agenda-executed',
        'Program derivations do not use the agenda; use pgreact.refresh_derivation_program.');
    SELECT EXISTS (
        SELECT 1
        FROM pgreact_internal.policy_set_members member
        JOIN pgreact_internal.policy_set_versions version
          USING (policy_set_version_id)
        WHERE member.member_kind = 'rule' AND member.member_name = rule_name
          AND member.scope_mode = 'POLICY_SET_REQUIRED'
          AND member.member_version IN ('1', episode.rule_version_id::text)
          AND version.state = 'DEPLOYED'
    ) INTO scoped;
    execution_time := clock_timestamp();
    IF scoped AND NOT pgreact_internal.m31_has_effective_rule_support(
        episode.activation_id, rule_name, episode.rule_version_id, execution_time) THEN
        IF episode.state = 'WITHDRAWN' THEN RETURN 'SKIPPED'; END IF;
        UPDATE pgreact_internal.agenda
        SET state = 'WITHDRAWN', completed_at = clock_timestamp(),
            lease_token = NULL, worker_id = NULL, lease_expires_at = NULL
        WHERE agenda.episode_id = target_episode_id
          AND agenda.state = 'LEASED'
          AND agenda.worker_id = expected_worker_id
          AND agenda.lease_token = expected_lease_token;
        IF FOUND THEN RETURN 'SKIPPED'; END IF;
    END IF;
    RETURN pgreact.execute_claimed_episode_m31_base(
        target_episode_id, expected_worker_id, expected_lease_token);
END
$m31$;

ALTER FUNCTION pgreact.claim_episode(uuid, text, integer)
    RENAME TO claim_episode_m31_base;

CREATE FUNCTION pgreact.claim_episode(
    target_version_id uuid, worker_id text, lease_seconds integer DEFAULT 60)
RETURNS TABLE(episode_id bigint, lease_token uuid, activation_id uuid, bindings jsonb)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $m31$
DECLARE claimed record;
    episode pgreact_internal.agenda%ROWTYPE;
    rule_name text;
    scoped boolean;
    execution_time timestamptz;
BEGIN
    PERFORM pg_advisory_xact_lock_shared(5788046901200000);
    PERFORM pg_advisory_xact_lock(hashtextextended(
        'm31:rule:' || target_version_id::text, 5788046901200005));
    LOOP
        SELECT * INTO claimed
        FROM pgreact.claim_episode_m31_base(target_version_id, worker_id, lease_seconds);
        IF NOT FOUND THEN RETURN; END IF;
    SELECT agenda.* INTO STRICT episode
    FROM pgreact_internal.agenda agenda
    WHERE agenda.episode_id = claimed.episode_id
    FOR UPDATE;
    execution_time := clock_timestamp();
    SELECT rule.rule_name INTO rule_name
    FROM pgreact_internal.rules rule
    JOIN pgreact_internal.rule_versions version USING (rule_id)
    WHERE version.rule_version_id = episode.rule_version_id;
    SELECT EXISTS (
        SELECT 1
        FROM pgreact_internal.policy_set_members member
        JOIN pgreact_internal.policy_set_versions version
          USING (policy_set_version_id)
        WHERE member.member_kind = 'rule' AND member.member_name = rule_name
          AND member.scope_mode = 'POLICY_SET_REQUIRED'
          AND member.member_version IN ('1', target_version_id::text)
          AND version.state = 'DEPLOYED'
    ) INTO scoped;
    IF scoped AND NOT pgreact_internal.m31_has_effective_rule_support(
        episode.activation_id, rule_name, target_version_id, execution_time) THEN
        UPDATE pgreact_internal.agenda
        SET state = 'WITHDRAWN', completed_at = clock_timestamp(),
            lease_token = NULL, worker_id = NULL, lease_expires_at = NULL
        WHERE agenda.episode_id = claimed.episode_id
          AND agenda.state = 'LEASED'
          AND agenda.worker_id = worker_id
          AND agenda.lease_token = claimed.lease_token;
        IF FOUND THEN CONTINUE; END IF;
    END IF;
    RETURN QUERY SELECT claimed.episode_id, claimed.lease_token,
                        claimed.activation_id, claimed.bindings;
    RETURN;
    END LOOP;
END
$m31$;

ALTER FUNCTION pgreact.claim_batch(uuid, text, text, integer, interval)
    RENAME TO claim_batch_m31_base;

CREATE FUNCTION pgreact.claim_batch(
    target_version_id uuid,
    event_kind text,
    worker_id text,
    max_items integer DEFAULT 32,
    lease_for interval DEFAULT interval '60 seconds')
RETURNS TABLE(batch_id uuid, item_order integer, episode_id bigint, lease_token uuid)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $m31$
BEGIN
    PERFORM pg_advisory_xact_lock_shared(5788046901200000);
    PERFORM pg_advisory_xact_lock(hashtextextended(
        'm31:rule:' || target_version_id::text, 5788046901200005));
    RETURN QUERY SELECT *
    FROM pgreact.claim_batch_m31_base(
        target_version_id, event_kind, worker_id, max_items, lease_for);
END
$m31$;

ALTER FUNCTION pgreact.execute_claimed_batch(uuid, text)
    RENAME TO execute_claimed_batch_m31_base;

CREATE FUNCTION pgreact.execute_claimed_batch(
    target_batch_id uuid, expected_worker_id text)
RETURNS TABLE(episode_id bigint, status text, error_code text, error_message text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $m31$
DECLARE batch_row pgreact_internal.execution_batches%ROWTYPE;
    rule_name text;
    stale_scope boolean := false;
    execution_time timestamptz;
BEGIN
    PERFORM pg_advisory_xact_lock_shared(5788046901200000);
    SELECT * INTO STRICT batch_row
    FROM pgreact_internal.execution_batches batch
    WHERE batch.batch_id = target_batch_id
    FOR UPDATE;
    PERFORM pg_advisory_xact_lock(hashtextextended(
        'm31:rule:' || batch_row.rule_version_id::text, 5788046901200005));
    SELECT rule.rule_name INTO rule_name
    FROM pgreact_internal.rules rule
    JOIN pgreact_internal.rule_versions version USING (rule_id)
    WHERE version.rule_version_id = batch_row.rule_version_id;
    IF EXISTS (
        SELECT 1
        FROM pgreact_internal.policy_set_members member
        JOIN pgreact_internal.policy_set_versions version
          USING (policy_set_version_id)
        WHERE member.member_kind = 'rule'
          AND member.member_name = rule_name
          AND member.scope_mode = 'POLICY_SET_REQUIRED'
          AND member.member_version IN ('1', batch_row.rule_version_id::text)
          AND version.state = 'DEPLOYED'
    ) THEN
        execution_time := clock_timestamp();
        SELECT EXISTS (
            SELECT 1
            FROM pgreact_internal.execution_batch_items item
            JOIN pgreact_internal.agenda agenda USING (episode_id)
            WHERE item.batch_id = target_batch_id
              AND NOT pgreact_internal.m31_has_effective_rule_support(
                  agenda.activation_id, rule_name, batch_row.rule_version_id,
                  execution_time))
        INTO stale_scope;
    END IF;
    IF stale_scope THEN
        UPDATE pgreact_internal.execution_batches
        SET state = 'REJECTED', diagnostic_code = 'M31_SCOPE_WITHDRAWN',
            diagnostic = jsonb_build_object(
                'code', 'M31_SCOPE_WITHDRAWN',
                'message', 'batch rejected before consequence invocation'),
            finished_at = clock_timestamp()
        WHERE batch_id = target_batch_id;
        UPDATE pgreact_internal.execution_batch_items
        SET outcome = 'SKIPPED', error_code = 'M31_SCOPE_WITHDRAWN',
            error_message = 'policy-set support was withdrawn before execution'
        WHERE batch_id = target_batch_id;
        UPDATE pgreact_internal.agenda agenda
        SET state = 'WITHDRAWN', completed_at = clock_timestamp(),
            lease_token = NULL, worker_id = NULL, lease_expires_at = NULL
        FROM pgreact_internal.execution_batch_items item
        WHERE item.batch_id = target_batch_id
          AND agenda.episode_id = item.episode_id
          AND agenda.state = 'LEASED';
        RETURN QUERY
        SELECT item.episode_id, item.outcome, item.error_code, item.error_message
        FROM pgreact_internal.execution_batch_items item
        WHERE item.batch_id = target_batch_id
        ORDER BY item.item_order;
        RETURN;
    END IF;
    RETURN QUERY SELECT *
    FROM pgreact.execute_claimed_batch_m31_base(target_batch_id, expected_worker_id);
END
$m31$;


ALTER FUNCTION pgreact_api.configure_roles(
    regrole, regrole, regrole, regrole, regrole)
    RENAME TO configure_roles_m30;

CREATE FUNCTION pgreact_api.configure_roles(
    author_role regrole,
    operator_role regrole,
    worker_role regrole,
    reader_role regrole,
    advanced_reader_role regrole)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $m31$
BEGIN
    PERFORM pgreact_api.configure_roles_m30(
        author_role, operator_role, worker_role, reader_role, advanced_reader_role);
    EXECUTE format('GRANT USAGE ON SCHEMA pgreact, pgreact_api TO %I, %I, %I',
                   author_role::text, operator_role::text, reader_role::text);
    EXECUTE format('GRANT USAGE ON TYPE pgreact_api.declaration, pgreact_api.target TO %I, %I, %I',
                   author_role::text, operator_role::text, reader_role::text);
    EXECUTE format('GRANT EXECUTE ON FUNCTION '
        || 'pgreact_api.declaration(text,text,jsonb), '
        || 'pgreact_api.target(text,text,text) TO %I, %I, %I',
        author_role::text, operator_role::text, reader_role::text);
    EXECUTE format('GRANT EXECUTE ON FUNCTION '
        || 'pgreact_api.validate_program(jsonb), '
        || 'pgreact_api.preview_program(jsonb), '
        || 'pgreact_api.declare_derived_relation(text,regtype,name[],integer), '
        || 'pgreact_api.deploy_program(jsonb,text), '
        || 'pgreact_api.remove_program(text,integer) TO %I', author_role::text);
    EXECUTE format('GRANT EXECUTE ON FUNCTION '
        || 'pgreact_api.request_watermark(text,text,name,timestamptz), '
        || 'pgreact_api.prune_window_history(text,timestamptz), '
        || 'pgreact_api.export_window_state(text), '
        || 'pgreact_api.restore_window_state(jsonb), '
        || 'pgreact_api.watermark_status(text) TO %I', operator_role::text);
    EXECUTE format('GRANT EXECUTE ON FUNCTION '
        || 'pgreact_api.watermark_status(text) TO %I', reader_role::text);
    EXECUTE 'REVOKE ALL ON FUNCTION '
        || 'pgreact_api.validate(pgreact_api.declaration), '
        || 'pgreact_api.preview(pgreact_api.declaration,jsonb), '
        || 'pgreact_api.deploy(pgreact_api.declaration,jsonb), '
        || 'pgreact_api.status(pgreact_api.target,jsonb), '
        || 'pgreact_api.explain(pgreact_api.target,jsonb,jsonb), '
        || 'pgreact_api.doctor(pgreact_api.target,jsonb), '
        || 'pgreact_api.run(pgreact_api.target,timestamptz), '
        || 'pgreact_api.run(timestamptz), '
        || 'pgreact_api.remove(pgreact_api.target,jsonb), '
        || 'pgreact_api.configure_roles(regrole,regrole,regrole,regrole,regrole) '
        || 'FROM PUBLIC';
    EXECUTE format('GRANT EXECUTE ON FUNCTION '
        || 'pgreact_api.validate(pgreact_api.declaration), '
        || 'pgreact_api.preview(pgreact_api.declaration,jsonb), '
        || 'pgreact_api.deploy(pgreact_api.declaration,jsonb), '
        || 'pgreact_api.remove(pgreact_api.target,jsonb), '
        || 'pgreact_api.run(pgreact_api.target,timestamptz) TO %I', author_role::text);
    EXECUTE format('GRANT EXECUTE ON FUNCTION '
        || 'pgreact_api.status(pgreact_api.target,jsonb), '
        || 'pgreact_api.explain(pgreact_api.target,jsonb,jsonb), '
        || 'pgreact_api.doctor(pgreact_api.target,jsonb), '
        || 'pgreact_api.run(timestamptz), '
        || 'pgreact_api.run(pgreact_api.target,timestamptz) TO %I', operator_role::text);
    EXECUTE format('GRANT EXECUTE ON FUNCTION '
        || 'pgreact_api.status(pgreact_api.target,jsonb), '
        || 'pgreact_api.explain(pgreact_api.target,jsonb,jsonb), '
        || 'pgreact_api.doctor(pgreact_api.target,jsonb) TO %I', reader_role::text);
END
$m31$;

REVOKE ALL ON FUNCTION pgreact_api.configure_roles(
    regrole, regrole, regrole, regrole, regrole) FROM PUBLIC;

DO $m31$
DECLARE author_role regrole;
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
$m31$;
