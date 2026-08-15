-- M24 effective-dated policy versions. Policy authority is selected from the
-- committed database-time frontier; deployment time and effective time remain
-- separate.

CREATE TABLE pgreact_internal.effective_policies (
    policy_id uuid PRIMARY KEY,
    policy_name text NOT NULL UNIQUE,
    owner_oid oid NOT NULL,
    authoritative_version_id uuid,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE pgreact_internal.effective_policy_versions (
    policy_version_id uuid PRIMARY KEY,
    policy_id uuid NOT NULL REFERENCES pgreact_internal.effective_policies,
    rule_version_id uuid UNIQUE REFERENCES pgreact_internal.rule_versions,
    target_kind text NOT NULL DEFAULT 'RULE'
        CHECK (target_kind IN ('RULE', 'PROGRAM')),
    program_version_id uuid REFERENCES pgreact_internal.derivation_program_versions,
    program_definition jsonb,
    version integer NOT NULL CHECK (version > 0),
    valid_from timestamptz NOT NULL CHECK (isfinite(valid_from)),
    valid_to timestamptz CHECK (valid_to IS NULL OR (isfinite(valid_to) AND valid_to > valid_from)),
    deployment_state text NOT NULL CHECK (deployment_state IN ('DEPLOYED', 'PAUSED', 'REMOVED')),
    effective_state text NOT NULL DEFAULT 'FUTURE'
        CHECK (effective_state IN ('FUTURE', 'CURRENT', 'EXPIRED', 'GAP', 'PAUSED', 'REMOVED')),
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    UNIQUE (policy_id, version),
    CHECK (
        (target_kind = 'RULE' AND rule_version_id IS NOT NULL
            AND program_version_id IS NULL AND program_definition IS NULL)
        OR
        (target_kind = 'PROGRAM' AND rule_version_id IS NULL
            AND program_definition IS NOT NULL)
    )
);

CREATE INDEX effective_policy_interval_idx
    ON pgreact_internal.effective_policy_versions (policy_id, valid_from, valid_to);

CREATE TABLE pgreact_internal.effective_policy_history (
    transition_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    policy_id uuid NOT NULL REFERENCES pgreact_internal.effective_policies,
    policy_version_id uuid REFERENCES pgreact_internal.effective_policy_versions,
    event_kind text NOT NULL CHECK (event_kind IN (
        'DEPLOYED', 'EFFECTIVE', 'EXPIRED', 'GAP', 'PAUSED', 'RESUMED', 'REMOVED'
    )),
    frontier timestamptz NOT NULL,
    details jsonb NOT NULL DEFAULT '{}'::jsonb,
    occurred_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    UNIQUE (policy_version_id, event_kind, frontier)
);

CREATE VIEW pgreact.effective_policies AS
SELECT policy.policy_id,
       policy.policy_name,
       pg_get_userbyid(policy.owner_oid) AS owner,
       policy.authoritative_version_id,
       frontier.frontier,
       CASE
           WHEN policy.authoritative_version_id IS NOT NULL THEN 'CURRENT'
           WHEN EXISTS (
               SELECT 1
               FROM pgreact_internal.effective_policy_versions version
               WHERE version.policy_id = policy.policy_id
                 AND version.deployment_state = 'DEPLOYED'
                 AND version.valid_from > frontier.frontier
           ) THEN 'FUTURE'
           ELSE 'GAP'
       END AS state,
       policy.created_at
FROM pgreact_internal.effective_policies policy
CROSS JOIN pgreact_internal.clock_frontier frontier;

CREATE VIEW pgreact.effective_policy_versions AS
SELECT version.policy_version_id,
       policy.policy_id,
       policy.policy_name,
       version.rule_version_id,
       version.target_kind,
       version.program_version_id,
       COALESCE(rule.rule_name, version.program_definition ->> 'name') AS rule_name,
       version.version,
       version.valid_from,
       version.valid_to,
       version.deployment_state,
       version.effective_state,
       version.policy_version_id = policy.authoritative_version_id AS authoritative,
       version.created_at
FROM pgreact_internal.effective_policy_versions version
JOIN pgreact_internal.effective_policies policy USING (policy_id)
LEFT JOIN pgreact_internal.rule_versions rule_version USING (rule_version_id)
LEFT JOIN pgreact_internal.rules rule USING (rule_id)
WHERE version.deployment_state <> 'REMOVED';

CREATE FUNCTION pgreact_internal.m24_policy_version_state(
    target_valid_from timestamptz,
    target_valid_to timestamptz,
    target_deployment_state text,
    target_frontier timestamptz
)
RETURNS text
LANGUAGE SQL
IMMUTABLE
PARALLEL SAFE
SET search_path = pg_catalog, pg_temp
AS $m24$
    SELECT CASE
        WHEN $3 = 'PAUSED' THEN 'PAUSED'
        WHEN $3 = 'REMOVED' THEN 'REMOVED'
        WHEN $1 > $4 THEN 'FUTURE'
        WHEN $2 IS NOT NULL AND $2 <= $4 THEN 'EXPIRED'
        ELSE 'CURRENT'
    END
$m24$;

CREATE FUNCTION pgreact_internal.validate_effective_policy(
    target_policy_name text,
    target_rule_version_id uuid,
    target_valid_from timestamptz,
    target_valid_to timestamptz
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
AS $m24$
DECLARE policy_row pgreact_internal.effective_policies%ROWTYPE;
    version_row pgreact_internal.rule_versions%ROWTYPE;
    frontier timestamptz;
    overlap record;
BEGIN
    SELECT clock.frontier INTO STRICT frontier
    FROM pgreact_internal.clock_frontier clock;

    IF target_policy_name IS NULL OR btrim(target_policy_name) = '' THEN
        RETURN QUERY SELECT 12, 'M24_POLICY_NAME', 'ERROR', '<unnamed>',
            'policy name must not be empty',
            'Choose one stable name for the policy identity.', '{}'::jsonb;
        RETURN;
    END IF;
    IF target_valid_from IS NULL OR NOT isfinite(target_valid_from) THEN
        RETURN QUERY SELECT 12, 'M24_VALID_FROM', 'ERROR', target_policy_name,
            'valid_from must be finite and non-null',
            'Use one finite timestamptz business-effective boundary.', '{}'::jsonb;
        RETURN;
    END IF;
    IF target_valid_to IS NOT NULL
       AND (NOT isfinite(target_valid_to) OR target_valid_to <= target_valid_from) THEN
        RETURN QUERY SELECT 12, 'M24_VALID_INTERVAL', 'ERROR', target_policy_name,
            'valid_to must be finite and greater than valid_from',
            'Use a half-open interval [valid_from, valid_to) or leave valid_to null for no upper bound.',
            jsonb_build_object('valid_from', target_valid_from, 'valid_to', target_valid_to);
        RETURN;
    END IF;
    IF target_valid_from < frontier THEN
        RETURN QUERY SELECT 12, 'M24_RETROACTIVE_INTERVAL', 'ERROR', target_policy_name,
            'a new effective policy version cannot begin before the committed frontier',
            'Schedule the version at or after the current database-time frontier; historical truth is not recomputed.',
            jsonb_build_object('frontier', frontier, 'valid_from', target_valid_from);
        RETURN;
    END IF;

    SELECT * INTO version_row
    FROM pgreact_internal.rule_versions
    WHERE rule_version_id = target_rule_version_id;
    IF NOT FOUND OR version_row.state = 'REMOVED' THEN
        RETURN QUERY SELECT 12, 'M24_TARGET_NOT_FOUND', 'ERROR', target_rule_version_id::text,
            'the target rule version does not exist or has been removed',
            'Create or retain one immutable rule version before scheduling it.', '{}'::jsonb;
        RETURN;
    END IF;
    IF version_row.owner_oid <> (SELECT oid FROM pg_roles WHERE rolname = session_user)
       AND NOT pgreact_internal.is_operator_admin() THEN
        RETURN QUERY SELECT 12, 'M24_TARGET_FORBIDDEN', 'ERROR', target_rule_version_id::text,
            'only the rule owner or pgreact_admin may schedule this policy version',
            'Use the owning role or the configured operator role.', '{}'::jsonb;
        RETURN;
    END IF;
    IF EXISTS (
        SELECT 1 FROM pgreact_internal.derivation_rule_versions
        WHERE rule_version_id = target_rule_version_id
    ) THEN
        RETURN QUERY SELECT 12, 'M24_PROGRAM_MEMBER_RULE', 'ERROR', target_rule_version_id::text,
            'a derivation-program member must be scheduled as part of its complete program',
            'Use author_effective_program with the immutable program definition.',
            '{}'::jsonb;
        RETURN;
    END IF;

    SELECT * INTO policy_row
    FROM pgreact_internal.effective_policies
    WHERE policy_name = target_policy_name;
    IF FOUND AND policy_row.owner_oid <> version_row.owner_oid
       AND NOT pgreact_internal.is_operator_admin() THEN
        RETURN QUERY SELECT 12, 'M24_POLICY_OWNER', 'ERROR', target_policy_name,
            'all versions of one policy must have one owner',
            'Schedule the version as the existing policy owner.', '{}'::jsonb;
        RETURN;
    END IF;

    SELECT version.policy_version_id, version.valid_from, version.valid_to
    INTO overlap
    FROM pgreact_internal.effective_policy_versions version
    JOIN pgreact_internal.effective_policies policy USING (policy_id)
    WHERE policy.policy_name = target_policy_name
      AND version.deployment_state <> 'REMOVED'
      AND version.rule_version_id <> target_rule_version_id
      AND version.valid_from < COALESCE(target_valid_to, 'infinity'::timestamptz)
      AND target_valid_from < COALESCE(version.valid_to, 'infinity'::timestamptz)
    ORDER BY version.valid_from, version.policy_version_id
    LIMIT 1;
    IF FOUND THEN
        RETURN QUERY SELECT 12, 'M24_INTERVAL_OVERLAP', 'ERROR', target_policy_name,
            'effective intervals for one policy must not overlap',
            'Use adjacent half-open intervals or an explicit no-authority gap.',
            jsonb_build_object('existing_version', overlap.policy_version_id,
                               'existing_valid_from', overlap.valid_from,
                               'existing_valid_to', overlap.valid_to,
                               'valid_from', target_valid_from,
                               'valid_to', target_valid_to);
        RETURN;
    END IF;

    IF EXISTS (
        SELECT 1 FROM pgreact_internal.effective_policy_versions
        WHERE rule_version_id = target_rule_version_id
          AND deployment_state <> 'REMOVED'
    ) THEN
        RETURN QUERY SELECT 12, 'M24_VERSION_ALREADY_SCHEDULED', 'ERROR',
            target_rule_version_id::text,
            'one immutable rule version can belong to only one effective policy version',
            'Create a new immutable rule version for a new policy interval.', '{}'::jsonb;
        RETURN;
    END IF;

    RETURN QUERY SELECT 12, 'OK', 'INFO', target_policy_name,
        'effective policy interval is valid and has unique authority',
        'Deploy it; it remains dormant until the committed database-time frontier reaches valid_from.',
        jsonb_build_object(
            'clock_domain', 'DATABASE_TIME',
            'interval', jsonb_build_array(target_valid_from, target_valid_to),
            'boundary', '[valid_from, valid_to)',
            'equality', 'the version beginning at the boundary is authoritative');
END
$m24$;

CREATE FUNCTION pgreact_api.validate_effective_policy(
    policy_name text,
    rule_version_id uuid,
    valid_from timestamptz,
    valid_to timestamptz DEFAULT NULL
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
LANGUAGE SQL
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m24$
    SELECT * FROM pgreact_internal.validate_effective_policy($1, $2, $3, $4)
$m24$;

CREATE FUNCTION pgreact_internal.validate_effective_program(
    target_policy_name text,
    target_definition jsonb,
    target_valid_from timestamptz,
    target_valid_to timestamptz
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
AS $m24$
DECLARE frontier timestamptz;
    policy_row pgreact_internal.effective_policies%ROWTYPE;
    diagnostic record;
    overlap record;
BEGIN
    SELECT clock.frontier INTO STRICT frontier
    FROM pgreact_internal.clock_frontier clock;
    IF target_policy_name IS NULL OR btrim(target_policy_name) = '' THEN
        RETURN QUERY SELECT 12, 'M24_POLICY_NAME', 'ERROR', '<unnamed>',
            'policy name must not be empty',
            'Choose one stable name for the policy identity.', '{}'::jsonb;
        RETURN;
    END IF;
    IF target_valid_from IS NULL OR NOT isfinite(target_valid_from) THEN
        RETURN QUERY SELECT 12, 'M24_VALID_FROM', 'ERROR', target_policy_name,
            'valid_from must be finite and non-null',
            'Use one finite timestamptz business-effective boundary.', '{}'::jsonb;
        RETURN;
    END IF;
    IF target_valid_to IS NOT NULL
       AND (NOT isfinite(target_valid_to) OR target_valid_to <= target_valid_from) THEN
        RETURN QUERY SELECT 12, 'M24_VALID_INTERVAL', 'ERROR', target_policy_name,
            'valid_to must be finite and greater than valid_from',
            'Use a half-open interval [valid_from, valid_to) or leave valid_to null for no upper bound.',
            jsonb_build_object('valid_from', target_valid_from, 'valid_to', target_valid_to);
        RETURN;
    END IF;
    IF target_valid_from < frontier THEN
        RETURN QUERY SELECT 12, 'M24_RETROACTIVE_INTERVAL', 'ERROR', target_policy_name,
            'a new effective policy version cannot begin before the committed frontier',
            'Schedule the version at or after the current database-time frontier.',
            jsonb_build_object('frontier', frontier, 'valid_from', target_valid_from);
        RETURN;
    END IF;
    SELECT result.* INTO diagnostic
    FROM pgreact.validate_derivation_program(target_definition) result
    WHERE result.severity = 'ERROR'
    ORDER BY result.code, result.object_identity
    LIMIT 1;
    IF FOUND THEN
        RETURN QUERY SELECT 12, diagnostic.code, diagnostic.severity,
            diagnostic.object_identity, diagnostic.message, diagnostic.hint,
            diagnostic.details;
        RETURN;
    END IF;
    SELECT * INTO policy_row
    FROM pgreact_internal.effective_policies
    WHERE policy_name = target_policy_name;
    IF FOUND AND policy_row.owner_oid <> (
        SELECT oid FROM pg_roles WHERE rolname = session_user
    ) AND NOT pgreact_internal.is_operator_admin() THEN
        RETURN QUERY SELECT 12, 'M24_POLICY_OWNER', 'ERROR', target_policy_name,
            'all versions of one policy must have one owner',
            'Schedule the version as the existing policy owner.', '{}'::jsonb;
        RETURN;
    END IF;
    IF FOUND AND EXISTS (
        SELECT 1
        FROM pgreact_internal.effective_policy_versions version
        WHERE version.policy_id = policy_row.policy_id
          AND version.deployment_state <> 'REMOVED'
          AND version.target_kind <> 'PROGRAM'
    ) THEN
        RETURN QUERY SELECT 12, 'M24_POLICY_TARGET_KIND', 'ERROR', target_policy_name,
            'one effective policy cannot mix rule and derivation-program versions',
            'Use a new policy identity for the other target kind.', '{}'::jsonb;
        RETURN;
    END IF;
    SELECT version.policy_version_id, version.valid_from, version.valid_to
    INTO overlap
    FROM pgreact_internal.effective_policy_versions version
    JOIN pgreact_internal.effective_policies policy USING (policy_id)
    WHERE policy.policy_name = target_policy_name
      AND version.deployment_state <> 'REMOVED'
      AND version.valid_from < COALESCE(target_valid_to, 'infinity'::timestamptz)
      AND target_valid_from < COALESCE(version.valid_to, 'infinity'::timestamptz)
    ORDER BY version.valid_from, version.policy_version_id
    LIMIT 1;
    IF FOUND THEN
        RETURN QUERY SELECT 12, 'M24_INTERVAL_OVERLAP', 'ERROR', target_policy_name,
            'effective intervals for one policy must not overlap',
            'Use adjacent half-open intervals or an explicit no-authority gap.',
            jsonb_build_object('existing_version', overlap.policy_version_id,
                               'existing_valid_from', overlap.valid_from,
                               'existing_valid_to', overlap.valid_to,
                               'valid_from', target_valid_from,
                               'valid_to', target_valid_to);
        RETURN;
    END IF;
    RETURN QUERY SELECT 12, 'OK', 'INFO', target_policy_name,
        'effective derivation-program interval is valid and has unique authority',
        'Deploy it; the program remains dormant until the committed database-time frontier reaches valid_from.',
        jsonb_build_object(
            'clock_domain', 'DATABASE_TIME',
            'target_kind', 'PROGRAM',
            'program', target_definition ->> 'name',
            'version', target_definition ->> 'version',
            'interval', jsonb_build_array(target_valid_from, target_valid_to),
            'boundary', '[valid_from, valid_to)');
END
$m24$;

CREATE FUNCTION pgreact_api.validate_effective_program(
    policy_name text,
    definition jsonb,
    valid_from timestamptz,
    valid_to timestamptz DEFAULT NULL
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
LANGUAGE SQL
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m24$
    SELECT * FROM pgreact_internal.validate_effective_program($1, $2, $3, $4)
$m24$;

CREATE FUNCTION pgreact_internal.m24_record(
    target_policy_id uuid,
    target_policy_version_id uuid,
    target_event_kind text,
    target_frontier timestamptz,
    target_details jsonb DEFAULT '{}'::jsonb
)
RETURNS void
LANGUAGE SQL
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m24$
    INSERT INTO pgreact_internal.effective_policy_history (
        policy_id, policy_version_id, event_kind, frontier, details
    ) VALUES ($1, $2, $3, $4, COALESCE($5, '{}'::jsonb))
    ON CONFLICT (policy_version_id, event_kind, frontier) DO NOTHING
$m24$;

CREATE FUNCTION pgreact_internal.m24_sync_rule(target_version_id uuid)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m24$
DECLARE version_row pgreact_internal.rule_versions%ROWTYPE;
    state_row pgreact_internal.activation_state%ROWTYPE;
    candidate record;
    candidate_count bigint;
    prior pgreact_internal.activation_state%ROWTYPE;
    canonical bytea;
    digest bytea;
    activation uuid;
    generation bigint;
    next_revision bigint;
    changed bigint := 0;
BEGIN
    SELECT * INTO STRICT version_row
    FROM pgreact_internal.rule_versions
    WHERE rule_version_id = target_version_id AND state = 'ACTIVE';

    EXECUTE format(
        'SELECT count(*) FROM %s source WHERE (%I) IS NULL',
        version_row.source_view_oid::regclass, version_row.key_column
    ) INTO candidate_count;
    IF candidate_count > 0 THEN
        RAISE EXCEPTION 'M24_NULL_KEY: policy source % contains % null semantic keys',
            version_row.source_view_name, candidate_count;
    END IF;
    EXECUTE format(
        'SELECT count(*) FROM (SELECT %1$I FROM %2$s GROUP BY %1$I HAVING count(*) > 1) duplicates',
        version_row.key_column, version_row.source_view_oid::regclass
    ) INTO candidate_count;
    IF candidate_count > 0 THEN
        RAISE EXCEPTION 'M24_DUPLICATE_KEY: policy source % contains duplicate semantic keys',
            version_row.source_view_name;
    END IF;

    FOR state_row IN
        SELECT * FROM pgreact_internal.activation_state
        WHERE rule_version_id = target_version_id AND active
        ORDER BY semantic_key
        FOR UPDATE
    LOOP
        EXECUTE format(
            'SELECT count(*) FROM %s source WHERE (%I)::bigint = $1',
            version_row.source_view_oid::regclass, version_row.key_column
        ) INTO candidate_count USING state_row.semantic_key;
        IF candidate_count = 0 THEN
            UPDATE pgreact_internal.activation_state
            SET active = false, current_bindings = NULL,
                deactivated_at = clock_timestamp(), last_seen_at = clock_timestamp()
            WHERE rule_version_id = target_version_id
              AND activation_id = state_row.activation_id;
            UPDATE pgreact_internal.agenda
            SET state = 'SUPERSEDED', completed_at = clock_timestamp()
            WHERE rule_version_id = target_version_id
              AND activation_id = state_row.activation_id
              AND state IN ('PENDING', 'RETRY_WAIT');
            PERFORM pgreact_internal.emit_event(
                version_row, state_row.activation_id, state_row.generation, 0,
                'DEACTIVATE', state_row.last_active_bindings, NULL);
            changed := changed + 1;
        ELSIF candidate_count > 1 THEN
            RAISE EXCEPTION 'M24_DUPLICATE_KEY: policy source % contains multiple rows for semantic key %',
                version_row.source_view_name, state_row.semantic_key;
        END IF;
    END LOOP;

    FOR candidate IN EXECUTE format(
        'SELECT (%1$I)::bigint AS semantic_key, to_jsonb(source) AS bindings '
        'FROM %2$s source ORDER BY %1$I',
        version_row.key_column, version_row.source_view_oid::regclass)
    LOOP
        SELECT count(*) INTO candidate_count
        FROM pgreact_internal.activation_state
        WHERE rule_version_id = target_version_id
          AND semantic_key = candidate.semantic_key;
        IF candidate_count > 1 THEN
            RAISE EXCEPTION 'M24_DUPLICATE_STATE: policy source % contains duplicate state for semantic key %',
                version_row.source_view_name, candidate.semantic_key;
        END IF;
        canonical := pgreact_internal.canonical_bigint_v1(candidate.semantic_key);
        digest := pgreact_internal.activation_digest(target_version_id, canonical);
        activation := pgreact_internal.activation_uuid(digest);
        SELECT * INTO prior
        FROM pgreact_internal.activation_state
        WHERE rule_version_id = target_version_id
          AND activation_id = activation
        FOR UPDATE;
        IF prior.activation_id IS NULL OR NOT prior.active THEN
            generation := COALESCE(prior.generation, 0) + 1;
            INSERT INTO pgreact_internal.activation_state (
                rule_version_id, activation_id, semantic_key, canonical_key,
                canonical_key_digest, key_codec_version, active, generation,
                revision, current_bindings, last_active_bindings,
                first_seen_at, last_seen_at
            ) VALUES (
                target_version_id, activation, candidate.semantic_key, canonical,
                digest, 1, true, generation, 0, candidate.bindings,
                candidate.bindings, clock_timestamp(), clock_timestamp()
            )
            ON CONFLICT (rule_version_id, activation_id) DO UPDATE
            SET active = true, generation = EXCLUDED.generation, revision = 0,
                current_bindings = EXCLUDED.current_bindings,
                last_active_bindings = EXCLUDED.last_active_bindings,
                last_seen_at = EXCLUDED.last_seen_at, deactivated_at = NULL;
            PERFORM pgreact_internal.emit_event(
                version_row, activation, generation, 0, 'ACTIVATE', NULL, candidate.bindings);
            changed := changed + 1;
        ELSIF pgreact_internal.watched_changed(
            version_row, prior.current_bindings, candidate.bindings
        ) THEN
            next_revision := prior.revision + 1;
            PERFORM pgreact_internal.emit_event(
                version_row, activation, prior.generation, next_revision, 'CHANGE',
                prior.current_bindings, candidate.bindings);
            UPDATE pgreact_internal.activation_state
            SET revision = next_revision, current_bindings = candidate.bindings,
                last_active_bindings = candidate.bindings, last_seen_at = clock_timestamp()
            WHERE rule_version_id = target_version_id AND activation_id = activation;
            changed := changed + 1;
        ELSE
            UPDATE pgreact_internal.activation_state
            SET current_bindings = candidate.bindings,
                last_active_bindings = candidate.bindings, last_seen_at = clock_timestamp()
            WHERE rule_version_id = target_version_id AND activation_id = activation;
        END IF;
    END LOOP;
    RETURN changed;
END
$m24$;

CREATE FUNCTION pgreact_internal.m24_deactivate_rule(target_version_id uuid)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m24$
DECLARE version_row pgreact_internal.rule_versions%ROWTYPE;
    state_row pgreact_internal.activation_state%ROWTYPE;
    changed bigint := 0;
BEGIN
    SELECT * INTO STRICT version_row
    FROM pgreact_internal.rule_versions
    WHERE rule_version_id = target_version_id;
    FOR state_row IN
        SELECT * FROM pgreact_internal.activation_state
        WHERE rule_version_id = target_version_id AND active
        ORDER BY semantic_key
        FOR UPDATE
    LOOP
        UPDATE pgreact_internal.activation_state
        SET active = false, current_bindings = NULL,
            deactivated_at = clock_timestamp(), last_seen_at = clock_timestamp()
        WHERE rule_version_id = target_version_id
          AND activation_id = state_row.activation_id;
        UPDATE pgreact_internal.agenda
        SET state = 'SUPERSEDED', completed_at = clock_timestamp()
        WHERE rule_version_id = target_version_id
          AND activation_id = state_row.activation_id
          AND state IN ('PENDING', 'RETRY_WAIT');
        PERFORM pgreact_internal.emit_event(
            version_row, state_row.activation_id, state_row.generation, 0,
            'DEACTIVATE', state_row.last_active_bindings, NULL);
        changed := changed + 1;
    END LOOP;
    RETURN changed;
END
$m24$;

CREATE FUNCTION pgreact_internal.m24_advance()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m24$
DECLARE policy_row record;
    current_row record;
    desired_row record;
    frontier timestamptz;
    transitioned bigint := 0;
    changed jsonb := '[]'::jsonb;
BEGIN
    SELECT clock.frontier INTO STRICT frontier
    FROM pgreact_internal.clock_frontier clock
    FOR UPDATE;

    FOR policy_row IN
        SELECT * FROM pgreact_internal.effective_policies ORDER BY policy_id FOR UPDATE
    LOOP
        SELECT version.policy_version_id, version.rule_version_id,
               version.target_kind, version.program_version_id,
               version.program_definition, version.valid_from,
               version.valid_to, version.effective_state
        INTO current_row
        FROM pgreact_internal.effective_policy_versions version
        WHERE version.policy_version_id = policy_row.authoritative_version_id;

        SELECT version.policy_version_id, version.rule_version_id,
               version.target_kind, version.program_version_id,
               version.program_definition, version.valid_from,
               version.valid_to
        INTO desired_row
        FROM pgreact_internal.effective_policy_versions version
        WHERE version.policy_id = policy_row.policy_id
          AND version.deployment_state = 'DEPLOYED'
          AND version.valid_from <= frontier
          AND (version.valid_to IS NULL OR frontier < version.valid_to)
        ORDER BY version.valid_from DESC, version.version DESC
        LIMIT 1;

        IF policy_row.authoritative_version_id IS DISTINCT FROM desired_row.policy_version_id THEN
            IF current_row.policy_version_id IS NOT NULL THEN
                IF current_row.target_kind = 'RULE' THEN
                    PERFORM pgreact_internal.m24_deactivate_rule(current_row.rule_version_id);
                    UPDATE pgreact_internal.rule_versions
                    SET state = 'PAUSED'
                    WHERE rule_version_id = current_row.rule_version_id
                      AND state <> 'REMOVED';
                ELSIF current_row.program_version_id IS NOT NULL THEN
                    PERFORM pgreact.remove_derivation_program(current_row.program_version_id);
                END IF;
                UPDATE pgreact_internal.effective_policy_versions
                SET effective_state = CASE
                    WHEN valid_to IS NOT NULL AND valid_to <= frontier THEN 'EXPIRED'
                    ELSE 'GAP'
                END
                WHERE policy_version_id = current_row.policy_version_id;
                PERFORM pgreact_internal.m24_record(
                    policy_row.policy_id, current_row.policy_version_id,
                    CASE WHEN current_row.valid_to IS NOT NULL AND current_row.valid_to <= frontier
                         THEN 'EXPIRED' ELSE 'GAP' END,
                    frontier,
                    jsonb_build_object('work_disposition', 'CANCEL_OLD'));
                transitioned := transitioned + 1;
            END IF;

            IF desired_row.policy_version_id IS NOT NULL THEN
                IF desired_row.target_kind = 'RULE' THEN
                    UPDATE pgreact_internal.rule_versions
                    SET state = 'ACTIVE'
                    WHERE rule_version_id = desired_row.rule_version_id
                      AND state <> 'REMOVED';
                    PERFORM pgreact_internal.m24_sync_rule(desired_row.rule_version_id);
                ELSE
                    UPDATE pgreact_internal.effective_policy_versions
                    SET program_version_id =
                        pgreact_internal.deploy_derivation_program(
                            desired_row.program_definition, NULL::uuid)
                    WHERE policy_version_id = desired_row.policy_version_id;
                END IF;
                UPDATE pgreact_internal.effective_policy_versions
                SET effective_state = 'CURRENT'
                WHERE policy_version_id = desired_row.policy_version_id;
                PERFORM pgreact_internal.m24_record(
                    policy_row.policy_id, desired_row.policy_version_id,
                    'EFFECTIVE', frontier,
                    jsonb_build_object('boundary', '[valid_from, valid_to)',
                                       'valid_from', desired_row.valid_from,
                                       'valid_to', desired_row.valid_to));
                changed := changed || jsonb_build_array(jsonb_build_object(
                    'policy', policy_row.policy_name,
                    'from', current_row.policy_version_id,
                    'to', desired_row.policy_version_id,
                    'state', 'CURRENT'));
            ELSE
                PERFORM pgreact_internal.m24_record(
                    policy_row.policy_id, NULL, 'GAP', frontier,
                    jsonb_build_object('reason', 'no deployed interval contains the frontier'));
                changed := changed || jsonb_build_array(jsonb_build_object(
                    'policy', policy_row.policy_name, 'state', 'GAP'));
            END IF;
            UPDATE pgreact_internal.effective_policies
            SET authoritative_version_id = desired_row.policy_version_id
            WHERE policy_id = policy_row.policy_id;
        END IF;

        UPDATE pgreact_internal.effective_policy_versions version
        SET effective_state = pgreact_internal.m24_policy_version_state(
            version.valid_from, version.valid_to, version.deployment_state, frontier)
        WHERE version.policy_id = policy_row.policy_id
          AND version.policy_version_id IS DISTINCT FROM desired_row.policy_version_id;
    END LOOP;
    RETURN jsonb_build_object(
        'frontier', frontier, 'transitions', transitioned, 'changed', changed);
END
$m24$;

CREATE FUNCTION pgreact_internal.register_effective_policy(
    target_policy_name text,
    target_rule_version_id uuid,
    target_valid_from timestamptz,
    target_valid_to timestamptz
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m24$
#variable_conflict use_variable
DECLARE diagnostic record;
    policy_id uuid;
    policy_version_id uuid := gen_random_uuid();
    owner_id oid;
    next_version integer;
    frontier timestamptz;
    rule_state text;
BEGIN
    SELECT result.* INTO diagnostic
    FROM pgreact_internal.validate_effective_policy(
        target_policy_name, target_rule_version_id, target_valid_from, target_valid_to) result
    WHERE result.severity = 'ERROR'
    ORDER BY result.code
    LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'pg-react effective-policy validation % for %: %',
            diagnostic.code, diagnostic.object_identity, diagnostic.message
            USING HINT = diagnostic.hint;
    END IF;
    SELECT owner_oid INTO STRICT owner_id
    FROM pgreact_internal.rule_versions
    WHERE rule_version_id = target_rule_version_id;
    SELECT clock.frontier INTO STRICT frontier
    FROM pgreact_internal.clock_frontier clock;

    SELECT policy.policy_id INTO policy_id
    FROM pgreact_internal.effective_policies policy
    WHERE policy.policy_name = target_policy_name
    FOR UPDATE;
    IF policy_id IS NULL THEN
        policy_id := gen_random_uuid();
        INSERT INTO pgreact_internal.effective_policies (
            policy_id, policy_name, owner_oid
        ) VALUES (policy_id, target_policy_name, owner_id);
    END IF;
    SELECT COALESCE(max(version), 0) + 1 INTO next_version
    FROM pgreact_internal.effective_policy_versions
    WHERE effective_policy_versions.policy_id = policy_id;
    INSERT INTO pgreact_internal.effective_policy_versions (
        policy_version_id, policy_id, rule_version_id, version,
        valid_from, valid_to, deployment_state, effective_state
    ) VALUES (
        policy_version_id, policy_id, target_rule_version_id, next_version,
        target_valid_from, target_valid_to, 'DEPLOYED',
        pgreact_internal.m24_policy_version_state(
            target_valid_from, target_valid_to, 'DEPLOYED', frontier));
    PERFORM pgreact_internal.m24_record(
        policy_id, policy_version_id, 'DEPLOYED', frontier,
        jsonb_build_object('deployment_frontier', frontier,
                           'valid_from', target_valid_from,
                           'valid_to', target_valid_to));
    SELECT state INTO STRICT rule_state
    FROM pgreact_internal.rule_versions
    WHERE rule_version_id = target_rule_version_id;
    IF target_valid_from > frontier THEN
        IF rule_state = 'ACTIVE' AND EXISTS (
            SELECT 1 FROM pgreact_internal.activation_state
            WHERE rule_version_id = target_rule_version_id AND active
        ) THEN
            RAISE EXCEPTION 'M24_FUTURE_RULE_ACTIVE: future policy version % already has active matches',
                target_rule_version_id
                USING HINT = 'Pause and reconcile the rule before scheduling it.';
        END IF;
        UPDATE pgreact_internal.rule_versions SET state = 'PAUSED'
        WHERE rule_version_id = target_rule_version_id AND state = 'ACTIVE';
    END IF;
    PERFORM pgreact_internal.m24_advance();
    RETURN policy_version_id;
END
$m24$;

CREATE FUNCTION pgreact_internal.register_effective_program(
    target_policy_name text,
    target_definition jsonb,
    target_valid_from timestamptz,
    target_valid_to timestamptz
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m24$
#variable_conflict use_variable
DECLARE diagnostic record;
    policy_id uuid;
    policy_version_id uuid := gen_random_uuid();
    owner_id oid;
    next_version integer;
    frontier timestamptz;
BEGIN
    SELECT result.* INTO diagnostic
    FROM pgreact_internal.validate_effective_program(
        target_policy_name, target_definition, target_valid_from, target_valid_to) result
    WHERE result.severity = 'ERROR'
    ORDER BY result.code
    LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'pg-react effective-program validation % for %: %',
            diagnostic.code, diagnostic.object_identity, diagnostic.message
            USING HINT = diagnostic.hint;
    END IF;
    SELECT oid INTO STRICT owner_id
    FROM pg_roles WHERE rolname = session_user;
    SELECT clock.frontier INTO STRICT frontier
    FROM pgreact_internal.clock_frontier clock;
    SELECT policy.policy_id INTO policy_id
    FROM pgreact_internal.effective_policies policy
    WHERE policy.policy_name = target_policy_name
    FOR UPDATE;
    IF policy_id IS NULL THEN
        policy_id := gen_random_uuid();
        INSERT INTO pgreact_internal.effective_policies (
            policy_id, policy_name, owner_oid
        ) VALUES (policy_id, target_policy_name, owner_id);
    END IF;
    SELECT COALESCE(max(version), 0) + 1 INTO next_version
    FROM pgreact_internal.effective_policy_versions
    WHERE effective_policy_versions.policy_id = policy_id;
    INSERT INTO pgreact_internal.effective_policy_versions (
        policy_version_id, policy_id, target_kind, program_definition, version,
        valid_from, valid_to, deployment_state, effective_state
    ) VALUES (
        policy_version_id, policy_id, 'PROGRAM', target_definition, next_version,
        target_valid_from, target_valid_to, 'DEPLOYED',
        pgreact_internal.m24_policy_version_state(
            target_valid_from, target_valid_to, 'DEPLOYED', frontier));
    PERFORM pgreact_internal.m24_record(
        policy_id, policy_version_id, 'DEPLOYED', frontier,
        jsonb_build_object('deployment_frontier', frontier,
                           'target_kind', 'PROGRAM',
                           'program', target_definition ->> 'name',
                           'version', target_definition ->> 'version',
                           'valid_from', target_valid_from,
                           'valid_to', target_valid_to));
    PERFORM pgreact_internal.m24_advance();
    RETURN policy_version_id;
END
$m24$;

CREATE FUNCTION pgreact_api.deploy_effective_policy(
    policy_name text,
    rule_version_id uuid,
    valid_from timestamptz,
    valid_to timestamptz DEFAULT NULL
)
RETURNS uuid
LANGUAGE SQL
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m24$
    SELECT pgreact_internal.register_effective_policy($1, $2, $3, $4)
$m24$;

CREATE FUNCTION pgreact_api.author_effective_rule(
    policy_name text,
    rule_name text,
    condition regclass,
    semantic_key name,
    valid_from timestamptz,
    valid_to timestamptz DEFAULT NULL,
    kind text DEFAULT 'COMMAND',
    on_activate regprocedure DEFAULT NULL,
    on_deactivate regprocedure DEFAULT NULL,
    on_change regprocedure DEFAULT NULL,
    bootstrap_policy text DEFAULT 'SEED_CURRENT',
    change_columns name[] DEFAULT NULL,
    salience integer DEFAULT 0,
    agenda_group text DEFAULT 'default',
    conflict_key_columns name[] DEFAULT NULL,
    max_attempts integer DEFAULT 1,
    initial_backoff_seconds integer DEFAULT 1,
    backoff_multiplier numeric DEFAULT 2,
    max_backoff_seconds integer DEFAULT 60
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m24$
DECLARE new_rule_version_id uuid;
    policy_version_id uuid;
BEGIN
new_rule_version_id := pgreact.create_rule(
        name => rule_name, definition => condition,
        key_columns => ARRAY[semantic_key]::name[], kind => kind,
        on_activate => on_activate, on_deactivate => on_deactivate,
        on_change => on_change, bootstrap_policy => bootstrap_policy,
        change_columns => change_columns, salience => salience,
        agenda_group => agenda_group, conflict_key_columns => conflict_key_columns,
        max_attempts => max_attempts, initial_backoff_seconds => initial_backoff_seconds,
        backoff_multiplier => backoff_multiplier, max_backoff_seconds => max_backoff_seconds);
    UPDATE pgreact_internal.rule_versions
    SET state = 'PAUSED'
    WHERE pgreact_internal.rule_versions.rule_version_id = new_rule_version_id;
    DELETE FROM pgreact_internal.activation_state
    WHERE activation_state.rule_version_id = new_rule_version_id;
    policy_version_id := pgreact_internal.register_effective_policy(
        policy_name, new_rule_version_id, valid_from, valid_to);
    RETURN policy_version_id;
END
$m24$;

CREATE FUNCTION pgreact_api.register_effective_policy_version(
    policy_name text,
    rule_version_id uuid,
    valid_from timestamptz,
    valid_to timestamptz DEFAULT NULL
)
RETURNS uuid
LANGUAGE SQL
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m24$
    SELECT pgreact_api.deploy_effective_policy($1, $2, $3, $4)
$m24$;

CREATE FUNCTION pgreact_api.author_effective_program(
    policy_name text,
    definition jsonb,
    valid_from timestamptz,
    valid_to timestamptz DEFAULT NULL
)
RETURNS uuid
LANGUAGE SQL
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m24$
    SELECT pgreact_internal.register_effective_program($1, $2, $3, $4)
$m24$;

CREATE FUNCTION pgreact_api.pause_effective_policy(target_policy_name text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m24$
#variable_conflict use_variable
DECLARE policy_id uuid;
BEGIN
    SELECT policy.policy_id INTO STRICT policy_id
    FROM pgreact_internal.effective_policies policy
    WHERE policy.policy_name = target_policy_name
      AND (policy.owner_oid = (SELECT oid FROM pg_roles WHERE rolname = session_user)
           OR pgreact_internal.is_operator_admin())
    FOR UPDATE;
    UPDATE pgreact_internal.effective_policy_versions
    SET deployment_state = 'PAUSED', effective_state = 'PAUSED'
    WHERE effective_policy_versions.policy_id = policy_id
      AND deployment_state = 'DEPLOYED';
    PERFORM pgreact_internal.m24_record(
        policy_id, NULL, 'PAUSED',
        (SELECT frontier FROM pgreact_internal.clock_frontier));
    PERFORM pgreact_internal.m24_advance();
END
$m24$;

CREATE FUNCTION pgreact_api.resume_effective_policy(target_policy_name text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m24$
#variable_conflict use_variable
DECLARE policy_id uuid;
BEGIN
    SELECT policy.policy_id INTO STRICT policy_id
    FROM pgreact_internal.effective_policies policy
    WHERE policy.policy_name = target_policy_name
      AND (policy.owner_oid = (SELECT oid FROM pg_roles WHERE rolname = session_user)
           OR pgreact_internal.is_operator_admin())
    FOR UPDATE;
    UPDATE pgreact_internal.effective_policy_versions
    SET deployment_state = 'DEPLOYED'
    WHERE effective_policy_versions.policy_id = policy_id
      AND deployment_state = 'PAUSED';
    PERFORM pgreact_internal.m24_record(
        policy_id, NULL, 'RESUMED',
        (SELECT frontier FROM pgreact_internal.clock_frontier));
    PERFORM pgreact_internal.m24_advance();
END
$m24$;

CREATE FUNCTION pgreact_api.remove_effective_policy(target_policy_name text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m24$
#variable_conflict use_variable
DECLARE policy_id uuid;
BEGIN
    SELECT policy.policy_id INTO STRICT policy_id
    FROM pgreact_internal.effective_policies policy
    WHERE policy.policy_name = target_policy_name
      AND (policy.owner_oid = (SELECT oid FROM pg_roles WHERE rolname = session_user)
           OR pgreact_internal.is_operator_admin())
    FOR UPDATE;
    UPDATE pgreact_internal.effective_policy_versions
    SET deployment_state = 'PAUSED', effective_state = 'PAUSED'
    WHERE effective_policy_versions.policy_id = policy_id
      AND deployment_state <> 'REMOVED';
    PERFORM pgreact_internal.m24_advance();
    UPDATE pgreact_internal.effective_policy_versions
    SET deployment_state = 'REMOVED', effective_state = 'REMOVED'
    WHERE effective_policy_versions.policy_id = policy_id;
    PERFORM pgreact_internal.m24_record(
        policy_id, NULL, 'REMOVED',
        (SELECT frontier FROM pgreact_internal.clock_frontier));
END
$m24$;

CREATE FUNCTION pgreact_internal.reconcile_effective_policy(target_policy_name text)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m24$
DECLARE version_id uuid;
    repaired bigint := 0;
BEGIN
    PERFORM pgreact_internal.m24_advance();
    SELECT policy.authoritative_version_id INTO version_id
    FROM pgreact_internal.effective_policies policy
    WHERE policy.policy_name = target_policy_name;
    IF version_id IS NOT NULL THEN
        SELECT repaired + pgreact_internal.m24_sync_rule(version.rule_version_id)
        INTO repaired
        FROM pgreact_internal.effective_policy_versions version
        WHERE version.policy_version_id = version_id;
    END IF;
    RETURN repaired;
END
$m24$;

CREATE FUNCTION pgreact_api.reconcile_effective_policy(target_policy_name text)
RETURNS bigint
LANGUAGE SQL
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m24$
    SELECT pgreact_internal.reconcile_effective_policy($1)
$m24$;

CREATE FUNCTION pgreact_api.effective_policy_status(target_policy_name text DEFAULT NULL)
RETURNS jsonb
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m24$
    SELECT jsonb_build_object(
        'contract_version', 12,
        'clock_domain', 'DATABASE_TIME',
        'frontier', (SELECT frontier FROM pgreact_internal.clock_frontier),
        'policies', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                'policy_id', policy.policy_id,
                'policy', policy.policy_name,
                'owner', pg_get_userbyid(policy.owner_oid),
                'state', public_policy.state,
                'authoritative_version', policy.authoritative_version_id,
                'versions', (
                    SELECT COALESCE(jsonb_agg(jsonb_build_object(
                        'policy_version_id', version.policy_version_id,
                        'rule_version_id', version.rule_version_id,
                        'target_kind', version.target_kind,
                        'program_version_id', version.program_version_id,
                        'rule', COALESCE(rule.rule_name, version.program_definition ->> 'name'),
                        'version', version.version,
                        'valid_from', version.valid_from,
                        'valid_to', version.valid_to,
                        'interval', '[valid_from, valid_to)',
                        'deployment_state', version.deployment_state,
                        'effective_state', version.effective_state,
                        'authoritative', version.policy_version_id = policy.authoritative_version_id,
                        'next_transition', CASE
                            WHEN version.effective_state = 'FUTURE' THEN version.valid_from
                            WHEN version.effective_state = 'CURRENT' THEN version.valid_to
                            ELSE NULL
                        END)
                        ORDER BY version.valid_from, version.version), '[]'::jsonb)
                    FROM pgreact_internal.effective_policy_versions version
                    LEFT JOIN pgreact_internal.rule_versions rule_version
                      ON rule_version.rule_version_id = version.rule_version_id
                    LEFT JOIN pgreact_internal.rules rule USING (rule_id)
                    WHERE version.policy_id = policy.policy_id
                      AND version.deployment_state <> 'REMOVED'
                ))
                ORDER BY policy.policy_name)
            FROM pgreact.effective_policies public_policy
            JOIN pgreact_internal.effective_policies policy
              USING (policy_id)
            WHERE target_policy_name IS NULL OR policy.policy_name = target_policy_name
        ), '[]'::jsonb)
    )
$m24$;

CREATE FUNCTION pgreact_api.preview_effective_policy(target_policy_name text DEFAULT NULL)
RETURNS jsonb
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m24$
    SELECT pgreact_api.effective_policy_status($1)
$m24$;

CREATE FUNCTION pgreact_api.effective_policy_preview(target_policy_name text DEFAULT NULL)
RETURNS jsonb
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m24$
    SELECT pgreact_api.preview_effective_policy($1)
$m24$;

CREATE FUNCTION pgreact_api.effective_policy_history(target_policy_name text)
RETURNS jsonb
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m24$
    SELECT COALESCE(jsonb_agg(to_jsonb(history) ORDER BY history.frontier, history.transition_id), '[]'::jsonb)
    FROM pgreact_internal.effective_policy_history history
    JOIN pgreact_internal.effective_policies policy USING (policy_id)
    WHERE policy.policy_name = $1
$m24$;

CREATE FUNCTION pgreact_api.explain_effective_policy(
    target_policy_name text,
    semantic_key bigint
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m24$
DECLARE policy_row record;
    version_row record;
    activation uuid;
    evidence jsonb;
BEGIN
    SELECT * INTO STRICT policy_row
    FROM pgreact_internal.effective_policies
    WHERE policy_name = target_policy_name;
    SELECT version.*, COALESCE(rule.rule_name, version.program_definition ->> 'name') AS rule_name
    INTO STRICT version_row
    FROM pgreact_internal.effective_policy_versions version
    LEFT JOIN pgreact_internal.rule_versions rule_version USING (rule_version_id)
    LEFT JOIN pgreact_internal.rules rule USING (rule_id)
    WHERE version.policy_version_id = policy_row.authoritative_version_id;
    IF version_row.target_kind = 'PROGRAM' THEN
        RETURN jsonb_build_object(
            'contract_version', 12,
            'policy', target_policy_name,
            'target_kind', 'PROGRAM',
            'program_version_id', version_row.program_version_id,
            'program', version_row.program_definition ->> 'name',
            'program_definition', version_row.program_definition,
            'interval', jsonb_build_object(
                'valid_from', version_row.valid_from,
                'valid_to', version_row.valid_to,
                'boundary', '[valid_from, valid_to)'),
            'frontier', (SELECT frontier FROM pgreact_internal.clock_frontier));
    END IF;
    activation := pgreact_internal.activation_uuid(
        pgreact_internal.activation_digest(
            version_row.rule_version_id,
            pgreact_internal.canonical_bigint_v1(semantic_key)));
    evidence := pgreact.explain_activation(version_row.rule_version_id, activation);
    RETURN jsonb_build_object(
        'contract_version', 12,
        'policy', target_policy_name,
        'policy_version_id', version_row.policy_version_id,
        'rule', version_row.rule_name,
        'semantic_key', semantic_key,
        'interval', jsonb_build_object(
            'valid_from', version_row.valid_from,
            'valid_to', version_row.valid_to,
            'boundary', '[valid_from, valid_to)'),
        'frontier', (SELECT frontier FROM pgreact_internal.clock_frontier),
        'evidence', evidence);
END
$m24$;

CREATE FUNCTION pgreact_api.effective_policy_explain(
    target_policy_name text,
    semantic_key bigint
)
RETURNS jsonb
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m24$
    SELECT pgreact_api.explain_effective_policy($1, $2)
$m24$;

CREATE FUNCTION pgreact_api.author_effective_policy(
    policy_name text,
    rule_name text,
    condition regclass,
    semantic_key name,
    valid_from timestamptz,
    valid_to timestamptz DEFAULT NULL,
    kind text DEFAULT 'COMMAND',
    on_activate regprocedure DEFAULT NULL,
    on_deactivate regprocedure DEFAULT NULL,
    on_change regprocedure DEFAULT NULL,
    bootstrap_policy text DEFAULT 'SEED_CURRENT',
    change_columns name[] DEFAULT NULL,
    salience integer DEFAULT 0,
    agenda_group text DEFAULT 'default',
    conflict_key_columns name[] DEFAULT NULL,
    max_attempts integer DEFAULT 1,
    initial_backoff_seconds integer DEFAULT 1,
    backoff_multiplier numeric DEFAULT 2,
    max_backoff_seconds integer DEFAULT 60
)
RETURNS uuid
LANGUAGE SQL
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m24$
    SELECT pgreact_api.author_effective_rule(
        $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14,
        $15, $16, $17, $18, $19)
$m24$;

CREATE FUNCTION pgreact_api.effective_policy_doctor()
RETURNS jsonb
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m24$
    WITH diagnostics AS (
        SELECT jsonb_build_object(
            'code', 'M24_EXTENSION_VERSION', 'severity', 'ERROR',
            'object_identity', 'pg_react',
            'message', 'the pg_react extension is not version 0.21.0',
            'hint', 'Install the matching extension files and run ALTER EXTENSION pg_react UPDATE TO ''0.21.0''.')
            AS diagnostic
        WHERE NOT EXISTS (
            SELECT 1 FROM pg_extension
            WHERE extname = 'pg_react' AND extversion = '0.21.0')
        UNION ALL
        SELECT jsonb_build_object(
            'code', 'M24_INTERVAL_OVERLAP', 'severity', 'ERROR',
            'object_identity', policy.policy_name,
            'message', 'deployed effective intervals overlap',
            'hint', 'Pause or remove the conflicting version before continuing.')
        FROM pgreact_internal.effective_policies policy
        JOIN pgreact_internal.effective_policy_versions left_version
          ON left_version.policy_id = policy.policy_id
         AND left_version.deployment_state <> 'REMOVED'
        JOIN pgreact_internal.effective_policy_versions right_version
          ON right_version.policy_id = policy.policy_id
         AND right_version.deployment_state <> 'REMOVED'
         AND left_version.policy_version_id < right_version.policy_version_id
        WHERE left_version.valid_from < COALESCE(right_version.valid_to, 'infinity'::timestamptz)
          AND right_version.valid_from < COALESCE(left_version.valid_to, 'infinity'::timestamptz)
        UNION ALL
        SELECT jsonb_build_object(
            'code', 'M24_AUTHORITY_DRIFT', 'severity', 'ERROR',
            'object_identity', policy.policy_name,
            'message', 'stored authority does not match the committed frontier',
            'hint', 'Run reconcile_effective_policy and inspect the transition history.')
        FROM pgreact_internal.effective_policies policy
        CROSS JOIN pgreact_internal.clock_frontier frontier
        WHERE policy.authoritative_version_id IS DISTINCT FROM (
            SELECT version.policy_version_id
            FROM pgreact_internal.effective_policy_versions version
            WHERE version.policy_id = policy.policy_id
              AND version.deployment_state = 'DEPLOYED'
              AND version.valid_from <= frontier.frontier
              AND (version.valid_to IS NULL OR frontier.frontier < version.valid_to)
            ORDER BY version.valid_from DESC, version.version DESC
            LIMIT 1)
    )
    SELECT jsonb_build_object(
        'contract_version', 12,
        'clock_domain', 'DATABASE_TIME',
        'status', CASE WHEN EXISTS (
            SELECT 1 FROM diagnostics WHERE diagnostic ->> 'severity' = 'ERROR')
            THEN 'attention' ELSE 'ready' END,
        'diagnostics', COALESCE((SELECT jsonb_agg(diagnostic) FROM diagnostics), '[]'::jsonb))
$m24$;

ALTER FUNCTION pgreact_api.run(timestamptz) SET SCHEMA pgreact_internal;
ALTER FUNCTION pgreact_internal.run(timestamptz) RENAME TO run_m23;

CREATE FUNCTION pgreact_api.run(sampled_time timestamptz DEFAULT clock_timestamp())
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m24$
DECLARE result jsonb;
    effective jsonb;
BEGIN
    result := pgreact_internal.run_m23(sampled_time);
    effective := pgreact_internal.m24_advance();
    RETURN jsonb_set(
        result || jsonb_build_object('effective_policies', effective),
        '{contract_version}', '12'::jsonb, true);
END
$m24$;

ALTER FUNCTION pgreact_api.status(text) SET SCHEMA pgreact_internal;
ALTER FUNCTION pgreact_internal.status(text) RENAME TO status_m23;

CREATE FUNCTION pgreact_api.status(target_name text DEFAULT NULL)
RETURNS jsonb
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m24$
    SELECT pgreact_internal.status_m23($1)
        || jsonb_build_object('effective_policies',
               pgreact_api.effective_policy_status($1) -> 'policies',
               'contract_version', 12)
$m24$;

ALTER FUNCTION pgreact_api.doctor() SET SCHEMA pgreact_internal;
ALTER FUNCTION pgreact_internal.doctor() RENAME TO doctor_m23;

CREATE FUNCTION pgreact_api.doctor()
RETURNS jsonb
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m24$
    SELECT jsonb_build_object(
        'contract_version', 12,
        'status', CASE WHEN EXISTS (
            SELECT 1
            FROM jsonb_array_elements(
                COALESCE(pgreact_internal.doctor_m23() -> 'diagnostics', '[]'::jsonb)
                || (pgreact_api.effective_policy_doctor() -> 'diagnostics')
            ) item
            WHERE item ->> 'severity' = 'ERROR'
        ) THEN 'attention' ELSE 'ready' END,
        'diagnostics', COALESCE(pgreact_internal.doctor_m23() -> 'diagnostics', '[]'::jsonb)
            || (pgreact_api.effective_policy_doctor() -> 'diagnostics'))
$m24$;

ALTER FUNCTION pgreact_api.configure_roles(regrole, regrole, regrole, regrole, regrole)
    SET SCHEMA pgreact_internal;
ALTER FUNCTION pgreact_internal.configure_roles(regrole, regrole, regrole, regrole, regrole)
    RENAME TO configure_roles_m23;

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
AS $m24$
BEGIN
    PERFORM pgreact_internal.configure_roles_m23(
        author_role, operator_role, worker_role, reader_role, advanced_reader_role);
    EXECUTE format(
        'GRANT EXECUTE ON FUNCTION pgreact_api.validate_effective_policy(text,uuid,timestamptz,timestamptz), '
        'pgreact_api.validate_effective_program(text,jsonb,timestamptz,timestamptz), '
        'pgreact_api.author_effective_rule(text,text,regclass,name,timestamptz,timestamptz,text,regprocedure,regprocedure,regprocedure,text,name[],integer,text,name[],integer,integer,numeric,integer), '
        'pgreact_api.author_effective_program(text,jsonb,timestamptz,timestamptz), '
        'pgreact_api.author_effective_policy(text,text,regclass,name,timestamptz,timestamptz,text,regprocedure,regprocedure,regprocedure,text,name[],integer,text,name[],integer,integer,numeric,integer), '
        'pgreact_api.deploy_effective_policy(text,uuid,timestamptz,timestamptz), '
        'pgreact_api.register_effective_policy_version(text,uuid,timestamptz,timestamptz) TO %I',
        author_role::text);
    EXECUTE format(
        'GRANT EXECUTE ON FUNCTION pgreact_api.effective_policy_status(text), '
        'pgreact_api.preview_effective_policy(text), '
        'pgreact_api.effective_policy_preview(text), '
        'pgreact_api.effective_policy_history(text), '
        'pgreact_api.explain_effective_policy(text,bigint), '
        'pgreact_api.effective_policy_explain(text,bigint), '
        'pgreact_api.effective_policy_doctor() TO %I',
        reader_role::text);
    EXECUTE format(
        'GRANT EXECUTE ON FUNCTION pgreact_api.effective_policy_status(text), '
        'pgreact_api.preview_effective_policy(text), '
        'pgreact_api.effective_policy_preview(text), '
        'pgreact_api.effective_policy_history(text), '
        'pgreact_api.explain_effective_policy(text,bigint), '
        'pgreact_api.effective_policy_explain(text,bigint), '
        'pgreact_api.effective_policy_doctor(), '
        'pgreact_api.pause_effective_policy(text), '
        'pgreact_api.resume_effective_policy(text), '
        'pgreact_api.remove_effective_policy(text), '
        'pgreact_api.reconcile_effective_policy(text) TO %I',
        operator_role::text);
END
$m24$;

DO $m24$
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
$m24$;

REVOKE ALL ON ALL TABLES IN SCHEMA pgreact_internal FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA pgreact_internal FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA pgreact_api FROM PUBLIC;

COMMENT ON EXTENSION pg_react IS
    'M24 effective-dated policy versions over the M23 practical temporal platform';
