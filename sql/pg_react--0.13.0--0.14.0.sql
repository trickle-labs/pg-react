-- M17 fixed-duration event-time windows. Windowed aggregates reuse the M16
-- aggregate engine through typed materialized inputs; this catalog owns the
-- temporal contract that M16 does not have.

CREATE TABLE pgreact_internal.window_programs (
    program_version_id uuid PRIMARY KEY,
    program_name text NOT NULL,
    program_version integer NOT NULL CHECK (program_version > 0),
    owner_oid oid NOT NULL,
    public_definition jsonb NOT NULL,
    input_relation_name text NOT NULL,
    condition_relation_name text NOT NULL,
    input_definition_digest bytea NOT NULL,
    input_row_signature bytea NOT NULL,
    condition_definition_digest bytea NOT NULL,
    condition_row_signature bytea NOT NULL,
    event_time_column name NOT NULL,
    duration_us bigint NOT NULL CHECK (duration_us > 0),
    allowed_lateness_us bigint NOT NULL CHECK (allowed_lateness_us >= 0),
    group_columns name[] NOT NULL CHECK (cardinality(group_columns) BETWEEN 1 AND 3),
    window_column name NOT NULL,
    helper_input_name text NOT NULL,
    helper_keys_name text NOT NULL,
    helper_input_store_name text NOT NULL,
    helper_keys_store_name text NOT NULL,
    max_facts bigint NOT NULL CHECK (max_facts > 0),
    lower_frontier bigint NOT NULL DEFAULT 0 CHECK (lower_frontier >= 0),
    observed_frontier bigint NOT NULL DEFAULT 0 CHECK (observed_frontier >= lower_frontier),
    requested_watermark timestamptz NOT NULL DEFAULT '-infinity',
    complete_watermark timestamptz NOT NULL DEFAULT '-infinity',
    history_floor timestamptz NOT NULL DEFAULT '-infinity',
    barrier text CHECK (barrier IS NULL OR barrier = 'LATE_INPUT'),
    active boolean NOT NULL DEFAULT true,
    last_source_fingerprint bytea NOT NULL DEFAULT sha256(''::bytea),
    last_observed_fingerprint bytea NOT NULL DEFAULT sha256(''::bytea),
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    UNIQUE (program_name, program_version)
);

CREATE UNIQUE INDEX window_program_one_active
    ON pgreact_internal.window_programs (program_name) WHERE active;

CREATE TABLE pgreact_internal.window_rules (
    program_version_id uuid NOT NULL REFERENCES pgreact_internal.window_programs ON DELETE CASCADE,
    rule_version_id uuid NOT NULL,
    rule_name text NOT NULL,
    rule_version integer NOT NULL CHECK (rule_version > 0),
    target_relation text NOT NULL,
    aggregate_function text NOT NULL CHECK (aggregate_function IN ('COUNT_STAR','COUNT','SUM','MIN','MAX')),
    value_expression name,
    comparison text NOT NULL CHECK (comparison IN ('=','<','<=','>','>=')),
    typed_threshold text NOT NULL,
    PRIMARY KEY (program_version_id, rule_version_id),
    UNIQUE (program_version_id, rule_name)
);

CREATE TABLE pgreact_internal.window_source_rows (
    program_version_id uuid NOT NULL REFERENCES pgreact_internal.window_programs ON DELETE CASCADE,
    row_data jsonb NOT NULL,
    public_window_key jsonb NOT NULL,
    event_time timestamptz NOT NULL,
    window_ordinal bigint NOT NULL,
    occurrences bigint NOT NULL CHECK (occurrences > 0),
    PRIMARY KEY (program_version_id, row_data, public_window_key, event_time, window_ordinal)
);

CREATE TABLE pgreact_internal.window_identities (
    program_version_id uuid NOT NULL REFERENCES pgreact_internal.window_programs ON DELETE CASCADE,
    public_window_key jsonb NOT NULL,
    canonical_window_key bytea NOT NULL,
    window_ordinal bigint NOT NULL,
    window_start timestamptz NOT NULL,
    window_end timestamptz NOT NULL,
    lateness_boundary timestamptz NOT NULL,
    final boolean NOT NULL DEFAULT false,
    PRIMARY KEY (program_version_id, public_window_key)
);

CREATE INDEX window_identity_boundary
    ON pgreact_internal.window_identities (program_version_id, lateness_boundary, canonical_window_key);

