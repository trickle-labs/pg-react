-- M29 policy-set gating: one immutable member list and one typed applicability source.

CREATE TABLE pgreact_internal.policy_sets (
    policy_set_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    set_name text NOT NULL UNIQUE,
    owner_oid oid NOT NULL,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE pgreact_internal.policy_set_versions (
    policy_set_version_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    policy_set_id uuid NOT NULL REFERENCES pgreact_internal.policy_sets,
    version text NOT NULL,
    normalized jsonb NOT NULL,
    declaration_digest bytea NOT NULL,
    applicability_kind text NOT NULL CHECK (applicability_kind IN ('relation', 'shared_condition')),
    applicability_source text NOT NULL,
    applicability_source_oid oid,
    applicability_condition_version_id uuid,
    subject_key name NOT NULL,
    subject_type regtype NOT NULL,
    valid_from timestamptz NOT NULL,
    valid_to timestamptz,
    complete_frontier timestamptz NOT NULL,
    applicability_fingerprint text NOT NULL,
    eligible_subjects jsonb NOT NULL DEFAULT '[]'::jsonb,
    eligible_subject_count bigint NOT NULL DEFAULT 0,
    state text NOT NULL CHECK (state IN ('DEPLOYED', 'REMOVED')),
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    deployed_at timestamptz,
    removed_at timestamptz,
    UNIQUE (policy_set_id, version),
    CHECK (valid_to IS NULL OR valid_to > valid_from)
);

CREATE UNIQUE INDEX policy_set_one_deployed_version
    ON pgreact_internal.policy_set_versions (policy_set_id, version)
    WHERE state = 'DEPLOYED';

CREATE TABLE pgreact_internal.policy_set_members (
    policy_set_version_id uuid NOT NULL REFERENCES pgreact_internal.policy_set_versions,
    ordinal integer NOT NULL CHECK (ordinal > 0),
    member_kind text NOT NULL,
    member_name text NOT NULL,
    member_version text NOT NULL,
    member_target jsonb NOT NULL,
    PRIMARY KEY (policy_set_version_id, ordinal),
    UNIQUE (policy_set_version_id, member_kind, member_name, member_version)
);

CREATE TABLE pgreact_internal.policy_set_history (
    event_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    policy_set_version_id uuid NOT NULL REFERENCES pgreact_internal.policy_set_versions,
    event_kind text NOT NULL CHECK (event_kind IN ('DEPLOYED', 'REFRESHED', 'REMOVED')),
    frontier timestamptz NOT NULL,
    details jsonb NOT NULL DEFAULT '{}'::jsonb,
    occurred_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE INDEX policy_set_version_lookup
    ON pgreact_internal.policy_set_versions (policy_set_id, state, valid_from, valid_to);

CREATE FUNCTION pgreact_internal.m29_finding(
    code text,
    severity text,
    object_identity text,
    field_path text,
    message text,
    hint text,
    details jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE SQL IMMUTABLE AS $$
    SELECT jsonb_build_object(
        'code', $1, 'severity', $2, 'blocker', $2 = 'ERROR',
        'object_identity', $3, 'field_path', $4, 'message', $5,
        'hint', $6, 'details', COALESCE($7, '{}'::jsonb),
        'evidence', '[]'::jsonb, 'truncated', false)
$$;

CREATE FUNCTION pgreact_internal.m29_normalize(declaration pgreact_api.declaration)
RETURNS jsonb
LANGUAGE SQL IMMUTABLE STRICT AS $$
    SELECT jsonb_build_object(
        'api_version', (declaration).api_version,
        'kind', (declaration).kind,
        'name', (declaration).name,
        'spec', jsonb_build_object(
            'version', (declaration).spec ->> 'version',
            'members', CASE WHEN jsonb_typeof((declaration).spec -> 'members') = 'array' THEN COALESCE((
                SELECT jsonb_agg(jsonb_build_object(
                    'kind', value ->> 'kind',
                    'name', value ->> 'name',
                    'version', value ->> 'version')
                    ORDER BY value ->> 'kind', value ->> 'name', value ->> 'version')
                FROM jsonb_array_elements((declaration).spec -> 'members') value
            ), '[]'::jsonb) ELSE '[]'::jsonb END,
            'applicability', jsonb_build_object(
                'source_kind', (declaration).spec -> 'applicability' ->> 'source_kind',
                'relation', (declaration).spec -> 'applicability' ->> 'relation',
                'condition', (declaration).spec -> 'applicability' ->> 'condition',
                'version', (declaration).spec -> 'applicability' ->> 'version',
                'subject_key', (declaration).spec -> 'applicability' ->> 'subject_key'),
            'valid_from', (declaration).spec ->> 'valid_from',
            'valid_to', (declaration).spec ->> 'valid_to',
            'evidence_limit', COALESCE((declaration).spec -> 'evidence_limit', '100'::jsonb)))
$$;

CREATE FUNCTION pgreact_internal.m29_relation_details(source_oid oid, key_column name)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $m29$
DECLARE result jsonb;
BEGIN
    EXECUTE format(
        'SELECT jsonb_build_object(''row_count'', count(*), ''null_count'', count(*) - count(s.%1$I), '
        '''distinct_count'', count(DISTINCT s.%1$I), ''eligible_subjects'', '
        'COALESCE(jsonb_agg(to_jsonb(s.%1$I) ORDER BY s.%1$I) '
        'FILTER (WHERE s.%1$I IS NOT NULL), ''[]''::jsonb)) FROM %2$s s',
        key_column, source_oid::regclass)
    INTO result;
    RETURN result;
END
$m29$;

CREATE FUNCTION pgreact_internal.m29_relation_fingerprint(
    source_oid oid,
    key_column name,
    complete_frontier timestamptz
)
RETURNS text
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $m29$
DECLARE details jsonb;
    signature bytea;
BEGIN
    IF source_oid IS NULL THEN
        RETURN NULL;
    END IF;
    details := pgreact_internal.m29_relation_details(source_oid, key_column);
    signature := pgreact_internal.source_row_signature(source_oid);
    RETURN encode(sha256(convert_to(
        COALESCE(details::text, '') || ':' || encode(signature, 'hex') || ':' ||
        COALESCE(complete_frontier::text, ''), 'UTF8')), 'hex');
END
$m29$;

CREATE FUNCTION pgreact_internal.m29_member_exists(
    member_kind text,
    member_name text,
    member_version text
)
RETURNS boolean
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $m29$
DECLARE found_member boolean := false;
BEGIN
    SELECT EXISTS (
        SELECT 1 FROM pgreact_internal.api_declarations
        WHERE kind = member_kind AND object_name = member_name AND state = 'DEPLOYED')
    INTO found_member;
    IF found_member THEN RETURN true; END IF;
    IF member_kind = 'rule' THEN
        SELECT EXISTS (SELECT 1 FROM pgreact.rules WHERE rule_name = member_name
                       AND (member_version IS NULL OR rule_version_id::text = member_version))
        INTO found_member;
    ELSIF member_kind = 'derived_program' THEN
        SELECT EXISTS (SELECT 1 FROM pgreact.derivation_programs WHERE program_name = member_name)
        INTO found_member;
    ELSIF member_kind = 'shared_condition' THEN
        SELECT EXISTS (SELECT 1 FROM pgreact_internal.shared_conditions WHERE condition_name = member_name)
        INTO found_member;
    ELSIF member_kind = 'effective_policy' THEN
        SELECT EXISTS (SELECT 1 FROM pgreact_internal.effective_policies WHERE policy_name = member_name)
        INTO found_member;
    ELSIF member_kind = 'parameter_family' THEN
        SELECT EXISTS (SELECT 1 FROM pgreact_internal.parameter_families WHERE family_name = member_name)
        INTO found_member;
    ELSIF member_kind = 'decision_program' THEN
        SELECT EXISTS (SELECT 1 FROM pgreact_internal.decision_programs WHERE program_name = member_name)
        INTO found_member;
    END IF;
    RETURN found_member;
END
$m29$;

CREATE FUNCTION pgreact_internal.m29_validate(declaration pgreact_api.declaration)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $m29$
DECLARE findings jsonb := '[]'::jsonb;
    normalized jsonb;
    spec jsonb;
    applicability jsonb;
    member jsonb;
    member_kind text;
    member_name text;
    member_version text;
    source_kind text;
    source_name text;
    relation_oid oid;
    condition_version_id uuid;
    subject_key name;
    subject_type regtype;
    field text;
    duplicate text;
    details jsonb;
    valid_from timestamptz;
    valid_to timestamptz;
    evidence_limit integer;
    source_owner oid;
    source_kind_catalog "char";
    source_rls boolean;
    condition_key name;
BEGIN
    IF declaration IS NULL THEN
        RETURN jsonb_build_object('normalized', NULL, 'findings', jsonb_build_array(
            pgreact_internal.m29_finding('M29_DECLARATION_NULL', 'ERROR', '<unnamed>', '<declaration>',
                'policy-set declaration is required', 'Build it with pgreact_api.declaration().')));
    END IF;
    normalized := pgreact_internal.m29_normalize(declaration);
    spec := COALESCE((declaration).spec, '{}'::jsonb);
    IF (declaration).api_version IS DISTINCT FROM '1' THEN
        findings := findings || jsonb_build_array(pgreact_internal.m29_finding(
            'M29_API_VERSION', 'ERROR', (declaration).name, 'api_version',
            'only declaration API version 1 is supported', 'Set api_version to 1.'));
    END IF;
    IF (declaration).kind IS DISTINCT FROM 'policy_set' THEN
        findings := findings || jsonb_build_array(pgreact_internal.m29_finding(
            'M29_KIND', 'ERROR', COALESCE((declaration).name, '<unnamed>'), 'kind',
            'this validator accepts policy_set declarations', 'Use kind policy_set.'));
    END IF;
    IF (declaration).name IS NULL OR (declaration).name !~ '^[A-Za-z_][A-Za-z0-9_.-]*$' THEN
        findings := findings || jsonb_build_array(pgreact_internal.m29_finding(
            'M29_NAME', 'ERROR', COALESCE((declaration).name, '<unnamed>'), 'name',
            'name must be a stable non-empty public name', 'Use letters, digits, underscore, dot, or hyphen.'));
    END IF;
    IF jsonb_typeof(spec) IS DISTINCT FROM 'object' THEN
        findings := findings || jsonb_build_array(pgreact_internal.m29_finding(
            'M29_SPEC', 'ERROR', COALESCE((declaration).name, '<unnamed>'), 'spec',
            'spec must be a JSON object', 'Provide version, members, applicability, and effective bounds.'));
        RETURN jsonb_build_object('normalized', normalized, 'findings', findings);
    END IF;
    FOR field IN SELECT key FROM jsonb_object_keys(spec) key LOOP
        IF field NOT IN ('version', 'members', 'applicability', 'valid_from', 'valid_to', 'evidence_limit') THEN
            findings := findings || jsonb_build_array(pgreact_internal.m29_finding(
                'M29_FIELD_UNKNOWN', 'ERROR', (declaration).name, 'spec.' || field,
                'policy-set declaration contains an unknown field',
                'Remove it or use a field in the M29 policy-set contract.', jsonb_build_object('field', field)));
            EXIT;
        END IF;
    END LOOP;
    IF NULLIF(btrim(spec ->> 'version'), '') IS NULL
       OR length(spec ->> 'version') > 64 OR spec ->> 'version' !~ '^[A-Za-z0-9][A-Za-z0-9._-]*$' THEN
        findings := findings || jsonb_build_array(pgreact_internal.m29_finding(
            'M29_VERSION', 'ERROR', (declaration).name, 'spec.version',
            'version must be a stable non-empty immutable identifier', 'Use a short value such as 1 or 2026-08.'));
    END IF;
    IF jsonb_typeof(spec -> 'members') IS DISTINCT FROM 'array'
       OR jsonb_array_length(COALESCE(spec -> 'members', '[]'::jsonb)) = 0 THEN
        findings := findings || jsonb_build_array(pgreact_internal.m29_finding(
            'M29_MEMBERS', 'ERROR', (declaration).name, 'spec.members',
            'members must be a non-empty array', 'List already-deployed policy targets.'));
    ELSIF jsonb_array_length(spec -> 'members') > 64 THEN
        findings := findings || jsonb_build_array(pgreact_internal.m29_finding(
            'M29_LIMIT', 'ERROR', (declaration).name, 'spec.members',
            'a policy set may contain at most 64 members', 'Split the population into smaller policy sets.'));
    ELSE
        FOR member IN SELECT value FROM jsonb_array_elements(spec -> 'members') value LOOP
            IF jsonb_typeof(member) IS DISTINCT FROM 'object' THEN
                findings := findings || jsonb_build_array(pgreact_internal.m29_finding(
                    'M29_MEMBER_SHAPE', 'ERROR', (declaration).name, 'spec.members',
                    'each member must be an object', 'Use kind, name, and version for every member.'));
                CONTINUE;
            END IF;
            member_kind := member ->> 'kind';
            member_name := member ->> 'name';
            member_version := member ->> 'version';
            SELECT key INTO field
            FROM jsonb_object_keys(member) key
            WHERE key NOT IN ('kind', 'name', 'version')
            ORDER BY key LIMIT 1;
            IF field IS NOT NULL THEN
                findings := findings || jsonb_build_array(pgreact_internal.m29_finding(
                    'M29_MEMBER_FIELD_UNKNOWN', 'ERROR', COALESCE(member_name, (declaration).name),
                    'spec.members', 'member contains an unknown field',
                    'Keep members to kind, name, and version.', jsonb_build_object('field', field)));
                field := NULL;
            END IF;
            IF member_kind NOT IN ('rule', 'derived_program', 'temporal_policy', 'effective_policy',
                                   'parameter_family', 'decision_program', 'shared_condition') THEN
                findings := findings || jsonb_build_array(pgreact_internal.m29_finding(
                    'M29_MEMBER_KIND', 'ERROR', COALESCE(member_name, (declaration).name), 'spec.members',
                    'member kind is unsupported', 'Use one of the released policy-bearing kinds.'));
            ELSIF NULLIF(btrim(member_name), '') IS NULL OR NULLIF(btrim(member_version), '') IS NULL THEN
                findings := findings || jsonb_build_array(pgreact_internal.m29_finding(
                    'M29_MEMBER_IDENTITY', 'ERROR', (declaration).name, 'spec.members',
                    'every member needs kind, name, and immutable version', 'Copy the exact deployed target identity.'));
            ELSIF NOT pgreact_internal.m29_member_exists(member_kind, member_name, member_version) THEN
                findings := findings || jsonb_build_array(pgreact_internal.m29_finding(
                    'M29_MEMBER_NOT_FOUND', 'ERROR', member_name, 'spec.members',
                    'the member target is not deployed', 'Deploy the member first and use its exact version.'));
            END IF;
            SELECT key INTO duplicate
            FROM jsonb_array_elements(spec -> 'members') value,
                 LATERAL (SELECT (value ->> 'kind') || ':' || (value ->> 'name') || ':' ||
                                  (value ->> 'version') AS key) item
            WHERE item.key = member_kind || ':' || member_name || ':' || member_version
            GROUP BY key HAVING count(*) > 1 LIMIT 1;
            IF duplicate IS NOT NULL THEN
                findings := findings || jsonb_build_array(pgreact_internal.m29_finding(
                    'M29_MEMBER_DUPLICATE', 'ERROR', (declaration).name, 'spec.members',
                    'a member target appears more than once', 'Keep each immutable member target once.',
                    jsonb_build_object('member', duplicate)));
                duplicate := NULL;
            END IF;
        END LOOP;
    END IF;
    applicability := spec -> 'applicability';
    IF jsonb_typeof(applicability) IS DISTINCT FROM 'object' THEN
        findings := findings || jsonb_build_array(pgreact_internal.m29_finding(
            'M29_APPLICABILITY', 'ERROR', (declaration).name, 'spec.applicability',
            'applicability must name one relation or shared condition',
            'Use source_kind relation or shared_condition and one subject_key.'));
    ELSE
        source_kind := applicability ->> 'source_kind';
        source_name := COALESCE(applicability ->> 'relation', applicability ->> 'condition');
        subject_key := NULLIF(applicability ->> 'subject_key', '')::name;
        SELECT key INTO field
        FROM jsonb_object_keys(applicability) key
        WHERE key NOT IN ('source_kind', 'relation', 'condition', 'version', 'subject_key')
        ORDER BY key LIMIT 1;
        IF field IS NOT NULL THEN
            findings := findings || jsonb_build_array(pgreact_internal.m29_finding(
                'M29_FIELD_UNKNOWN', 'ERROR', (declaration).name, 'spec.applicability.' || field,
                'applicability contains an unknown field',
                'Remove the field or use the M29 applicability contract.', jsonb_build_object('field', field)));
            field := NULL;
        END IF;
        IF source_kind NOT IN ('relation', 'shared_condition') THEN
            findings := findings || jsonb_build_array(pgreact_internal.m29_finding(
                'M29_SOURCE_KIND', 'ERROR', (declaration).name, 'spec.applicability.source_kind',
                'applicability source kind is unsupported', 'Choose relation or shared_condition.'));
        ELSIF subject_key IS NULL THEN
            findings := findings || jsonb_build_array(pgreact_internal.m29_finding(
                'M29_SUBJECT_KEY', 'ERROR', (declaration).name, 'spec.applicability.subject_key',
                'a typed subject key is required', 'Name the one bigint, uuid, or text key column.'));
        ELSIF source_kind = 'relation' THEN
            IF source_name IS NULL OR source_name !~ '^[A-Za-z_][A-Za-z0-9_]*\.[A-Za-z_][A-Za-z0-9_]*$' THEN
                findings := findings || jsonb_build_array(pgreact_internal.m29_finding(
                    'M29_SOURCE_NAME', 'ERROR', (declaration).name, 'spec.applicability.relation',
                    'relation sources must be schema-qualified', 'Use schema_name.object_name.'));
            ELSE
                relation_oid := to_regclass(source_name);
                IF relation_oid IS NULL THEN
                    findings := findings || jsonb_build_array(pgreact_internal.m29_finding(
                        'M29_SOURCE_NOT_FOUND', 'ERROR', source_name, 'spec.applicability.relation',
                        'the applicability relation does not exist', 'Create it before previewing the policy set.'));
                ELSE
                    SELECT relkind, relrowsecurity, relowner INTO source_kind_catalog, source_rls, source_owner
                    FROM pg_class WHERE oid = relation_oid;
                    IF source_kind_catalog NOT IN ('r', 'p', 'v', 'm', 'f') THEN
                        findings := findings || jsonb_build_array(pgreact_internal.m29_finding(
                            'M29_SOURCE_KIND', 'ERROR', source_name, 'spec.applicability.relation',
                            'the applicability source is not a finite PostgreSQL relation',
                            'Use a table, partitioned table, view, materialized view, or foreign table.'));
                    END IF;
                    IF source_rls THEN
                        findings := findings || jsonb_build_array(pgreact_internal.m29_finding(
                            'M29_RLS_UNSUPPORTED', 'ERROR', source_name, 'spec.applicability.relation',
                            'row-level-security sources are not supported',
                            'Expose an authorized non-RLS relation or view.'));
                    END IF;
                    IF NOT has_table_privilege(session_user, relation_oid, 'SELECT') THEN
                        findings := findings || jsonb_build_array(pgreact_internal.m29_finding(
                            'M29_SOURCE_UNAUTHORIZED', 'ERROR', source_name, 'spec.applicability.relation',
                            'the caller does not have SELECT on the applicability source',
                            'Grant SELECT on the source to the policy-set author.'));
                    END IF;
                    SELECT a.atttypid::regtype INTO subject_type
                    FROM pg_attribute a
                    WHERE a.attrelid = relation_oid AND a.attname = subject_key
                      AND a.attnum > 0 AND NOT a.attisdropped;
                    IF subject_type IS NULL THEN
                        findings := findings || jsonb_build_array(pgreact_internal.m29_finding(
                            'M29_SUBJECT_KEY_NOT_FOUND', 'ERROR', source_name, 'spec.applicability.subject_key',
                            'the subject key column does not exist', 'Use a column present in the source relation.'));
                    ELSIF subject_type NOT IN ('bigint'::regtype, 'uuid'::regtype, 'text'::regtype) THEN
                        findings := findings || jsonb_build_array(pgreact_internal.m29_finding(
                            'M29_SUBJECT_KEY_TYPE', 'ERROR', source_name, 'spec.applicability.subject_key',
                            'subject keys must be bigint, uuid, or text', 'Use one of the supported stable key types.'));
                    ELSE
                        IF subject_type = 'text'::regtype AND EXISTS (
                            SELECT 1 FROM pg_attribute a
                            JOIN pg_collation c ON c.oid = a.attcollation
                            WHERE a.attrelid = relation_oid AND a.attname = subject_key
                              AND (NOT c.collisdeterministic OR c.collname NOT IN ('C', 'default'))) THEN
                            findings := findings || jsonb_build_array(pgreact_internal.m29_finding(
                                'M29_SUBJECT_KEY_COLLATION', 'ERROR', source_name,
                                'spec.applicability.subject_key',
                                'text subject keys require a deterministic C collation',
                                'Use COLLATE "C" for the applicability key.'));
                        END IF;
                        details := pgreact_internal.m29_relation_details(relation_oid, subject_key);
                        IF (details ->> 'null_count')::bigint > 0 THEN
                            findings := findings || jsonb_build_array(pgreact_internal.m29_finding(
                                'M29_SUBJECT_NULL', 'ERROR', source_name, 'spec.applicability.subject_key',
                                'applicability rows must have non-null subject keys',
                                'Remove null gate rows before deployment.', details));
                        END IF;
                        IF (details ->> 'distinct_count')::bigint <> (details ->> 'row_count')::bigint THEN
                            findings := findings || jsonb_build_array(pgreact_internal.m29_finding(
                                'M29_SUBJECT_DUPLICATE', 'ERROR', source_name, 'spec.applicability.subject_key',
                                'applicability subject keys must be unique',
                                'Keep one gate row per eligible subject.', details));
                        END IF;
                        IF (details ->> 'row_count')::bigint > 100000 THEN
                            findings := findings || jsonb_build_array(pgreact_internal.m29_finding(
                                'M29_LIMIT', 'ERROR', source_name, 'spec.applicability.relation',
                                'applicability source exceeds the 100000-row limit',
                                'Partition or narrow the source before deployment.', details));
                        END IF;
                    END IF;
                END IF;
            END IF;
        ELSE
            SELECT version.condition_version_id, condition.key_columns[1]
            INTO condition_version_id, condition_key
            FROM pgreact_internal.shared_condition_versions version
            JOIN pgreact_internal.shared_conditions condition USING (condition_id)
            WHERE condition.condition_name = source_name
              AND version.state = 'ACTIVE'
              AND (applicability ->> 'version' IS NULL
                   OR version.version::text = applicability ->> 'version');
            IF condition_version_id IS NULL THEN
                findings := findings || jsonb_build_array(pgreact_internal.m29_finding(
                    'M29_SHARED_CONDITION_NOT_FOUND', 'ERROR', source_name, 'spec.applicability.condition',
                    'the named shared condition version is not active',
                    'Deploy the shared condition and use its active version.'));
            ELSIF condition_key IS DISTINCT FROM subject_key THEN
                findings := findings || jsonb_build_array(pgreact_internal.m29_finding(
                    'M29_SUBJECT_KEY_MISMATCH', 'ERROR', source_name, 'spec.applicability.subject_key',
                    'the set subject key must match the shared condition key',
                    'Use the shared condition’s declared key column.'));
            ELSE
                relation_oid := to_regclass(source_name);
                IF relation_oid IS NULL THEN
                    findings := findings || jsonb_build_array(pgreact_internal.m29_finding(
                        'M29_SOURCE_NOT_FOUND', 'ERROR', source_name, 'spec.applicability.condition',
                        'the shared condition relation is unavailable', 'Restore the shared condition before deployment.'));
                ELSE
                    subject_type := (SELECT a.atttypid::regtype FROM pg_attribute a
                                     WHERE a.attrelid = relation_oid AND a.attname = subject_key
                                       AND a.attnum > 0 AND NOT a.attisdropped);
                    details := pgreact_internal.m29_relation_details(relation_oid, subject_key);
                    IF subject_type NOT IN ('bigint'::regtype, 'uuid'::regtype, 'text'::regtype) THEN
                        findings := findings || jsonb_build_array(pgreact_internal.m29_finding(
                            'M29_SUBJECT_KEY_TYPE', 'ERROR', source_name, 'spec.applicability.subject_key',
                            'shared-condition subject keys must be bigint, uuid, or text',
                            'Change the shared condition key to a supported type.'));
                    ELSIF (details ->> 'null_count')::bigint > 0
                       OR (details ->> 'distinct_count')::bigint <> (details ->> 'row_count')::bigint THEN
                        findings := findings || jsonb_build_array(pgreact_internal.m29_finding(
                            'M29_SOURCE_NOT_CANONICAL', 'ERROR', source_name, 'spec.applicability.condition',
                            'the shared condition must expose one non-null unique subject row per subject',
                            'Repair the condition source and refresh its version.', details));
                    END IF;
                END IF;
            END IF;
        END IF;
    END IF;
    BEGIN
        valid_from := (spec ->> 'valid_from')::timestamptz;
    EXCEPTION WHEN OTHERS THEN
        valid_from := NULL;
    END;
    IF valid_from IS NULL THEN
        findings := findings || jsonb_build_array(pgreact_internal.m29_finding(
            'M29_VALID_FROM', 'ERROR', (declaration).name, 'spec.valid_from',
            'valid_from must be a timestamp', 'Use an ISO-8601 PostgreSQL timestamptz.'));
    END IF;
    IF NULLIF(spec ->> 'valid_to', '') IS NOT NULL THEN
        BEGIN
            valid_to := (spec ->> 'valid_to')::timestamptz;
        EXCEPTION WHEN OTHERS THEN
            valid_to := NULL;
        END;
        IF valid_to IS NULL OR valid_from IS NULL OR valid_to <= valid_from THEN
            findings := findings || jsonb_build_array(pgreact_internal.m29_finding(
                'M29_VALID_BOUNDS', 'ERROR', (declaration).name, 'spec.valid_to',
                'valid_to must be later than valid_from', 'Use a half-open [valid_from, valid_to) interval.'));
        END IF;
    END IF;
    BEGIN
        evidence_limit := COALESCE((spec ->> 'evidence_limit')::integer, 100);
    EXCEPTION WHEN OTHERS THEN
        evidence_limit := 0;
    END;
    IF evidence_limit < 1 OR evidence_limit > 1000 THEN
        findings := findings || jsonb_build_array(pgreact_internal.m29_finding(
            'M29_EVIDENCE_LIMIT', 'ERROR', (declaration).name, 'spec.evidence_limit',
            'evidence_limit must be between 1 and 1000', 'Choose a bounded evidence page size.'));
    END IF;
    RETURN jsonb_build_object('normalized', normalized, 'findings', findings,
        'source', jsonb_build_object('relation', relation_oid, 'condition_version_id', condition_version_id,
                                     'subject_key', subject_key, 'subject_type', subject_type,
                                     'source_kind', source_kind, 'source_name', source_name),
        'valid_from', valid_from, 'valid_to', valid_to, 'evidence_limit', evidence_limit);
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('normalized', normalized, 'findings', findings || jsonb_build_array(
        pgreact_internal.m29_finding('M29_VALIDATION', 'ERROR', COALESCE((declaration).name, '<unnamed>'),
            '<declaration>', SQLERRM, 'Correct the policy-set declaration and validate again.')));
END
$m29$;

CREATE FUNCTION pgreact_internal.m29_snapshot(normalized jsonb)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $m29$
DECLARE app jsonb := normalized -> 'spec' -> 'applicability';
    source_oid oid;
    details jsonb;
    frontier timestamptz := (SELECT frontier FROM pgreact_internal.clock_frontier WHERE singleton);
    source_name text := COALESCE(app ->> 'relation', app ->> 'condition');
    source_version_id uuid;
    source_kind text := app ->> 'source_kind';
    key name := (app ->> 'subject_key')::name;
    fingerprint text;
BEGIN
    IF source_kind = 'shared_condition' THEN
        SELECT version.condition_version_id INTO source_version_id
        FROM pgreact_internal.shared_condition_versions version
        JOIN pgreact_internal.shared_conditions condition USING (condition_id)
        WHERE condition.condition_name = source_name AND version.state = 'ACTIVE'
          AND (app ->> 'version' IS NULL OR version.version::text = app ->> 'version');
    END IF;
    source_oid := to_regclass(source_name);
    details := pgreact_internal.m29_relation_details(source_oid, key);
    fingerprint := pgreact_internal.m29_relation_fingerprint(source_oid, key, frontier);
    RETURN jsonb_build_object('source_kind', source_kind, 'source_name', source_name,
        'source_oid', source_oid, 'source_version_id', source_version_id,
        'subject_key', key, 'subject_type',
        (SELECT a.atttypid::regtype::text FROM pg_attribute a
         WHERE a.attrelid = source_oid AND a.attname = key AND a.attnum > 0 AND NOT a.attisdropped),
        'complete_frontier', frontier, 'applicability_fingerprint', fingerprint,
        'eligible_subjects', details -> 'eligible_subjects',
        'eligible_subject_count', details -> 'row_count');
END
$m29$;

CREATE FUNCTION pgreact_internal.m29_digest(normalized jsonb, snapshot jsonb)
RETURNS text
LANGUAGE SQL IMMUTABLE STRICT AS $$
    SELECT encode(sha256(convert_to($1::text || ':' || $2::text, 'UTF8')), 'hex')
$$;

CREATE FUNCTION pgreact_internal.m29_envelope(
    operation text,
    normalized jsonb,
    state text,
    summary jsonb,
    findings jsonb DEFAULT '[]'::jsonb,
    evidence jsonb DEFAULT '{}'::jsonb,
    diagnostics jsonb DEFAULT '[]'::jsonb
)
RETURNS jsonb
LANGUAGE SQL IMMUTABLE AS $$
    SELECT jsonb_build_object(
        'contract_version', 17, 'operation', $1,
        'target', jsonb_build_object('kind', COALESCE($2 ->> 'kind', '<unknown>'),
                                     'name', COALESCE($2 ->> 'name', '<unknown>')),
        'state', $3, 'summary', COALESCE($4, '{}'::jsonb),
        'findings', COALESCE($5, '[]'::jsonb), 'evidence', COALESCE($6, '{}'::jsonb),
        'diagnostics', COALESCE($7, '[]'::jsonb), 'truncated', false)
$$;

CREATE FUNCTION pgreact_internal.m29_preview(declaration pgreact_api.declaration, operation text DEFAULT 'preview')
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $m29$
DECLARE checked jsonb;
    normalized jsonb;
    findings jsonb;
    snapshot jsonb;
    digest text;
    evidence_limit integer;
BEGIN
    checked := pgreact_internal.m29_validate(declaration);
    normalized := checked -> 'normalized';
    findings := checked -> 'findings';
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(findings) item WHERE item ->> 'severity' = 'ERROR') THEN
        RETURN pgreact_internal.m29_envelope(operation, normalized, 'attention',
            jsonb_build_object('read_only', true), findings);
    END IF;
    snapshot := pgreact_internal.m29_snapshot(normalized);
    digest := pgreact_internal.m29_digest(normalized, snapshot);
    evidence_limit := COALESCE((normalized -> 'spec' ->> 'evidence_limit')::integer, 100);
    RETURN pgreact_internal.m29_envelope(operation, normalized, 'ready',
        jsonb_build_object('read_only', true, 'preview_digest', digest,
            'version', normalized -> 'spec' ->> 'version',
            'member_count', jsonb_array_length(normalized -> 'spec' -> 'members'),
            'source_kind', snapshot ->> 'source_kind', 'source_name', snapshot ->> 'source_name',
            'subject_key', snapshot ->> 'subject_key',
            'complete_frontier', snapshot ->> 'complete_frontier',
            'applicability_fingerprint', snapshot ->> 'applicability_fingerprint',
            'eligible_subject_count', snapshot -> 'eligible_subject_count'),
        findings,
        jsonb_build_object('normalized_declaration', normalized, 'snapshot',
            jsonb_set(snapshot, '{eligible_subjects}',
                COALESCE((SELECT jsonb_agg(value ORDER BY value)
                          FROM jsonb_array_elements(snapshot -> 'eligible_subjects') value
                          LIMIT evidence_limit), '[]'::jsonb), true)),
        '[]'::jsonb);
END
$m29$;

ALTER FUNCTION pgreact_api.validate(pgreact_api.declaration) RENAME TO validate_m28;
ALTER FUNCTION pgreact_api.preview(pgreact_api.declaration, jsonb) RENAME TO preview_m28;
ALTER FUNCTION pgreact_api.deploy(pgreact_api.declaration, jsonb) RENAME TO deploy_m28;
ALTER FUNCTION pgreact_api.status(pgreact_api.target, jsonb) RENAME TO status_m28;
ALTER FUNCTION pgreact_api.explain(pgreact_api.target, jsonb, jsonb) RENAME TO explain_m28;
ALTER FUNCTION pgreact_api.doctor(pgreact_api.target, jsonb) RENAME TO doctor_m28;
ALTER FUNCTION pgreact_api.run(pgreact_api.target, timestamptz) RENAME TO run_m28;
ALTER FUNCTION pgreact_api.remove(pgreact_api.target, jsonb) RENAME TO remove_m28;

CREATE FUNCTION pgreact_api.validate(declaration pgreact_api.declaration)
RETURNS jsonb LANGUAGE SQL STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
    SELECT CASE WHEN ($1).kind = 'policy_set' THEN
        pgreact_internal.m29_preview($1, 'validate')
    ELSE pgreact_api.validate_m28($1) END
$$;

CREATE FUNCTION pgreact_api.preview(
    declaration pgreact_api.declaration,
    options jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $m29$
BEGIN
    IF options IS NULL OR jsonb_typeof(options) IS DISTINCT FROM 'object' THEN
        RAISE EXCEPTION 'M29_OPTIONS: options must be a JSON object';
    END IF;
    IF (declaration).kind = 'policy_set' THEN
        RETURN pgreact_internal.m29_preview(declaration);
    END IF;
    RETURN pgreact_api.preview_m28(declaration, options);
END
$m29$;

CREATE FUNCTION pgreact_api.deploy(
    declaration pgreact_api.declaration,
    preconditions jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $m29$
DECLARE checked jsonb;
    normalized jsonb;
    findings jsonb;
    snapshot jsonb;
    preview_digest text;
    existing pgreact_internal.policy_set_versions%ROWTYPE;
    set_row pgreact_internal.policy_sets%ROWTYPE;
    owner_id oid := (SELECT oid FROM pg_roles WHERE rolname = session_user);
    set_version text;
    allow_create boolean := true;
    member jsonb;
    ordinal integer := 0;
    source jsonb;
    set_valid_from timestamptz;
    set_valid_to timestamptz;
    set_id uuid;
BEGIN
    IF (declaration).kind <> 'policy_set' THEN
        RETURN pgreact_api.deploy_m28(declaration, preconditions);
    END IF;
    IF preconditions IS NULL OR jsonb_typeof(preconditions) IS DISTINCT FROM 'object' THEN
        RAISE EXCEPTION 'M29_PRECONDITIONS: preconditions must be a JSON object';
    END IF;
    checked := pgreact_internal.m29_validate(declaration);
    normalized := checked -> 'normalized';
    findings := checked -> 'findings';
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(findings) item WHERE item ->> 'severity' = 'ERROR') THEN
        RAISE EXCEPTION 'M29_VALIDATION: %', findings;
    END IF;
    snapshot := pgreact_internal.m29_snapshot(normalized);
    preview_digest := pgreact_internal.m29_digest(normalized, snapshot);
    IF preconditions ->> 'preview_digest' IS NOT NULL
       AND preconditions ->> 'preview_digest' <> preview_digest THEN
        RAISE EXCEPTION 'M29_PREVIEW_STALE'
            USING HINT = 'Preview the policy set again after applicability or member changes.';
    END IF;
    allow_create := COALESCE((preconditions ->> 'allow_create')::boolean, true);
    set_version := normalized -> 'spec' ->> 'version';
    set_valid_from := (normalized -> 'spec' ->> 'valid_from')::timestamptz;
    set_valid_to := NULLIF(normalized -> 'spec' ->> 'valid_to', '')::timestamptz;
    PERFORM pg_advisory_xact_lock(hashtextextended((declaration).name, 5788046901200004));
    SELECT * INTO set_row FROM pgreact_internal.policy_sets
    WHERE set_name = (declaration).name FOR UPDATE;
    IF FOUND THEN
        IF NOT pg_has_role(session_user, set_row.owner_oid, 'USAGE')
           AND NOT pgreact_internal.is_operator_admin() THEN
            RAISE EXCEPTION 'M29_OWNER: only the policy-set owner or operator may deploy this target';
        END IF;
        set_id := set_row.policy_set_id;
    ELSE
        INSERT INTO pgreact_internal.policy_sets(set_name, owner_oid)
        VALUES ((declaration).name, owner_id) RETURNING policy_set_id INTO set_id;
    END IF;
    SELECT * INTO existing FROM pgreact_internal.policy_set_versions
    WHERE policy_set_id = set_id AND version = set_version FOR UPDATE;
    IF FOUND THEN
        IF existing.declaration_digest IS DISTINCT FROM sha256(convert_to(normalized::text, 'UTF8')) THEN
            RAISE EXCEPTION 'M29_VERSION_IMMUTABLE: policy-set version % already has a different declaration', set_version;
        END IF;
        IF existing.state = 'DEPLOYED' AND allow_create THEN
            RAISE EXCEPTION 'M29_EXISTS: policy-set version % is already deployed', set_version
                USING HINT = 'Use a new immutable version for a changed policy set.';
        END IF;
        IF existing.state = 'DEPLOYED' AND NOT allow_create
           AND preconditions ->> 'expected_current_digest' IS DISTINCT FROM encode(existing.declaration_digest, 'hex') THEN
            RAISE EXCEPTION 'M29_REPLACE_STALE';
        END IF;
        UPDATE pgreact_internal.policy_set_versions
        SET state = 'DEPLOYED', removed_at = NULL, deployed_at = clock_timestamp(),
            complete_frontier = (snapshot ->> 'complete_frontier')::timestamptz,
            applicability_fingerprint = snapshot ->> 'applicability_fingerprint',
            eligible_subjects = snapshot -> 'eligible_subjects',
            eligible_subject_count = (snapshot ->> 'eligible_subject_count')::bigint
        WHERE policy_set_version_id = existing.policy_set_version_id;
    ELSE
        IF EXISTS (
            SELECT 1 FROM pgreact_internal.policy_set_versions other
            WHERE other.policy_set_id = set_id AND other.state = 'DEPLOYED'
              AND tstzrange(other.valid_from, COALESCE(other.valid_to, 'infinity'::timestamptz), '[)')
                  && tstzrange(set_valid_from, COALESCE(set_valid_to, 'infinity'::timestamptz), '[)')) THEN
            RAISE EXCEPTION 'M29_EFFECTIVE_OVERLAP: policy-set effective intervals overlap';
        END IF;
        source := checked -> 'source';
        INSERT INTO pgreact_internal.policy_set_versions(
            policy_set_id, version, normalized, declaration_digest, applicability_kind,
            applicability_source, applicability_source_oid, applicability_condition_version_id,
            subject_key, subject_type, valid_from, valid_to, complete_frontier,
            applicability_fingerprint, eligible_subjects, eligible_subject_count, state, deployed_at)
        VALUES (set_id, set_version, normalized, sha256(convert_to(normalized::text, 'UTF8')),
            source ->> 'source_kind', source ->> 'source_name', (source ->> 'relation')::oid,
            (source ->> 'condition_version_id')::uuid, (source ->> 'subject_key')::name,
            (source ->> 'subject_type')::regtype, set_valid_from, set_valid_to,
            (snapshot ->> 'complete_frontier')::timestamptz,
            snapshot ->> 'applicability_fingerprint', snapshot -> 'eligible_subjects',
            (snapshot ->> 'eligible_subject_count')::bigint, 'DEPLOYED', clock_timestamp())
        RETURNING policy_set_version_id INTO existing.policy_set_version_id;
        INSERT INTO pgreact_internal.policy_set_members(
            policy_set_version_id, ordinal, member_kind, member_name, member_version, member_target)
        SELECT existing.policy_set_version_id, row_number() OVER (), value ->> 'kind',
               value ->> 'name', value ->> 'version', value
        FROM jsonb_array_elements(normalized -> 'spec' -> 'members') value;
    END IF;
    INSERT INTO pgreact_internal.policy_set_history(policy_set_version_id, event_kind, frontier, details)
    VALUES (existing.policy_set_version_id, 'DEPLOYED', (snapshot ->> 'complete_frontier')::timestamptz,
        jsonb_build_object('preview_digest', preview_digest, 'eligible_subject_count', snapshot -> 'eligible_subject_count'));
    RETURN pgreact_internal.m29_envelope('deploy', normalized, 'deployed',
        jsonb_build_object('read_only', false, 'policy_set_version_id', existing.policy_set_version_id,
            'preview_digest', preview_digest, 'version', set_version,
            'complete_frontier', snapshot ->> 'complete_frontier',
            'eligible_subject_count', snapshot -> 'eligible_subject_count'), findings,
        jsonb_build_object('normalized_declaration', normalized, 'snapshot', snapshot));
END
$m29$;

CREATE FUNCTION pgreact_internal.m29_status(target pgreact_api.target)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $m29$
DECLARE version_row pgreact_internal.policy_set_versions%ROWTYPE;
    normalized jsonb;
    members jsonb;
BEGIN
    SELECT version.* INTO version_row
    FROM pgreact_internal.policy_set_versions version
    JOIN pgreact_internal.policy_sets set USING (policy_set_id)
    WHERE set.set_name = (target).name
      AND ((target).version IS NULL OR version.version = (target).version)
    ORDER BY version.valid_from DESC, version.created_at DESC LIMIT 1;
    IF NOT FOUND THEN
        normalized := jsonb_build_object('api_version', '1', 'kind', 'policy_set',
            'name', (target).name, 'spec', '{}'::jsonb);
        RETURN pgreact_internal.m29_envelope('status', normalized, 'not_found',
            jsonb_build_object('read_only', true), jsonb_build_array(pgreact_internal.m29_finding(
                'M29_TARGET_NOT_FOUND', 'ERROR', (target).name, 'target',
                'policy-set target was not found', 'Use the stable policy-set name and version.')));
    END IF;
    SELECT jsonb_agg(jsonb_build_object('ordinal', ordinal, 'kind', member_kind,
        'name', member_name, 'version', member_version) ORDER BY ordinal)
    INTO members FROM pgreact_internal.policy_set_members
    WHERE policy_set_version_id = version_row.policy_set_version_id;
    RETURN pgreact_internal.m29_envelope('status', version_row.normalized,
        lower(version_row.state), jsonb_build_object(
        'policy_set_version_id', version_row.policy_set_version_id,
            'version', version_row.version, 'owner', pg_get_userbyid(
                (SELECT owner_oid FROM pgreact_internal.policy_sets WHERE policy_set_id = version_row.policy_set_id)),
            'valid_from', version_row.valid_from, 'valid_to', version_row.valid_to,
            'complete_frontier', version_row.complete_frontier,
            'applicability_fingerprint', version_row.applicability_fingerprint,
            'eligible_subject_count', version_row.eligible_subject_count,
            'deployed_at', version_row.deployed_at, 'removed_at', version_row.removed_at,
            'members', COALESCE(members, '[]'::jsonb)),
        '[]'::jsonb, jsonb_build_object(
            'normalized_declaration', version_row.normalized,
            'eligible_subjects', version_row.eligible_subjects));
END
$m29$;

CREATE FUNCTION pgreact_api.status(target pgreact_api.target, options jsonb DEFAULT '{}'::jsonb)
RETURNS jsonb LANGUAGE SQL STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
    SELECT CASE WHEN ($1).kind = 'policy_set' THEN pgreact_internal.m29_status($1)
           ELSE pgreact_api.status_m28($1, $2) END
$$;

CREATE FUNCTION pgreact_internal.m29_subject_eligible(target pgreact_api.target, subject jsonb)
RETURNS boolean
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $m29$
DECLARE key_column name;
    subject_value jsonb;
    eligible boolean;
BEGIN
    SELECT version.subject_key, version.eligible_subjects @> jsonb_build_array(
        CASE WHEN jsonb_typeof(subject) = 'object' THEN subject -> version.subject_key ELSE subject END)
    INTO key_column, eligible
    FROM pgreact_internal.policy_set_versions version
    JOIN pgreact_internal.policy_sets set USING (policy_set_id)
    WHERE set.set_name = (target).name
      AND (($1).version IS NULL OR version.version = ($1).version)
      AND version.state = 'DEPLOYED'
    ORDER BY version.valid_from DESC LIMIT 1;
    RETURN COALESCE(eligible, false);
END
$m29$;

CREATE FUNCTION pgreact_api.explain(target pgreact_api.target, subject jsonb DEFAULT NULL, options jsonb DEFAULT '{}'::jsonb)
RETURNS jsonb LANGUAGE SQL STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
    SELECT CASE WHEN ($1).kind = 'policy_set' THEN
        pgreact_internal.m29_status($1) || jsonb_build_object('operation', 'explain',
            'evidence', jsonb_build_object('subject', $2, 'options', $3,
                'eligible', CASE WHEN $2 IS NULL THEN NULL
                                ELSE pgreact_internal.m29_subject_eligible($1, $2) END)
        )
    ELSE pgreact_api.explain_m28($1, $2, $3) END
$$;

CREATE FUNCTION pgreact_api.doctor(target pgreact_api.target, options jsonb DEFAULT '{}'::jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $m29$
DECLARE result jsonb;
    row_data pgreact_internal.policy_set_versions%ROWTYPE;
    current_fingerprint text;
    diagnostics jsonb := '[]'::jsonb;
BEGIN
    IF (target).kind <> 'policy_set' THEN RETURN pgreact_api.doctor_m28(target, options); END IF;
    result := pgreact_internal.m29_status(target);
    SELECT version.* INTO row_data
    FROM pgreact_internal.policy_set_versions version
    JOIN pgreact_internal.policy_sets set USING (policy_set_id)
    WHERE set.set_name = (target).name
      AND (($1).version IS NULL OR version.version = ($1).version)
      AND version.state = 'DEPLOYED'
    ORDER BY version.valid_from DESC LIMIT 1;
    IF NOT FOUND THEN
        diagnostics := jsonb_build_array(pgreact_internal.m29_finding(
            'M29_TARGET_NOT_FOUND', 'ERROR', (target).name, 'target',
            'no deployed policy-set version is available', 'Deploy a valid policy-set version.'));
    ELSE
        current_fingerprint := pgreact_internal.m29_relation_fingerprint(
            row_data.applicability_source_oid, row_data.subject_key, row_data.complete_frontier);
        IF current_fingerprint IS DISTINCT FROM row_data.applicability_fingerprint THEN
            diagnostics := jsonb_build_array(pgreact_internal.m29_finding(
                'M29_SOURCE_DRIFT', 'ERROR', (target).name, 'applicability',
                'the applicability source changed after deployment',
                'Run the policy-set again or deploy a new immutable version.',
                jsonb_build_object('deployed', row_data.applicability_fingerprint,
                                   'current', current_fingerprint)));
        ELSE
            diagnostics := jsonb_build_array(jsonb_build_object(
                'code', 'M29_POLICY_SET_READY', 'severity', 'INFO', 'blocker', false,
                'object_identity', (target).name,
                'message', 'policy-set applicability is current and fail-closed',
                'hint', 'Use status or explain to inspect eligible subjects.'));
        END IF;
    END IF;
    RETURN result || jsonb_build_object('operation', 'doctor', 'diagnostics', diagnostics);
END
$m29$;

CREATE FUNCTION pgreact_api.run(target pgreact_api.target, sampled_time timestamptz DEFAULT clock_timestamp())
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $m29$
DECLARE row_data pgreact_internal.policy_set_versions%ROWTYPE;
    snapshot jsonb;
BEGIN
    IF (target).kind <> 'policy_set' THEN RETURN pgreact_api.run_m28(target, sampled_time); END IF;
    SELECT version.* INTO row_data
    FROM pgreact_internal.policy_set_versions version
    JOIN pgreact_internal.policy_sets set USING (policy_set_id)
    WHERE set.set_name = (target).name
      AND (($1).version IS NULL OR version.version = ($1).version)
      AND version.state = 'DEPLOYED'
      AND version.valid_from <= sampled_time
      AND (version.valid_to IS NULL OR sampled_time < version.valid_to)
    ORDER BY version.valid_from DESC LIMIT 1;
    IF NOT FOUND THEN RETURN pgreact_internal.m29_status(target) || jsonb_build_object(
        'operation', 'run', 'sampled_time', sampled_time); END IF;
    snapshot := pgreact_internal.m29_snapshot(row_data.normalized);
    UPDATE pgreact_internal.policy_set_versions
    SET complete_frontier = (snapshot ->> 'complete_frontier')::timestamptz,
        applicability_fingerprint = snapshot ->> 'applicability_fingerprint',
        eligible_subjects = snapshot -> 'eligible_subjects',
        eligible_subject_count = (snapshot ->> 'eligible_subject_count')::bigint
    WHERE policy_set_version_id = row_data.policy_set_version_id;
    INSERT INTO pgreact_internal.policy_set_history(policy_set_version_id, event_kind, frontier, details)
    VALUES (row_data.policy_set_version_id, 'REFRESHED', (snapshot ->> 'complete_frontier')::timestamptz,
        jsonb_build_object('eligible_subject_count', snapshot -> 'eligible_subject_count'));
    RETURN pgreact_internal.m29_status(target) || jsonb_build_object(
        'operation', 'run', 'sampled_time', sampled_time, 'gated', true);
END
$m29$;

CREATE FUNCTION pgreact_api.remove(target pgreact_api.target, preconditions jsonb DEFAULT '{}'::jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $m29$
DECLARE row_data pgreact_internal.policy_set_versions%ROWTYPE;
    set_owner_oid oid;
BEGIN
    IF (target).kind <> 'policy_set' THEN RETURN pgreact_api.remove_m28(target, preconditions); END IF;
    SELECT version.* INTO row_data
    FROM pgreact_internal.policy_set_versions version
    JOIN pgreact_internal.policy_sets set USING (policy_set_id)
    WHERE set.set_name = (target).name
      AND (($1).version IS NULL OR version.version = ($1).version)
    ORDER BY version.valid_from DESC LIMIT 1 FOR UPDATE;
    IF NOT FOUND THEN RETURN pgreact_internal.m29_status(target); END IF;
    SELECT set.owner_oid INTO set_owner_oid FROM pgreact_internal.policy_sets set
    WHERE set.policy_set_id = row_data.policy_set_id;
    IF NOT pg_has_role(session_user, set_owner_oid, 'USAGE') AND NOT pgreact_internal.is_operator_admin() THEN
        RAISE EXCEPTION 'M29_OWNER: only the policy-set owner or operator may remove this target';
    END IF;
    UPDATE pgreact_internal.policy_set_versions SET state = 'REMOVED', removed_at = clock_timestamp()
    WHERE policy_set_version_id = row_data.policy_set_version_id;
    INSERT INTO pgreact_internal.policy_set_history(policy_set_version_id, event_kind, frontier, details)
    VALUES (row_data.policy_set_version_id,
        'REMOVED', (SELECT frontier FROM pgreact_internal.clock_frontier WHERE singleton), '{}');
    RETURN pgreact_internal.m29_envelope('remove', row_data.normalized, 'removed',
        jsonb_build_object('read_only', false, 'policy_set_version_id', row_data.policy_set_version_id));
END
$m29$;

CREATE VIEW pgreact.policy_sets AS
SELECT set.policy_set_id, set.set_name, pg_get_userbyid(set.owner_oid) AS owner,
       set.created_at
FROM pgreact_internal.policy_sets set;

CREATE VIEW pgreact.policy_set_versions AS
SELECT version.policy_set_version_id, set.set_name, version.version,
       version.applicability_kind, version.applicability_source,
       version.subject_key, version.subject_type::text AS subject_type,
       version.valid_from, version.valid_to, version.complete_frontier,
       version.applicability_fingerprint, version.eligible_subject_count,
       version.state, pg_get_userbyid(set.owner_oid) AS owner,
       version.deployed_at, version.removed_at
FROM pgreact_internal.policy_set_versions version
JOIN pgreact_internal.policy_sets set USING (policy_set_id);

CREATE VIEW pgreact.policy_set_members AS
SELECT set.set_name, version.version, member.ordinal, member.member_kind,
       member.member_name, member.member_version
FROM pgreact_internal.policy_set_members member
JOIN pgreact_internal.policy_set_versions version USING (policy_set_version_id)
JOIN pgreact_internal.policy_sets set USING (policy_set_id);

CREATE VIEW pgreact.policy_set_eligible_subjects AS
SELECT version.policy_set_version_id, set.set_name, version.version,
       value AS subject, version.complete_frontier
FROM pgreact_internal.policy_set_versions version
JOIN pgreact_internal.policy_sets set USING (policy_set_id)
CROSS JOIN LATERAL jsonb_array_elements(version.eligible_subjects) value;

ALTER FUNCTION pgreact_api.configure_roles(regrole, regrole, regrole, regrole, regrole)
    SET SCHEMA pgreact_internal;
ALTER FUNCTION pgreact_internal.configure_roles(regrole, regrole, regrole, regrole, regrole)
    RENAME TO configure_roles_m29;

CREATE FUNCTION pgreact_api.configure_roles(
    author_role regrole, operator_role regrole, worker_role regrole,
    reader_role regrole, advanced_reader_role regrole)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $m29$
BEGIN
    PERFORM pgreact_internal.configure_roles_m29(
        author_role, operator_role, worker_role, reader_role, advanced_reader_role);
    EXECUTE format('GRANT SELECT ON pgreact.policy_sets, pgreact.policy_set_versions, '
                   'pgreact.policy_set_members, pgreact.policy_set_eligible_subjects TO %I, %I',
                   reader_role::text, operator_role::text);
    EXECUTE format('GRANT EXECUTE ON FUNCTION pgreact_api.validate(pgreact_api.declaration), '
                   'pgreact_api.preview(pgreact_api.declaration,jsonb), '
                   'pgreact_api.deploy(pgreact_api.declaration,jsonb), '
                   'pgreact_api.remove(pgreact_api.target,jsonb) TO %I', author_role::text);
    EXECUTE format('GRANT EXECUTE ON FUNCTION pgreact_api.status(pgreact_api.target,jsonb), '
                   'pgreact_api.explain(pgreact_api.target,jsonb,jsonb), '
                   'pgreact_api.doctor(pgreact_api.target,jsonb) TO %I, %I',
                   reader_role::text, operator_role::text);
    EXECUTE format('GRANT EXECUTE ON FUNCTION pgreact_api.run(pgreact_api.target,timestamptz) TO %I, %I',
                   author_role::text, operator_role::text);
END
$m29$;

DO $m29$
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
$m29$;

REVOKE ALL ON ALL TABLES IN SCHEMA pgreact_internal FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA pgreact_internal FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA pgreact_api FROM PUBLIC;
REVOKE ALL ON pgreact.policy_sets, pgreact.policy_set_versions,
    pgreact.policy_set_members, pgreact.policy_set_eligible_subjects FROM PUBLIC;

COMMENT ON EXTENSION pg_react IS
    'M29 policy-set gating: versioned typed applicability over the M28 public façade';
