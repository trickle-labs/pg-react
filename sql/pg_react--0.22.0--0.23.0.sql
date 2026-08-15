-- M26 decision tables. Candidate rows remain ordinary PostgreSQL data; this
-- migration adds durable selection and explanation semantics around them.

CREATE TABLE pgreact_internal.decision_programs (
    program_id uuid PRIMARY KEY,
    program_name text NOT NULL UNIQUE,
    owner_oid oid NOT NULL,
    state text NOT NULL DEFAULT 'ACTIVE' CHECK (state IN ('ACTIVE', 'PAUSED', 'REMOVED')),
    created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE pgreact_internal.decision_program_versions (
    version_id uuid PRIMARY KEY,
    program_id uuid NOT NULL REFERENCES pgreact_internal.decision_programs,
    version_no integer NOT NULL CHECK (version_no > 0),
    candidate_relation_oid oid NOT NULL,
    candidate_relation_name text NOT NULL,
    subject_key_column name NOT NULL,
    candidate_key_column name NOT NULL,
    priority_column name NOT NULL,
    result_columns name[] NOT NULL CHECK (cardinality(result_columns) > 0),
    result_types jsonb NOT NULL,
    source_signature bytea NOT NULL,
    source_definition_digest bytea NOT NULL,
    max_candidates integer NOT NULL CHECK (max_candidates > 0),
    valid_from timestamptz NOT NULL,
    valid_to timestamptz,
    state text NOT NULL DEFAULT 'DEPLOYED' CHECK (state IN ('DEPLOYED', 'RETIRED')),
    deployed_by oid NOT NULL,
    deployed_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    UNIQUE (program_id, version_no),
    CHECK (valid_to IS NULL OR valid_to > valid_from)
);

CREATE INDEX decision_program_versions_window_idx
    ON pgreact_internal.decision_program_versions (program_id, valid_from, valid_to);

CREATE TABLE pgreact_internal.decision_subject_state (
    program_id uuid NOT NULL REFERENCES pgreact_internal.decision_programs ON DELETE CASCADE,
    subject_key bigint NOT NULL,
    version_id uuid REFERENCES pgreact_internal.decision_program_versions,
    state text NOT NULL CHECK (state IN ('NO_CANDIDATE', 'WINNER', 'AMBIGUOUS')),
    winner_candidate bigint,
    winner_priority bigint,
    winner_result jsonb,
    activation_id uuid,
    generation bigint NOT NULL DEFAULT 0 CHECK (generation >= 0),
    revision bigint NOT NULL DEFAULT 0 CHECK (revision >= 0),
    competitors jsonb NOT NULL DEFAULT '[]'::jsonb,
    competitors_truncated boolean NOT NULL DEFAULT false,
    first_seen_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    last_seen_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (program_id, subject_key),
    CHECK ((state = 'WINNER') = (winner_candidate IS NOT NULL AND activation_id IS NOT NULL)),
    CHECK (state <> 'WINNER' OR winner_priority IS NOT NULL)
);

CREATE TABLE pgreact_internal.decision_lifecycle_events (
    event_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    program_id uuid NOT NULL REFERENCES pgreact_internal.decision_programs ON DELETE CASCADE,
    version_id uuid REFERENCES pgreact_internal.decision_program_versions,
    subject_key bigint NOT NULL,
    candidate_key bigint,
    activation_id uuid,
    event_kind text NOT NULL CHECK (event_kind IN (
        'WINNER_IN', 'WINNER_OUT', 'WINNER_REVISION',
        'AMBIGUITY_ENTER', 'AMBIGUITY_EXIT', 'NO_CANDIDATE')),
    generation bigint NOT NULL CHECK (generation >= 0),
    revision bigint NOT NULL CHECK (revision >= 0),
    details jsonb NOT NULL DEFAULT '{}'::jsonb,
    occurred_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE INDEX decision_lifecycle_event_idx
    ON pgreact_internal.decision_lifecycle_events (program_id, subject_key, event_id);

CREATE TABLE pgreact_internal.decision_work (
    program_id uuid NOT NULL REFERENCES pgreact_internal.decision_programs ON DELETE CASCADE,
    subject_key bigint NOT NULL,
    activation_id uuid,
    claimable boolean NOT NULL DEFAULT false,
    state text NOT NULL CHECK (state IN ('WINNER', 'AMBIGUOUS', 'NO_CANDIDATE')),
    updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (program_id, subject_key)
);

CREATE FUNCTION pgreact_internal.decision_source_digest(source_relid oid)
RETURNS bytea
LANGUAGE SQL
STABLE
PARALLEL SAFE
SET search_path = pg_catalog, pg_temp
AS $m26$
    SELECT sha256(convert_to(COALESCE(pg_get_viewdef($1, true), ''), 'UTF8'))
$m26$;

CREATE FUNCTION pgreact_internal.decision_activation_id(
    target_version uuid, target_subject bigint, target_candidate bigint)
RETURNS uuid
LANGUAGE SQL
IMMUTABLE
STRICT
PARALLEL SAFE
SET search_path = pg_catalog, pg_temp
AS $m26$
    SELECT pgreact_internal.activation_uuid(
        sha256(uuid_send($1) || int8send($2) || int8send($3)))
$m26$;

CREATE FUNCTION pgreact_internal.decision_result(row_data jsonb, columns name[])
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
STRICT
PARALLEL SAFE
SET search_path = pg_catalog, pg_temp
AS $m26$
DECLARE column_name name;
    result jsonb := '{}'::jsonb;
BEGIN
    FOREACH column_name IN ARRAY columns LOOP
        result := result || jsonb_build_object(column_name::text, row_data -> (column_name::text));
    END LOOP;
    RETURN result;
END
$m26$;

CREATE FUNCTION pgreact_internal.validate_decision_program(
    target_program_name text,
    target_relation regclass,
    target_subject_column name,
    target_candidate_column name,
    target_priority_column name,
    target_result_columns name[],
    target_max_candidates integer DEFAULT 1000
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
AS $m26$
DECLARE relation_row record;
    key_row record;
    column_name name;
    column_row record;
    duplicate_name name;
    value_types jsonb := '[]'::jsonb;
    duplicate_pairs bigint;
    largest_subject bigint;
    invalid boolean := false;
BEGIN
    IF target_program_name IS NULL OR btrim(target_program_name) = '' THEN
        RETURN QUERY SELECT 14, 'M26_PROGRAM_NAME', 'ERROR', '<unnamed>',
            'decision program name must not be empty',
            'Choose one stable program identity.', '{}'::jsonb;
        RETURN;
    END IF;
    IF target_max_candidates IS NULL OR target_max_candidates < 1 THEN
        RETURN QUERY SELECT 14, 'M26_CANDIDATE_LIMIT', 'ERROR', target_program_name,
            'candidate limit must be positive',
            'Choose a bounded candidates-per-subject limit.', '{}'::jsonb;
        RETURN;
    END IF;
    SELECT c.relkind, c.relowner, c.relrowsecurity, n.nspname, c.relname
    INTO relation_row
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.oid = target_relation;
    IF NOT FOUND OR relation_row.relkind NOT IN ('r', 'p', 'v', 'm') THEN
        RETURN QUERY SELECT 14, 'M26_CANDIDATE_RELATION', 'ERROR', target_relation::text,
            'candidate source must be a table, partitioned table, view, or materialized view',
            'Use one maintained PostgreSQL candidate relation.', '{}'::jsonb;
        RETURN;
    END IF;
    IF relation_row.relrowsecurity THEN
        RETURN QUERY SELECT 14, 'M26_CANDIDATE_RLS', 'ERROR', target_relation::text,
            'row-level security is not supported for a candidate source',
            'Use ordinary grants on a source without row-level security.', '{}'::jsonb;
        invalid := true;
    END IF;
    IF NOT pg_has_role(session_user, relation_row.relowner, 'USAGE')
       AND NOT pgreact_internal.is_operator_admin() THEN
        RETURN QUERY SELECT 14, 'M26_CANDIDATE_OWNER', 'ERROR', target_relation::text,
            'the candidate source must be owned by the author',
            'Use the relation owner or configured operator role.', '{}'::jsonb;
        invalid := true;
    END IF;
    IF target_subject_column IS NULL OR target_candidate_column IS NULL
       OR target_priority_column IS NULL
       OR target_subject_column = target_candidate_column
       OR target_subject_column = target_priority_column
       OR target_candidate_column = target_priority_column THEN
        RETURN QUERY SELECT 14, 'M26_CANDIDATE_COLUMNS', 'ERROR', target_relation::text,
            'subject, candidate, and priority columns must be distinct',
            'Declare three existing columns with separate identities.', '{}'::jsonb;
        RETURN;
    END IF;
    IF target_result_columns IS NULL OR cardinality(target_result_columns) = 0 THEN
        RETURN QUERY SELECT 14, 'M26_RESULT_COLUMNS', 'ERROR', target_relation::text,
            'at least one typed result column is required',
            'Declare the columns returned by the winning candidate.', '{}'::jsonb;
        RETURN;
    END IF;
    SELECT value FROM unnest(target_result_columns) value
    GROUP BY value HAVING count(*) > 1 LIMIT 1 INTO duplicate_name;
    IF duplicate_name IS NOT NULL
       OR target_subject_column = ANY(target_result_columns)
       OR target_candidate_column = ANY(target_result_columns)
       OR target_priority_column = ANY(target_result_columns) THEN
        RETURN QUERY SELECT 14, 'M26_RESULT_COLUMNS', 'ERROR', target_relation::text,
            'result columns must be distinct from each other and from identity columns',
            'List each declared column exactly once.', '{}'::jsonb;
        RETURN;
    END IF;
    FOREACH column_name IN ARRAY ARRAY[target_subject_column, target_candidate_column,
                                      target_priority_column] LOOP
        SELECT a.atttypid, a.attnotnull, a.attgenerated
        INTO column_row
        FROM pg_attribute a
        WHERE a.attrelid = target_relation AND a.attname = column_name
          AND a.attnum > 0 AND NOT a.attisdropped;
        IF NOT FOUND THEN
            RETURN QUERY SELECT 14, 'M26_CANDIDATE_COLUMN', 'ERROR', target_relation::text,
                format('candidate column %I does not exist', column_name),
                'Declare existing subject, candidate, and priority columns.', '{}'::jsonb;
            invalid := true;
        ELSIF column_row.atttypid <> 'int8'::regtype
              OR (relation_row.relkind IN ('r', 'p') AND NOT column_row.attnotnull)
              OR column_row.attgenerated <> '' THEN
            RETURN QUERY SELECT 14, CASE WHEN column_name = target_priority_column
                THEN 'M26_PRIORITY_TYPE' ELSE 'M26_IDENTITY_TYPE' END, 'ERROR', target_relation::text,
                format('candidate column %I must be a stored NOT NULL bigint column', column_name),
                'Use bigint identity and priority columns; view rows are checked at refresh time.',
                jsonb_build_object('column', column_name,
                                   'type', format_type(column_row.atttypid, NULL),
                                   'not_null', column_row.attnotnull);
            invalid := true;
        END IF;
    END LOOP;
    FOREACH column_name IN ARRAY target_result_columns LOOP
        SELECT a.atttypid, a.attnotnull, a.attgenerated
        INTO column_row
        FROM pg_attribute a
        WHERE a.attrelid = target_relation AND a.attname = column_name
          AND a.attnum > 0 AND NOT a.attisdropped;
        IF NOT FOUND THEN
            RETURN QUERY SELECT 14, 'M26_RESULT_COLUMN', 'ERROR', target_relation::text,
                format('result column %I does not exist', column_name),
                'Declare only existing scalar PostgreSQL columns.', '{}'::jsonb;
            invalid := true;
        ELSIF column_row.attgenerated <> '' OR column_row.atttypid NOT IN (
            'bool'::regtype, 'int2'::regtype, 'int4'::regtype, 'int8'::regtype,
            'numeric'::regtype, 'text'::regtype, 'varchar'::regtype, 'uuid'::regtype,
            'date'::regtype, 'timestamp'::regtype, 'timestamptz'::regtype) THEN
            RETURN QUERY SELECT 14, 'M26_RESULT_TYPE', 'ERROR', target_relation::text,
                format('result column %I must use a supported scalar type', column_name),
                'Use boolean, integer, numeric, text, uuid, date, timestamp, or timestamptz.',
                jsonb_build_object('column', column_name,
                                   'type', format_type(column_row.atttypid, NULL));
            invalid := true;
        ELSE
            value_types := value_types || jsonb_build_array(jsonb_build_object(
                'column', column_name, 'type', format_type(column_row.atttypid, NULL)));
        END IF;
    END LOOP;
    IF invalid THEN RETURN; END IF;
    EXECUTE format(
        'SELECT count(*) FROM (SELECT r.%1$I, r.%2$I FROM %3$s r GROUP BY 1, 2 HAVING count(*) > 1) d',
        target_subject_column, target_candidate_column, target_relation::text)
    INTO duplicate_pairs;
    IF duplicate_pairs > 0 THEN
        RETURN QUERY SELECT 14, 'M26_CANDIDATE_UNIQUE', 'ERROR', target_relation::text,
            'the candidate source contains duplicate subject and candidate identities',
            'Make each (subject, candidate) pair unique before deployment.',
            jsonb_build_object('duplicate_pairs', duplicate_pairs);
        RETURN;
    END IF;
    EXECUTE format(
        'SELECT coalesce(max(candidate_count), 0) FROM '
        '(SELECT count(*) AS candidate_count FROM %1$s r GROUP BY r.%2$I) s',
        target_relation::text, target_subject_column)
    INTO largest_subject;
    IF largest_subject > target_max_candidates THEN
        RETURN QUERY SELECT 14, 'M26_CANDIDATE_LIMIT', 'ERROR', target_relation::text,
            'a subject has more candidates than the declared admission limit',
            'Reduce the candidate set or raise the bounded limit before deployment.',
            jsonb_build_object('largest_subject', largest_subject,
                               'max_candidates', target_max_candidates);
        RETURN;
    END IF;
    RETURN QUERY SELECT 14, 'OK', 'INFO', target_program_name,
        'decision program declaration is valid',
        'The lowest priority candidate will win; an equal best priority is explicit ambiguity.',
        jsonb_build_object('candidate_relation', target_relation::text,
                           'subject_column', target_subject_column,
                           'candidate_column', target_candidate_column,
                           'priority_column', target_priority_column,
                           'result_columns', target_result_columns,
                           'result_types', value_types,
                           'max_candidates', target_max_candidates,
                           'key_codec', 'bigint-v1');
END
$m26$;

CREATE FUNCTION pgreact_api.validate_decision_program(
    program_name text,
    candidate_relation regclass,
    subject_key_column name,
    candidate_key_column name,
    priority_column name,
    result_columns name[],
    max_candidates integer DEFAULT 1000
)
RETURNS TABLE(contract_version integer, code text, severity text,
              object_identity text, message text, hint text, details jsonb)
LANGUAGE SQL
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m26$
    SELECT * FROM pgreact_internal.validate_decision_program(
        $1, $2, $3, $4, $5, $6, $7)
$m26$;

CREATE FUNCTION pgreact_internal.load_decision_candidates(target_version_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m26$
DECLARE version_row pgreact_internal.decision_program_versions%ROWTYPE;
    null_rows bigint;
BEGIN
    SELECT * INTO STRICT version_row
    FROM pgreact_internal.decision_program_versions
    WHERE version_id = target_version_id;
    IF version_row.source_signature IS DISTINCT FROM
       pgreact_internal.source_row_signature(version_row.candidate_relation_oid)
       OR version_row.source_definition_digest IS DISTINCT FROM
          pgreact_internal.decision_source_digest(version_row.candidate_relation_oid) THEN
        RAISE EXCEPTION 'M26_DECISION_DRIFT: candidate relation % changed after declaration',
            version_row.candidate_relation_name;
    END IF;
    DROP TABLE IF EXISTS pg_temp.m26_decision_candidates;
    CREATE TEMP TABLE pg_temp.m26_decision_candidates (
        subject_key bigint NOT NULL,
        candidate_key bigint NOT NULL,
        priority bigint NOT NULL,
        row_data jsonb NOT NULL
    ) ON COMMIT DROP;
    EXECUTE format(
        'INSERT INTO pg_temp.m26_decision_candidates(subject_key, candidate_key, priority, row_data) '
        'SELECT r.%1$I, r.%2$I, r.%3$I, to_jsonb(r) FROM %4$s r',
        version_row.subject_key_column, version_row.candidate_key_column,
        version_row.priority_column, version_row.candidate_relation_oid::regclass);
    EXECUTE 'SELECT count(*) FROM pg_temp.m26_decision_candidates '
        'WHERE subject_key IS NULL OR candidate_key IS NULL OR priority IS NULL'
        INTO null_rows;
    IF null_rows > 0 THEN
        RAISE EXCEPTION 'M26_CANDIDATE_NULL: candidate identity and priority columns must be non-null';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_temp.m26_decision_candidates
               GROUP BY subject_key, candidate_key HAVING count(*) > 1) THEN
        RAISE EXCEPTION 'M26_CANDIDATE_UNIQUE: candidate source contains duplicate subject and candidate identities';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_temp.m26_decision_candidates
               GROUP BY subject_key HAVING count(*) > version_row.max_candidates) THEN
        RAISE EXCEPTION 'M26_CANDIDATE_LIMIT: candidate source exceeds the declared per-subject limit';
    END IF;
END
$m26$;

CREATE FUNCTION pgreact_internal.record_decision_event(
    target_program_id uuid, target_version_id uuid, target_subject bigint,
    target_candidate bigint, target_activation uuid, target_kind text,
    target_generation bigint, target_revision bigint, target_details jsonb)
RETURNS void
LANGUAGE SQL
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m26$
    INSERT INTO pgreact_internal.decision_lifecycle_events(
        program_id, version_id, subject_key, candidate_key, activation_id,
        event_kind, generation, revision, details)
    VALUES ($1, $2, $3, $4, $5, $6, $7, $8, COALESCE($9, '{}'::jsonb))
$m26$;

CREATE FUNCTION pgreact_internal.refresh_decision_program(
    target_program_id uuid, sampled_time timestamptz)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m26$
DECLARE version_row pgreact_internal.decision_program_versions%ROWTYPE;
    program_row pgreact_internal.decision_programs%ROWTYPE;
    old_state pgreact_internal.decision_subject_state%ROWTYPE;
    subject_row record;
    candidate_row record;
    winner_row record;
    desired_state text;
    desired_candidate bigint;
    desired_priority bigint;
    desired_result jsonb;
    competitors jsonb;
    candidate_result jsonb;
    activation uuid;
    generation bigint;
    revision bigint;
    top_count bigint;
    competitor_count bigint;
    competitors_truncated boolean;
    changed bigint := 0;
    had_old boolean;
BEGIN
    -- ponytail: one per-program lock; shard by subject only if throughput requires it.
    PERFORM pg_advisory_xact_lock(hashtextextended(target_program_id::text, 26));
    SELECT * INTO STRICT program_row FROM pgreact_internal.decision_programs
    WHERE program_id = target_program_id AND state <> 'REMOVED';
    SELECT * INTO version_row
    FROM pgreact_internal.decision_program_versions
    WHERE program_id = target_program_id AND state = 'DEPLOYED'
      AND valid_from <= sampled_time
      AND (valid_to IS NULL OR sampled_time < valid_to)
    ORDER BY valid_from DESC, version_no DESC LIMIT 1;
    IF NOT FOUND THEN
        FOR old_state IN SELECT * FROM pgreact_internal.decision_subject_state
                         WHERE program_id = target_program_id FOR UPDATE LOOP
            IF old_state.state = 'WINNER' THEN
                PERFORM pgreact_internal.record_decision_event(
                    target_program_id, old_state.version_id, old_state.subject_key,
                    old_state.winner_candidate, old_state.activation_id, 'WINNER_OUT',
                    old_state.generation, old_state.revision,
                    jsonb_build_object('reason', 'no authoritative decision version'));
            END IF;
            UPDATE pgreact_internal.decision_subject_state
            SET version_id = NULL, state = 'NO_CANDIDATE', winner_candidate = NULL,
                winner_priority = NULL, winner_result = NULL, activation_id = NULL,
                competitors = '[]'::jsonb, last_seen_at = clock_timestamp()
            WHERE program_id = target_program_id AND subject_key = old_state.subject_key;
            UPDATE pgreact_internal.decision_work
            SET activation_id = NULL, claimable = false, state = 'NO_CANDIDATE',
                updated_at = clock_timestamp()
            WHERE program_id = target_program_id AND subject_key = old_state.subject_key;
        END LOOP;
        RETURN 0;
    END IF;
    PERFORM pgreact_internal.load_decision_candidates(version_row.version_id);
    FOR subject_row IN
        SELECT subject_key FROM pg_temp.m26_decision_candidates
        UNION
        SELECT subject_key FROM pgreact_internal.decision_subject_state
        WHERE program_id = target_program_id
        ORDER BY subject_key
    LOOP
        desired_candidate := NULL;
        desired_priority := NULL;
        desired_result := NULL;
        SELECT min(priority), count(*) FILTER (WHERE priority = (SELECT min(c.priority)
               FROM pg_temp.m26_decision_candidates c
               WHERE c.subject_key = subject_row.subject_key))
        INTO desired_priority, top_count
        FROM pg_temp.m26_decision_candidates c
        WHERE c.subject_key = subject_row.subject_key;
        IF desired_priority IS NULL THEN
            desired_state := 'NO_CANDIDATE';
            competitors := '[]'::jsonb;
            competitors_truncated := false;
        ELSE
            competitors := '[]'::jsonb;
            SELECT count(*) INTO competitor_count
            FROM pg_temp.m26_decision_candidates
            WHERE subject_key = subject_row.subject_key;
            competitors_truncated := competitor_count > 25;
            FOR candidate_row IN
                SELECT candidate_key, priority, row_data
                FROM pg_temp.m26_decision_candidates
                WHERE subject_key = subject_row.subject_key
                ORDER BY priority, candidate_key
                LIMIT 25
            LOOP
                candidate_result := pgreact_internal.decision_result(
                    candidate_row.row_data, version_row.result_columns);
                competitors := competitors || jsonb_build_array(jsonb_build_object(
                    'candidate', candidate_row.candidate_key,
                    'priority', candidate_row.priority,
                    'result', candidate_result));
            END LOOP;
            IF top_count > 1 THEN
                desired_state := 'AMBIGUOUS';
            ELSE
                desired_state := 'WINNER';
                SELECT candidate_key, priority, row_data INTO winner_row
                FROM pg_temp.m26_decision_candidates
                WHERE subject_key = subject_row.subject_key
                  AND priority = desired_priority
                ORDER BY candidate_key LIMIT 1;
                desired_candidate := winner_row.candidate_key;
                desired_result := pgreact_internal.decision_result(
                    winner_row.row_data, version_row.result_columns);
            END IF;
        END IF;
        SELECT * INTO old_state FROM pgreact_internal.decision_subject_state
        WHERE program_id = target_program_id AND subject_key = subject_row.subject_key
        FOR UPDATE;
        had_old := FOUND;
        IF NOT had_old AND desired_state = 'NO_CANDIDATE' THEN CONTINUE; END IF;
        activation := CASE WHEN desired_state = 'WINNER' THEN
            pgreact_internal.decision_activation_id(version_row.version_id,
                                                    subject_row.subject_key, desired_candidate)
            ELSE NULL END;
        generation := COALESCE(old_state.generation, 0);
        revision := COALESCE(old_state.revision, 0);
        IF had_old AND old_state.state = 'WINNER'
           AND (desired_state <> 'WINNER' OR old_state.activation_id IS DISTINCT FROM activation) THEN
            PERFORM pgreact_internal.record_decision_event(
                target_program_id, old_state.version_id, old_state.subject_key,
                old_state.winner_candidate, old_state.activation_id, 'WINNER_OUT',
                old_state.generation, old_state.revision,
                jsonb_build_object('reason', CASE WHEN desired_state = 'WINNER'
                    THEN 'winner_replaced' ELSE lower(desired_state) END));
        END IF;
        IF had_old AND old_state.state = 'AMBIGUOUS' AND desired_state <> 'AMBIGUOUS' THEN
            PERFORM pgreact_internal.record_decision_event(
                target_program_id, version_row.version_id, subject_row.subject_key,
                NULL, NULL, 'AMBIGUITY_EXIT', old_state.generation, old_state.revision,
                jsonb_build_object('state', desired_state));
        END IF;
        IF desired_state = 'AMBIGUOUS' AND (NOT had_old OR old_state.state <> 'AMBIGUOUS') THEN
            PERFORM pgreact_internal.record_decision_event(
                target_program_id, version_row.version_id, subject_row.subject_key,
                NULL, NULL, 'AMBIGUITY_ENTER', generation, revision,
                jsonb_build_object('competitors', competitors));
        ELSIF desired_state = 'WINNER' AND (NOT had_old OR old_state.activation_id IS DISTINCT FROM activation) THEN
            generation := generation + 1;
            revision := 0;
            PERFORM pgreact_internal.record_decision_event(
                target_program_id, version_row.version_id, subject_row.subject_key,
                desired_candidate, activation, 'WINNER_IN', generation, revision,
                jsonb_build_object('priority', desired_priority, 'result', desired_result));
        ELSIF desired_state = 'WINNER' AND old_state.winner_result IS DISTINCT FROM desired_result THEN
            revision := revision + 1;
            PERFORM pgreact_internal.record_decision_event(
                target_program_id, version_row.version_id, subject_row.subject_key,
                desired_candidate, activation, 'WINNER_REVISION', generation, revision,
                jsonb_build_object('priority', desired_priority, 'result', desired_result));
        END IF;
        IF desired_state = 'NO_CANDIDATE' AND (NOT had_old OR old_state.state <> 'NO_CANDIDATE') THEN
            PERFORM pgreact_internal.record_decision_event(
                target_program_id, version_row.version_id, subject_row.subject_key,
                NULL, NULL, 'NO_CANDIDATE', generation, revision, '{}'::jsonb);
        END IF;
        INSERT INTO pgreact_internal.decision_subject_state(
            program_id, subject_key, version_id, state, winner_candidate,
            winner_priority, winner_result, activation_id, generation, revision,
            competitors, competitors_truncated, first_seen_at, last_seen_at)
        VALUES (target_program_id, subject_row.subject_key, version_row.version_id,
                desired_state, desired_candidate, desired_priority, desired_result,
                activation, generation, revision, competitors, competitors_truncated,
                COALESCE(old_state.first_seen_at, clock_timestamp()), clock_timestamp())
        ON CONFLICT (program_id, subject_key) DO UPDATE SET
            version_id = EXCLUDED.version_id, state = EXCLUDED.state,
            winner_candidate = EXCLUDED.winner_candidate,
            winner_priority = EXCLUDED.winner_priority,
            winner_result = EXCLUDED.winner_result,
            activation_id = EXCLUDED.activation_id, generation = EXCLUDED.generation,
            revision = EXCLUDED.revision, competitors = EXCLUDED.competitors,
            competitors_truncated = EXCLUDED.competitors_truncated,
            last_seen_at = EXCLUDED.last_seen_at;
        INSERT INTO pgreact_internal.decision_work(
            program_id, subject_key, activation_id, claimable, state)
        VALUES (target_program_id, subject_row.subject_key, activation,
                desired_state = 'WINNER', desired_state)
        ON CONFLICT (program_id, subject_key) DO UPDATE SET
            activation_id = EXCLUDED.activation_id, claimable = EXCLUDED.claimable,
            state = EXCLUDED.state, updated_at = clock_timestamp();
        changed := changed + 1;
    END LOOP;
    RETURN changed;
END
$m26$;

CREATE FUNCTION pgreact_api.author_decision_program(
    program_name text,
    candidate_relation regclass,
    subject_key_column name,
    candidate_key_column name,
    priority_column name,
    result_columns name[],
    valid_from timestamptz DEFAULT clock_timestamp(),
    valid_to timestamptz DEFAULT NULL,
    max_candidates integer DEFAULT 1000
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m26$
DECLARE diagnostic record;
    target_program_id uuid;
    version_id uuid := gen_random_uuid();
    next_version integer;
    current_frontier timestamptz;
    result_types jsonb;
BEGIN
    SELECT * INTO diagnostic
    FROM pgreact_internal.validate_decision_program(
        program_name, candidate_relation, subject_key_column, candidate_key_column,
        priority_column, result_columns, max_candidates)
    WHERE severity = 'ERROR' LIMIT 1;
    IF FOUND THEN RAISE EXCEPTION 'M26_VALIDATION:%: %', diagnostic.code, diagnostic.message; END IF;
    IF valid_from IS NULL OR NOT isfinite(valid_from)
       OR (valid_to IS NOT NULL AND (NOT isfinite(valid_to) OR valid_to <= valid_from)) THEN
        RAISE EXCEPTION 'M26_INTERVAL: decision version interval is empty, inverted, or non-finite';
    END IF;
    SELECT p.program_id INTO target_program_id FROM pgreact_internal.decision_programs p
    WHERE p.program_name = author_decision_program.program_name AND p.state <> 'REMOVED'
    FOR UPDATE;
    IF target_program_id IS NULL THEN
        target_program_id := gen_random_uuid();
        INSERT INTO pgreact_internal.decision_programs(program_id, program_name, owner_oid)
        VALUES (target_program_id, program_name, session_user::regrole::oid);
    ELSIF NOT pg_has_role(session_user,
                          (SELECT owner_oid FROM pgreact_internal.decision_programs p WHERE p.program_id = target_program_id),
                          'USAGE') AND NOT pgreact_internal.is_operator_admin() THEN
        RAISE EXCEPTION 'M26_CANDIDATE_OWNER: only the decision program owner or operator may replace a program';
    END IF;
    IF EXISTS (
        SELECT 1 FROM pgreact_internal.decision_program_versions v
        WHERE v.program_id = target_program_id AND v.state = 'DEPLOYED'
          AND v.valid_from < COALESCE(author_decision_program.valid_to, 'infinity'::timestamptz)
          AND COALESCE(v.valid_to, 'infinity'::timestamptz) > author_decision_program.valid_from) THEN
        RAISE EXCEPTION 'M26_INTERVAL_OVERLAP: decision version overlaps an existing authoritative interval';
    END IF;
    SELECT COALESCE(max(version_no), 0) + 1 INTO next_version
    FROM pgreact_internal.decision_program_versions v WHERE v.program_id = target_program_id;
    SELECT details -> 'result_types' INTO result_types
    FROM pgreact_internal.validate_decision_program(
        program_name, candidate_relation, subject_key_column, candidate_key_column,
        priority_column, result_columns, max_candidates)
    WHERE code = 'OK' LIMIT 1;
    INSERT INTO pgreact_internal.decision_program_versions(
        version_id, program_id, version_no, candidate_relation_oid, candidate_relation_name,
        subject_key_column, candidate_key_column, priority_column, result_columns, result_types,
        source_signature, source_definition_digest, max_candidates, valid_from, valid_to, deployed_by)
    VALUES (version_id, target_program_id, next_version,
            candidate_relation, candidate_relation::text, subject_key_column, candidate_key_column,
            priority_column, result_columns, COALESCE(result_types, '[]'::jsonb),
            pgreact_internal.source_row_signature(candidate_relation),
            pgreact_internal.decision_source_digest(candidate_relation), max_candidates,
            valid_from, valid_to, session_user::regrole::oid);
    SELECT frontier INTO current_frontier FROM pgreact_internal.clock_frontier;
    IF current_frontier >= valid_from
       AND (valid_to IS NULL OR current_frontier < valid_to) THEN
        PERFORM pgreact_internal.refresh_decision_program(target_program_id, current_frontier);
    END IF;
    RETURN version_id;
END
$m26$;

CREATE FUNCTION pgreact_api.deploy_decision_program(program_name text, version_id uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m26$
DECLARE target_program uuid;
    owner_oid oid;
BEGIN
    SELECT p.program_id, p.owner_oid INTO target_program, owner_oid
    FROM pgreact_internal.decision_programs p
    JOIN pgreact_internal.decision_program_versions v USING (program_id)
    WHERE p.program_name = deploy_decision_program.program_name
      AND v.version_id = deploy_decision_program.version_id
      AND p.state <> 'REMOVED';
    IF NOT FOUND THEN RAISE EXCEPTION 'M26_VERSION: decision program version was not found'; END IF;
    IF NOT pg_has_role(session_user, owner_oid, 'USAGE')
       AND NOT pgreact_internal.is_operator_admin() THEN
        RAISE EXCEPTION 'M26_CANDIDATE_OWNER: only the decision program owner or operator may deploy a version';
    END IF;
    UPDATE pgreact_internal.decision_program_versions SET state = 'DEPLOYED'
    WHERE version_id = deploy_decision_program.version_id;
    RETURN deploy_decision_program.version_id;
END
$m26$;

CREATE FUNCTION pgreact_api.pause_decision_program(program_name text)
RETURNS void
LANGUAGE SQL SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $m26$
    UPDATE pgreact_internal.decision_programs SET state = 'PAUSED'
    WHERE decision_programs.program_name = $1 AND state = 'ACTIVE'
$m26$;

CREATE FUNCTION pgreact_api.resume_decision_program(program_name text)
RETURNS void
LANGUAGE SQL SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $m26$
    UPDATE pgreact_internal.decision_programs SET state = 'ACTIVE'
    WHERE decision_programs.program_name = $1 AND state = 'PAUSED'
$m26$;

CREATE FUNCTION pgreact_api.remove_decision_program(program_name text)
RETURNS void
LANGUAGE SQL SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $m26$
    UPDATE pgreact_internal.decision_programs SET state = 'REMOVED'
    WHERE decision_programs.program_name = $1 AND state <> 'REMOVED'
$m26$;

CREATE FUNCTION pgreact_api.reconcile_decision_program(program_name text)
RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $m26$
DECLARE target_program uuid;
    current_frontier timestamptz;
BEGIN
    SELECT program_id INTO target_program FROM pgreact_internal.decision_programs
    WHERE decision_programs.program_name = reconcile_decision_program.program_name
      AND state <> 'REMOVED';
    IF NOT FOUND THEN RAISE EXCEPTION 'M26_PROGRAM: decision program was not found'; END IF;
    SELECT frontier INTO current_frontier FROM pgreact_internal.clock_frontier;
    RETURN pgreact_internal.refresh_decision_program(target_program, current_frontier);
END
$m26$;

CREATE VIEW pgreact.decision_programs AS
SELECT p.program_id, p.program_name, pg_get_userbyid(p.owner_oid) AS owner, p.state,
       v.version_id, v.version_no, v.candidate_relation_name AS candidate_relation,
       v.subject_key_column, v.candidate_key_column, v.priority_column,
       v.result_columns, v.result_types, v.max_candidates, v.valid_from, v.valid_to,
       v.source_signature, v.source_definition_digest, v.state AS version_state,
       v.deployed_at
FROM pgreact_internal.decision_programs p
LEFT JOIN LATERAL (
    SELECT version.* FROM pgreact_internal.decision_program_versions version
    WHERE version.program_id = p.program_id AND version.state = 'DEPLOYED'
    ORDER BY version.valid_from DESC, version.version_no DESC LIMIT 1
) v ON true
WHERE p.state <> 'REMOVED';

CREATE VIEW pgreact.decision_winners AS
SELECT state.program_id, program.program_name, state.subject_key, state.version_id,
       state.state, state.winner_candidate, state.winner_priority, state.winner_result,
       state.activation_id, state.generation, state.revision, state.competitors,
       state.competitors_truncated,
       work.claimable, state.first_seen_at, state.last_seen_at
FROM pgreact_internal.decision_subject_state state
JOIN pgreact_internal.decision_programs program USING (program_id)
LEFT JOIN pgreact_internal.decision_work work USING (program_id, subject_key)
WHERE program.state <> 'REMOVED';

CREATE VIEW pgreact.decision_history AS
SELECT event.event_id, event.program_id, program.program_name, event.version_id,
       event.subject_key, event.candidate_key, event.activation_id, event.event_kind,
       event.generation, event.revision, event.details, event.occurred_at
FROM pgreact_internal.decision_lifecycle_events event
JOIN pgreact_internal.decision_programs program USING (program_id)
WHERE program.state <> 'REMOVED';

CREATE FUNCTION pgreact_api.decision_status(target_program_name text DEFAULT NULL)
RETURNS jsonb
LANGUAGE SQL STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $m26$
    SELECT jsonb_build_object(
        'contract_version', 14,
        'programs', COALESCE((SELECT jsonb_agg(to_jsonb(p) ORDER BY p.program_name)
                              FROM pgreact.decision_programs p
                              WHERE $1 IS NULL OR p.program_name = $1), '[]'::jsonb),
        'subjects', COALESCE((SELECT jsonb_agg(to_jsonb(w) ORDER BY w.program_name, w.subject_key)
                              FROM pgreact.decision_winners w
                              WHERE $1 IS NULL OR w.program_name = $1), '[]'::jsonb),
        'frontier', (SELECT frontier FROM pgreact_internal.clock_frontier),
        'selection', 'lowest priority wins; an equal best priority is ambiguous')
$m26$;

CREATE FUNCTION pgreact_api.decision_history(target_program_name text)
RETURNS jsonb
LANGUAGE SQL STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $m26$
    SELECT jsonb_build_object('contract_version', 14, 'program', $1,
        'events', COALESCE((SELECT jsonb_agg(to_jsonb(h) ORDER BY h.event_id)
                            FROM pgreact.decision_history h
                            WHERE h.program_name = $1), '[]'::jsonb))
$m26$;

CREATE FUNCTION pgreact_api.decision_preview(target_program_name text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $m26$
DECLARE program_row record;
    version_row record;
    subject_row record;
    candidate_row record;
    subjects jsonb := '[]'::jsonb;
    candidates jsonb;
    candidate_result jsonb;
    top_priority bigint;
    top_count bigint;
    candidate_count bigint;
    preview_state text;
BEGIN
    SELECT * INTO program_row FROM pgreact_internal.decision_programs
    WHERE program_name = target_program_name AND state <> 'REMOVED';
    IF NOT FOUND THEN RETURN jsonb_build_object('contract_version', 14, 'available', false,
                                                'program', target_program_name); END IF;
    SELECT * INTO version_row FROM pgreact_internal.decision_program_versions
    WHERE program_id = program_row.program_id AND state = 'DEPLOYED'
    ORDER BY valid_from DESC, version_no DESC LIMIT 1;
    IF NOT FOUND THEN RETURN jsonb_build_object('contract_version', 14, 'available', false,
                                                'program', target_program_name); END IF;
    PERFORM pgreact_internal.load_decision_candidates(version_row.version_id);
    FOR subject_row IN SELECT DISTINCT subject_key FROM pg_temp.m26_decision_candidates ORDER BY subject_key LOOP
        candidates := '[]'::jsonb;
        FOR candidate_row IN SELECT candidate_key, priority, row_data
            FROM pg_temp.m26_decision_candidates WHERE subject_key = subject_row.subject_key
            ORDER BY priority, candidate_key LIMIT 25 LOOP
            candidate_result := pgreact_internal.decision_result(candidate_row.row_data, version_row.result_columns);
            candidates := candidates || jsonb_build_array(jsonb_build_object(
                'candidate', candidate_row.candidate_key, 'priority', candidate_row.priority,
                'result', candidate_result));
        END LOOP;
        SELECT min(priority), count(*) FILTER (WHERE priority = (SELECT min(c.priority)
               FROM pg_temp.m26_decision_candidates c WHERE c.subject_key = subject_row.subject_key))
        INTO top_priority, top_count FROM pg_temp.m26_decision_candidates c
        WHERE c.subject_key = subject_row.subject_key;
        SELECT count(*) INTO candidate_count FROM pg_temp.m26_decision_candidates c
        WHERE c.subject_key = subject_row.subject_key;
        preview_state := CASE WHEN top_count > 1 THEN 'AMBIGUOUS' ELSE 'WINNER' END;
        subjects := subjects || jsonb_build_array(jsonb_build_object(
            'subject', subject_row.subject_key, 'state', preview_state,
            'top_priority', top_priority, 'candidates', candidates,
            'truncated', candidate_count > 25));
    END LOOP;
    RETURN jsonb_build_object('contract_version', 14, 'available', true,
        'program', target_program_name, 'version_id', version_row.version_id,
        'side_effect_free', true, 'subjects', subjects,
        'competitor_limit', 25);
END
$m26$;

CREATE FUNCTION pgreact_api.decision_explain(target_program_name text, target_subject bigint)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $m26$
DECLARE explanation jsonb;
    current_state jsonb;
BEGIN
    explanation := pgreact_api.decision_preview(target_program_name);
    SELECT to_jsonb(w) INTO current_state FROM pgreact.decision_winners w
    WHERE w.program_name = target_program_name AND w.subject_key = target_subject;
    RETURN explanation || jsonb_build_object('subject', target_subject,
        'current', current_state,
        'lifecycle', COALESCE((SELECT jsonb_agg(to_jsonb(h) ORDER BY h.event_id)
            FROM pgreact.decision_history h
            WHERE h.program_name = target_program_name AND h.subject_key = target_subject), '[]'::jsonb),
        'note', 'A subject absent from both candidates and retained winner history is never-observed.');
END
$m26$;

CREATE FUNCTION pgreact_api.decision_doctor()
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $m26$
DECLARE diagnostics jsonb := '[]'::jsonb;
    version_row record;
    row_count bigint;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_react' AND extversion = '0.23.0') THEN
        diagnostics := diagnostics || jsonb_build_array(jsonb_build_object(
            'code', 'M26_EXTENSION_VERSION', 'severity', 'ERROR',
            'object_identity', 'pg_react', 'message', 'pg_react extension version is not 0.23.0',
            'hint', 'Install the matching extension files and run ALTER EXTENSION pg_react UPDATE TO ''0.23.0''.'));
    END IF;
    FOR version_row IN
        SELECT v.*, p.program_name FROM pgreact_internal.decision_program_versions v
        JOIN pgreact_internal.decision_programs p USING (program_id)
        WHERE p.state <> 'REMOVED' AND v.state = 'DEPLOYED'
    LOOP
        IF version_row.source_signature IS DISTINCT FROM pgreact_internal.source_row_signature(version_row.candidate_relation_oid)
           OR version_row.source_definition_digest IS DISTINCT FROM pgreact_internal.decision_source_digest(version_row.candidate_relation_oid) THEN
            diagnostics := diagnostics || jsonb_build_array(jsonb_build_object(
                'code', 'M26_DECISION_DRIFT', 'severity', 'ERROR', 'object_identity', version_row.program_name,
                'message', 'the candidate relation definition changed after declaration',
                'hint', 'Restore the declared relation shape or replace the decision-program version.'));
        ELSE
            EXECUTE format('SELECT count(*) FROM %s', version_row.candidate_relation_oid::regclass) INTO row_count;
            IF row_count > version_row.max_candidates * 100000 THEN
                diagnostics := diagnostics || jsonb_build_array(jsonb_build_object(
                    'code', 'M26_CANDIDATE_LIMIT', 'severity', 'ERROR', 'object_identity', version_row.program_name,
                    'message', 'the candidate relation exceeds the published admission envelope',
                    'hint', 'Archive or partition candidate rows before continuing.'));
            END IF;
        END IF;
    END LOOP;
    RETURN jsonb_build_object('contract_version', 14,
        'status', CASE WHEN EXISTS (SELECT 1 FROM jsonb_array_elements(diagnostics) d
                                    WHERE d ->> 'severity' = 'ERROR') THEN 'attention' ELSE 'ready' END,
        'diagnostics', diagnostics);
END
$m26$;

ALTER FUNCTION pgreact_api.run(timestamptz) SET SCHEMA pgreact_internal;
ALTER FUNCTION pgreact_internal.run(timestamptz) RENAME TO run_m25;

CREATE FUNCTION pgreact_api.run(sampled_time timestamptz DEFAULT clock_timestamp())
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $m26$
DECLARE result jsonb;
    program_row record;
BEGIN
    result := pgreact_internal.run_m25(sampled_time);
    FOR program_row IN SELECT program_id FROM pgreact_internal.decision_programs WHERE state = 'ACTIVE' LOOP
        PERFORM pgreact_internal.refresh_decision_program(program_row.program_id, sampled_time);
    END LOOP;
    RETURN jsonb_set(result || jsonb_build_object('decision_programs', pgreact_api.decision_status()),
                     '{contract_version}', '14'::jsonb, true);
END
$m26$;

ALTER FUNCTION pgreact_api.status(text) SET SCHEMA pgreact_internal;
ALTER FUNCTION pgreact_internal.status(text) RENAME TO status_m25;

CREATE FUNCTION pgreact_api.status(target_name text DEFAULT NULL)
RETURNS jsonb
LANGUAGE SQL STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $m26$
    SELECT pgreact_internal.status_m25($1)
        || jsonb_build_object('decision_programs', pgreact_api.decision_status($1),
                              'contract_version', 14)
$m26$;

ALTER FUNCTION pgreact_api.doctor() SET SCHEMA pgreact_internal;
ALTER FUNCTION pgreact_internal.doctor() RENAME TO doctor_m25;

CREATE FUNCTION pgreact_api.doctor()
RETURNS jsonb
LANGUAGE SQL STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $m26$
    SELECT jsonb_build_object(
        'contract_version', 14,
        'status', CASE WHEN EXISTS (
            SELECT 1 FROM jsonb_array_elements(
                COALESCE(pgreact_internal.doctor_m25() -> 'diagnostics', '[]'::jsonb)
                || (pgreact_api.decision_doctor() -> 'diagnostics')) d
            WHERE d ->> 'severity' = 'ERROR') THEN 'attention' ELSE 'ready' END,
        'diagnostics', COALESCE(pgreact_internal.doctor_m25() -> 'diagnostics', '[]'::jsonb)
            || (pgreact_api.decision_doctor() -> 'diagnostics'))
$m26$;

ALTER FUNCTION pgreact_api.configure_roles(regrole, regrole, regrole, regrole, regrole)
    SET SCHEMA pgreact_internal;
ALTER FUNCTION pgreact_internal.configure_roles(regrole, regrole, regrole, regrole, regrole)
    RENAME TO configure_roles_m25;

CREATE FUNCTION pgreact_api.configure_roles(
    author_role regrole, operator_role regrole, worker_role regrole,
    reader_role regrole, advanced_reader_role regrole)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $m26$
BEGIN
    PERFORM pgreact_internal.configure_roles_m25(
        author_role, operator_role, worker_role, reader_role, advanced_reader_role);
    EXECUTE format('GRANT SELECT ON pgreact.decision_programs, pgreact.decision_winners, pgreact.decision_history TO %I, %I',
                   reader_role::text, operator_role::text);
    EXECUTE format('GRANT EXECUTE ON FUNCTION pgreact_api.validate_decision_program(text,regclass,name,name,name,name[],integer), '
        'pgreact_api.author_decision_program(text,regclass,name,name,name,name[],timestamptz,timestamptz,integer), '
        'pgreact_api.deploy_decision_program(text,uuid), pgreact_api.pause_decision_program(text), '
        'pgreact_api.resume_decision_program(text), pgreact_api.remove_decision_program(text) TO %I', author_role::text);
    EXECUTE format('GRANT EXECUTE ON FUNCTION pgreact_api.decision_status(text), '
        'pgreact_api.decision_history(text), pgreact_api.decision_preview(text), '
        'pgreact_api.decision_explain(text,bigint), pgreact_api.decision_doctor() TO %I, %I',
        reader_role::text, operator_role::text);
    EXECUTE format('GRANT EXECUTE ON FUNCTION pgreact_api.reconcile_decision_program(text) TO %I', operator_role::text);
END
$m26$;

DO $m26$
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
$m26$;

REVOKE ALL ON ALL TABLES IN SCHEMA pgreact_internal FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA pgreact_internal FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA pgreact_api FROM PUBLIC;

COMMENT ON EXTENSION pg_react IS
    'M26 deterministic decision tables over the M25 parameterized policy platform';