CREATE TABLE pgreact_internal.window_corrections (
    correction_order bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    correction_identity text NOT NULL UNIQUE,
    program_version_id uuid NOT NULL REFERENCES pgreact_internal.window_programs ON DELETE CASCADE,
    program_name text NOT NULL,
    program_version integer NOT NULL,
    rule_version_id uuid NOT NULL,
    rule_name text NOT NULL,
    rule_version integer NOT NULL,
    target_relation text NOT NULL,
    public_window_key jsonb NOT NULL,
    public_group_key jsonb NOT NULL,
    window_ordinal bigint NOT NULL,
    canonical_window_key bytea NOT NULL,
    lower_frontier bigint NOT NULL CHECK (lower_frontier > 0),
    before_value text,
    after_value text,
    before_truth boolean,
    after_truth boolean,
    support_generation integer NOT NULL CHECK (support_generation >= 0),
    created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE INDEX window_correction_history
    ON pgreact_internal.window_corrections
       (program_version_id, window_ordinal, lower_frontier, rule_name);

CREATE TABLE pgreact_internal.window_finalizations (
    finalization_identity text PRIMARY KEY,
    program_version_id uuid NOT NULL REFERENCES pgreact_internal.window_programs ON DELETE CASCADE,
    public_window_key jsonb NOT NULL,
    canonical_window_key bytea NOT NULL,
    lateness_boundary timestamptz NOT NULL,
    finalized_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    UNIQUE (program_version_id, public_window_key)
);

CREATE TABLE pgreact_internal.window_lifecycle (
    lifecycle_order bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    program_version_id uuid NOT NULL REFERENCES pgreact_internal.window_programs ON DELETE CASCADE,
    lower_frontier bigint NOT NULL,
    public_window_key jsonb NOT NULL,
    canonical_window_key bytea NOT NULL,
    rule_name text NOT NULL,
    event_kind text NOT NULL CHECK (event_kind IN ('ACTIVATE','DEACTIVATE')),
    support_generation integer NOT NULL CHECK (support_generation > 0),
    UNIQUE (program_version_id, lower_frontier, public_window_key, rule_name, event_kind)
);

CREATE TABLE pgreact_internal.window_diagnostics (
    diagnostic_order bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    contract_version integer NOT NULL DEFAULT 6 CHECK (contract_version = 6),
    code text NOT NULL,
    severity text NOT NULL CHECK (severity IN ('ERROR','WARNING','INFO')),
    object_identity text NOT NULL,
    sqlstate text NOT NULL CHECK (length(sqlstate) = 5),
    message text NOT NULL,
    hint text NOT NULL,
    details jsonb NOT NULL DEFAULT '{}'::jsonb,
    program_version_id uuid REFERENCES pgreact_internal.window_programs ON DELETE CASCADE,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE pgreact_internal.window_audits (
    audit_order bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    program_version_id uuid REFERENCES pgreact_internal.window_programs ON DELETE SET NULL,
    operation text NOT NULL,
    actor name NOT NULL DEFAULT session_user,
    details jsonb NOT NULL,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE FUNCTION pgreact_internal.fixed_interval_us(value text, allow_zero boolean)
RETURNS bigint
LANGUAGE plpgsql
IMMUTABLE
STRICT
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE parsed interval; micros numeric;
BEGIN
    BEGIN
        parsed := value::interval;
    EXCEPTION WHEN OTHERS THEN
        RAISE EXCEPTION 'M17_WINDOW_INTERVAL_INVALID: %', value USING ERRCODE = '22023';
    END;
    IF extract(year FROM parsed) <> 0 OR extract(month FROM parsed) <> 0 THEN
        RAISE EXCEPTION 'M17_WINDOW_INTERVAL_INVALID: % is not fixed-duration', value
            USING ERRCODE = '22023';
    END IF;
    micros := extract(epoch FROM parsed)::numeric * 1000000;
    IF micros <> trunc(micros) OR micros > 9223372036854775807
       OR micros < (CASE WHEN allow_zero THEN 0 ELSE 1 END) THEN
        RAISE EXCEPTION 'M17_WINDOW_INTERVAL_INVALID: % is outside the supported range', value
            USING ERRCODE = '22023';
    END IF;
    RETURN micros::bigint;
END
$$;

CREATE FUNCTION pgreact_internal.window_ordinal(value timestamptz, duration_us bigint)
RETURNS bigint
LANGUAGE plpgsql
IMMUTABLE
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE micros numeric; result numeric;
BEGIN
    IF value IS NULL THEN
        RAISE EXCEPTION 'M17_EVENT_TIME_NULL: event time must be non-null' USING ERRCODE = '22004';
    END IF;
    IF NOT isfinite(value) THEN
        RAISE EXCEPTION 'M17_EVENT_TIME_INFINITE: event time must be finite' USING ERRCODE = '22008';
    END IF;
    micros := extract(epoch FROM value)::numeric * 1000000;
    result := floor(micros / duration_us::numeric);
    IF result < -9223372036854775808 OR result > 9223372036854775807 THEN
        RAISE EXCEPTION 'M17_WINDOW_ORDINAL_RANGE: event time is outside the signed ordinal range'
            USING ERRCODE = '22008';
    END IF;
    RETURN result::bigint;
END
$$;

CREATE FUNCTION pgreact_internal.window_bound(window_ordinal bigint, duration_us bigint)
RETURNS timestamptz
LANGUAGE plpgsql
IMMUTABLE
STRICT
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE micros numeric := window_ordinal::numeric * duration_us::numeric; result timestamptz;
BEGIN
    BEGIN
        result := 'epoch'::timestamptz + (micros::text || ' microseconds')::interval;
    EXCEPTION WHEN OTHERS THEN
        RAISE EXCEPTION 'M17_WINDOW_ORDINAL_RANGE: window bound is not a finite timestamptz'
            USING ERRCODE = '22008';
    END;
    IF NOT isfinite(result) THEN
        RAISE EXCEPTION 'M17_WINDOW_ORDINAL_RANGE: window bound is not finite'
            USING ERRCODE = '22008';
    END IF;
    RETURN result;
END
$$;

CREATE FUNCTION pgreact_internal.window_key_bytes(public_key jsonb)
RETURNS bytea
LANGUAGE SQL
IMMUTABLE
STRICT
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT sha256(convert_to($1::text, 'UTF8'))
$$;

ALTER FUNCTION pgreact_api.validate_program(jsonb) SET SCHEMA pgreact_internal;
ALTER FUNCTION pgreact_internal.validate_program(jsonb) RENAME TO validate_program_m16;
ALTER FUNCTION pgreact_api.preview_program(jsonb) SET SCHEMA pgreact_internal;
ALTER FUNCTION pgreact_internal.preview_program(jsonb) RENAME TO preview_program_m16;
ALTER FUNCTION pgreact_api.deploy_program(jsonb, text) SET SCHEMA pgreact_internal;
ALTER FUNCTION pgreact_internal.deploy_program(jsonb, text) RENAME TO deploy_program_m16;

CREATE FUNCTION pgreact_internal.is_window_program(definition jsonb)
RETURNS boolean
LANGUAGE SQL
IMMUTABLE
RETURNS NULL ON NULL INPUT
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT EXISTS (
        SELECT 1 FROM jsonb_array_elements(CASE
            WHEN jsonb_typeof($1 -> 'rules') = 'array' THEN $1 -> 'rules' ELSE '[]'::jsonb END) rule
        WHERE (rule -> 'aggregate_input') ? 'window')
$$;

CREATE FUNCTION pgreact_internal.normalized_window_program(definition jsonb)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
STRICT
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE result jsonb := pgreact_api.infer_program(definition); item record; window_value jsonb;
BEGIN
    FOR item IN SELECT value, ordinal FROM jsonb_array_elements(result -> 'rules')
        WITH ORDINALITY rule(value, ordinal)
    LOOP
        IF NOT (item.value -> 'aggregate_input') ? 'window' THEN CONTINUE; END IF;
        window_value := item.value #> '{aggregate_input,window}';
        result := jsonb_set(result,
            ARRAY['rules',(item.ordinal - 1)::text,'aggregate_input','window'],
            jsonb_build_object(
                'event_time', window_value ->> 'event_time',
                'duration_us', pgreact_internal.fixed_interval_us(window_value ->> 'duration', false),
                'allowed_lateness_us', pgreact_internal.fixed_interval_us(
                    window_value ->> 'allowed_lateness', true),
                'alignment', 'UTC_EPOCH'));
    END LOOP;
    RETURN result;
END
$$;

CREATE FUNCTION pgreact_api.validate_program(definition jsonb)
RETURNS TABLE(
    contract_version integer, code text, severity text,
    object_identity text, message text, hint text, details jsonb
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    item record;
    aggregate_item jsonb;
    window_item jsonb;
    first_relation text;
    first_condition text;
    first_event name;
    duration_value bigint;
    lateness_value bigint;
    first_duration bigint;
    first_lateness bigint;
    input_oid oid;
    condition_oid oid;
    target_spec pgreact_internal.keyed_derived_relations%ROWTYPE;
    event_attribute record;
    value_attribute record;
    function_name text;
    result_type oid;
    group_column name;
    rule_count integer;
BEGIN
    IF NOT pgreact_internal.is_window_program(definition) THEN
        RETURN QUERY SELECT * FROM pgreact_internal.validate_program_m16(definition);
        RETURN;
    END IF;
    IF jsonb_typeof(definition) IS DISTINCT FROM 'object'
       OR jsonb_typeof(definition -> 'rules') IS DISTINCT FROM 'array'
       OR jsonb_array_length(definition -> 'rules') = 0 THEN
        RETURN QUERY SELECT 6, 'M17_PROGRAM_INVALID', 'ERROR', 'program',
            'windowed program must be an object with at least one rule',
            'Declare one or more rules sharing one timed aggregate input.', '{}'::jsonb;
        RETURN;
    END IF;
    rule_count := jsonb_array_length(definition -> 'rules');
    IF COALESCE((definition ->> 'max_facts')::bigint, 0) < rule_count THEN
        RETURN QUERY SELECT 6, 'M17_RESOURCE_LIMIT', 'ERROR', definition ->> 'name',
            'max_facts cannot hold one state for every window rule',
            'Raise max_facts to at least the number of rules.',
            jsonb_build_object('required', rule_count);
        RETURN;
    END IF;
    FOR item IN SELECT value, ordinal FROM jsonb_array_elements(definition -> 'rules')
        WITH ORDINALITY rules(value, ordinal)
    LOOP
        aggregate_item := item.value -> 'aggregate_input';
        window_item := aggregate_item -> 'window';
        IF jsonb_typeof(aggregate_item) IS DISTINCT FROM 'object'
           OR jsonb_typeof(window_item) IS DISTINCT FROM 'object'
           OR NOT aggregate_item ?& ARRAY['relation','key','comparison','threshold','window']
           OR (aggregate_item ? 'function') <> (aggregate_item ? 'expression')
           OR (SELECT count(*) FROM jsonb_object_keys(aggregate_item)) <>
              (CASE WHEN aggregate_item ? 'function' THEN 7 ELSE 5 END)
           OR NOT window_item ?& ARRAY['event_time','duration','allowed_lateness']
           OR (SELECT count(*) FROM jsonb_object_keys(window_item)) <> 3 THEN
            RETURN QUERY SELECT 6, 'M17_WINDOW_DECLARATION_INVALID', 'ERROR',
                COALESCE(item.value ->> 'name', item.ordinal::text),
                'windowed aggregate_input has unsupported or missing members',
                'Use relation, key, comparison, threshold, optional function/expression, and one event_time/duration/allowed_lateness window.',
                '{}'::jsonb;
            RETURN;
        END IF;
        BEGIN
            duration_value := pgreact_internal.fixed_interval_us(window_item ->> 'duration', false);
            lateness_value := pgreact_internal.fixed_interval_us(
                window_item ->> 'allowed_lateness', true);
        EXCEPTION WHEN SQLSTATE '22023' THEN
            RETURN QUERY SELECT 6, 'M17_WINDOW_INTERVAL_INVALID', 'ERROR',
                item.value ->> 'name', 'window duration or allowed lateness is invalid',
                'Use fixed integral microsecond intervals; duration must be positive and lateness nonnegative.',
                jsonb_build_object('duration', window_item -> 'duration',
                                   'allowed_lateness', window_item -> 'allowed_lateness');
            RETURN;
        END;
        IF item.ordinal = 1 THEN
            first_relation := aggregate_item ->> 'relation';
            first_condition := item.value ->> 'definition';
            first_event := (window_item ->> 'event_time')::name;
            first_duration := duration_value;
            first_lateness := lateness_value;
        ELSIF first_relation IS DISTINCT FROM aggregate_item ->> 'relation'
              OR first_condition IS DISTINCT FROM item.value ->> 'definition'
              OR first_event IS DISTINCT FROM (window_item ->> 'event_time')::name
              OR first_duration IS DISTINCT FROM duration_value
              OR first_lateness IS DISTINCT FROM lateness_value THEN
            RETURN QUERY SELECT 6, 'M17_MULTIPLE_WINDOWS', 'ERROR', definition ->> 'name',
                'all windowed rules in one program must share one logical timed input',
                'Use one relation, event-time column, duration, lateness, and group source.', '{}'::jsonb;
            RETURN;
        END IF;
        input_oid := to_regclass(aggregate_item ->> 'relation');
        condition_oid := to_regclass(item.value ->> 'definition');
        IF input_oid IS NULL OR condition_oid IS NULL THEN
            RETURN QUERY SELECT 6, 'M17_WINDOW_RELATION_UNRESOLVED', 'ERROR', item.value ->> 'name',
                'window input or group source does not resolve',
                'Use schema-qualified existing relations.',
                jsonb_build_object('input', aggregate_item -> 'relation',
                                   'condition', item.value -> 'definition');
            RETURN;
        END IF;
        IF cardinality(parse_ident(aggregate_item ->> 'relation', true)) <> 2
           OR cardinality(parse_ident(item.value ->> 'definition', true)) <> 2 THEN
            RETURN QUERY SELECT 6, 'M17_WINDOW_RELATION_UNQUALIFIED', 'ERROR', item.value ->> 'name',
                'window input and group source must be schema-qualified',
                'Qualify both relations with their schema.', '{}'::jsonb;
            RETURN;
        END IF;
        IF NOT has_table_privilege(session_user, input_oid, 'SELECT')
           OR NOT has_table_privilege(session_user, condition_oid, 'SELECT') THEN
            RETURN QUERY SELECT 6, 'PROGRAM_AGGREGATE_UNAUTHORIZED', 'ERROR', item.value ->> 'name',
                'program author cannot read the timed input or group source',
                'Grant SELECT on both relations to the author.', '{}'::jsonb;
            RETURN;
        END IF;
        IF EXISTS (SELECT 1 FROM pg_class WHERE oid IN (input_oid, condition_oid) AND relrowsecurity) THEN
            RETURN QUERY SELECT 6, 'PROGRAM_AGGREGATE_RLS_UNSUPPORTED', 'ERROR', item.value ->> 'name',
                'row-level-security sources are outside the supported window boundary',
                'Use an authorized non-RLS projection.', '{}'::jsonb;
            RETURN;
        END IF;
        SELECT attnum, atttypid INTO event_attribute
        FROM pg_attribute
        WHERE attrelid = input_oid AND attname = (window_item ->> 'event_time')::name
          AND attnum > 0 AND NOT attisdropped;
        IF NOT FOUND OR event_attribute.atttypid IS DISTINCT FROM 'timestamptz'::regtype::oid THEN
            RETURN QUERY SELECT 6, 'M17_EVENT_TIME_TYPE', 'ERROR', item.value ->> 'name',
                'event_time must name one direct timestamptz column',
                'Project a finite non-null timestamptz column and name it directly.',
                jsonb_build_object('event_time', window_item -> 'event_time');
            RETURN;
        END IF;
        SELECT spec.* INTO target_spec FROM pgreact_internal.keyed_derived_relations spec
        WHERE spec.public_name = item.value ->> 'target';
        IF NOT FOUND OR cardinality(target_spec.key_columns) NOT BETWEEN 2 AND 4
           OR target_spec.key_types[cardinality(target_spec.key_types)] <> 'bigint'::regtype THEN
            RETURN QUERY SELECT 6, 'M17_WINDOW_KEY_INVALID', 'ERROR', item.value ->> 'name',
                'window target key must append one bigint ordinal to one to three group components',
                'Declare the target with group keys followed by a bigint window ordinal.', '{}'::jsonb;
            RETURN;
        END IF;
        IF EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = input_oid
                   AND attname = target_spec.key_columns[cardinality(target_spec.key_columns)]
                   AND attnum > 0 AND NOT attisdropped) THEN
            RETURN QUERY SELECT 6, 'M17_WINDOW_KEY_AMBIGUOUS', 'ERROR', item.value ->> 'name',
                'timed input already exposes the reserved target window-ordinal column',
                'Rename that source column or the target ordinal column.', '{}'::jsonb;
            RETURN;
        END IF;
        FOREACH group_column IN ARRAY target_spec.key_columns[1:cardinality(target_spec.key_columns)-1]
        LOOP
            IF NOT EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = input_oid
                           AND attname = group_column AND attnum > 0 AND NOT attisdropped)
               OR NOT EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = condition_oid
                              AND attname = group_column AND attnum > 0 AND NOT attisdropped) THEN
                RETURN QUERY SELECT 6, 'M17_WINDOW_KEY_UNBOUND', 'ERROR', item.value ->> 'name',
                    'group key is not directly present in both source relations',
                    'Expose every target group-key column from the timed input and group source.',
                    jsonb_build_object('column', group_column);
                RETURN;
            END IF;
        END LOOP;
        function_name := COALESCE(aggregate_item ->> 'function', 'COUNT_STAR');
        IF function_name NOT IN ('COUNT','SUM','MIN','MAX','COUNT_STAR')
           OR (function_name = 'COUNT' AND aggregate_item ->> 'expression' = '*') THEN
            RETURN QUERY SELECT 6, 'PROGRAM_AGGREGATE_FUNCTION_UNSUPPORTED', 'ERROR', item.value ->> 'name',
                'aggregate function is outside the M16 allow-list',
                'Use inherited COUNT(*) or COUNT, SUM, MIN, or MAX over one named column.',
                jsonb_build_object('function', function_name);
            RETURN;
        END IF;
        IF function_name <> 'COUNT_STAR' THEN
            SELECT attnum, atttypid, attcollation INTO value_attribute
            FROM pg_attribute WHERE attrelid = input_oid
              AND attname = (aggregate_item ->> 'expression')::name
              AND attnum > 0 AND NOT attisdropped;
            result_type := pgreact_internal.aggregate_result_type(function_name, value_attribute.atttypid);
            IF NOT FOUND OR result_type IS NULL THEN
                RETURN QUERY SELECT 6, 'PROGRAM_AGGREGATE_TYPE_UNSUPPORTED', 'ERROR', item.value ->> 'name',
                    'aggregate expression type is unsupported',
                    'Use one M16-supported direct column and aggregate function.',
                    jsonb_build_object('expression', aggregate_item -> 'expression');
                RETURN;
            END IF;
        ELSIF (aggregate_item ->> 'threshold')::bigint < 0 THEN
            RETURN QUERY SELECT 6, 'PROGRAM_AGGREGATE_THRESHOLD_INVALID', 'ERROR', item.value ->> 'name',
                'COUNT(*) threshold must be nonnegative', 'Use a nonnegative bigint threshold.', '{}'::jsonb;
            RETURN;
        END IF;
    END LOOP;
    RETURN QUERY SELECT 6, 'PROGRAM_VALID', 'INFO', definition ->> 'name',
        'windowed program is valid', 'Preview and deploy this exact definition.',
        jsonb_build_object('normalized_definition',
                           pgreact_internal.normalized_window_program(definition));
END
$$;

CREATE FUNCTION pgreact_internal.window_plan_digest(definition jsonb)
RETURNS text
LANGUAGE SQL
STABLE
STRICT
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT encode(sha256(convert_to(
        pgreact_internal.normalized_window_program($1)::text || ':' || session_user || ':' ||
        encode(pgreact_internal.source_closure_digest(
            to_regclass($1 #>> '{rules,0,definition}')), 'hex') || ':' ||
        encode(pgreact_internal.source_closure_digest(
            to_regclass($1 #>> '{rules,0,aggregate_input,relation}')), 'hex'), 'UTF8')), 'hex')
$$;

CREATE FUNCTION pgreact_api.preview_program(definition jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE diagnostic record;
BEGIN
    IF NOT pgreact_internal.is_window_program(definition) THEN
        RETURN pgreact_internal.preview_program_m16(definition);
    END IF;
    SELECT * INTO diagnostic FROM pgreact_api.validate_program(definition)
    WHERE severity = 'ERROR' ORDER BY code, object_identity LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'M17_PROGRAM_INVALID: % for %', diagnostic.code, diagnostic.object_identity
            USING HINT = diagnostic.hint;
    END IF;
    RETURN jsonb_build_object(
        'contract_version', 6,
        'program', pgreact_internal.normalized_window_program(definition),
        'plan_digest', pgreact_internal.window_plan_digest(definition));
END
$$;

CREATE FUNCTION pgreact_api.deploy_program(definition jsonb, expected_plan_digest text)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    diagnostic record;
    actual_digest text;
    rewritten jsonb := definition;
    first_rule jsonb := definition #> '{rules,0}';
    window_item jsonb := definition #> '{rules,0,aggregate_input,window}';
    target_spec pgreact_internal.keyed_derived_relations%ROWTYPE;
    old_program pgreact_internal.window_programs%ROWTYPE;
    has_old boolean := false;
    deployed uuid;
    helper_suffix text := md5((definition ->> 'name') || '@' || (definition ->> 'version'));
    helper_input text := format('pgreact_runtime.m17_input_%s', helper_suffix);
    helper_keys text := format('pgreact_runtime.m17_keys_%s', helper_suffix);
    helper_input_store text := format('pgreact_runtime.m17_input_store_%s', helper_suffix);
    helper_keys_store text := format('pgreact_runtime.m17_keys_store_%s', helper_suffix);
    group_columns name[];
    group_list text;
    join_list text;
    window_column name;
    item record;
    rule_version_id uuid;
    function_name text;
    input_name text := first_rule #>> '{aggregate_input,relation}';
    condition_name text := first_rule ->> 'definition';
    input_oid oid;
    condition_oid oid;
    duration_value bigint;
    lateness_value bigint;
BEGIN
    IF NOT pgreact_internal.is_window_program(definition) THEN
        RETURN pgreact_internal.deploy_program_m16(definition, expected_plan_digest);
    END IF;
    SELECT * INTO diagnostic FROM pgreact_api.validate_program(definition)
    WHERE severity = 'ERROR' ORDER BY code, object_identity LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'M17_PROGRAM_INVALID: % for %', diagnostic.code, diagnostic.object_identity
            USING HINT = diagnostic.hint;
    END IF;
    actual_digest := pgreact_internal.window_plan_digest(definition);
    IF expected_plan_digest IS NOT NULL AND expected_plan_digest <> actual_digest THEN
        RAISE EXCEPTION 'M17_PROGRAM_PREVIEW_STALE'
            USING ERRCODE = '55000',
                  HINT = 'Preview the program again after DDL or deployment changes.';
    END IF;
    SELECT spec.* INTO STRICT target_spec
    FROM pgreact_internal.keyed_derived_relations spec
    WHERE spec.public_name = first_rule ->> 'target';
    group_columns := target_spec.key_columns[1:cardinality(target_spec.key_columns)-1];
    window_column := target_spec.key_columns[cardinality(target_spec.key_columns)];
    SELECT string_agg(format('%I', value), ', ' ORDER BY ordinal),
           string_agg(format('%I', value), ', ' ORDER BY ordinal)
    INTO group_list, join_list
    FROM unnest(group_columns) WITH ORDINALITY column_name(value, ordinal);
    input_oid := to_regclass(input_name);
    condition_oid := to_regclass(condition_name);
    duration_value := pgreact_internal.fixed_interval_us(window_item ->> 'duration', false);
    lateness_value := pgreact_internal.fixed_interval_us(
        window_item ->> 'allowed_lateness', true);
    SELECT prior.* INTO old_program
    FROM pgreact_internal.window_programs prior
    WHERE prior.program_name = definition ->> 'name' AND prior.active
    FOR UPDATE;
    has_old := FOUND;

    EXECUTE format('DROP VIEW IF EXISTS %s CASCADE', helper_input);
    EXECUTE format('DROP VIEW IF EXISTS %s CASCADE', helper_keys);
    EXECUTE format('DROP TABLE IF EXISTS %s CASCADE', helper_input_store);
    EXECUTE format('DROP TABLE IF EXISTS %s CASCADE', helper_keys_store);
    EXECUTE format(
        'CREATE TABLE %s AS SELECT source.*, 0::bigint AS %I FROM %s source WITH NO DATA',
        helper_input_store, window_column, input_oid::regclass);
    EXECUTE format(
        'CREATE TABLE %s AS SELECT %s, %I FROM %s WITH NO DATA',
        helper_keys_store, group_list, window_column, helper_input_store);
    EXECUTE format('CREATE VIEW %s AS SELECT * FROM %s', helper_input, helper_input_store);
    EXECUTE format('CREATE VIEW %s AS SELECT * FROM %s', helper_keys, helper_keys_store);
    EXECUTE format('ALTER TABLE %s OWNER TO %I', helper_input_store, session_user);
    EXECUTE format('ALTER TABLE %s OWNER TO %I', helper_keys_store, session_user);
    EXECUTE format('ALTER VIEW %s OWNER TO %I', helper_input, session_user);
    EXECUTE format('ALTER VIEW %s OWNER TO %I', helper_keys, session_user);
    EXECUTE format('ALTER TABLE %s ADD PRIMARY KEY (%s, %I)',
                   helper_keys_store, group_list, window_column);
    IF has_old THEN
        EXECUTE format('INSERT INTO %s SELECT * FROM %s',
                       helper_keys_store, old_program.helper_keys_name);
        EXECUTE format(
            'INSERT INTO %s SELECT source.*, pgreact_internal.window_ordinal(source.%I, $1) '
            'FROM %s source JOIN %s condition USING (%s)',
            helper_input_store, (window_item ->> 'event_time')::name,
            input_oid::regclass, condition_oid::regclass, join_list)
        USING duration_value;
    END IF;

    FOR item IN SELECT value, ordinal FROM jsonb_array_elements(definition -> 'rules')
        WITH ORDINALITY rules(value, ordinal)
    LOOP
        rewritten := jsonb_set(rewritten,
            ARRAY['rules',(item.ordinal - 1)::text,'definition'], to_jsonb(helper_keys));
        rewritten := jsonb_set(rewritten,
            ARRAY['rules',(item.ordinal - 1)::text,'aggregate_input'],
            ((item.value -> 'aggregate_input') - 'window') || jsonb_build_object('relation', helper_input));
    END LOOP;
    deployed := pgreact_internal.deploy_program_m16(rewritten, NULL);
    IF has_old THEN
        UPDATE pgreact_internal.window_programs SET active = false
        WHERE program_version_id = old_program.program_version_id;
    END IF;
    INSERT INTO pgreact_internal.window_programs (
        program_version_id, program_name, program_version, owner_oid, public_definition,
        input_relation_name, condition_relation_name,
        input_definition_digest, input_row_signature,
        condition_definition_digest, condition_row_signature,
        event_time_column, duration_us, allowed_lateness_us, group_columns, window_column,
        helper_input_name, helper_keys_name, helper_input_store_name, helper_keys_store_name,
        max_facts,
        lower_frontier, observed_frontier, requested_watermark, complete_watermark,
        history_floor, last_source_fingerprint, last_observed_fingerprint)
    VALUES (
        deployed, definition ->> 'name', (definition ->> 'version')::integer,
        (SELECT oid FROM pg_roles WHERE rolname = session_user), definition,
        input_name, condition_name,
        pgreact_internal.source_closure_digest(input_oid),
        pgreact_internal.source_row_signature(input_oid),
        pgreact_internal.source_closure_digest(condition_oid),
        pgreact_internal.source_row_signature(condition_oid),
        (window_item ->> 'event_time')::name, duration_value, lateness_value,
        group_columns, window_column, helper_input, helper_keys,
        helper_input_store, helper_keys_store,
        (definition ->> 'max_facts')::bigint,
        CASE WHEN has_old THEN old_program.lower_frontier ELSE 0 END,
        CASE WHEN has_old THEN old_program.observed_frontier ELSE 0 END,
        CASE WHEN has_old THEN old_program.requested_watermark ELSE '-infinity' END,
        CASE WHEN has_old THEN old_program.complete_watermark ELSE '-infinity' END,
        CASE WHEN has_old THEN old_program.history_floor ELSE '-infinity' END,
        CASE WHEN has_old THEN old_program.last_source_fingerprint ELSE sha256(''::bytea) END,
        CASE WHEN has_old THEN old_program.last_observed_fingerprint ELSE sha256(''::bytea) END);

    FOR item IN SELECT value, ordinal FROM jsonb_array_elements(definition -> 'rules')
        WITH ORDINALITY rules(value, ordinal)
    LOOP
        SELECT version.rule_version_id INTO STRICT rule_version_id
        FROM pgreact_internal.rules rule
        JOIN pgreact_internal.rule_versions version USING (rule_id)
        WHERE rule.rule_name = item.value ->> 'name' AND version.state = 'ACTIVE';
        function_name := COALESCE(item.value #>> '{aggregate_input,function}', 'COUNT_STAR');
        INSERT INTO pgreact_internal.window_rules (
            program_version_id, rule_version_id, rule_name, rule_version,
            target_relation, aggregate_function, value_expression, comparison, typed_threshold)
        VALUES (
            deployed, rule_version_id, item.value ->> 'name',
            (item.value ->> 'version')::integer, item.value ->> 'target', function_name,
            (item.value #>> '{aggregate_input,expression}')::name,
            item.value #>> '{aggregate_input,comparison}',
            item.value #>> '{aggregate_input,threshold}');
    END LOOP;
    IF has_old THEN
        INSERT INTO pgreact_internal.window_source_rows
        SELECT deployed, row_data, public_window_key, event_time, window_ordinal, occurrences
        FROM pgreact_internal.window_source_rows
        WHERE program_version_id = old_program.program_version_id;
        INSERT INTO pgreact_internal.window_identities
        SELECT deployed, public_window_key, canonical_window_key, window_ordinal,
               window_start, window_end, lateness_boundary, final
        FROM pgreact_internal.window_identities
        WHERE program_version_id = old_program.program_version_id;
        PERFORM pgreact_internal.seed_window_corrections(deployed);
    END IF;
    INSERT INTO pgreact_internal.window_audits(program_version_id, operation, details)
    VALUES (deployed, 'DEPLOY', jsonb_build_object(
        'program', definition ->> 'name', 'version', (definition ->> 'version')::integer,
        'replacement', has_old));
    RETURN deployed;
END
$$;

CREATE FUNCTION pgreact_internal.begin_window_stage()
RETURNS void
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    CREATE TEMP TABLE IF NOT EXISTS m17_current_rows (
        program_version_id uuid NOT NULL,
        row_data jsonb NOT NULL,
        public_window_key jsonb NOT NULL,
        event_time timestamptz NOT NULL,
        window_ordinal bigint NOT NULL,
        occurrences bigint NOT NULL,
        PRIMARY KEY (program_version_id, row_data, public_window_key, event_time, window_ordinal)
    ) ON COMMIT DELETE ROWS;
    CREATE TEMP TABLE IF NOT EXISTS m17_affected_windows (
        program_version_id uuid NOT NULL,
        public_window_key jsonb NOT NULL,
        window_ordinal bigint NOT NULL,
        canonical_window_key bytea NOT NULL,
        PRIMARY KEY (program_version_id, public_window_key)
    ) ON COMMIT DELETE ROWS;
    TRUNCATE m17_current_rows, m17_affected_windows;
END
$$;

CREATE FUNCTION pgreact_internal.load_window_rows(target_program uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    program pgreact_internal.window_programs%ROWTYPE;
    group_arguments text;
    join_list text;
    sql text;
BEGIN
    SELECT * INTO STRICT program FROM pgreact_internal.window_programs
    WHERE program_version_id = target_program;
    IF program.input_definition_digest IS DISTINCT FROM
           pgreact_internal.source_closure_digest(to_regclass(program.input_relation_name))
       OR program.input_row_signature IS DISTINCT FROM
           pgreact_internal.source_row_signature(to_regclass(program.input_relation_name))
       OR program.condition_definition_digest IS DISTINCT FROM
           pgreact_internal.source_closure_digest(to_regclass(program.condition_relation_name))
       OR program.condition_row_signature IS DISTINCT FROM
           pgreact_internal.source_row_signature(to_regclass(program.condition_relation_name)) THEN
        RAISE EXCEPTION 'M17_SOURCE_DRIFT: timed input or group source changed for %',
            program.program_name USING ERRCODE = '55000',
            HINT = 'Replace the complete program through its public API.';
    END IF;
    DELETE FROM m17_current_rows WHERE program_version_id = target_program;
    SELECT string_agg(format('to_jsonb(current_row.%I)', value), ', ' ORDER BY ordinal),
           string_agg(format('%I', value), ', ' ORDER BY ordinal)
    INTO group_arguments, join_list
    FROM unnest(program.group_columns) WITH ORDINALITY column_name(value, ordinal);
    group_arguments := group_arguments || format(', to_jsonb(current_row.%I)', program.window_column);
    sql := format(
        'INSERT INTO pg_temp.m17_current_rows '
        '(program_version_id,row_data,public_window_key,event_time,window_ordinal,occurrences) '
        'SELECT $1, row_data, public_window_key, event_time, window_ordinal, count(*) '
        'FROM (SELECT to_jsonb(current_row) AS row_data, jsonb_build_array(%s) AS public_window_key, '
        'current_row.%I AS event_time, current_row.%I AS window_ordinal '
        'FROM (SELECT source.*, pgreact_internal.window_ordinal(source.%I, $2) AS %I '
        'FROM %s source JOIN %s condition USING (%s)) current_row) rows '
        'GROUP BY row_data, public_window_key, event_time, window_ordinal',
        group_arguments, program.event_time_column, program.window_column,
        program.event_time_column, program.window_column,
        to_regclass(program.input_relation_name), to_regclass(program.condition_relation_name), join_list);
    EXECUTE sql USING target_program, program.duration_us;
END
$$;

CREATE FUNCTION pgreact_internal.staged_window_fingerprint(target_program uuid)
RETURNS bytea
LANGUAGE SQL
STABLE
STRICT
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT sha256(convert_to(COALESCE(string_agg(
        row_data::text || ':' || public_window_key::text || ':' ||
        event_time::text || ':' || occurrences::text, E'\n'
        ORDER BY public_window_key::text, event_time, row_data::text), ''), 'UTF8'))
    FROM pg_temp.m17_current_rows WHERE program_version_id = $1
$$;

CREATE FUNCTION pgreact_internal.stage_differs(target_program uuid)
RETURNS boolean
LANGUAGE SQL
STABLE
STRICT
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT EXISTS (
        SELECT 1
        FROM pg_temp.m17_current_rows current_row
        FULL JOIN pgreact_internal.window_source_rows previous
          ON previous.program_version_id = $1
         AND current_row.program_version_id = previous.program_version_id
         AND current_row.row_data = previous.row_data
         AND current_row.public_window_key = previous.public_window_key
         AND current_row.event_time = previous.event_time
         AND current_row.window_ordinal = previous.window_ordinal
        WHERE COALESCE(current_row.program_version_id, previous.program_version_id) = $1
          AND current_row.occurrences IS DISTINCT FROM previous.occurrences)
$$;

CREATE FUNCTION pgreact_internal.prepare_window_program(target_program uuid)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    program pgreact_internal.window_programs%ROWTYPE;
    fingerprint bytea;
    affected_count bigint;
    state_count bigint;
    rule_count bigint;
    late record;
    group_list text;
    join_list text;
BEGIN
    SELECT * INTO STRICT program FROM pgreact_internal.window_programs
    WHERE program_version_id = target_program FOR UPDATE;
    PERFORM pgreact_internal.load_window_rows(target_program);
    fingerprint := pgreact_internal.staged_window_fingerprint(target_program);
    IF program.barrier IS NOT NULL THEN
        IF fingerprint IS DISTINCT FROM program.last_observed_fingerprint THEN
            UPDATE pgreact_internal.window_programs
            SET observed_frontier = observed_frontier + 1,
                last_observed_fingerprint = fingerprint
            WHERE program_version_id = target_program;
        END IF;
        RETURN 'barrier';
    END IF;
    IF NOT pgreact_internal.stage_differs(target_program) THEN
        RETURN 'unchanged';
    END IF;
    IF fingerprint IS DISTINCT FROM program.last_observed_fingerprint THEN
        program.observed_frontier := program.observed_frontier + 1;
    END IF;
    WITH changed AS (
        SELECT current_row.public_window_key AS current_key,
               current_row.window_ordinal AS current_ordinal,
               current_row.event_time AS current_time,
               previous.public_window_key AS previous_key,
               previous.window_ordinal AS previous_ordinal,
               previous.event_time AS previous_time
        FROM pg_temp.m17_current_rows current_row
        FULL JOIN pgreact_internal.window_source_rows previous
          ON previous.program_version_id = target_program
         AND current_row.program_version_id = previous.program_version_id
         AND current_row.row_data = previous.row_data
         AND current_row.public_window_key = previous.public_window_key
         AND current_row.event_time = previous.event_time
         AND current_row.window_ordinal = previous.window_ordinal
        WHERE COALESCE(current_row.program_version_id, previous.program_version_id) = target_program
          AND current_row.occurrences IS DISTINCT FROM previous.occurrences
    ), affected AS (
        SELECT current_key AS public_window_key, current_ordinal AS window_ordinal
        FROM changed WHERE current_key IS NOT NULL
        UNION
        SELECT previous_key, previous_ordinal FROM changed WHERE previous_key IS NOT NULL
    )
    INSERT INTO pg_temp.m17_affected_windows
    SELECT target_program, public_window_key, window_ordinal,
           pgreact_internal.window_key_bytes(public_window_key)
    FROM affected ON CONFLICT DO NOTHING;

    SELECT affected.public_window_key, affected.window_ordinal,
           COALESCE(current_row.event_time, previous.event_time) AS event_time,
           pgreact_internal.window_bound(affected.window_ordinal, program.duration_us)
             + ((program.duration_us + program.allowed_lateness_us)::text || ' microseconds')::interval
             AS lateness_boundary
    INTO late
    FROM pg_temp.m17_affected_windows affected
    LEFT JOIN LATERAL (
        SELECT event_time FROM pg_temp.m17_current_rows row_value
        WHERE row_value.program_version_id = target_program
          AND row_value.public_window_key = affected.public_window_key
          AND NOT EXISTS (
              SELECT 1 FROM pgreact_internal.window_source_rows previous_row
              WHERE previous_row.program_version_id = target_program
                AND previous_row.row_data = row_value.row_data
                AND previous_row.public_window_key = row_value.public_window_key
                AND previous_row.event_time = row_value.event_time
                AND previous_row.window_ordinal = row_value.window_ordinal
                AND previous_row.occurrences = row_value.occurrences)
        ORDER BY event_time LIMIT 1) current_row ON true
    LEFT JOIN LATERAL (
        SELECT event_time FROM pgreact_internal.window_source_rows row_value
        WHERE row_value.program_version_id = target_program
          AND row_value.public_window_key = affected.public_window_key
          AND NOT EXISTS (
              SELECT 1 FROM pg_temp.m17_current_rows current_value
              WHERE current_value.program_version_id = target_program
                AND current_value.row_data = row_value.row_data
                AND current_value.public_window_key = row_value.public_window_key
                AND current_value.event_time = row_value.event_time
                AND current_value.window_ordinal = row_value.window_ordinal
                AND current_value.occurrences = row_value.occurrences)
        ORDER BY event_time LIMIT 1) previous ON true
    WHERE affected.program_version_id = target_program
      AND pgreact_internal.window_bound(affected.window_ordinal, program.duration_us)
            + ((program.duration_us + program.allowed_lateness_us)::text || ' microseconds')::interval
          <= program.complete_watermark
    ORDER BY affected.canonical_window_key LIMIT 1;
    IF FOUND THEN
        UPDATE pgreact_internal.window_programs
        SET barrier = 'LATE_INPUT', observed_frontier = program.observed_frontier,
            last_observed_fingerprint = fingerprint
        WHERE program_version_id = target_program;
        INSERT INTO pgreact_internal.window_diagnostics (
            code,severity,object_identity,sqlstate,message,hint,details,program_version_id)
        VALUES (
            'M17_INPUT_FINALIZED','ERROR',
            program.program_name || '/' || program.input_relation_name || '.' || program.event_time_column,
            '55000', 'timed input changed finalized window ' ||
                replace(late.public_window_key::text, ' ', ''),
            'Restore the authoritative input to the finalized aggregate, then reconcile the program.',
            jsonb_build_object(
                'complete_watermark', to_char(program.complete_watermark AT TIME ZONE 'UTC',
                    'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
                'event_time', to_char(late.event_time AT TIME ZONE 'UTC',
                    'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
                'lateness_boundary', to_char(late.lateness_boundary AT TIME ZONE 'UTC',
                    'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
                'lower_frontier', program.observed_frontier,
                'window_key', late.public_window_key), target_program);
        RETURN 'late';
    END IF;
    SELECT count(*) INTO affected_count FROM pg_temp.m17_affected_windows
    WHERE program_version_id = target_program;
    SELECT count(*) INTO rule_count FROM pgreact_internal.window_rules
    WHERE program_version_id = target_program;
    SELECT count(*) INTO state_count FROM (
        SELECT public_window_key FROM pgreact_internal.window_identities
        WHERE program_version_id = target_program
        UNION
        SELECT public_window_key FROM pg_temp.m17_current_rows
        WHERE program_version_id = target_program) states;
    IF state_count * rule_count > program.max_facts
       OR affected_count * rule_count > program.max_facts THEN
        RAISE EXCEPTION 'M17_RESOURCE_LIMIT: window states or corrections require %, max_facts is %',
            greatest(state_count * rule_count, affected_count * rule_count), program.max_facts
            USING ERRCODE = '54000';
    END IF;
    SELECT string_agg(format('%I', value), ', ' ORDER BY ordinal),
           string_agg(format('%I', value), ', ' ORDER BY ordinal)
    INTO group_list, join_list
    FROM unnest(program.group_columns) WITH ORDINALITY column_name(value, ordinal);
    EXECUTE format('TRUNCATE %s', program.helper_input_store_name);
    EXECUTE format(
        'INSERT INTO %s SELECT source.*, pgreact_internal.window_ordinal(source.%I, $1) '
        'FROM %s source JOIN %s condition USING (%s)',
        program.helper_input_store_name, program.event_time_column,
        to_regclass(program.input_relation_name), to_regclass(program.condition_relation_name), join_list)
    USING program.duration_us;
    EXECUTE format(
        'INSERT INTO %s SELECT DISTINCT %s, %I FROM %s ON CONFLICT DO NOTHING',
        program.helper_keys_store_name, group_list, program.window_column,
        program.helper_input_store_name);
    INSERT INTO pgreact_internal.window_identities (
        program_version_id,public_window_key,canonical_window_key,window_ordinal,
        window_start,window_end,lateness_boundary)
    SELECT target_program, affected.public_window_key, affected.canonical_window_key,
           affected.window_ordinal,
           pgreact_internal.window_bound(affected.window_ordinal, program.duration_us),
           pgreact_internal.window_bound(affected.window_ordinal, program.duration_us)
             + (program.duration_us::text || ' microseconds')::interval,
           pgreact_internal.window_bound(affected.window_ordinal, program.duration_us)
             + ((program.duration_us + program.allowed_lateness_us)::text || ' microseconds')::interval
    FROM pg_temp.m17_affected_windows affected
    WHERE affected.program_version_id = target_program
    ON CONFLICT (program_version_id, public_window_key) DO NOTHING;
    UPDATE pgreact_internal.window_programs
    SET observed_frontier = program.observed_frontier,
        last_observed_fingerprint = fingerprint
    WHERE program_version_id = target_program;
    RETURN 'changed';
END
$$;

CREATE FUNCTION pgreact_internal.append_window_corrections(target_program uuid, seed boolean)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    program pgreact_internal.window_programs%ROWTYPE;
    state record;
    previous record;
    old_generation integer;
    next_generation integer;
    inserted_count bigint := 0;
    row_count bigint;
BEGIN
    SELECT * INTO STRICT program FROM pgreact_internal.window_programs
    WHERE program_version_id = target_program;
    FOR state IN
        SELECT rules.rule_version_id, rules.rule_name, rules.rule_version,
               rules.target_relation, identity.public_window_key,
               identity.public_window_key -
                   (jsonb_array_length(identity.public_window_key) - 1) AS public_group_key,
               identity.window_ordinal,
               evidence.canonical_group_key, evidence.exact_value, evidence.truth_result
        FROM pgreact_internal.window_rules rules
        JOIN pgreact_internal.aggregate_dependency_evidence evidence
          ON evidence.program_version_id = rules.program_version_id
         AND evidence.rule_version_id = rules.rule_version_id AND evidence.active
        JOIN pgreact_internal.window_identities identity
          ON identity.program_version_id = rules.program_version_id
         AND identity.public_window_key = evidence.public_group_key
        JOIN pg_temp.m17_affected_windows affected
          ON affected.program_version_id = identity.program_version_id
         AND affected.public_window_key = identity.public_window_key
        WHERE rules.program_version_id = target_program
        ORDER BY
            (identity.public_window_key -
                (jsonb_array_length(identity.public_window_key) - 1))::text,
            identity.window_ordinal,
            rules.rule_name
    LOOP
        UPDATE pgreact_internal.window_identities
        SET canonical_window_key = state.canonical_group_key
        WHERE program_version_id = target_program
          AND public_window_key = state.public_window_key;
        SELECT correction.after_value, correction.after_truth,
               correction.support_generation
        INTO previous
        FROM pgreact_internal.window_corrections correction
        WHERE correction.program_version_id = target_program
          AND correction.rule_name = state.rule_name
          AND correction.public_window_key = state.public_window_key
        ORDER BY correction.lower_frontier DESC, correction.correction_order DESC LIMIT 1;
        old_generation := COALESCE(previous.support_generation, 0);
        IF seed AND NOT FOUND THEN
            SELECT correction.support_generation INTO old_generation
            FROM pgreact_internal.window_corrections correction
            JOIN pgreact_internal.window_programs prior
              ON prior.program_version_id = correction.program_version_id
            WHERE prior.program_name = program.program_name
              AND prior.program_version < program.program_version
              AND correction.rule_name = state.rule_name
              AND correction.public_window_key = state.public_window_key
            ORDER BY prior.program_version DESC, correction.lower_frontier DESC,
                     correction.correction_order DESC LIMIT 1;
            old_generation := COALESCE(old_generation, 0);
        END IF;
        next_generation := CASE
            WHEN state.truth_result IS TRUE AND previous.after_truth IS NOT TRUE AND NOT seed
                THEN old_generation + 1
            WHEN state.truth_result IS TRUE AND seed AND old_generation = 0 THEN 1
            ELSE old_generation
        END;
        INSERT INTO pgreact_internal.window_corrections (
            correction_identity,program_version_id,program_name,program_version,
            rule_version_id,rule_name,rule_version,target_relation,
            public_window_key,public_group_key,window_ordinal,
            canonical_window_key,lower_frontier,
            before_value,after_value,before_truth,after_truth,support_generation)
        VALUES (
            format('%s@%s/%s@%s/%s/F%s', program.program_name, program.program_version,
                   state.rule_name, state.rule_version,
                   replace(state.public_window_key::text, ' ', ''),
                   program.observed_frontier),
            target_program,program.program_name,program.program_version,
            state.rule_version_id,state.rule_name,state.rule_version,state.target_relation,
            state.public_window_key,state.public_group_key,state.window_ordinal,
            state.canonical_group_key,program.observed_frontier,
            CASE WHEN seed THEN NULL ELSE previous.after_value END,state.exact_value,
            CASE WHEN seed THEN NULL ELSE previous.after_truth END,state.truth_result,next_generation)
        ON CONFLICT (correction_identity) DO NOTHING;
        GET DIAGNOSTICS row_count = ROW_COUNT;
        IF row_count = 0 THEN CONTINUE; END IF;
        IF NOT seed AND state.truth_result IS TRUE AND previous.after_truth IS NOT TRUE THEN
            INSERT INTO pgreact_internal.window_lifecycle (
                program_version_id,lower_frontier,public_window_key,canonical_window_key,
                rule_name,event_kind,support_generation)
            VALUES (target_program,program.observed_frontier,state.public_window_key,
                    state.canonical_group_key,state.rule_name,'ACTIVATE',next_generation);
        ELSIF NOT seed AND previous.after_truth IS TRUE AND state.truth_result IS NOT TRUE THEN
            INSERT INTO pgreact_internal.window_lifecycle (
                program_version_id,lower_frontier,public_window_key,canonical_window_key,
                rule_name,event_kind,support_generation)
            VALUES (target_program,program.observed_frontier,state.public_window_key,
                    state.canonical_group_key,state.rule_name,'DEACTIVATE',old_generation);
        END IF;
        inserted_count := inserted_count + row_count;
    END LOOP;
    RETURN inserted_count;
END
$$;

CREATE FUNCTION pgreact_internal.seed_window_corrections(target_program uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    PERFORM pgreact_internal.begin_window_stage();
    INSERT INTO pg_temp.m17_affected_windows
    SELECT program_version_id, public_window_key, window_ordinal, canonical_window_key
    FROM pgreact_internal.window_identities WHERE program_version_id = target_program;
    IF EXISTS (SELECT 1 FROM pg_temp.m17_affected_windows
               WHERE program_version_id = target_program)
       AND (SELECT observed_frontier FROM pgreact_internal.window_programs
            WHERE program_version_id = target_program) > 0 THEN
        PERFORM pgreact_internal.append_window_corrections(target_program, true);
    END IF;
END
$$;

CREATE FUNCTION pgreact_internal.finish_window_program(target_program uuid)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE fingerprint bytea; correction_count bigint;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_temp.m17_affected_windows
                   WHERE program_version_id = target_program) THEN
        RETURN 0;
    END IF;
    correction_count := pgreact_internal.append_window_corrections(target_program, false);
    fingerprint := pgreact_internal.staged_window_fingerprint(target_program);
    DELETE FROM pgreact_internal.window_source_rows WHERE program_version_id = target_program;
    INSERT INTO pgreact_internal.window_source_rows
    SELECT program_version_id,row_data,public_window_key,event_time,window_ordinal,occurrences
    FROM pg_temp.m17_current_rows WHERE program_version_id = target_program;
    UPDATE pgreact_internal.window_programs
    SET lower_frontier = observed_frontier,
        last_source_fingerprint = fingerprint,
        last_observed_fingerprint = fingerprint
    WHERE program_version_id = target_program;
    RETURN correction_count;
END
$$;

CREATE FUNCTION pgreact_internal.advance_window_watermark(target_program uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    program pgreact_internal.window_programs%ROWTYPE;
    boundary timestamptz;
    identity_count bigint;
    batch_limit integer := current_setting('pg_react.batch_size')::integer;
    finalized jsonb;
BEGIN
    SELECT * INTO STRICT program FROM pgreact_internal.window_programs
    WHERE program_version_id = target_program FOR UPDATE;
    IF program.barrier IS NOT NULL OR program.complete_watermark >= program.requested_watermark THEN
        RETURN jsonb_build_object('status', CASE WHEN program.barrier IS NULL THEN 'complete' ELSE 'blocked' END,
                                  'finalized', '[]'::jsonb);
    END IF;
    SELECT min(lateness_boundary) INTO boundary
    FROM pgreact_internal.window_identities
    WHERE program_version_id = target_program AND NOT final
      AND lateness_boundary > program.complete_watermark
      AND lateness_boundary <= program.requested_watermark;
    IF boundary IS NULL THEN
        UPDATE pgreact_internal.window_programs
        SET complete_watermark = requested_watermark
        WHERE program_version_id = target_program;
        RETURN jsonb_build_object('status','complete','finalized','[]'::jsonb);
    END IF;
    SELECT count(*) INTO identity_count FROM pgreact_internal.window_identities
    WHERE program_version_id = target_program AND NOT final AND lateness_boundary = boundary;
    IF identity_count > batch_limit THEN
        INSERT INTO pgreact_internal.window_diagnostics (
            code,severity,object_identity,sqlstate,message,hint,details,program_version_id)
        VALUES ('M17_WATERMARK_BATCH_LIMIT','ERROR',program.program_name,'54000',
            'earliest lateness boundary exceeds pg_react.batch_size',
            'Raise pg_react.batch_size to at least the required minimum and retry.',
            jsonb_build_object('required_minimum',identity_count,'batch_size',batch_limit,
                               'lateness_boundary',boundary),target_program);
        RETURN jsonb_build_object('status','failed','code','M17_WATERMARK_BATCH_LIMIT',
                                  'finalized','[]'::jsonb);
    END IF;
    IF current_setting('pg_react.m17_fail_watermark', true) = 'on' THEN
        INSERT INTO pgreact_internal.window_diagnostics (
            code,severity,object_identity,sqlstate,message,hint,details,program_version_id)
        VALUES ('M17_WATERMARK_BATCH_FAILED','ERROR',program.program_name,'XX000',
            'injected watermark advancement failure',
            'Clear pg_react.m17_fail_watermark and repeat the requested target.',
            jsonb_build_object('complete_watermark',program.complete_watermark,
                               'requested_watermark',program.requested_watermark),target_program);
        RETURN jsonb_build_object('status','failed','code','M17_WATERMARK_BATCH_FAILED',
                                  'finalized','[]'::jsonb);
    END IF;
    WITH finalized_rows AS (
        UPDATE pgreact_internal.window_identities
        SET final = true
        WHERE program_version_id = target_program AND NOT final AND lateness_boundary = boundary
        RETURNING public_window_key,canonical_window_key,lateness_boundary
    ), recorded AS (
        INSERT INTO pgreact_internal.window_finalizations (
            finalization_identity,program_version_id,public_window_key,
            canonical_window_key,lateness_boundary)
        SELECT replace(public_window_key::text, ' ', '') || '@' ||
               to_char(lateness_boundary AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
               target_program,public_window_key,canonical_window_key,lateness_boundary
        FROM finalized_rows ON CONFLICT DO NOTHING
        RETURNING public_window_key,canonical_window_key
    )
    SELECT COALESCE(jsonb_agg(public_window_key ORDER BY canonical_window_key),'[]'::jsonb)
    INTO finalized FROM recorded;
    UPDATE pgreact_internal.window_programs SET complete_watermark = boundary
    WHERE program_version_id = target_program;
    RETURN jsonb_build_object(
        'status',CASE WHEN boundary = program.requested_watermark THEN 'complete' ELSE 'pending' END,
        'finalized',finalized);
END
$$;

ALTER FUNCTION pgreact_api.run(timestamptz) SET SCHEMA pgreact_internal;
ALTER FUNCTION pgreact_internal.run(timestamptz) RENAME TO run_m16;

CREATE FUNCTION pgreact_api.run(sampled_time timestamptz DEFAULT clock_timestamp())
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    result jsonb;
    program record;
    prepare_status text;
    summaries jsonb := '[]'::jsonb;
    advance_result jsonb;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pgreact_internal.window_programs WHERE active) THEN
        RETURN pgreact_internal.run_m16(sampled_time);
    END IF;
    PERFORM pg_advisory_xact_lock(5788046901200000);
    PERFORM pgreact_internal.begin_window_stage();
    FOR program IN SELECT program_version_id,program_name
        FROM pgreact_internal.window_programs WHERE active ORDER BY program_name
    LOOP
        prepare_status := pgreact_internal.prepare_window_program(program.program_version_id);
        summaries := summaries || jsonb_build_array(jsonb_build_object(
            'program',program.program_name,'maintenance',prepare_status));
    END LOOP;
    result := pgreact_internal.run_m16(sampled_time);
    FOR program IN SELECT program_version_id,program_name
        FROM pgreact_internal.window_programs WHERE active AND barrier IS NULL ORDER BY program_name
    LOOP
        PERFORM pgreact_internal.finish_window_program(program.program_version_id);
        advance_result := pgreact_internal.advance_window_watermark(program.program_version_id);
        summaries := summaries || jsonb_build_array(
            jsonb_build_object('program',program.program_name,'watermark',advance_result));
    END LOOP;
    RETURN jsonb_set(result, '{contract_version}', '6'::jsonb)
        || jsonb_build_object('windows',summaries);
END
$$;

CREATE FUNCTION pgreact_api.request_watermark(
    program_name text,
    input_relation text,
    event_time_column name,
    target timestamptz
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE program pgreact_internal.window_programs%ROWTYPE;
BEGIN
    IF NOT pgreact_internal.is_operator_admin() THEN
        RAISE EXCEPTION 'M17_WATERMARK_UNAUTHORIZED: % is not the configured operator', session_user
            USING ERRCODE = '42501';
    END IF;
    IF pg_is_in_recovery() THEN
        RAISE EXCEPTION 'M17_WATERMARK_STANDBY: watermark requests require a writable primary'
            USING ERRCODE = '25006';
    END IF;
    IF target IS NULL OR NOT isfinite(target) THEN
        RAISE EXCEPTION 'M17_WATERMARK_TARGET_INVALID: target must be finite and non-null'
            USING ERRCODE = '22008';
    END IF;
    IF cardinality(parse_ident(input_relation, true)) <> 2 THEN
        RAISE EXCEPTION 'M17_WATERMARK_INPUT_UNQUALIFIED: %', input_relation
            USING ERRCODE = '22023';
    END IF;
    SELECT * INTO program FROM pgreact_internal.window_programs
    WHERE window_programs.program_name = request_watermark.program_name
      AND active FOR UPDATE;
    IF NOT FOUND OR to_regclass(program.input_relation_name) IS DISTINCT FROM to_regclass(input_relation)
       OR program.event_time_column IS DISTINCT FROM request_watermark.event_time_column THEN
        RAISE EXCEPTION 'M17_WATERMARK_INPUT_UNKNOWN: %.%', input_relation, event_time_column
            USING ERRCODE = '22023';
    END IF;
    IF target < program.requested_watermark THEN
        RAISE EXCEPTION 'M17_WATERMARK_BACKWARD: target % precedes requested watermark %',
            target, program.requested_watermark USING ERRCODE = '22023';
    END IF;
    IF target = program.requested_watermark THEN RETURN; END IF;
    UPDATE pgreact_internal.window_programs SET requested_watermark = target
    WHERE program_version_id = program.program_version_id;
    INSERT INTO pgreact_internal.window_audits(program_version_id,operation,details)
    VALUES (program.program_version_id,'REQUEST_WATERMARK',
            jsonb_build_object('previous',program.requested_watermark,'target',target));
END
$$;

CREATE FUNCTION pgreact_api.watermark_status(program_name text)
RETURNS TABLE(
    input_relation text,
    event_time_column name,
    requested_watermark timestamptz,
    complete_watermark timestamptz,
    history_floor timestamptz,
    status text,
    barrier text
)
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT input_relation_name,event_time_column,requested_watermark,complete_watermark,
           history_floor,
           CASE WHEN barrier IS NOT NULL THEN 'blocked'
                WHEN complete_watermark < requested_watermark THEN 'pending' ELSE 'complete' END,
           barrier
    FROM pgreact_internal.window_programs
    WHERE window_programs.program_name = $1 AND active
$$;

CREATE FUNCTION pgreact_api.export_window_state(program_name text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE program pgreact_internal.window_programs%ROWTYPE;
BEGIN
    IF NOT pgreact_internal.is_operator_admin() THEN
        RAISE EXCEPTION 'M17_RECOVERY_UNAUTHORIZED: % is not the configured operator',session_user
            USING ERRCODE='42501';
    END IF;
    SELECT * INTO STRICT program FROM pgreact_internal.window_programs
    WHERE window_programs.program_name=export_window_state.program_name AND active;
    RETURN jsonb_build_object(
        'contract_version',6,
        'program',jsonb_build_object(
            'name',program.program_name,'version',program.program_version,
            'lower_frontier',program.lower_frontier,'observed_frontier',program.observed_frontier,
            'engine_frontier',(SELECT frontier FROM pgreact_internal.derivation_program_versions
                               WHERE program_version_id=program.program_version_id),
            'requested_watermark',program.requested_watermark,
            'complete_watermark',program.complete_watermark,
            'history_floor',program.history_floor,'barrier',program.barrier,
            'source_fingerprint',encode(program.last_source_fingerprint,'hex'),
            'observed_fingerprint',encode(program.last_observed_fingerprint,'hex')),
        'source_rows',COALESCE((SELECT jsonb_agg(jsonb_build_object(
            'row_data',row_data,'public_window_key',public_window_key,
            'event_time',event_time,'window_ordinal',window_ordinal,'occurrences',occurrences)
            ORDER BY public_window_key,event_time,row_data::text)
            FROM pgreact_internal.window_source_rows
            WHERE program_version_id=program.program_version_id),'[]'::jsonb),
        'identities',COALESCE((SELECT jsonb_agg(jsonb_build_object(
            'public_window_key',public_window_key,
            'canonical_window_key',encode(canonical_window_key,'hex'),
            'window_ordinal',window_ordinal,'window_start',window_start,'window_end',window_end,
            'lateness_boundary',lateness_boundary,'final',final)
            ORDER BY window_ordinal,public_window_key)
            FROM pgreact_internal.window_identities
            WHERE program_version_id=program.program_version_id),'[]'::jsonb),
        'evidence',COALESCE((SELECT jsonb_agg(to_jsonb(evidence)
            ORDER BY rule_name,window_ordinal)
            FROM pgreact.window_evidence evidence
            WHERE evidence.program_name=program.program_name),'[]'::jsonb),
        'corrections',COALESCE((SELECT jsonb_agg(jsonb_build_object(
            'correction_order',correction_order,'correction_identity',correction_identity,
            'rule_name',rule_name,'rule_version',rule_version,'target_relation',target_relation,
            'public_window_key',public_window_key,'public_group_key',public_group_key,
            'window_ordinal',window_ordinal,'canonical_window_key',encode(canonical_window_key,'hex'),
            'lower_frontier',lower_frontier,'before_value',before_value,'after_value',after_value,
            'before_truth',before_truth,'after_truth',after_truth,
            'support_generation',support_generation,'created_at',created_at)
            ORDER BY correction_order)
            FROM pgreact_internal.window_corrections
            WHERE program_version_id=program.program_version_id),'[]'::jsonb),
        'finalizations',COALESCE((SELECT jsonb_agg(jsonb_build_object(
            'finalization_identity',finalization_identity,'public_window_key',public_window_key,
            'canonical_window_key',encode(canonical_window_key,'hex'),
            'lateness_boundary',lateness_boundary,'finalized_at',finalized_at)
            ORDER BY lateness_boundary,public_window_key)
            FROM pgreact_internal.window_finalizations
            WHERE program_version_id=program.program_version_id),'[]'::jsonb),
        'lifecycle',COALESCE((SELECT jsonb_agg(jsonb_build_object(
            'lifecycle_order',lifecycle_order,'lower_frontier',lower_frontier,
            'public_window_key',public_window_key,
            'canonical_window_key',encode(canonical_window_key,'hex'),
            'rule_name',rule_name,'event_kind',event_kind,
            'support_generation',support_generation) ORDER BY lifecycle_order)
            FROM pgreact_internal.window_lifecycle
            WHERE program_version_id=program.program_version_id),'[]'::jsonb),
        'diagnostics',COALESCE((SELECT jsonb_agg(jsonb_build_object(
            'diagnostic_order',diagnostic_order,'contract_version',contract_version,'code',code,
            'severity',severity,'object_identity',object_identity,'sqlstate',sqlstate,
            'message',message,'hint',hint,'details',details,'created_at',created_at)
            ORDER BY diagnostic_order)
            FROM pgreact_internal.window_diagnostics
            WHERE program_version_id=program.program_version_id),'[]'::jsonb),
        'audits',COALESCE((SELECT jsonb_agg(jsonb_build_object(
            'audit_order',audit_order,'operation',operation,'actor',actor,
            'details',details,'created_at',created_at) ORDER BY audit_order)
            FROM pgreact_internal.window_audits
            WHERE program_version_id=program.program_version_id),'[]'::jsonb));
END
$$;

CREATE FUNCTION pgreact_api.restore_window_state(recovery_state jsonb)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    program pgreact_internal.window_programs%ROWTYPE;
    item jsonb;
    rule_id uuid;
BEGIN
    IF NOT pgreact_internal.is_operator_admin() THEN
        RAISE EXCEPTION 'M17_RECOVERY_UNAUTHORIZED: % is not the configured operator',session_user
            USING ERRCODE='42501';
    END IF;
    IF recovery_state ->> 'contract_version' <> '6'
       OR jsonb_typeof(recovery_state -> 'program') IS DISTINCT FROM 'object' THEN
        RAISE EXCEPTION 'M17_RECOVERY_STATE_INVALID: expected contract version 6'
            USING ERRCODE='22023';
    END IF;
    SELECT * INTO STRICT program FROM pgreact_internal.window_programs
    WHERE window_programs.program_name=recovery_state #>> '{program,name}' AND active FOR UPDATE;
    IF program.program_version <> (recovery_state #>> '{program,version}')::integer THEN
        RAISE EXCEPTION 'M17_RECOVERY_STATE_INVALID: active program version differs'
            USING ERRCODE='22023';
    END IF;
    PERFORM pg_advisory_xact_lock(5788046901200000);
    DELETE FROM pgreact_internal.window_corrections WHERE program_version_id=program.program_version_id;
    DELETE FROM pgreact_internal.window_finalizations WHERE program_version_id=program.program_version_id;
    DELETE FROM pgreact_internal.window_lifecycle WHERE program_version_id=program.program_version_id;
    DELETE FROM pgreact_internal.window_diagnostics WHERE program_version_id=program.program_version_id;
    DELETE FROM pgreact_internal.window_audits WHERE program_version_id=program.program_version_id;
    DELETE FROM pgreact_internal.window_source_rows WHERE program_version_id=program.program_version_id;
    DELETE FROM pgreact_internal.window_identities WHERE program_version_id=program.program_version_id;
    FOR item IN SELECT value FROM jsonb_array_elements(recovery_state -> 'source_rows') value LOOP
        INSERT INTO pgreact_internal.window_source_rows VALUES (
            program.program_version_id,item -> 'row_data',item -> 'public_window_key',
            (item ->> 'event_time')::timestamptz,(item ->> 'window_ordinal')::bigint,
            (item ->> 'occurrences')::bigint);
    END LOOP;
    FOR item IN SELECT value FROM jsonb_array_elements(recovery_state -> 'identities') value LOOP
        INSERT INTO pgreact_internal.window_identities VALUES (
            program.program_version_id,item -> 'public_window_key',
            decode(item ->> 'canonical_window_key','hex'),(item ->> 'window_ordinal')::bigint,
            (item ->> 'window_start')::timestamptz,(item ->> 'window_end')::timestamptz,
            (item ->> 'lateness_boundary')::timestamptz,(item ->> 'final')::boolean);
    END LOOP;
    FOR item IN SELECT value FROM jsonb_array_elements(recovery_state -> 'corrections') value LOOP
        SELECT rules.rule_version_id INTO STRICT rule_id FROM pgreact_internal.window_rules rules
        WHERE rules.program_version_id=program.program_version_id
          AND rules.rule_name=item ->> 'rule_name';
        INSERT INTO pgreact_internal.window_corrections (
            correction_order,correction_identity,program_version_id,program_name,program_version,
            rule_version_id,rule_name,rule_version,target_relation,public_window_key,
            public_group_key,window_ordinal,canonical_window_key,lower_frontier,
            before_value,after_value,before_truth,after_truth,support_generation,created_at)
        OVERRIDING SYSTEM VALUE VALUES (
            (item ->> 'correction_order')::bigint,item ->> 'correction_identity',
            program.program_version_id,program.program_name,program.program_version,rule_id,
            item ->> 'rule_name',(item ->> 'rule_version')::integer,item ->> 'target_relation',
            item -> 'public_window_key',item -> 'public_group_key',
            (item ->> 'window_ordinal')::bigint,decode(item ->> 'canonical_window_key','hex'),
            (item ->> 'lower_frontier')::bigint,item ->> 'before_value',item ->> 'after_value',
            (item ->> 'before_truth')::boolean,(item ->> 'after_truth')::boolean,
            (item ->> 'support_generation')::integer,(item ->> 'created_at')::timestamptz);
    END LOOP;
    FOR item IN SELECT value FROM jsonb_array_elements(recovery_state -> 'finalizations') value LOOP
        INSERT INTO pgreact_internal.window_finalizations VALUES (
            item ->> 'finalization_identity',program.program_version_id,
            item -> 'public_window_key',decode(item ->> 'canonical_window_key','hex'),
            (item ->> 'lateness_boundary')::timestamptz,(item ->> 'finalized_at')::timestamptz);
    END LOOP;
    FOR item IN SELECT value FROM jsonb_array_elements(recovery_state -> 'lifecycle') value LOOP
        INSERT INTO pgreact_internal.window_lifecycle (
            lifecycle_order,program_version_id,lower_frontier,public_window_key,
            canonical_window_key,rule_name,event_kind,support_generation)
        OVERRIDING SYSTEM VALUE VALUES (
            (item ->> 'lifecycle_order')::bigint,program.program_version_id,
            (item ->> 'lower_frontier')::bigint,item -> 'public_window_key',
            decode(item ->> 'canonical_window_key','hex'),item ->> 'rule_name',
            item ->> 'event_kind',(item ->> 'support_generation')::integer);
    END LOOP;
    FOR item IN SELECT value FROM jsonb_array_elements(recovery_state -> 'diagnostics') value LOOP
        INSERT INTO pgreact_internal.window_diagnostics (
            diagnostic_order,contract_version,code,severity,object_identity,sqlstate,
            message,hint,details,program_version_id,created_at)
        OVERRIDING SYSTEM VALUE VALUES (
            (item ->> 'diagnostic_order')::bigint,(item ->> 'contract_version')::integer,
            item ->> 'code',item ->> 'severity',item ->> 'object_identity',item ->> 'sqlstate',
            item ->> 'message',item ->> 'hint',item -> 'details',program.program_version_id,
            (item ->> 'created_at')::timestamptz);
    END LOOP;
    FOR item IN SELECT value FROM jsonb_array_elements(recovery_state -> 'audits') value LOOP
        INSERT INTO pgreact_internal.window_audits (
            audit_order,program_version_id,operation,actor,details,created_at)
        OVERRIDING SYSTEM VALUE VALUES (
            (item ->> 'audit_order')::bigint,program.program_version_id,item ->> 'operation',
            (item ->> 'actor')::name,item -> 'details',(item ->> 'created_at')::timestamptz);
    END LOOP;
    UPDATE pgreact_internal.window_programs SET
        lower_frontier=(recovery_state #>> '{program,lower_frontier}')::bigint,
        observed_frontier=(recovery_state #>> '{program,observed_frontier}')::bigint,
        requested_watermark=(recovery_state #>> '{program,requested_watermark}')::timestamptz,
        complete_watermark=(recovery_state #>> '{program,complete_watermark}')::timestamptz,
        history_floor=(recovery_state #>> '{program,history_floor}')::timestamptz,
        barrier=(recovery_state #>> '{program,barrier}')::text,
        last_source_fingerprint=decode(recovery_state #>> '{program,source_fingerprint}','hex'),
        last_observed_fingerprint=decode(recovery_state #>> '{program,observed_fingerprint}','hex')
    WHERE program_version_id=program.program_version_id;
    UPDATE pgreact_internal.derivation_program_versions
    SET frontier=(recovery_state #>> '{program,engine_frontier}')::bigint
    WHERE program_version_id=program.program_version_id;
    PERFORM setval(pg_get_serial_sequence('pgreact_internal.window_corrections','correction_order'),
        COALESCE((SELECT max(correction_order) FROM pgreact_internal.window_corrections),1),true);
    PERFORM setval(pg_get_serial_sequence('pgreact_internal.window_lifecycle','lifecycle_order'),
        COALESCE((SELECT max(lifecycle_order) FROM pgreact_internal.window_lifecycle),1),true);
    PERFORM setval(pg_get_serial_sequence('pgreact_internal.window_diagnostics','diagnostic_order'),
        COALESCE((SELECT max(diagnostic_order) FROM pgreact_internal.window_diagnostics),1),true);
    PERFORM setval(pg_get_serial_sequence('pgreact_internal.window_audits','audit_order'),
        COALESCE((SELECT max(audit_order) FROM pgreact_internal.window_audits),1),true);
END
$$;

CREATE VIEW pgreact.window_evidence AS
SELECT
    program.program_name,
    program.program_version,
    rules.rule_name,
    rules.rule_version,
    rules.target_relation,
    identity.public_window_key,
    identity.window_ordinal,
    program.input_relation_name,
    rules.aggregate_function,
    rules.value_expression,
    aggregate_rule.input_type_name,
    aggregate_rule.result_type_name,
    program.event_time_column,
    program.duration_us,
    'UTC_EPOCH'::text AS alignment,
    identity.window_start,
    identity.window_end,
    program.requested_watermark,
    program.complete_watermark,
    identity.lateness_boundary,
    identity.final AS is_final,
    latest.after_value AS exact_value,
    rules.comparison,
    rules.typed_threshold,
    latest.correction_identity AS last_correction_identity,
    latest.lower_frontier AS last_correction_frontier,
    program.lower_frontier AS program_lower_frontier,
    latest.after_truth AS truth_result,
    COALESCE(latest.support_generation,0) AS support_generation
FROM pgreact_internal.window_programs program
JOIN pgreact_internal.window_rules rules USING (program_version_id)
JOIN pgreact_internal.derivation_program_aggregate_inputs aggregate_rule
  ON aggregate_rule.program_version_id = rules.program_version_id
 AND aggregate_rule.rule_version_id = rules.rule_version_id
JOIN pgreact_internal.window_identities identity
  ON identity.program_version_id = rules.program_version_id
JOIN LATERAL (
    SELECT correction_identity,lower_frontier,support_generation,after_value,after_truth
    FROM pgreact_internal.window_corrections correction
    WHERE correction.program_version_id = rules.program_version_id
      AND correction.rule_version_id = rules.rule_version_id
      AND correction.public_window_key = identity.public_window_key
    ORDER BY correction.lower_frontier DESC,correction.correction_order DESC LIMIT 1
) latest ON true
WHERE program.active;

CREATE VIEW pgreact.window_diagnostics AS
SELECT contract_version,code,severity,object_identity,sqlstate,message,hint,details,created_at
FROM pgreact_internal.window_diagnostics
ORDER BY diagnostic_order;

CREATE FUNCTION pgreact_api.window_corrections(
    program_name text,
    result_limit integer,
    after_cursor text DEFAULT NULL
)
RETURNS TABLE(
    correction_identity text,
    program_version integer,
    rule_name text,
    public_window_key jsonb,
    lower_frontier bigint,
    before_value text,
    after_value text,
    before_truth boolean,
    after_truth boolean,
    support_generation integer,
    next_cursor text
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE cursor_row pgreact_internal.window_corrections%ROWTYPE;
BEGIN
    IF result_limit NOT BETWEEN 1 AND 1000 THEN
        RAISE EXCEPTION 'M17_HISTORY_LIMIT: limit must be between 1 and 1000'
            USING ERRCODE = '22023';
    END IF;
    IF after_cursor IS NOT NULL THEN
        SELECT * INTO cursor_row FROM pgreact_internal.window_corrections correction
        WHERE correction.correction_identity = after_cursor
          AND correction.program_name = $1;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'M17_HISTORY_CURSOR: unknown correction cursor'
                USING ERRCODE = '22023';
        END IF;
    END IF;
    RETURN QUERY
    SELECT correction.correction_identity,correction.program_version,correction.rule_name,
           correction.public_window_key,correction.lower_frontier,
           correction.before_value,correction.after_value,
           correction.before_truth,correction.after_truth,correction.support_generation,
           correction.correction_identity
    FROM pgreact_internal.window_corrections correction
    WHERE correction.program_name = window_corrections.program_name
      AND (after_cursor IS NULL OR
           (correction.public_group_key::text,correction.window_ordinal,
            correction.lower_frontier,correction.rule_name,correction.correction_order) >
           (cursor_row.public_group_key::text,cursor_row.window_ordinal,
            cursor_row.lower_frontier,cursor_row.rule_name,cursor_row.correction_order))
    ORDER BY correction.public_group_key::text,correction.window_ordinal,
             correction.lower_frontier,correction.rule_name,correction.correction_order
    LIMIT result_limit;
END
$$;

CREATE FUNCTION pgreact_internal.assert_window_history(target_program uuid)
RETURNS void
LANGUAGE plpgsql
STABLE
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM pgreact_internal.window_identities identity
        LEFT JOIN pgreact_internal.window_finalizations finalization
          USING (program_version_id,public_window_key)
        WHERE identity.program_version_id = target_program AND identity.final
          AND finalization.finalization_identity IS NULL)
       OR EXISTS (
        SELECT 1 FROM pgreact_internal.window_rules rules
        JOIN pgreact_internal.aggregate_dependency_evidence evidence
          ON evidence.program_version_id = rules.program_version_id
         AND evidence.rule_version_id = rules.rule_version_id AND evidence.active
        LEFT JOIN pgreact_internal.window_corrections correction
          ON correction.program_version_id = rules.program_version_id
         AND correction.rule_version_id = rules.rule_version_id
         AND correction.public_window_key = evidence.public_group_key
        WHERE rules.program_version_id = target_program
        GROUP BY rules.rule_version_id,evidence.public_group_key
        HAVING count(correction.correction_identity) = 0) THEN
        RAISE EXCEPTION 'M17_HISTORY_UNRECOVERABLE: correction or finalization identity is missing'
            USING ERRCODE = '55000',
                  HINT = 'Restore the verified physical backup.';
    END IF;
END
$$;

ALTER FUNCTION pgreact_api.reconcile_program(text) SET SCHEMA pgreact_internal;
ALTER FUNCTION pgreact_internal.reconcile_program(text) RENAME TO reconcile_program_m16;

CREATE FUNCTION pgreact_api.reconcile_program(program_name text)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    program pgreact_internal.window_programs%ROWTYPE;
    fingerprint bytea;
    repaired bigint;
BEGIN
    SELECT * INTO program FROM pgreact_internal.window_programs
    WHERE window_programs.program_name = reconcile_program.program_name AND active FOR UPDATE;
    IF NOT FOUND THEN RETURN pgreact_internal.reconcile_program_m16(program_name); END IF;
    IF NOT pgreact_internal.is_operator_admin() THEN
        RAISE EXCEPTION 'M17_RECONCILE_UNAUTHORIZED: % is not the configured operator', session_user
            USING ERRCODE = '42501';
    END IF;
    PERFORM pg_advisory_xact_lock(5788046901200000);
    PERFORM pgreact_internal.assert_window_history(program.program_version_id);
    IF program.barrier IS NULL THEN
        RETURN pgreact_internal.reconcile_program_m16(program_name);
    END IF;
    PERFORM pgreact_internal.begin_window_stage();
    PERFORM pgreact_internal.load_window_rows(program.program_version_id);
    IF pgreact_internal.stage_differs(program.program_version_id) THEN
        RAISE EXCEPTION 'M17_LATE_INPUT_UNRESOLVED: authoritative input still differs from finalized state'
            USING ERRCODE = '55000',
                  HINT = 'Restore the authoritative input, then reconcile again.';
    END IF;
    fingerprint := pgreact_internal.staged_window_fingerprint(program.program_version_id);
    repaired := pgreact_internal.reconcile_program_m16(program_name);
    UPDATE pgreact_internal.window_programs
    SET observed_frontier = observed_frontier +
            CASE WHEN fingerprint IS DISTINCT FROM last_observed_fingerprint THEN 1 ELSE 0 END,
        lower_frontier = observed_frontier +
            CASE WHEN fingerprint IS DISTINCT FROM last_observed_fingerprint THEN 1 ELSE 0 END,
        last_source_fingerprint = fingerprint,
        last_observed_fingerprint = fingerprint,
        barrier = NULL
    WHERE program_version_id = program.program_version_id;
    INSERT INTO pgreact_internal.window_audits(program_version_id,operation,details)
    VALUES (program.program_version_id,'LATE_INPUT_REPAIRED',
            jsonb_build_object('program',program.program_name));
    RETURN repaired;
END
$$;

CREATE FUNCTION pgreact_api.prune_window_history(program_name text, cutoff timestamptz)
RETURNS TABLE(windows bigint, corrections bigint, blocked bigint)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    program pgreact_internal.window_programs%ROWTYPE;
    deleted_count bigint := 0;
    window_count bigint := 0;
BEGIN
    IF NOT pgreact_internal.is_operator_admin() THEN
        RAISE EXCEPTION 'M17_PRUNE_UNAUTHORIZED: % is not the configured operator', session_user
            USING ERRCODE = '42501';
    END IF;
    IF cutoff IS NULL OR NOT isfinite(cutoff) THEN
        RAISE EXCEPTION 'M17_HISTORY_CUTOFF_INVALID: cutoff must be finite'
            USING ERRCODE = '22008';
    END IF;
    SELECT * INTO STRICT program FROM pgreact_internal.window_programs
    WHERE window_programs.program_name = prune_window_history.program_name AND active FOR UPDATE;
    IF cutoff < program.history_floor OR cutoff > program.complete_watermark THEN
        RAISE EXCEPTION 'M17_HISTORY_CUTOFF_INVALID: cutoff is outside the committed recovery horizon'
            USING ERRCODE = '22023';
    END IF;
    IF cutoff = program.history_floor THEN
        RETURN QUERY SELECT 0::bigint,0::bigint,0::bigint;
        RETURN;
    END IF;
    WITH ranked AS (
        SELECT correction.correction_order,correction.public_window_key,
               row_number() OVER (
                   PARTITION BY correction.rule_version_id,correction.public_window_key
                   ORDER BY correction.lower_frontier DESC,correction.correction_order DESC) AS position
        FROM pgreact_internal.window_corrections correction
        JOIN pgreact_internal.window_identities identity
          USING (program_version_id,public_window_key)
        WHERE correction.program_version_id = program.program_version_id
          AND identity.final AND identity.lateness_boundary < cutoff
    ), candidates AS (
        SELECT * FROM ranked WHERE position > 1
    ), deleted AS (
        DELETE FROM pgreact_internal.window_corrections correction
        USING candidates
        WHERE correction.correction_order = candidates.correction_order
        RETURNING candidates.public_window_key)
    SELECT count(*),count(DISTINCT public_window_key) INTO deleted_count,window_count FROM deleted;
    UPDATE pgreact_internal.window_programs SET history_floor = cutoff
    WHERE program_version_id = program.program_version_id;
    INSERT INTO pgreact_internal.window_audits(program_version_id,operation,details)
    VALUES (program.program_version_id,'PRUNE_WINDOW_HISTORY',jsonb_build_object(
        'cutoff',cutoff,'windows',window_count,'corrections',deleted_count,'blocked',0));
    RETURN QUERY SELECT window_count,deleted_count,0::bigint;
END
$$;

ALTER FUNCTION pgreact_api.explain(text,jsonb) SET SCHEMA pgreact_internal;
ALTER FUNCTION pgreact_internal.explain(text,jsonb) RENAME TO explain_m16;

CREATE FUNCTION pgreact_api.explain(target text, semantic_key jsonb)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE evidence_row record; known_target boolean;
BEGIN
    SELECT EXISTS (
        SELECT 1 FROM pgreact_internal.window_rules rules
        JOIN pgreact_internal.window_programs program USING (program_version_id)
        WHERE program.active AND rules.target_relation = target) INTO known_target;
    IF NOT known_target THEN RETURN pgreact_internal.explain_m16(target,semantic_key); END IF;
    SELECT * INTO evidence_row FROM pgreact.window_evidence evidence
    WHERE evidence.target_relation = target AND evidence.public_window_key = semantic_key;
    IF NOT FOUND OR evidence_row.truth_result IS NOT TRUE THEN
        RETURN jsonb_build_object(
            'contract_version',6,
            'target',jsonb_build_object('kind','fact','name',target,'key',semantic_key),
            'evidence',NULL);
    END IF;
    RETURN jsonb_build_object(
        'contract_version',6,
        'target',jsonb_build_object('kind','fact','name',target,'key',semantic_key),
        'support','G' || evidence_row.support_generation,
        'evidence',to_jsonb(evidence_row));
END
$$;

ALTER FUNCTION pgreact_api.remove_program(text,integer) SET SCHEMA pgreact_internal;
ALTER FUNCTION pgreact_internal.remove_program(text,integer) RENAME TO remove_program_m16;

CREATE FUNCTION pgreact_api.remove_program(program_name text, program_version integer)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE target_program uuid;
BEGIN
    SELECT window_programs.program_version_id INTO target_program
    FROM pgreact_internal.window_programs
    WHERE window_programs.program_name = remove_program.program_name
      AND window_programs.program_version = remove_program.program_version AND active FOR UPDATE;
    PERFORM pgreact_internal.remove_program_m16(program_name,program_version);
    IF target_program IS NOT NULL THEN
        UPDATE pgreact_internal.window_programs SET active = false
        WHERE program_version_id = target_program;
        INSERT INTO pgreact_internal.window_audits(program_version_id,operation,details)
        VALUES (target_program,'REMOVE',jsonb_build_object(
            'program',program_name,'version',program_version));
    END IF;
END
$$;

ALTER FUNCTION pgreact_api.doctor() SET SCHEMA pgreact_internal;
ALTER FUNCTION pgreact_internal.doctor() RENAME TO doctor_m16;

CREATE FUNCTION pgreact_api.doctor()
RETURNS jsonb
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
    WITH inherited AS (
        SELECT diagnostic
        FROM jsonb_array_elements(pgreact_internal.doctor_m16() -> 'diagnostics') diagnostic
        WHERE diagnostic ->> 'code' <> 'M16_EXTENSION_VERSION'
    ), diagnostics AS (
        SELECT diagnostic FROM inherited
        UNION ALL
        SELECT jsonb_build_object(
            'code','M17_EXTENSION_VERSION','severity','ERROR','object_identity','pg_react',
            'message','pg_react extension version is not 0.14.0',
            'hint','Install matching files and run ALTER EXTENSION pg_react UPDATE.')
        WHERE NOT EXISTS (SELECT 1 FROM pg_extension
                          WHERE extname = 'pg_react' AND extversion = '0.14.0')
        UNION ALL
        SELECT jsonb_build_object(
            'code','M17_LATE_INPUT_BARRIER','severity','ERROR',
            'object_identity',program_name,
            'message','program is blocked by input beyond a finalized window',
            'hint','Restore the authoritative input and call pgreact_api.reconcile_program.')
        FROM pgreact_internal.window_programs WHERE active AND barrier = 'LATE_INPUT'
    ), ordered AS (
        SELECT diagnostic FROM diagnostics
        ORDER BY CASE diagnostic ->> 'severity' WHEN 'ERROR' THEN 1 WHEN 'WARNING' THEN 2 ELSE 3 END,
                 diagnostic ->> 'code',diagnostic ->> 'object_identity'
    )
    SELECT jsonb_build_object(
        'contract_version',CASE WHEN EXISTS (
            SELECT 1 FROM pgreact_internal.window_programs WHERE active) THEN 6 ELSE 5 END,
        'status',CASE WHEN EXISTS (SELECT 1 FROM ordered
                                  WHERE diagnostic ->> 'severity' = 'ERROR')
                      THEN 'attention' ELSE 'ready' END,
        'diagnostics',COALESCE((SELECT jsonb_agg(diagnostic) FROM ordered),'[]'::jsonb))
$$;

ALTER FUNCTION pgreact_api.configure_roles(regrole,regrole,regrole,regrole,regrole)
SET SCHEMA pgreact_internal;
ALTER FUNCTION pgreact_internal.configure_roles(regrole,regrole,regrole,regrole,regrole)
RENAME TO configure_roles_m16;

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
AS $$
BEGIN
    PERFORM pgreact_internal.configure_roles_m16(
        author_role,operator_role,worker_role,reader_role,advanced_reader_role);
    EXECUTE format(
        'GRANT EXECUTE ON FUNCTION pgreact_api.request_watermark(text,text,name,timestamptz), '
        'pgreact_api.prune_window_history(text,timestamptz), '
        'pgreact_api.export_window_state(text), pgreact_api.restore_window_state(jsonb), '
        'pgreact_api.watermark_status(text) TO %I', operator_role::text);
    EXECUTE format(
        'GRANT EXECUTE ON FUNCTION pgreact_api.watermark_status(text) TO %I', reader_role::text);
    EXECUTE format(
        'GRANT EXECUTE ON FUNCTION pgreact_api.window_corrections(text,integer,text) TO %I, %I',
        operator_role::text,advanced_reader_role::text);
    EXECUTE format('GRANT SELECT ON pgreact.window_evidence,pgreact.window_diagnostics TO %I, %I',
                   operator_role::text,reader_role::text);
END
$$;

REVOKE ALL ON ALL TABLES IN SCHEMA pgreact_internal FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA pgreact_internal FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pgreact_internal.derivation_program_graph(jsonb) TO PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA pgreact_api FROM PUBLIC;
REVOKE ALL ON pgreact.window_evidence,pgreact.window_diagnostics FROM PUBLIC;

DO $$
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
            author_role,operator_role,worker_role,reader_role,advanced_reader_role);
    END IF;
END
$$;

COMMENT ON EXTENSION pg_react IS
    'M17 fixed-duration event-time windows, watermarks, corrections, and finalization';
