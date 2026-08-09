-- M7 maintained derived knowledge. Derivations reuse the existing activation
-- evaluator but maintain supports and facts instead of creating agenda work.

ALTER TABLE pgreact_internal.rule_versions
    ADD COLUMN rule_kind text NOT NULL DEFAULT 'STANDARD'
        CHECK (rule_kind IN ('STANDARD', 'DERIVATION'));

CREATE TABLE pgreact_internal.derived_relations (
    relation_id uuid PRIMARY KEY,
    relation_name text NOT NULL UNIQUE,
    owner_oid oid NOT NULL,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE pgreact_internal.derived_relation_versions (
    relation_version_id uuid PRIMARY KEY,
    relation_id uuid NOT NULL REFERENCES pgreact_internal.derived_relations,
    version integer NOT NULL CHECK (version > 0),
    owner_oid oid NOT NULL,
    row_type_oid oid NOT NULL,
    row_type_name text NOT NULL,
    row_signature bytea NOT NULL,
    key_column name NOT NULL,
    public_view_oid oid,
    public_view_name text NOT NULL,
    state text NOT NULL CHECK (state IN ('ACTIVE', 'REMOVED')),
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    UNIQUE (relation_id, version)
);

CREATE UNIQUE INDEX derived_relation_one_active_version
    ON pgreact_internal.derived_relation_versions (relation_id)
    WHERE state = 'ACTIVE';

CREATE TABLE pgreact_internal.derivation_rule_versions (
    rule_version_id uuid PRIMARY KEY REFERENCES pgreact_internal.rule_versions,
    rule_id uuid NOT NULL REFERENCES pgreact_internal.rules,
    relation_version_id uuid NOT NULL REFERENCES pgreact_internal.derived_relation_versions,
    version integer NOT NULL CHECK (version > 0),
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    UNIQUE (rule_id, version)
);

CREATE TABLE pgreact_internal.derived_frontiers (
    relation_version_id uuid PRIMARY KEY REFERENCES pgreact_internal.derived_relation_versions,
    frontier bigint NOT NULL CHECK (frontier > 0),
    transaction_id xid8 NOT NULL,
    advanced_at timestamptz NOT NULL
);

CREATE TABLE pgreact_internal.derived_supports (
    support_id uuid PRIMARY KEY,
    relation_version_id uuid NOT NULL REFERENCES pgreact_internal.derived_relation_versions,
    rule_version_id uuid NOT NULL REFERENCES pgreact_internal.rule_versions,
    activation_id uuid NOT NULL,
    activation_generation bigint NOT NULL CHECK (activation_generation > 0),
    activation_revision bigint NOT NULL CHECK (activation_revision >= 0),
    semantic_key bigint NOT NULL,
    fact_id uuid NOT NULL,
    fact jsonb NOT NULL,
    source_binding jsonb NOT NULL,
    active boolean NOT NULL,
    first_frontier bigint NOT NULL,
    last_frontier bigint,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    invalidated_at timestamptz,
    UNIQUE (rule_version_id, activation_id, activation_generation, activation_revision)
);

CREATE UNIQUE INDEX derived_support_one_active_activation
    ON pgreact_internal.derived_supports (rule_version_id, activation_id)
    WHERE active;
CREATE INDEX derived_support_active_fact
    ON pgreact_internal.derived_supports (relation_version_id, semantic_key)
    WHERE active;

CREATE TABLE pgreact_internal.derived_facts (
    relation_version_id uuid NOT NULL REFERENCES pgreact_internal.derived_relation_versions,
    fact_id uuid NOT NULL,
    semantic_key bigint NOT NULL,
    fact jsonb NOT NULL,
    support_count bigint NOT NULL CHECK (support_count > 0),
    first_frontier bigint NOT NULL,
    last_frontier bigint NOT NULL,
    first_derived_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    last_changed_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (relation_version_id, fact_id),
    UNIQUE (relation_version_id, semantic_key)
);

CREATE TABLE pgreact_internal.derived_reconciliations (
    reconciliation_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    relation_version_id uuid NOT NULL REFERENCES pgreact_internal.derived_relation_versions,
    started_at timestamptz NOT NULL,
    completed_at timestamptz,
    repairs bigint,
    status text NOT NULL CHECK (status IN ('RUNNING', 'COMPLETED')),
    requested_by name NOT NULL
);

CREATE TABLE pgreact_internal.derived_repair_diagnostics (
    reconciliation_id bigint NOT NULL REFERENCES pgreact_internal.derived_reconciliations,
    diagnostic_order integer NOT NULL CHECK (diagnostic_order > 0),
    code text NOT NULL CHECK (code IN (
        'MISSING_SUPPORT', 'EXTRA_SUPPORT', 'STALE_SUPPORT',
        'MISSING_FACT', 'EXTRA_FACT', 'STALE_FACT'
    )),
    object_identity text NOT NULL,
    details jsonb NOT NULL,
    PRIMARY KEY (reconciliation_id, diagnostic_order)
);

CREATE FUNCTION pgreact_internal.composite_type_signature(target_type oid)
RETURNS bytea
LANGUAGE SQL
STABLE
STRICT
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT sha256(convert_to(string_agg(
        format('%s:%s:%s', a.attname, a.atttypid, a.attnotnull), ',' ORDER BY a.attnum
    ), 'UTF8'))
    FROM pg_catalog.pg_type t
    JOIN pg_catalog.pg_attribute a ON a.attrelid = t.typrelid
    WHERE t.oid = $1 AND t.typtype = 'c' AND a.attnum > 0 AND NOT a.attisdropped
$$;

CREATE FUNCTION pgreact_internal.source_reads_derived(source_oid oid)
RETURNS boolean
LANGUAGE SQL
STABLE
STRICT
SET search_path = pg_catalog, pg_temp
AS $$
    WITH RECURSIVE dependencies(relid) AS (
        SELECT $1
        UNION
        SELECT d.refobjid
        FROM dependencies parent
        JOIN pg_catalog.pg_rewrite rw ON rw.ev_class = parent.relid
        JOIN pg_catalog.pg_depend d
          ON d.classid = 'pg_rewrite'::regclass AND d.objid = rw.oid
         AND d.refclassid = 'pg_class'::regclass
        JOIN pg_catalog.pg_class c ON c.oid = d.refobjid
        WHERE c.relkind IN ('v', 'm')
    )
    SELECT EXISTS (
        SELECT 1
        FROM dependencies d
        JOIN pgreact_internal.derived_relation_versions v
          ON v.public_view_oid = d.relid AND v.state = 'ACTIVE'
    )
$$;

CREATE FUNCTION pgreact_internal.assert_derived_owner(target_relation_version uuid)
RETURNS pgreact_internal.derived_relation_versions
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE relation_row pgreact_internal.derived_relation_versions%ROWTYPE;
BEGIN
    SELECT * INTO STRICT relation_row
    FROM pgreact_internal.derived_relation_versions
    WHERE relation_version_id = target_relation_version;
    IF relation_row.owner_oid <> (SELECT oid FROM pg_catalog.pg_roles WHERE rolname = session_user)
       AND NOT pgreact_internal.is_operator_admin() THEN
        RAISE EXCEPTION 'only the derived-relation owner or pgreact_admin may manage %',
            relation_row.public_view_name;
    END IF;
    RETURN relation_row;
END
$$;

CREATE FUNCTION pgreact.validate_derived_relation(
    name text,
    row_type regtype,
    key_columns name[],
    relation_version integer DEFAULT 1
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
AS $$
DECLARE
    parts text[] := pg_catalog.parse_ident(name, true);
    caller_oid oid := (SELECT oid FROM pg_catalog.pg_roles WHERE rolname = session_user);
    type_row record;
    schema_oid oid;
BEGIN
    IF cardinality(parts) <> 2 THEN
        RETURN QUERY SELECT 2, 'RELATION_NAME_INVALID', 'ERROR', name,
            'derived relation names must be schema-qualified',
            'Use schema.relation.', '{}'::jsonb;
        RETURN;
    END IF;
    schema_oid := pg_catalog.to_regnamespace(parts[1]);
    IF schema_oid IS NULL OR NOT pg_catalog.has_schema_privilege(session_user, schema_oid, 'CREATE') THEN
        RETURN QUERY SELECT 2, 'RELATION_SCHEMA_UNSAFE', 'ERROR', name,
            'the relation owner must have CREATE on the target schema',
            'Choose an owned schema or grant CREATE explicitly.', '{}'::jsonb;
        RETURN;
    END IF;
    SELECT t.typowner, t.typtype, t.typrelid,
           format('%I.%I', n.nspname, t.typname) AS identity
    INTO type_row
    FROM pg_catalog.pg_type t
    JOIN pg_catalog.pg_namespace n ON n.oid = t.typnamespace
    WHERE t.oid = row_type;
    IF type_row.typtype IS DISTINCT FROM 'c' OR type_row.typowner IS DISTINCT FROM caller_oid THEN
        RETURN QUERY SELECT 2, 'ROW_TYPE_UNSAFE', 'ERROR', row_type::text,
            'the declared row type must be a caller-owned PostgreSQL composite type',
            'Create and own one composite type for the derived fact shape.', '{}'::jsonb;
        RETURN;
    END IF;
    IF cardinality(key_columns) IS DISTINCT FROM 1 THEN
        RETURN QUERY SELECT 2, 'KEY_CODEC_UNSUPPORTED', 'ERROR', name,
            'M7 supports exactly one semantic key column',
            'Use one non-null bigint key column.', '{}'::jsonb;
        RETURN;
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM pg_catalog.pg_attribute
        WHERE attrelid = type_row.typrelid AND attname = key_columns[1]
          AND atttypid = 'bigint'::regtype AND attnum > 0 AND NOT attisdropped
    ) THEN
        RETURN QUERY SELECT 2, 'KEY_NOT_BIGINT', 'ERROR', name,
            'M7 semantic keys must use bigint codec v1',
            'Declare one bigint key attribute in the row type.',
            jsonb_build_object('key_column', key_columns[1]);
        RETURN;
    END IF;
    IF relation_version < 1 THEN
        RETURN QUERY SELECT 2, 'RELATION_VERSION_INVALID', 'ERROR', name,
            'relation versions are positive integers',
            'Start at version 1 and increment immutably.', '{}'::jsonb;
        RETURN;
    END IF;
    IF pg_catalog.to_regclass(format('%I.%I', parts[1], parts[2])) IS NOT NULL THEN
        RETURN QUERY SELECT 2, 'RELATION_NAME_EXISTS', 'ERROR', name,
            'the public derived relation name already exists',
            'Choose an unused qualified relation name.', '{}'::jsonb;
        RETURN;
    END IF;
    IF EXISTS (
        SELECT 1 FROM pgreact_internal.derived_relations r
        JOIN pgreact_internal.derived_relation_versions v USING (relation_id)
        WHERE r.relation_name = format('%I.%I', parts[1], parts[2])
          AND v.version = relation_version
    ) THEN
        RETURN QUERY SELECT 2, 'RELATION_VERSION_EXISTS', 'ERROR', name,
            'that immutable derived relation version already exists',
            'Use the active version or increment the version.', '{}'::jsonb;
        RETURN;
    END IF;
    RETURN QUERY SELECT 2, 'OK', 'INFO', format('%I.%I', parts[1], parts[2]),
        'derived relation can be created',
        'Create derivation rules whose source views project this complete row type.',
        jsonb_build_object('row_type', type_row.identity, 'key_codec', 'bigint-v1',
                           'version', relation_version);
END
$$;

CREATE FUNCTION pgreact.create_derived_relation(
    name text,
    row_type regtype,
    key_columns name[],
    relation_version integer DEFAULT 1
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    diagnostic record;
    parts text[] := pg_catalog.parse_ident(name, true);
    relation_id uuid := gen_random_uuid();
    version_id uuid := gen_random_uuid();
    caller_oid oid := (SELECT oid FROM pg_catalog.pg_roles WHERE rolname = session_user);
    type_name text;
    qualified_name text;
    view_oid oid;
BEGIN
    SELECT * INTO diagnostic
    FROM pgreact.validate_derived_relation(name, row_type, key_columns, relation_version)
    WHERE severity = 'ERROR' ORDER BY code LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'pg-react derived relation validation % for %: %',
            diagnostic.code, diagnostic.object_identity, diagnostic.message
            USING HINT = diagnostic.hint;
    END IF;
    qualified_name := format('%I.%I', parts[1], parts[2]);
    SELECT format('%I.%I', n.nspname, t.typname) INTO STRICT type_name
    FROM pg_catalog.pg_type t
    JOIN pg_catalog.pg_namespace n ON n.oid = t.typnamespace
    WHERE t.oid = row_type;
    INSERT INTO pgreact_internal.derived_relations
        (relation_id, relation_name, owner_oid)
    VALUES (relation_id, qualified_name, caller_oid);
    INSERT INTO pgreact_internal.derived_relation_versions (
        relation_version_id, relation_id, version, owner_oid, row_type_oid,
        row_type_name, row_signature, key_column, public_view_name, state
    ) VALUES (
        version_id, relation_id, relation_version, caller_oid, row_type,
        type_name, pgreact_internal.composite_type_signature(row_type),
        key_columns[1], qualified_name, 'ACTIVE'
    );
    EXECUTE format(
        'CREATE VIEW %s WITH (security_barrier=true) AS '
        'SELECT (pg_catalog.jsonb_populate_record(NULL::%s, f.fact)).* '
        'FROM pgreact_internal.derived_facts f WHERE f.relation_version_id = %L::uuid',
        qualified_name, type_name, version_id
    );
    view_oid := pg_catalog.to_regclass(qualified_name);
    UPDATE pgreact_internal.derived_relation_versions
    SET public_view_oid = view_oid WHERE relation_version_id = version_id;
    EXECUTE format('REVOKE ALL ON %s FROM PUBLIC', qualified_name);
    EXECUTE format('GRANT SELECT ON %s TO %I', qualified_name, session_user);
    RETURN version_id;
END
$$;

CREATE FUNCTION pgreact.validate_derivation_rule(
    definition regclass,
    target_relation uuid,
    key_columns name[],
    rule_version integer DEFAULT 1
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
AS $$
DECLARE
    relation_row pgreact_internal.derived_relation_versions%ROWTYPE;
    source_row record;
    target_attribute record;
    diagnostic record;
BEGIN
    SELECT * INTO relation_row
    FROM pgreact_internal.derived_relation_versions
    WHERE relation_version_id = target_relation AND state = 'ACTIVE';
    IF NOT FOUND THEN
        RETURN QUERY SELECT 2, 'TARGET_RELATION_INACTIVE', 'ERROR', target_relation::text,
            'the target derived relation version is not active',
            'Use one active caller-owned derived relation version.', '{}'::jsonb;
        RETURN;
    END IF;
    IF relation_row.owner_oid <> (SELECT oid FROM pg_catalog.pg_roles WHERE rolname = session_user) THEN
        RETURN QUERY SELECT 2, 'TARGET_RELATION_NOT_OWNED', 'ERROR', relation_row.public_view_name,
            'the derivation owner must own its target relation',
            'Create the derivation as the relation owner.', '{}'::jsonb;
        RETURN;
    END IF;
    SELECT * INTO diagnostic FROM pgreact.validate_rule(definition, key_columns, NULL) AS d
    WHERE d.severity = 'ERROR' ORDER BY d.code LIMIT 1;
    IF FOUND THEN
        RETURN QUERY SELECT 2, diagnostic.code, diagnostic.severity,
            diagnostic.object_identity, diagnostic.message, diagnostic.hint, diagnostic.details;
        RETURN;
    END IF;
    IF pgreact_internal.source_reads_derived(definition) THEN
        RETURN QUERY SELECT 2, 'DERIVATION_CHAIN_UNSUPPORTED', 'ERROR', definition::text,
            'derivation source views may not read derived relations',
            'Read only supported authoritative PostgreSQL relations.', '{}'::jsonb;
        RETURN;
    END IF;
    IF key_columns[1] IS DISTINCT FROM relation_row.key_column THEN
        RETURN QUERY SELECT 2, 'DERIVATION_KEY_MISMATCH', 'ERROR', definition::text,
            'the derivation key must match the target relation semantic key',
            'Project the target key under its declared name.',
            jsonb_build_object('expected', relation_row.key_column, 'received', key_columns[1]);
        RETURN;
    END IF;
    SELECT c.reltype INTO STRICT source_row
    FROM pg_catalog.pg_class c WHERE c.oid = definition;
    FOR target_attribute IN
        SELECT a.attname, a.atttypid
        FROM pg_catalog.pg_type t
        JOIN pg_catalog.pg_attribute a ON a.attrelid = t.typrelid
        WHERE t.oid = relation_row.row_type_oid AND a.attnum > 0 AND NOT a.attisdropped
        ORDER BY a.attnum
    LOOP
        IF NOT EXISTS (
            SELECT 1 FROM pg_catalog.pg_attribute a
            WHERE a.attrelid = definition AND a.attname = target_attribute.attname
              AND a.atttypid = target_attribute.atttypid
              AND a.attnum > 0 AND NOT a.attisdropped
        ) THEN
            RETURN QUERY SELECT 2, 'DERIVATION_FACT_SHAPE', 'ERROR', definition::text,
                'the derivation source does not project the complete target row type',
                'Project every target attribute with its exact PostgreSQL type.',
                jsonb_build_object('missing_or_mismatched_column', target_attribute.attname);
            RETURN;
        END IF;
    END LOOP;
    IF rule_version < 1 THEN
        RETURN QUERY SELECT 2, 'DERIVATION_VERSION_INVALID', 'ERROR', definition::text,
            'derivation rule versions are positive integers',
            'Start at version 1 and increment immutably.', '{}'::jsonb;
        RETURN;
    END IF;
    RETURN QUERY SELECT 2, 'OK', 'INFO', definition::text,
        'derivation rule can contribute one support per active match',
        'Create the immutable derivation rule version.',
        jsonb_build_object('target', relation_row.public_view_name,
                           'version', rule_version, 'agenda', false);
END
$$;

CREATE FUNCTION pgreact_internal.advance_derived_frontier(target_relation uuid)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE result bigint;
BEGIN
    INSERT INTO pgreact_internal.derived_frontiers (
        relation_version_id, frontier, transaction_id, advanced_at
    ) VALUES (
        target_relation, 1, pg_catalog.pg_current_xact_id(), clock_timestamp()
    )
    ON CONFLICT (relation_version_id) DO UPDATE SET
        frontier = CASE
            WHEN pgreact_internal.derived_frontiers.transaction_id = EXCLUDED.transaction_id
                THEN pgreact_internal.derived_frontiers.frontier
            ELSE pgreact_internal.derived_frontiers.frontier + 1
        END,
        transaction_id = EXCLUDED.transaction_id,
        advanced_at = CASE
            WHEN pgreact_internal.derived_frontiers.transaction_id = EXCLUDED.transaction_id
                THEN pgreact_internal.derived_frontiers.advanced_at
            ELSE EXCLUDED.advanced_at
        END
    RETURNING frontier INTO result;
    RETURN result;
END
$$;

CREATE FUNCTION pgreact_internal.project_derived_fact(target_relation uuid, binding jsonb)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE relation_row pgreact_internal.derived_relation_versions%ROWTYPE; result jsonb;
BEGIN
    SELECT * INTO STRICT relation_row
    FROM pgreact_internal.derived_relation_versions
    WHERE relation_version_id = target_relation;
    IF pgreact_internal.composite_type_signature(relation_row.row_type_oid)
       IS DISTINCT FROM relation_row.row_signature THEN
        RAISE EXCEPTION 'derived row type drift for %', relation_row.public_view_name;
    END IF;
    EXECUTE format(
        'SELECT to_jsonb(pg_catalog.jsonb_populate_record(NULL::%s, $1))',
        relation_row.row_type_name
    ) INTO result USING binding;
    IF result ->> relation_row.key_column IS NULL THEN
        RAISE EXCEPTION 'derived fact key %.% must be non-null',
            relation_row.public_view_name, relation_row.key_column;
    END IF;
    RETURN result;
END
$$;

CREATE FUNCTION pgreact_internal.recompute_derived_fact(
    target_relation uuid,
    target_key bigint,
    frontier_value bigint
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    support_total bigint;
    distinct_facts bigint;
    current_fact jsonb;
    canonical bytea := pgreact_internal.canonical_bigint_v1(target_key);
    target_fact_id uuid := pgreact_internal.activation_uuid(
        pgreact_internal.activation_digest(target_relation, canonical));
BEGIN
    SELECT count(*), count(DISTINCT fact::text), min(fact::text)::jsonb
    INTO support_total, distinct_facts, current_fact
    FROM pgreact_internal.derived_supports
    WHERE relation_version_id = target_relation
      AND semantic_key = target_key AND active;
    IF distinct_facts > 1 THEN
        RAISE EXCEPTION 'conflicting derived payloads for relation % key %',
            target_relation, target_key;
    ELSIF support_total = 0 THEN
        DELETE FROM pgreact_internal.derived_facts
        WHERE relation_version_id = target_relation AND semantic_key = target_key;
    ELSE
        INSERT INTO pgreact_internal.derived_facts (
            relation_version_id, fact_id, semantic_key, fact, support_count,
            first_frontier, last_frontier
        ) VALUES (
            target_relation, target_fact_id, target_key, current_fact, support_total,
            frontier_value, frontier_value
        )
        ON CONFLICT (relation_version_id, fact_id) DO UPDATE SET
            fact = EXCLUDED.fact,
            support_count = EXCLUDED.support_count,
            last_frontier = EXCLUDED.last_frontier,
            last_changed_at = clock_timestamp();
    END IF;
END
$$;

CREATE FUNCTION pgreact_internal.maintain_derived_support(
    target_rule_version uuid,
    target_activation uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    derivation pgreact_internal.derivation_rule_versions%ROWTYPE;
    activation pgreact_internal.activation_state%ROWTYPE;
    old_support record;
    projected jsonb;
    canonical bytea;
    target_fact_id uuid;
    target_support_id uuid;
    frontier_value bigint;
    clean_binding jsonb;
BEGIN
    SELECT d.* INTO derivation
    FROM pgreact_internal.derivation_rule_versions d
    JOIN pgreact_internal.rule_versions v USING (rule_version_id)
    WHERE d.rule_version_id = target_rule_version AND v.rule_kind = 'DERIVATION';
    IF NOT FOUND THEN RETURN; END IF;
    SELECT * INTO activation
    FROM pgreact_internal.activation_state
    WHERE rule_version_id = target_rule_version AND activation_id = target_activation;
    IF NOT FOUND THEN RETURN; END IF;
    IF activation.active THEN
        clean_binding := activation.current_bindings - '__pgt_row_id';
        projected := pgreact_internal.project_derived_fact(
            derivation.relation_version_id, clean_binding);
        canonical := pgreact_internal.canonical_bigint_v1(activation.semantic_key);
        target_fact_id := pgreact_internal.activation_uuid(
            pgreact_internal.activation_digest(derivation.relation_version_id, canonical));
        target_support_id := pgreact_internal.activation_uuid(sha256(convert_to(
            target_rule_version::text || ':' || target_activation::text || ':' ||
            activation.generation || ':' || activation.revision || ':' || target_fact_id::text,
            'UTF8')));
        IF EXISTS (
            SELECT 1 FROM pgreact_internal.derived_supports s
            WHERE s.relation_version_id = derivation.relation_version_id
              AND s.semantic_key = activation.semantic_key AND s.active
              AND s.support_id <> target_support_id AND s.fact IS DISTINCT FROM projected
        ) THEN
            RAISE EXCEPTION 'conflicting derived payloads for % key %',
                derivation.relation_version_id, activation.semantic_key;
        END IF;
    END IF;
    IF EXISTS (
        SELECT 1 FROM pgreact_internal.derived_supports s
        WHERE s.rule_version_id = target_rule_version
          AND s.activation_id = target_activation AND s.active
          AND (NOT activation.active OR s.support_id <> target_support_id)
    ) OR (activation.active AND NOT EXISTS (
        SELECT 1 FROM pgreact_internal.derived_supports s
        WHERE s.support_id = target_support_id AND s.active
          AND s.source_binding = clean_binding AND s.fact = projected
    )) THEN
        frontier_value := pgreact_internal.advance_derived_frontier(derivation.relation_version_id);
    ELSE
        RETURN;
    END IF;
    FOR old_support IN
        UPDATE pgreact_internal.derived_supports
        SET active = false, last_frontier = frontier_value,
            invalidated_at = clock_timestamp()
        WHERE rule_version_id = target_rule_version
          AND activation_id = target_activation AND active
          AND (NOT activation.active OR support_id <> target_support_id)
        RETURNING relation_version_id, semantic_key
    LOOP
        PERFORM pgreact_internal.recompute_derived_fact(
            old_support.relation_version_id, old_support.semantic_key, frontier_value);
    END LOOP;
    IF activation.active THEN
        INSERT INTO pgreact_internal.derived_supports (
            support_id, relation_version_id, rule_version_id, activation_id,
            activation_generation, activation_revision, semantic_key, fact_id,
            fact, source_binding, active, first_frontier
        ) VALUES (
            target_support_id, derivation.relation_version_id, target_rule_version,
            target_activation, activation.generation, activation.revision,
            activation.semantic_key, target_fact_id, projected,
            clean_binding, true, frontier_value
        )
        ON CONFLICT (support_id) DO UPDATE SET
            fact = EXCLUDED.fact, source_binding = EXCLUDED.source_binding,
            active = true, last_frontier = NULL, invalidated_at = NULL;
        PERFORM pgreact_internal.recompute_derived_fact(
            derivation.relation_version_id, activation.semantic_key, frontier_value);
    END IF;
END
$$;

CREATE FUNCTION pgreact_internal.capture_derived_activation()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    IF TG_OP = 'UPDATE'
       AND (NEW.active, NEW.generation, NEW.revision, NEW.current_bindings)
           IS NOT DISTINCT FROM
           (OLD.active, OLD.generation, OLD.revision, OLD.current_bindings) THEN
        RETURN NEW;
    END IF;
    PERFORM pgreact_internal.maintain_derived_support(
        NEW.rule_version_id, NEW.activation_id);
    RETURN NEW;
END
$$;

CREATE TRIGGER pgreact_maintain_derived_support
AFTER INSERT OR UPDATE OF active, generation, revision, current_bindings
ON pgreact_internal.activation_state
FOR EACH ROW EXECUTE FUNCTION pgreact_internal.capture_derived_activation();

CREATE FUNCTION pgreact.create_derivation_rule(
    name text,
    definition regclass,
    key_columns name[],
    target_relation uuid,
    rule_version integer DEFAULT 1,
    bootstrap_policy text DEFAULT 'SEED_CURRENT'
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    diagnostic record;
    version_id uuid;
    watched name[];
    active_activation record;
BEGIN
    SELECT * INTO diagnostic
    FROM pgreact.validate_derivation_rule(
        definition, target_relation, key_columns, rule_version)
    WHERE severity = 'ERROR' ORDER BY code LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'pg-react derivation validation % for %: %',
            diagnostic.code, diagnostic.object_identity, diagnostic.message
            USING HINT = diagnostic.hint;
    END IF;
    IF EXISTS (
        SELECT 1 FROM pgreact_internal.rules r
        JOIN pgreact_internal.rule_versions v USING (rule_id)
        WHERE r.rule_name = name AND v.state <> 'REMOVED'
    ) THEN
        RAISE EXCEPTION 'a non-removed rule named % already exists', name;
    END IF;
    version_id := pgreact_internal.register_reference_rule(
        name, definition, key_columns[1], NULL, bootstrap_policy);
    SELECT array_agg(a.attname ORDER BY a.attnum) INTO watched
    FROM pg_catalog.pg_attribute a
    WHERE a.attrelid = definition AND a.attnum > 0 AND NOT a.attisdropped
      AND a.attname <> key_columns[1];
    UPDATE pgreact_internal.rule_versions
    SET rule_kind = 'DERIVATION', change_columns = watched
    WHERE rule_version_id = version_id;
    INSERT INTO pgreact_internal.derivation_rule_versions (
        rule_version_id, rule_id, relation_version_id, version
    ) SELECT version_id, rule_id, target_relation, rule_version
    FROM pgreact_internal.rule_versions WHERE rule_version_id = version_id;
    FOR active_activation IN
        SELECT activation_id FROM pgreact_internal.activation_state
        WHERE rule_version_id = version_id AND active
    LOOP
        PERFORM pgreact_internal.maintain_derived_support(
            version_id, active_activation.activation_id);
    END LOOP;
    RETURN version_id;
END
$$;

CREATE FUNCTION pgreact.refresh_derived_relation(target_relation uuid)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE producer record; producers bigint := 0;
BEGIN
    PERFORM pgreact_internal.assert_derived_owner(target_relation);
    -- ponytail: reuse the lifecycle-wide lock; split by relation only if measured contention requires it.
    PERFORM pg_catalog.pg_advisory_xact_lock(5788046901200000);
    FOR producer IN
        SELECT v.rule_version_id
        FROM pgreact_internal.derivation_rule_versions d
        JOIN pgreact_internal.rule_versions v USING (rule_version_id)
        JOIN pgreact_internal.rules r ON r.rule_id = d.rule_id
        WHERE d.relation_version_id = target_relation AND v.state = 'ACTIVE'
        ORDER BY r.rule_name, d.version
    LOOP
        PERFORM pgreact_internal.refresh_rule(producer.rule_version_id);
        producers := producers + 1;
    END LOOP;
    RETURN producers;
END
$$;

CREATE FUNCTION pgreact_internal.retire_derivation_rule(target_version_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE version_row pgreact_internal.rule_versions%ROWTYPE; activation record;
BEGIN
    SELECT * INTO STRICT version_row
    FROM pgreact_internal.rule_versions WHERE rule_version_id = target_version_id;
    IF version_row.rule_kind <> 'DERIVATION' THEN
        RAISE EXCEPTION 'rule version % is not a derivation', target_version_id;
    END IF;
    FOR activation IN
        SELECT activation_id FROM pgreact_internal.activation_state
        WHERE rule_version_id = target_version_id AND active
    LOOP
        UPDATE pgreact_internal.activation_state
        SET active = false, current_bindings = NULL,
            deactivated_at = clock_timestamp(), last_seen_at = clock_timestamp()
        WHERE rule_version_id = target_version_id
          AND activation_id = activation.activation_id;
    END LOOP;
    PERFORM pgtrickle.drop_stream_table(version_row.match_name, true);
    UPDATE pgreact_internal.rule_versions
    SET state = 'REMOVED', match_relid = NULL
    WHERE rule_version_id = target_version_id;
END
$$;

CREATE FUNCTION pgreact.remove_derivation_rule(target_version_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE derivation pgreact_internal.derivation_rule_versions%ROWTYPE;
BEGIN
    PERFORM pgreact_internal.assert_rule_owner(target_version_id);
    SELECT * INTO STRICT derivation
    FROM pgreact_internal.derivation_rule_versions
    WHERE rule_version_id = target_version_id;
    PERFORM pg_catalog.pg_advisory_xact_lock(5788046901200000);
    PERFORM pgreact_internal.retire_derivation_rule(target_version_id);
END
$$;

CREATE FUNCTION pgreact.replace_derivation_rule(
    target_version_id uuid,
    definition regclass,
    key_columns name[],
    rule_version integer,
    bootstrap_policy text DEFAULT 'SEED_CURRENT'
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    prior pgreact_internal.rule_versions%ROWTYPE;
    derivation pgreact_internal.derivation_rule_versions%ROWTYPE;
    next_version uuid;
    orphan_rule uuid;
    rule_name text;
BEGIN
    prior := pgreact_internal.assert_rule_owner(target_version_id);
    SELECT * INTO STRICT derivation
    FROM pgreact_internal.derivation_rule_versions
    WHERE rule_version_id = target_version_id;
    IF prior.state NOT IN ('ACTIVE', 'PAUSED') THEN
        RAISE EXCEPTION 'only active or paused derivations can be replaced';
    END IF;
    SELECT r.rule_name INTO STRICT rule_name
    FROM pgreact_internal.rules r WHERE r.rule_id = prior.rule_id;
    PERFORM pg_catalog.pg_advisory_xact_lock(5788046901200000);
    UPDATE pgreact_internal.rule_versions SET state = 'REMOVED'
    WHERE rule_version_id = target_version_id;
    next_version := pgreact.create_derivation_rule(
        rule_name, definition, key_columns, derivation.relation_version_id,
        rule_version, bootstrap_policy);
    SELECT rule_id INTO STRICT orphan_rule
    FROM pgreact_internal.rule_versions WHERE rule_version_id = next_version;
    UPDATE pgreact_internal.rule_versions SET rule_id = prior.rule_id
    WHERE rule_version_id = next_version;
    UPDATE pgreact_internal.derivation_rule_versions SET rule_id = prior.rule_id
    WHERE rule_version_id = next_version;
    DELETE FROM pgreact_internal.rules WHERE rule_id = orphan_rule;
    PERFORM pgreact_internal.retire_derivation_rule(target_version_id);
    RETURN next_version;
END
$$;

CREATE VIEW pgreact.derived_relations AS
SELECT r.relation_id, r.relation_name, v.relation_version_id,
       v.version AS relation_version, pg_get_userbyid(v.owner_oid) AS owner,
       v.row_type_name AS row_type, v.key_column, v.public_view_name,
       v.state, v.created_at
FROM pgreact_internal.derived_relations r
JOIN pgreact_internal.derived_relation_versions v USING (relation_id);

CREATE VIEW pgreact.derived_facts AS
SELECT f.relation_version_id, r.relation_name, v.version AS relation_version,
       f.fact_id, f.semantic_key, f.fact, f.support_count,
       f.first_frontier, f.last_frontier, f.first_derived_at, f.last_changed_at
FROM pgreact_internal.derived_facts f
JOIN pgreact_internal.derived_relation_versions v USING (relation_version_id)
JOIN pgreact_internal.derived_relations r USING (relation_id);

CREATE VIEW pgreact.support_history AS
SELECT s.support_id, s.relation_version_id, dr.relation_name,
       dv.version AS relation_version, r.rule_name,
       d.version AS rule_version, s.rule_version_id, s.activation_id,
       s.activation_generation, s.activation_revision, s.semantic_key,
       s.fact, s.source_binding, s.active, s.first_frontier,
       s.last_frontier, s.created_at, s.invalidated_at
FROM pgreact_internal.derived_supports s
JOIN pgreact_internal.derived_relation_versions dv USING (relation_version_id)
JOIN pgreact_internal.derived_relations dr USING (relation_id)
JOIN pgreact_internal.derivation_rule_versions d USING (rule_version_id)
JOIN pgreact_internal.rules r ON r.rule_id = d.rule_id;

CREATE VIEW pgreact.derived_repair_diagnostics AS
SELECT d.reconciliation_id, r.relation_version_id, dr.relation_name,
       rv.version AS relation_version, d.diagnostic_order, d.code,
       d.object_identity, d.details, r.started_at, r.completed_at
FROM pgreact_internal.derived_repair_diagnostics d
JOIN pgreact_internal.derived_reconciliations r USING (reconciliation_id)
JOIN pgreact_internal.derived_relation_versions rv USING (relation_version_id)
JOIN pgreact_internal.derived_relations dr USING (relation_id);

CREATE FUNCTION pgreact.current_facts(target_relation uuid, target_key bigint DEFAULT NULL)
RETURNS SETOF pgreact.derived_facts
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    PERFORM pgreact_internal.assert_derived_owner(target_relation);
    RETURN QUERY SELECT * FROM pgreact.derived_facts f
    WHERE f.relation_version_id = target_relation
      AND (target_key IS NULL OR f.semantic_key = target_key)
    ORDER BY f.semantic_key;
END
$$;

CREATE FUNCTION pgreact.explain_fact(target_relation uuid, target_key bigint)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE result jsonb;
BEGIN
    PERFORM pgreact_internal.assert_derived_owner(target_relation);
    SELECT jsonb_build_object(
        'relation', f.relation_name || '@' || f.relation_version,
        'fact', f.fact,
        'active_supports', (
            SELECT jsonb_agg(jsonb_build_object(
                'rule', s.rule_name || '@' || s.rule_version,
                'activation_generation', s.activation_generation,
                'source_binding', s.source_binding
            ) ORDER BY s.rule_name, s.rule_version, s.activation_generation,
                       s.activation_revision)
            FROM pgreact.support_history s
            WHERE s.relation_version_id = target_relation
              AND s.semantic_key = target_key AND s.active
        )
    ) INTO result
    FROM pgreact.derived_facts f
    WHERE f.relation_version_id = target_relation
      AND f.semantic_key = target_key;
    RETURN result;
END
$$;

CREATE FUNCTION pgreact.reconcile_derived_relation(target_relation uuid)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    relation_row pgreact_internal.derived_relation_versions%ROWTYPE;
    run_id bigint;
    diagnostic_order integer := 0;
    expected record;
    actual record;
    projected jsonb;
    canonical bytea;
    expected_fact_id uuid;
    expected_support_id uuid;
    frontier_value bigint;
    support_total bigint;
    expected_fact jsonb;
BEGIN
    relation_row := pgreact_internal.assert_derived_owner(target_relation);
    PERFORM pg_catalog.pg_advisory_xact_lock(5788046901200000);
    SELECT frontier INTO frontier_value
    FROM pgreact_internal.derived_frontiers
    WHERE relation_version_id = target_relation;
    frontier_value := COALESCE(frontier_value, 1);
    INSERT INTO pgreact_internal.derived_reconciliations (
        relation_version_id, started_at, status, requested_by
    ) VALUES (target_relation, clock_timestamp(), 'RUNNING', session_user)
    RETURNING reconciliation_id INTO run_id;

    FOR actual IN
        SELECT s.*
        FROM pgreact_internal.derived_supports s
        LEFT JOIN pgreact_internal.activation_state a
          ON a.rule_version_id = s.rule_version_id
         AND a.activation_id = s.activation_id
         AND a.active
         AND a.generation = s.activation_generation
         AND a.revision = s.activation_revision
         AND a.current_bindings - '__pgt_row_id' = s.source_binding
        LEFT JOIN pgreact_internal.rule_versions v
          ON v.rule_version_id = s.rule_version_id AND v.state = 'ACTIVE'
        WHERE s.relation_version_id = target_relation AND s.active
          AND (a.activation_id IS NULL OR v.rule_version_id IS NULL)
        ORDER BY s.support_id
    LOOP
        diagnostic_order := diagnostic_order + 1;
        INSERT INTO pgreact_internal.derived_repair_diagnostics VALUES (
            run_id, diagnostic_order,
            CASE WHEN EXISTS (
                SELECT 1 FROM pgreact_internal.activation_state a
                WHERE a.rule_version_id = actual.rule_version_id
                  AND a.activation_id = actual.activation_id
            ) THEN 'STALE_SUPPORT' ELSE 'EXTRA_SUPPORT' END,
            actual.support_id::text,
            jsonb_build_object('rule_version_id', actual.rule_version_id,
                               'activation_id', actual.activation_id)
        );
        UPDATE pgreact_internal.derived_supports
        SET active = false, last_frontier = COALESCE(last_frontier, frontier_value),
            invalidated_at = COALESCE(invalidated_at, clock_timestamp())
        WHERE support_id = actual.support_id;
    END LOOP;

    FOR expected IN
        SELECT d.rule_version_id, a.activation_id, a.generation, a.revision,
               a.semantic_key, a.current_bindings
        FROM pgreact_internal.derivation_rule_versions d
        JOIN pgreact_internal.rule_versions v USING (rule_version_id)
        JOIN pgreact_internal.activation_state a USING (rule_version_id)
        WHERE d.relation_version_id = target_relation
          AND v.state = 'ACTIVE' AND a.active
        ORDER BY d.rule_version_id, a.activation_id
    LOOP
        projected := pgreact_internal.project_derived_fact(
            target_relation, expected.current_bindings - '__pgt_row_id');
        canonical := pgreact_internal.canonical_bigint_v1(expected.semantic_key);
        expected_fact_id := pgreact_internal.activation_uuid(
            pgreact_internal.activation_digest(target_relation, canonical));
        expected_support_id := pgreact_internal.activation_uuid(sha256(convert_to(
            expected.rule_version_id::text || ':' || expected.activation_id::text || ':' ||
            expected.generation || ':' || expected.revision || ':' || expected_fact_id::text,
            'UTF8')));
        SELECT * INTO actual FROM pgreact_internal.derived_supports
        WHERE support_id = expected_support_id;
        IF NOT FOUND THEN
            diagnostic_order := diagnostic_order + 1;
            INSERT INTO pgreact_internal.derived_repair_diagnostics VALUES (
                run_id, diagnostic_order, 'MISSING_SUPPORT', expected_support_id::text,
                jsonb_build_object('rule_version_id', expected.rule_version_id,
                                   'activation_id', expected.activation_id)
            );
            INSERT INTO pgreact_internal.derived_supports (
                support_id, relation_version_id, rule_version_id, activation_id,
                activation_generation, activation_revision, semantic_key, fact_id,
                fact, source_binding, active, first_frontier
            ) VALUES (
                expected_support_id, target_relation, expected.rule_version_id,
                expected.activation_id, expected.generation, expected.revision,
                expected.semantic_key, expected_fact_id, projected,
                expected.current_bindings - '__pgt_row_id', true, frontier_value
            );
        ELSIF NOT actual.active OR actual.fact IS DISTINCT FROM projected
              OR actual.source_binding IS DISTINCT FROM expected.current_bindings - '__pgt_row_id'
              OR actual.semantic_key IS DISTINCT FROM expected.semantic_key THEN
            diagnostic_order := diagnostic_order + 1;
            INSERT INTO pgreact_internal.derived_repair_diagnostics VALUES (
                run_id, diagnostic_order, 'STALE_SUPPORT', expected_support_id::text,
                jsonb_build_object('rule_version_id', expected.rule_version_id,
                                   'activation_id', expected.activation_id)
            );
            UPDATE pgreact_internal.derived_supports SET
                semantic_key = expected.semantic_key, fact_id = expected_fact_id,
                fact = projected, source_binding = expected.current_bindings - '__pgt_row_id',
                active = true, last_frontier = NULL, invalidated_at = NULL
            WHERE support_id = expected_support_id;
        END IF;
    END LOOP;

    FOR actual IN
        SELECT f.* FROM pgreact_internal.derived_facts f
        WHERE f.relation_version_id = target_relation ORDER BY f.semantic_key
    LOOP
        SELECT count(*), min(s.fact::text)::jsonb
        INTO support_total, expected_fact
        FROM pgreact_internal.derived_supports s
        WHERE s.relation_version_id = target_relation
          AND s.semantic_key = actual.semantic_key AND s.active;
        IF support_total = 0 THEN
            diagnostic_order := diagnostic_order + 1;
            INSERT INTO pgreact_internal.derived_repair_diagnostics VALUES (
                run_id, diagnostic_order, 'EXTRA_FACT', actual.fact_id::text,
                jsonb_build_object('semantic_key', actual.semantic_key)
            );
            DELETE FROM pgreact_internal.derived_facts
            WHERE relation_version_id = target_relation AND fact_id = actual.fact_id;
        ELSIF actual.support_count IS DISTINCT FROM support_total
              OR actual.fact IS DISTINCT FROM expected_fact THEN
            diagnostic_order := diagnostic_order + 1;
            INSERT INTO pgreact_internal.derived_repair_diagnostics VALUES (
                run_id, diagnostic_order, 'STALE_FACT', actual.fact_id::text,
                jsonb_build_object('semantic_key', actual.semantic_key,
                                   'support_count', support_total)
            );
            UPDATE pgreact_internal.derived_facts SET
                fact = expected_fact, support_count = support_total,
                last_changed_at = clock_timestamp()
            WHERE relation_version_id = target_relation AND fact_id = actual.fact_id;
        END IF;
    END LOOP;

    FOR expected IN
        SELECT s.semantic_key, min(s.fact::text)::jsonb AS fact, count(*) AS support_count
        FROM pgreact_internal.derived_supports s
        WHERE s.relation_version_id = target_relation AND s.active
        GROUP BY s.semantic_key
        HAVING NOT EXISTS (
            SELECT 1 FROM pgreact_internal.derived_facts f
            WHERE f.relation_version_id = target_relation
              AND f.semantic_key = s.semantic_key
        )
        ORDER BY s.semantic_key
    LOOP
        canonical := pgreact_internal.canonical_bigint_v1(expected.semantic_key);
        expected_fact_id := pgreact_internal.activation_uuid(
            pgreact_internal.activation_digest(target_relation, canonical));
        diagnostic_order := diagnostic_order + 1;
        INSERT INTO pgreact_internal.derived_repair_diagnostics VALUES (
            run_id, diagnostic_order, 'MISSING_FACT', expected_fact_id::text,
            jsonb_build_object('semantic_key', expected.semantic_key,
                               'support_count', expected.support_count)
        );
        INSERT INTO pgreact_internal.derived_facts (
            relation_version_id, fact_id, semantic_key, fact, support_count,
            first_frontier, last_frontier
        ) VALUES (
            target_relation, expected_fact_id, expected.semantic_key, expected.fact,
            expected.support_count, frontier_value, frontier_value
        );
    END LOOP;

    UPDATE pgreact_internal.derived_reconciliations
    SET completed_at = clock_timestamp(), repairs = diagnostic_order,
        status = 'COMPLETED'
    WHERE reconciliation_id = run_id;
    RETURN diagnostic_order;
END
$$;

CREATE FUNCTION pgreact_internal.replace_derived_relation(
    target_relation uuid,
    row_type regtype,
    key_columns name[],
    relation_version integer
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    prior pgreact_internal.derived_relation_versions%ROWTYPE;
    next_version uuid := gen_random_uuid();
    type_row record;
BEGIN
    prior := pgreact_internal.assert_derived_owner(target_relation);
    IF prior.state <> 'ACTIVE' THEN
        RAISE EXCEPTION 'only an active derived relation can be replaced';
    END IF;
    SELECT t.typowner, format('%I.%I', n.nspname, t.typname) AS identity
    INTO STRICT type_row
    FROM pg_catalog.pg_type t
    JOIN pg_catalog.pg_namespace n ON n.oid = t.typnamespace
    WHERE t.oid = row_type AND t.typtype = 'c';
    IF type_row.typowner <> prior.owner_oid
       OR cardinality(key_columns) IS DISTINCT FROM 1
       OR key_columns[1] IS DISTINCT FROM prior.key_column
       OR pgreact_internal.composite_type_signature(row_type) IS DISTINCT FROM prior.row_signature THEN
        RAISE EXCEPTION 'M7 derived relation replacement must preserve the exact row type and key';
    END IF;
    IF relation_version <= prior.version THEN
        RAISE EXCEPTION 'derived relation replacement version must increase beyond %', prior.version;
    END IF;
    UPDATE pgreact_internal.derived_relation_versions SET state = 'REMOVED'
    WHERE relation_version_id = target_relation;
    INSERT INTO pgreact_internal.derived_relation_versions (
        relation_version_id, relation_id, version, owner_oid, row_type_oid,
        row_type_name, row_signature, key_column, public_view_oid,
        public_view_name, state
    ) VALUES (
        next_version, prior.relation_id, relation_version, prior.owner_oid,
        row_type, type_row.identity, prior.row_signature, prior.key_column,
        prior.public_view_oid, prior.public_view_name, 'ACTIVE'
    );
    EXECUTE format(
        'CREATE OR REPLACE VIEW %s WITH (security_barrier=true) AS '
        'SELECT (pg_catalog.jsonb_populate_record(NULL::%s, f.fact)).* '
        'FROM pgreact_internal.derived_facts f WHERE f.relation_version_id = %L::uuid',
        prior.public_view_name, type_row.identity, next_version
    );
    RETURN next_version;
END
$$;

CREATE FUNCTION pgreact_internal.remove_derived_relation(target_relation uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE relation_row pgreact_internal.derived_relation_versions%ROWTYPE;
BEGIN
    relation_row := pgreact_internal.assert_derived_owner(target_relation);
    IF EXISTS (
        SELECT 1 FROM pgreact_internal.derivation_rule_versions d
        JOIN pgreact_internal.rule_versions v USING (rule_version_id)
        WHERE d.relation_version_id = target_relation AND v.state <> 'REMOVED'
    ) THEN
        RAISE EXCEPTION 'cannot remove derived relation % with active producers',
            relation_row.public_view_name;
    END IF;
    IF EXISTS (
        SELECT 1 FROM pgreact_internal.rule_versions v
        WHERE v.rule_kind = 'STANDARD' AND v.state <> 'REMOVED'
          AND EXISTS (
              WITH RECURSIVE dependencies(relid) AS (
                  SELECT v.source_view_oid
                  UNION
                  SELECT d.refobjid
                  FROM dependencies parent
                  JOIN pg_catalog.pg_rewrite rw ON rw.ev_class = parent.relid
                  JOIN pg_catalog.pg_depend d
                    ON d.classid = 'pg_rewrite'::regclass AND d.objid = rw.oid
                   AND d.refclassid = 'pg_class'::regclass
                  JOIN pg_catalog.pg_class c ON c.oid = d.refobjid
                  WHERE c.relkind IN ('v', 'm')
              )
              SELECT 1 FROM dependencies WHERE relid = relation_row.public_view_oid
          )
    ) THEN
        RAISE EXCEPTION 'cannot remove derived relation % with active consumers',
            relation_row.public_view_name;
    END IF;
    IF EXISTS (
        SELECT 1 FROM pgreact_internal.derived_facts
        WHERE relation_version_id = target_relation
    ) THEN
        RAISE EXCEPTION 'cannot remove derived relation % while current facts remain',
            relation_row.public_view_name;
    END IF;
    EXECUTE format(
        'CREATE OR REPLACE VIEW %s WITH (security_barrier=true) AS '
        'SELECT (pg_catalog.jsonb_populate_record(NULL::%s, f.fact)).* '
        'FROM pgreact_internal.derived_facts f '
        'WHERE f.relation_version_id = %L::uuid AND false',
        relation_row.public_view_name, relation_row.row_type_name, target_relation
    );
    UPDATE pgreact_internal.derived_relation_versions
    SET state = 'REMOVED'
    WHERE relation_version_id = target_relation;
END
$$;

CREATE FUNCTION pgreact.remove_derived_relation(target_relation uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    PERFORM pg_catalog.pg_advisory_xact_lock(5788046901200000);
    PERFORM pg_catalog.pg_advisory_xact_lock(5788046901200001);
    PERFORM pgreact_internal.remove_derived_relation(target_relation);
END
$$;

CREATE TABLE pgreact_internal.rule_pack_derived_relations (
    pack_version_id uuid NOT NULL REFERENCES pgreact_internal.rule_pack_versions,
    relation_name text NOT NULL,
    relation_version_id uuid NOT NULL REFERENCES pgreact_internal.derived_relation_versions,
    PRIMARY KEY (pack_version_id, relation_name)
);

CREATE TABLE pgreact_internal.rule_pack_derivations (
    pack_version_id uuid NOT NULL REFERENCES pgreact_internal.rule_pack_versions,
    rule_name text NOT NULL,
    rule_version_id uuid NOT NULL REFERENCES pgreact_internal.rule_versions,
    target_relation text NOT NULL,
    dependencies text[] NOT NULL,
    PRIMARY KEY (pack_version_id, rule_name)
);

CREATE TABLE pgreact_internal.rule_pack_derived_actions (
    pack_version_id uuid NOT NULL REFERENCES pgreact_internal.rule_pack_versions,
    action_order integer NOT NULL CHECK (action_order > 0),
    object_kind text NOT NULL CHECK (object_kind IN ('DERIVED_RELATION', 'DERIVATION')),
    action text NOT NULL CHECK (action IN ('ADD', 'KEEP', 'REPLACE', 'REMOVE')),
    object_name text NOT NULL,
    old_version_id uuid,
    new_version_id uuid,
    details jsonb NOT NULL,
    PRIMARY KEY (pack_version_id, action_order)
);

ALTER FUNCTION pgreact.validate_pack(jsonb, jsonb) RENAME TO validate_pack_v1;
ALTER FUNCTION pgreact.preview_pack(jsonb, jsonb) RENAME TO preview_pack_v1;
ALTER FUNCTION pgreact.deploy_pack(jsonb, text, jsonb) RENAME TO deploy_pack_v1;
ALTER FUNCTION pgreact.explain_pack(text) RENAME TO explain_pack_v1;
ALTER FUNCTION pgreact.validate_pack_v1(jsonb, jsonb) SET SCHEMA pgreact_internal;
ALTER FUNCTION pgreact.preview_pack_v1(jsonb, jsonb) SET SCHEMA pgreact_internal;
ALTER FUNCTION pgreact.deploy_pack_v1(jsonb, text, jsonb) SET SCHEMA pgreact_internal;
ALTER FUNCTION pgreact.explain_pack_v1(text) SET SCHEMA pgreact_internal;

CREATE FUNCTION pgreact_internal.m7_pack_definition(definition jsonb)
RETURNS jsonb
LANGUAGE SQL
IMMUTABLE
STRICT
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT jsonb_set(
        $1 - 'derived_relations' - 'derivations'
           - 'remove_derivations' - 'remove_derived_relations',
        '{rules}',
        COALESCE((
            SELECT jsonb_agg(jsonb_set(
                rule_item,
                '{depends_on}',
                COALESCE((
                    SELECT jsonb_agg(dependency ORDER BY dependency #>> '{}')
                    FROM jsonb_array_elements(COALESCE(rule_item -> 'depends_on', '[]'::jsonb)) dependency
                    WHERE EXISTS (
                        SELECT 1 FROM jsonb_array_elements($1 -> 'rules') ordinary
                        WHERE ordinary ->> 'name' = dependency #>> '{}'
                    )
                ), '[]'::jsonb)
            ) ORDER BY ordinal)
            FROM jsonb_array_elements($1 -> 'rules') WITH ORDINALITY r(rule_item, ordinal)
        ), '[]'::jsonb),
        true
    )
$$;

CREATE FUNCTION pgreact_internal.m7_pack_plan_digest(definition jsonb, mappings jsonb)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    material text;
    item record;
    mapped_identity text;
    object_oid oid;
    state_material text;
BEGIN
    material := definition::text || E'\n' || mappings::text || E'\nowner:' || session_user ||
        E'\nv1:' || pgreact_internal.pack_plan_digest(
            pgreact_internal.m7_pack_definition(definition), mappings);
    FOR item IN
        SELECT value, ordinal
        FROM jsonb_array_elements(definition -> 'derived_relations')
        WITH ORDINALITY r(value, ordinal)
    LOOP
        mapped_identity := pgreact_internal.pack_mapping(
            mappings, 'objects', item.value ->> 'name');
        SELECT concat_ws(':', v.relation_version_id, v.version, v.state,
                         encode(v.row_signature, 'hex'), v.key_column, v.public_view_oid)
        INTO state_material
        FROM pgreact_internal.derived_relations r
        JOIN pgreact_internal.derived_relation_versions v USING (relation_id)
        WHERE r.relation_name = mapped_identity AND v.state = 'ACTIVE';
        object_oid := to_regtype(pgreact_internal.pack_mapping(
            mappings, 'objects', item.value ->> 'row_type'))::oid;
        material := material || format(E'\nrelation:%s:%s:%s:%s', item.ordinal,
            mapped_identity, object_oid,
            COALESCE(state_material, '<add>'));
    END LOOP;
    FOR item IN
        SELECT value, ordinal
        FROM jsonb_array_elements(definition -> 'derivations')
        WITH ORDINALITY r(value, ordinal)
    LOOP
        mapped_identity := pgreact_internal.pack_mapping(
            mappings, 'objects', item.value ->> 'definition');
        object_oid := to_regclass(mapped_identity);
        SELECT concat_ws(':', v.rule_version_id, d.version, v.state, v.match_name,
                         d.relation_version_id,
                         encode(v.source_definition_digest, 'hex'),
                         (SELECT count(*) FROM pgreact_internal.derived_supports s
                          WHERE s.rule_version_id = v.rule_version_id AND s.active))
        INTO state_material
        FROM pgreact_internal.rules r
        JOIN pgreact_internal.rule_versions v USING (rule_id)
        JOIN pgreact_internal.derivation_rule_versions d USING (rule_version_id)
        WHERE r.rule_name = item.value ->> 'name' AND v.state <> 'REMOVED'
        ORDER BY v.created_at DESC LIMIT 1;
        material := material || format(E'\nderivation:%s:%s:%s:%s:%s', item.ordinal,
            item.value ->> 'name', object_oid,
            CASE WHEN object_oid IS NULL THEN '<missing>'
                 ELSE encode(sha256(convert_to(pg_get_viewdef(object_oid, true), 'UTF8')), 'hex') END,
            COALESCE(state_material, '<add>'));
    END LOOP;
    RETURN encode(sha256(convert_to(material, 'UTF8')), 'hex');
END
$$;

CREATE FUNCTION pgreact.validate_pack(definition jsonb, mappings jsonb DEFAULT '{}'::jsonb)
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
AS $$
#variable_conflict use_variable
DECLARE
    diagnostic record;
    unknown_key text;
    duplicate_name text;
    item record;
    relation_item jsonb;
    mapped_name text;
    mapped_type text;
    mapped_source text;
    row_type_oid oid;
    source_oid oid;
    active_relation record;
    active_rule record;
    target_item jsonb;
    target_type_oid oid;
    target_key name;
    attribute record;
    dependency text;
    prior_pack uuid;
    has_error boolean := false;
BEGIN
    IF NOT (definition ? 'derived_relations' OR definition ? 'derivations'
            OR definition ? 'remove_derivations' OR definition ? 'remove_derived_relations') THEN
        RETURN QUERY SELECT * FROM pgreact_internal.validate_pack_v1(definition, mappings);
        RETURN;
    END IF;
    SELECT key INTO unknown_key FROM jsonb_object_keys(definition) key
    WHERE key <> ALL (ARRAY[
        'format_version', 'pack', 'version', 'owner', 'rules', 'remove',
        'derived_relations', 'derivations', 'remove_derivations',
        'remove_derived_relations'
    ]) ORDER BY key LIMIT 1;
    IF unknown_key IS NOT NULL THEN
        RETURN QUERY SELECT 2, 'PACK_FIELD_UNKNOWN', 'ERROR', unknown_key,
            'pack definition contains an unknown field',
            'Remove the field or use a newer format.', '{}'::jsonb;
        RETURN;
    END IF;
    IF definition -> 'format_version' IS DISTINCT FROM '1'::jsonb
       OR pg_catalog.jsonb_typeof(definition -> 'derived_relations') IS DISTINCT FROM 'array'
       OR pg_catalog.jsonb_typeof(definition -> 'derivations') IS DISTINCT FROM 'array'
       OR pg_catalog.jsonb_typeof(definition -> 'remove_derivations') IS DISTINCT FROM 'array'
       OR pg_catalog.jsonb_typeof(definition -> 'remove_derived_relations') IS DISTINCT FROM 'array' THEN
        RETURN QUERY SELECT 2, 'PACK_COLLECTION_INVALID', 'ERROR', '<pack>',
            'M7 packs use format_version 1 and four derived-object arrays',
            'Provide derived_relations, derivations, remove_derivations, and remove_derived_relations arrays.',
            '{}'::jsonb;
        RETURN;
    END IF;
    FOR diagnostic IN
        SELECT * FROM pgreact_internal.validate_pack_v1(
            pgreact_internal.m7_pack_definition(definition), mappings)
    LOOP
        RETURN QUERY SELECT 2, diagnostic.code, diagnostic.severity,
            diagnostic.object_identity, diagnostic.message, diagnostic.hint, diagnostic.details;
        has_error := has_error OR diagnostic.severity = 'ERROR';
    END LOOP;
    IF has_error THEN RETURN; END IF;

    SELECT name INTO duplicate_name FROM (
        SELECT value ->> 'name' AS name
        FROM jsonb_array_elements(definition -> 'derived_relations')
        UNION ALL
        SELECT value ->> 'name' FROM jsonb_array_elements(definition -> 'derivations')
        UNION ALL
        SELECT value ->> 'name' FROM jsonb_array_elements(definition -> 'rules')
    ) names GROUP BY name HAVING count(*) > 1 ORDER BY name LIMIT 1;
    IF duplicate_name IS NOT NULL THEN
        RETURN QUERY SELECT 2, 'OBJECT_NAME_DUPLICATE', 'ERROR', duplicate_name,
            'portable object names must be unique across the pack',
            'Keep one relation, derivation, or ordinary rule with each name.', '{}'::jsonb;
        RETURN;
    END IF;

    FOR item IN
        SELECT value, ordinal FROM jsonb_array_elements(definition -> 'derived_relations')
        WITH ORDINALITY r(value, ordinal)
    LOOP
        SELECT key INTO unknown_key FROM jsonb_object_keys(item.value) key
        WHERE key <> ALL (ARRAY['name', 'row_type', 'key', 'version'])
        ORDER BY key LIMIT 1;
        IF unknown_key IS NOT NULL OR item.value ->> 'name' IS NULL
           OR item.value ->> 'row_type' IS NULL OR item.value ->> 'key' IS NULL
           OR (item.value ->> 'version')::integer < 1 THEN
            RETURN QUERY SELECT 2, 'DERIVED_RELATION_INVALID', 'ERROR',
                COALESCE(item.value ->> 'name', item.ordinal::text),
                'derived relation definitions require only name, row_type, key, and positive version',
                'Use exact portable identities and one bigint key.', '{}'::jsonb;
            RETURN;
        END IF;
        mapped_name := pgreact_internal.pack_mapping(mappings, 'objects', item.value ->> 'name');
        mapped_type := pgreact_internal.pack_mapping(mappings, 'objects', item.value ->> 'row_type');
        row_type_oid := to_regtype(mapped_type)::oid;
        IF row_type_oid IS NULL OR NOT EXISTS (
            SELECT 1 FROM pg_catalog.pg_type t
            WHERE t.oid = row_type_oid AND t.typtype = 'c'
              AND t.typowner = (SELECT oid FROM pg_catalog.pg_roles WHERE rolname = session_user)
        ) OR NOT EXISTS (
            SELECT 1 FROM pg_catalog.pg_type t
            JOIN pg_catalog.pg_attribute a ON a.attrelid = t.typrelid
            WHERE t.oid = row_type_oid AND a.attname = (item.value ->> 'key')::name
              AND a.atttypid = 'bigint'::regtype AND a.attnum > 0 AND NOT a.attisdropped
        ) THEN
            RETURN QUERY SELECT 2, 'DERIVED_RELATION_TYPE_UNSAFE', 'ERROR', item.value ->> 'name',
                'mapped row type must be caller-owned and contain the declared bigint key',
                'Correct the object mapping or row type.',
                jsonb_build_object('mapped_name', mapped_name, 'mapped_row_type', mapped_type);
            RETURN;
        END IF;
        SELECT v.* INTO active_relation
        FROM pgreact_internal.derived_relations r
        JOIN pgreact_internal.derived_relation_versions v USING (relation_id)
        WHERE r.relation_name = mapped_name AND v.state = 'ACTIVE';
        IF FOUND AND ((item.value ->> 'version')::integer < active_relation.version
           OR active_relation.key_column IS DISTINCT FROM (item.value ->> 'key')::name
           OR active_relation.row_signature IS DISTINCT FROM
              pgreact_internal.composite_type_signature(row_type_oid)) THEN
            RETURN QUERY SELECT 2, 'DERIVED_RELATION_REPLACEMENT_UNSAFE', 'ERROR', item.value ->> 'name',
                'M7 relation replacement must increase or keep the version and preserve row type and key',
                'Use a higher compatible version; defer schema evolution to a later milestone.', '{}'::jsonb;
            RETURN;
        END IF;
    END LOOP;

    FOR item IN
        SELECT value, ordinal FROM jsonb_array_elements(definition -> 'derivations')
        WITH ORDINALITY r(value, ordinal)
    LOOP
        SELECT key INTO unknown_key FROM jsonb_object_keys(item.value) key
        WHERE key <> ALL (ARRAY['name', 'definition', 'key', 'target', 'version',
                               'bootstrap_policy', 'depends_on'])
        ORDER BY key LIMIT 1;
        target_item := NULL;
        SELECT value INTO target_item
        FROM jsonb_array_elements(definition -> 'derived_relations') r(value)
        WHERE value ->> 'name' = item.value ->> 'target';
        IF unknown_key IS NOT NULL OR item.value ->> 'name' IS NULL
           OR item.value ->> 'definition' IS NULL OR item.value ->> 'key' IS NULL
           OR target_item IS NULL OR (item.value ->> 'version')::integer < 1
           OR COALESCE(item.value ->> 'bootstrap_policy', 'SEED_CURRENT')
              NOT IN ('SEED_CURRENT', 'REQUIRE_EMPTY') THEN
            RETURN QUERY SELECT 2, 'DERIVATION_INVALID', 'ERROR',
                COALESCE(item.value ->> 'name', item.ordinal::text),
                'derivations require name, source definition, key, declared target, and positive version',
                'Declare the target relation in the same pack and use no consequence fields.', '{}'::jsonb;
            RETURN;
        END IF;
        mapped_source := pgreact_internal.pack_mapping(
            mappings, 'objects', item.value ->> 'definition');
        source_oid := to_regclass(mapped_source);
        target_type_oid := to_regtype(pgreact_internal.pack_mapping(
            mappings, 'objects', target_item ->> 'row_type'))::oid;
        target_key := (target_item ->> 'key')::name;
        SELECT * INTO diagnostic FROM pgreact.validate_rule(
            source_oid::regclass, ARRAY[(item.value ->> 'key')::name], NULL) AS d
        WHERE d.severity = 'ERROR' ORDER BY d.code LIMIT 1;
        IF source_oid IS NULL OR FOUND OR pgreact_internal.source_reads_derived(source_oid)
           OR (item.value ->> 'key')::name IS DISTINCT FROM target_key THEN
            RETURN QUERY SELECT 2,
                CASE WHEN pgreact_internal.source_reads_derived(source_oid)
                     THEN 'DERIVATION_CHAIN_UNSUPPORTED' ELSE 'DERIVATION_SOURCE_INVALID' END,
                'ERROR', item.value ->> 'name',
                'derivation source or key violates the non-recursive target contract',
                'Use a caller-owned authoritative source view that projects the target key.',
                jsonb_build_object('mapped_source', mapped_source);
            RETURN;
        END IF;
        FOR attribute IN
            SELECT a.attname, a.atttypid
            FROM pg_catalog.pg_type t
            JOIN pg_catalog.pg_attribute a ON a.attrelid = t.typrelid
            WHERE t.oid = target_type_oid AND a.attnum > 0 AND NOT a.attisdropped
        LOOP
            IF NOT EXISTS (
                SELECT 1 FROM pg_catalog.pg_attribute a
                WHERE a.attrelid = source_oid AND a.attname = attribute.attname
                  AND a.atttypid = attribute.atttypid
                  AND a.attnum > 0 AND NOT a.attisdropped
            ) THEN
                RETURN QUERY SELECT 2, 'DERIVATION_FACT_SHAPE', 'ERROR', item.value ->> 'name',
                    'derivation source does not project the complete target row type',
                    'Project every target attribute with its exact PostgreSQL type.',
                    jsonb_build_object('column', attribute.attname);
                RETURN;
            END IF;
        END LOOP;
        SELECT v.rule_kind, v.rule_version_id, d.version,
               d.relation_version_id, v.source_view_name, v.source_definition
        INTO active_rule
        FROM pgreact_internal.rules r
        JOIN pgreact_internal.rule_versions v USING (rule_id)
        LEFT JOIN pgreact_internal.derivation_rule_versions d USING (rule_version_id)
        WHERE r.rule_name = item.value ->> 'name' AND v.state <> 'REMOVED'
        ORDER BY v.created_at DESC LIMIT 1;
        IF FOUND AND (active_rule.rule_kind <> 'DERIVATION'
           OR (item.value ->> 'version')::integer < active_rule.version) THEN
            RETURN QUERY SELECT 2, 'DERIVATION_REPLACEMENT_UNSAFE', 'ERROR', item.value ->> 'name',
                'an active rule has an incompatible kind or newer immutable version',
                'Use a new name or increase the derivation version.', '{}'::jsonb;
            RETURN;
        END IF;
        FOR dependency IN
            SELECT value #>> '{}'
            FROM jsonb_array_elements(COALESCE(item.value -> 'depends_on', '[]'::jsonb)) value
        LOOP
            IF NOT EXISTS (
                SELECT 1 FROM (
                    SELECT value ->> 'name' AS name FROM jsonb_array_elements(definition -> 'derived_relations')
                    UNION ALL SELECT value ->> 'name' FROM jsonb_array_elements(definition -> 'derivations')
                    UNION ALL SELECT value ->> 'name' FROM jsonb_array_elements(definition -> 'rules')
                ) names WHERE name = dependency
            ) THEN
                RETURN QUERY SELECT 2, 'DEPENDENCY_MISSING', 'ERROR', dependency,
                    'derivation dependency is not declared in this pack version',
                    'Declare every dependency or remove the edge.', '{}'::jsonb;
                RETURN;
            END IF;
        END LOOP;
    END LOOP;

    SELECT v.pack_version_id INTO prior_pack
    FROM pgreact_internal.rule_packs p
    JOIN pgreact_internal.rule_pack_versions v USING (pack_id)
    WHERE p.pack_name = definition ->> 'pack' AND v.state = 'ACTIVE';
    IF prior_pack IS NOT NULL AND EXISTS (
        SELECT 1 FROM pgreact_internal.rule_pack_derivations old
        WHERE old.pack_version_id = prior_pack
          AND NOT (definition -> 'derivations' @>
                   jsonb_build_array(jsonb_build_object('name', old.rule_name)))
          AND NOT (definition -> 'remove_derivations' @>
                   jsonb_build_array(jsonb_build_object('name', old.rule_name)))
    ) THEN
        RETURN QUERY SELECT 2, 'DERIVATION_REMOVAL_IMPLICIT', 'ERROR', '<pack>',
            'every omitted derivation requires an explicit removal',
            'List it in remove_derivations.', '{}'::jsonb;
        RETURN;
    END IF;
    IF prior_pack IS NOT NULL AND EXISTS (
        SELECT 1 FROM pgreact_internal.rule_pack_derived_relations old
        WHERE old.pack_version_id = prior_pack
          AND NOT (definition -> 'derived_relations' @>
                   jsonb_build_array(jsonb_build_object('name', old.relation_name)))
          AND NOT (definition -> 'remove_derived_relations' @>
                   jsonb_build_array(jsonb_build_object('name', old.relation_name)))
    ) THEN
        RETURN QUERY SELECT 2, 'DERIVED_RELATION_REMOVAL_IMPLICIT', 'ERROR', '<pack>',
            'every omitted derived relation requires an explicit removal',
            'List it in remove_derived_relations after removing consumers and producers.', '{}'::jsonb;
        RETURN;
    END IF;
    RETURN QUERY SELECT 2, 'OK', 'INFO', definition ->> 'pack',
        'M7 pack is valid',
        'Preview and deploy with the returned immutable plan digest.',
        jsonb_build_object('derived_relations', jsonb_array_length(definition -> 'derived_relations'),
                           'derivations', jsonb_array_length(definition -> 'derivations'));
END
$$;

CREATE FUNCTION pgreact.preview_pack(definition jsonb, mappings jsonb DEFAULT '{}'::jsonb)
RETURNS TABLE(
    plan_digest text,
    action_order integer,
    action text,
    rule_name text,
    dependencies text[],
    generated_object_changes jsonb,
    lifecycle_risks jsonb,
    details jsonb
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
#variable_conflict use_variable
DECLARE
    diagnostic record;
    item record;
    current_row record;
    preview_row record;
    digest text;
    ordinal integer := 0;
    mapped_name text;
    mapped_source text;
    dependency_names text[];
BEGIN
    IF NOT (definition ? 'derived_relations' OR definition ? 'derivations'
            OR definition ? 'remove_derivations' OR definition ? 'remove_derived_relations') THEN
        RETURN QUERY SELECT * FROM pgreact_internal.preview_pack_v1(definition, mappings);
        RETURN;
    END IF;
    SELECT * INTO diagnostic FROM pgreact.validate_pack(definition, mappings) d
    WHERE d.severity = 'ERROR' ORDER BY d.code, d.object_identity LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'pg-react pack validation % for %: %',
            diagnostic.code, diagnostic.object_identity, diagnostic.message
            USING HINT = diagnostic.hint;
    END IF;
    digest := pgreact_internal.m7_pack_plan_digest(definition, mappings);
    FOR item IN
        SELECT value, array_ordinal
        FROM jsonb_array_elements(definition -> 'derived_relations')
        WITH ORDINALITY r(value, array_ordinal)
    LOOP
        ordinal := ordinal + 1;
        mapped_name := pgreact_internal.pack_mapping(
            mappings, 'objects', item.value ->> 'name');
        SELECT v.relation_version_id, v.version, v.state INTO current_row
        FROM pgreact_internal.derived_relations r
        JOIN pgreact_internal.derived_relation_versions v USING (relation_id)
        WHERE r.relation_name = mapped_name AND v.state = 'ACTIVE';
        plan_digest := digest;
        action_order := ordinal;
        action := CASE WHEN current_row.relation_version_id IS NULL THEN 'ADD'
                       WHEN current_row.version = (item.value ->> 'version')::integer THEN 'KEEP'
                       ELSE 'REPLACE' END;
        rule_name := item.value ->> 'name';
        dependencies := ARRAY[]::text[];
        generated_object_changes := jsonb_build_object(
            'object_kind', 'DERIVED_RELATION',
            'public_view', mapped_name,
            'row_type', pgreact_internal.pack_mapping(
                mappings, 'objects', item.value ->> 'row_type'));
        lifecycle_risks := CASE WHEN action = 'REPLACE'
            THEN jsonb_build_array('all producers must move to the new immutable relation version atomically')
            ELSE '[]'::jsonb END;
        details := jsonb_build_object(
            'prior_relation_version_id', current_row.relation_version_id,
            'prior_version', current_row.version,
            'next_version', (item.value ->> 'version')::integer);
        RETURN NEXT;
    END LOOP;
    FOR item IN
        SELECT value, array_ordinal
        FROM jsonb_array_elements(definition -> 'derivations')
        WITH ORDINALITY r(value, array_ordinal)
    LOOP
        ordinal := ordinal + 1;
        SELECT v.rule_version_id, d.version, v.state, v.source_view_name
        INTO current_row
        FROM pgreact_internal.rules r
        JOIN pgreact_internal.rule_versions v USING (rule_id)
        JOIN pgreact_internal.derivation_rule_versions d USING (rule_version_id)
        WHERE r.rule_name = item.value ->> 'name' AND v.state <> 'REMOVED'
        ORDER BY v.created_at DESC LIMIT 1;
        SELECT array_agg(value #>> '{}' ORDER BY dependency_ordinal)::text[]
        INTO dependency_names
        FROM jsonb_array_elements(COALESCE(item.value -> 'depends_on', '[]'::jsonb))
        WITH ORDINALITY d(value, dependency_ordinal);
        mapped_source := pgreact_internal.pack_mapping(
            mappings, 'objects', item.value ->> 'definition');
        plan_digest := digest;
        action_order := ordinal;
        action := CASE WHEN current_row.rule_version_id IS NULL THEN 'ADD'
                       WHEN current_row.version = (item.value ->> 'version')::integer
                        AND current_row.source_view_name = mapped_source THEN 'KEEP'
                       ELSE 'REPLACE' END;
        rule_name := item.value ->> 'name';
        dependencies := COALESCE(dependency_names, ARRAY[]::text[]);
        generated_object_changes := jsonb_build_object(
            'object_kind', 'DERIVATION',
            'create', jsonb_build_array('match_relation', 'support_binding'),
            'agenda', false);
        lifecycle_risks := CASE WHEN action = 'REPLACE'
            THEN jsonb_build_array('old supports retract after replacement supports are seeded')
            ELSE jsonb_build_array(COALESCE(item.value ->> 'bootstrap_policy', 'SEED_CURRENT') ||
                                   ' may seed current supports') END;
        details := jsonb_build_object(
            'source', item.value ->> 'definition', 'mapped_source', mapped_source,
            'target', item.value ->> 'target',
            'prior_rule_version_id', current_row.rule_version_id,
            'prior_version', current_row.version,
            'next_version', (item.value ->> 'version')::integer);
        RETURN NEXT;
    END LOOP;
    FOR preview_row IN
        SELECT * FROM pgreact_internal.preview_pack_v1(
            pgreact_internal.m7_pack_definition(definition), mappings)
        ORDER BY action_order
    LOOP
        ordinal := ordinal + 1;
        plan_digest := digest;
        action_order := ordinal;
        action := preview_row.action;
        rule_name := preview_row.rule_name;
        dependencies := preview_row.dependencies;
        generated_object_changes := preview_row.generated_object_changes;
        lifecycle_risks := preview_row.lifecycle_risks;
        details := preview_row.details;
        RETURN NEXT;
    END LOOP;
    FOR item IN
        SELECT value FROM jsonb_array_elements(definition -> 'remove_derivations') value
    LOOP
        ordinal := ordinal + 1;
        plan_digest := digest; action_order := ordinal; action := 'REMOVE';
        rule_name := item.value ->> 'name'; dependencies := ARRAY[]::text[];
        generated_object_changes := jsonb_build_object('object_kind', 'DERIVATION');
        lifecycle_risks := jsonb_build_array('active supports retract before commit');
        details := '{}'::jsonb;
        RETURN NEXT;
    END LOOP;
    FOR item IN
        SELECT value FROM jsonb_array_elements(definition -> 'remove_derived_relations') value
    LOOP
        ordinal := ordinal + 1;
        plan_digest := digest; action_order := ordinal; action := 'REMOVE';
        rule_name := item.value ->> 'name'; dependencies := ARRAY[]::text[];
        generated_object_changes := jsonb_build_object('object_kind', 'DERIVED_RELATION');
        lifecycle_risks := jsonb_build_array('removal requires no active producer, consumer, or fact');
        details := '{}'::jsonb;
        RETURN NEXT;
    END LOOP;
END
$$;

CREATE FUNCTION pgreact.deploy_pack(
    definition jsonb,
    expected_plan_digest text,
    mappings jsonb DEFAULT '{}'::jsonb
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
#variable_conflict use_variable
DECLARE
    diagnostic record;
    actual_digest text;
    v1_definition jsonb;
    v1_digest text;
    pack_version uuid;
    prior_pack_version uuid;
    item record;
    relation_item record;
    current_relation record;
    target_relation uuid;
    current_rule record;
    next_version uuid;
    prior_version uuid;
    mapped_name text;
    mapped_type text;
    mapped_source text;
    dependency_names text[];
    action_name text;
    action_number integer := 0;
BEGIN
    IF NOT (definition ? 'derived_relations' OR definition ? 'derivations'
            OR definition ? 'remove_derivations' OR definition ? 'remove_derived_relations') THEN
        RETURN pgreact_internal.deploy_pack_v1(definition, expected_plan_digest, mappings);
    END IF;
    PERFORM pg_catalog.pg_advisory_xact_lock(5788046901200000);
    PERFORM pg_catalog.pg_advisory_xact_lock(5788046901200001);
    SELECT * INTO diagnostic FROM pgreact.validate_pack(definition, mappings) d
    WHERE d.severity = 'ERROR' ORDER BY d.code, d.object_identity LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'pg-react pack validation % for %: %',
            diagnostic.code, diagnostic.object_identity, diagnostic.message
            USING HINT = diagnostic.hint;
    END IF;
    actual_digest := pgreact_internal.m7_pack_plan_digest(definition, mappings);
    IF expected_plan_digest IS DISTINCT FROM actual_digest THEN
        RAISE EXCEPTION 'rule-pack preview is stale'
            USING HINT = 'Run pgreact.preview_pack again after concurrent DDL, support, or deployment changes.',
                  DETAIL = format('expected %s, current %s', expected_plan_digest, actual_digest);
    END IF;
    SELECT v.pack_version_id INTO prior_pack_version
    FROM pgreact_internal.rule_packs p
    JOIN pgreact_internal.rule_pack_versions v USING (pack_id)
    WHERE p.pack_name = definition ->> 'pack' AND v.state = 'ACTIVE';

    FOR item IN
        SELECT value FROM jsonb_array_elements(definition -> 'derived_relations') value
    LOOP
        mapped_name := pgreact_internal.pack_mapping(
            mappings, 'objects', item.value ->> 'name');
        mapped_type := pgreact_internal.pack_mapping(
            mappings, 'objects', item.value ->> 'row_type');
        SELECT v.relation_version_id, v.version INTO current_relation
        FROM pgreact_internal.derived_relations r
        JOIN pgreact_internal.derived_relation_versions v USING (relation_id)
        WHERE r.relation_name = mapped_name AND v.state = 'ACTIVE';
        IF current_relation.relation_version_id IS NULL THEN
            PERFORM pgreact.create_derived_relation(
                mapped_name, to_regtype(mapped_type),
                ARRAY[(item.value ->> 'key')::name],
                (item.value ->> 'version')::integer);
        ELSIF current_relation.version < (item.value ->> 'version')::integer THEN
            PERFORM pgreact_internal.replace_derived_relation(
                current_relation.relation_version_id, to_regtype(mapped_type),
                ARRAY[(item.value ->> 'key')::name],
                (item.value ->> 'version')::integer);
        END IF;
    END LOOP;

    FOR item IN
        SELECT value FROM jsonb_array_elements(definition -> 'derivations') value
    LOOP
        mapped_source := pgreact_internal.pack_mapping(
            mappings, 'objects', item.value ->> 'definition');
        mapped_name := pgreact_internal.pack_mapping(
            mappings, 'objects', item.value ->> 'target');
        SELECT v.relation_version_id INTO STRICT target_relation
        FROM pgreact_internal.derived_relations r
        JOIN pgreact_internal.derived_relation_versions v USING (relation_id)
        WHERE r.relation_name = mapped_name AND v.state = 'ACTIVE';
        SELECT v.rule_version_id, v.rule_kind, v.source_view_name,
               v.source_definition, d.version, d.relation_version_id
        INTO current_rule
        FROM pgreact_internal.rules r
        JOIN pgreact_internal.rule_versions v USING (rule_id)
        LEFT JOIN pgreact_internal.derivation_rule_versions d USING (rule_version_id)
        WHERE r.rule_name = item.value ->> 'name' AND v.state <> 'REMOVED'
        ORDER BY v.created_at DESC LIMIT 1;
        IF current_rule.rule_version_id IS NULL THEN
            PERFORM pgreact.create_derivation_rule(
                item.value ->> 'name', to_regclass(mapped_source),
                ARRAY[(item.value ->> 'key')::name], target_relation,
                (item.value ->> 'version')::integer,
                COALESCE(item.value ->> 'bootstrap_policy', 'SEED_CURRENT'));
        ELSIF current_rule.rule_kind <> 'DERIVATION' THEN
            RAISE EXCEPTION 'cannot replace non-derivation rule % with a derivation',
                item.value ->> 'name';
        ELSIF current_rule.version = (item.value ->> 'version')::integer
              AND current_rule.source_view_name = mapped_source
              AND current_rule.source_definition = pg_get_viewdef(to_regclass(mapped_source), true)
              AND current_rule.relation_version_id = target_relation THEN
            NULL;
        ELSIF current_rule.version >= (item.value ->> 'version')::integer THEN
            RAISE EXCEPTION 'immutable derivation version % already exists for %',
                current_rule.version, item.value ->> 'name';
        ELSE
            PERFORM pgreact.replace_derivation_rule(
                current_rule.rule_version_id, to_regclass(mapped_source),
                ARRAY[(item.value ->> 'key')::name],
                (item.value ->> 'version')::integer,
                COALESCE(item.value ->> 'bootstrap_policy', 'SEED_CURRENT'));
        END IF;
    END LOOP;

    v1_definition := pgreact_internal.m7_pack_definition(definition);
    v1_digest := pgreact_internal.pack_plan_digest(v1_definition, mappings);
    PERFORM pgreact_internal.maybe_fail_pack('derived');
    pack_version := pgreact_internal.deploy_pack_v1(v1_definition, v1_digest, mappings);
    UPDATE pgreact_internal.rule_pack_versions SET
        definition = deploy_pack.definition,
        definition_digest = sha256(convert_to(deploy_pack.definition::text, 'UTF8')),
        plan_digest = actual_digest
    WHERE pack_version_id = pack_version;

    FOR item IN
        SELECT value FROM jsonb_array_elements(definition -> 'derived_relations') value
    LOOP
        action_number := action_number + 1;
        mapped_name := pgreact_internal.pack_mapping(
            mappings, 'objects', item.value ->> 'name');
        SELECT v.relation_version_id INTO STRICT next_version
        FROM pgreact_internal.derived_relations r
        JOIN pgreact_internal.derived_relation_versions v USING (relation_id)
        WHERE r.relation_name = mapped_name AND v.state = 'ACTIVE';
        SELECT relation_version_id INTO prior_version
        FROM pgreact_internal.rule_pack_derived_relations
        WHERE pack_version_id = prior_pack_version
          AND relation_name = item.value ->> 'name';
        action_name := CASE WHEN prior_version IS NULL THEN 'ADD'
                            WHEN prior_version = next_version THEN 'KEEP'
                            ELSE 'REPLACE' END;
        INSERT INTO pgreact_internal.rule_pack_derived_relations VALUES (
            pack_version, item.value ->> 'name', next_version);
        INSERT INTO pgreact_internal.rule_pack_derived_actions VALUES (
            pack_version, action_number, 'DERIVED_RELATION', action_name,
            item.value ->> 'name', prior_version, next_version,
            jsonb_build_object('mapped_name', mapped_name,
                               'version', (item.value ->> 'version')::integer));
    END LOOP;
    FOR item IN
        SELECT value FROM jsonb_array_elements(definition -> 'derivations') value
    LOOP
        action_number := action_number + 1;
        SELECT v.rule_version_id INTO STRICT next_version
        FROM pgreact_internal.rules r
        JOIN pgreact_internal.rule_versions v USING (rule_id)
        WHERE r.rule_name = item.value ->> 'name' AND v.state <> 'REMOVED'
        ORDER BY v.created_at DESC LIMIT 1;
        SELECT rule_version_id INTO prior_version
        FROM pgreact_internal.rule_pack_derivations
        WHERE pack_version_id = prior_pack_version
          AND rule_name = item.value ->> 'name';
        SELECT array_agg(value #>> '{}' ORDER BY ordinal)::text[] INTO dependency_names
        FROM jsonb_array_elements(COALESCE(item.value -> 'depends_on', '[]'::jsonb))
        WITH ORDINALITY d(value, ordinal);
        action_name := CASE WHEN prior_version IS NULL THEN 'ADD'
                            WHEN prior_version = next_version THEN 'KEEP'
                            ELSE 'REPLACE' END;
        INSERT INTO pgreact_internal.rule_pack_derivations VALUES (
            pack_version, item.value ->> 'name', next_version,
            item.value ->> 'target', COALESCE(dependency_names, ARRAY[]::text[]));
        INSERT INTO pgreact_internal.rule_pack_derived_actions VALUES (
            pack_version, action_number, 'DERIVATION', action_name,
            item.value ->> 'name', prior_version, next_version,
            jsonb_build_object('target', item.value ->> 'target',
                               'dependencies', COALESCE(to_jsonb(dependency_names), '[]'::jsonb)));
    END LOOP;

    FOR item IN
        SELECT value FROM jsonb_array_elements(definition -> 'remove_derivations') value
    LOOP
        action_number := action_number + 1;
        SELECT rule_version_id INTO STRICT prior_version
        FROM pgreact_internal.rule_pack_derivations
        WHERE pack_version_id = prior_pack_version
          AND rule_name = item.value ->> 'name';
        PERFORM pgreact_internal.retire_derivation_rule(prior_version);
        INSERT INTO pgreact_internal.rule_pack_derived_actions VALUES (
            pack_version, action_number, 'DERIVATION', 'REMOVE',
            item.value ->> 'name', prior_version, NULL, '{}'::jsonb);
    END LOOP;
    FOR item IN
        SELECT value FROM jsonb_array_elements(definition -> 'remove_derived_relations') value
    LOOP
        action_number := action_number + 1;
        SELECT relation_version_id INTO STRICT prior_version
        FROM pgreact_internal.rule_pack_derived_relations
        WHERE pack_version_id = prior_pack_version
          AND relation_name = item.value ->> 'name';
        PERFORM pgreact_internal.remove_derived_relation(prior_version);
        INSERT INTO pgreact_internal.rule_pack_derived_actions VALUES (
            pack_version, action_number, 'DERIVED_RELATION', 'REMOVE',
            item.value ->> 'name', prior_version, NULL, '{}'::jsonb);
    END LOOP;
    RETURN pack_version;
END
$$;

CREATE OR REPLACE FUNCTION pgreact.pack_history(target_pack_name text DEFAULT NULL)
RETURNS TABLE(
    pack_name text,
    version text,
    status text,
    definition_digest text,
    plan_digest text,
    deployed_at timestamptz,
    deployed_by name,
    actions jsonb
)
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT p.pack_name, v.version, v.state,
           encode(v.definition_digest, 'hex'), v.plan_digest,
           v.deployed_at, v.deployed_by,
           COALESCE((
               SELECT jsonb_agg(action ORDER BY phase, action_order, object_name)
               FROM (
                   SELECT 2 AS phase, a.action_order, a.rule_name AS object_name,
                          jsonb_build_object(
                              'order', a.action_order, 'action', a.action,
                              'rule', a.rule_name,
                              'old_rule_version_id', a.old_rule_version_id,
                              'new_rule_version_id', a.new_rule_version_id,
                              'old_work_policy', a.old_work_policy,
                              'details', a.details) AS action
                   FROM pgreact_internal.rule_pack_actions a
                   WHERE a.pack_version_id = v.pack_version_id
                   UNION ALL
                   SELECT CASE WHEN a.action = 'REMOVE' THEN 3
                               WHEN a.object_kind = 'DERIVED_RELATION' THEN 0 ELSE 1 END,
                          a.action_order, a.object_name,
                          jsonb_build_object(
                              'order', a.action_order, 'action', a.action,
                              'rule', a.object_name,
                              'old_rule_version_id', a.old_version_id,
                              'new_rule_version_id', a.new_version_id,
                              'old_work_policy', NULL,
                              'details', a.details || jsonb_build_object(
                                  'object_kind', a.object_kind))
                   FROM pgreact_internal.rule_pack_derived_actions a
                   WHERE a.pack_version_id = v.pack_version_id
               ) combined
           ), '[]'::jsonb)
    FROM pgreact_internal.rule_packs p
    JOIN pgreact_internal.rule_pack_versions v USING (pack_id)
    WHERE p.owner_oid = (SELECT oid FROM pg_catalog.pg_roles WHERE rolname = session_user)
      AND ($1 IS NULL OR p.pack_name = $1)
    ORDER BY p.pack_name, v.deployed_at
$$;

CREATE FUNCTION pgreact.explain_pack(target_pack_name text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    base jsonb;
    active_version uuid;
BEGIN
    base := pgreact_internal.explain_pack_v1(target_pack_name);
    SELECT v.pack_version_id INTO active_version
    FROM pgreact_internal.rule_packs p
    JOIN pgreact_internal.rule_pack_versions v USING (pack_id)
    WHERE p.pack_name = target_pack_name
      AND p.owner_oid = (SELECT oid FROM pg_catalog.pg_roles WHERE rolname = session_user)
      AND v.state = 'ACTIVE';
    IF active_version IS NULL THEN RETURN base; END IF;
    RETURN base || jsonb_build_object(
        'derived_relations', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                'name', m.relation_name, 'relation_version_id', m.relation_version_id,
                'version', v.version, 'state', v.state,
                'public_view', v.public_view_name
            ) ORDER BY m.relation_name)
            FROM pgreact_internal.rule_pack_derived_relations m
            JOIN pgreact_internal.derived_relation_versions v USING (relation_version_id)
            WHERE m.pack_version_id = active_version
        ), '[]'::jsonb),
        'derivations', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                'name', m.rule_name, 'rule_version_id', m.rule_version_id,
                'version', d.version, 'state', v.state,
                'target', m.target_relation, 'dependencies', m.dependencies,
                'active_supports', (SELECT count(*)
                    FROM pgreact_internal.derived_supports s
                    WHERE s.rule_version_id = m.rule_version_id AND s.active)
            ) ORDER BY m.rule_name)
            FROM pgreact_internal.rule_pack_derivations m
            JOIN pgreact_internal.derivation_rule_versions d USING (rule_version_id)
            JOIN pgreact_internal.rule_versions v USING (rule_version_id)
            WHERE m.pack_version_id = active_version
        ), '[]'::jsonb)
    );
END
$$;

CREATE OR REPLACE FUNCTION pgreact.health_check()
RETURNS TABLE(code text, severity text, object_identity text, message text, hint text)
LANGUAGE SQL
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
 SELECT 'BARRIER', 'ERROR', b.rule_version_id::text, 'claims are blocked', 'Repair the reported condition and reconcile or refresh through pg-reactd.' FROM pgreact_internal.rule_barriers b
 UNION ALL SELECT 'SOURCE_DRIFT', CASE WHEN d.status = 'INCOMPATIBLE' THEN 'ERROR' ELSE 'WARNING' END,
   d.rule_version_id::text, 'source view differs from the deployed snapshot',
   CASE WHEN d.status = 'INCOMPATIBLE' THEN 'Claims are blocked; pause, drain, and replace the rule.' ELSE 'Pause, drain, and replace the rule to adopt the changed view.' END
 FROM pgreact.source_drift() d WHERE d.status <> 'CURRENT'
 UNION ALL SELECT 'CONSEQUENCE_DRIFT', 'ERROR', b.rule_version_id::text,
   'consequence or dispatcher is missing, changed, or no longer exact',
   'Pause, drain, and replace the rule with an exact valid consequence binding.'
 FROM pgreact_internal.consequence_bindings b
 LEFT JOIN pg_catalog.pg_proc f ON f.oid = b.function_oid
 LEFT JOIN pg_catalog.pg_proc p ON p.oid = b.dispatcher_oid
 WHERE f.oid IS NULL OR sha256(convert_to(pg_get_functiondef(f.oid), 'UTF8')) <> b.function_digest
    OR (b.dispatcher_oid IS NOT NULL AND (p.oid IS NULL OR sha256(convert_to(pg_get_functiondef(p.oid), 'UTF8')) <> b.dispatcher_digest))
 UNION ALL SELECT 'FAILED_EPISODE', 'ERROR', a.episode_id::text, 'episode reached terminal failure', 'Inspect it with pgreact.explain_episode, then retry or cancel it.'
 FROM pgreact_internal.agenda a WHERE a.state = 'FAILED'
 UNION ALL SELECT 'STALE_LEASE', 'WARNING', a.episode_id::text, 'lease has expired and can be reclaimed', 'Run pgreact.sweep_expired_leases for this rule version.'
 FROM pgreact_internal.agenda a WHERE a.state = 'LEASED' AND a.lease_expires_at <= clock_timestamp()
 UNION ALL SELECT 'AGENDA_BACKLOG', 'WARNING', a.rule_version_id::text, 'pending work exceeds 80 percent of its configured limit',
   'Drain, cancel, or raise the approved per-rule limit before the refresh path reaches backpressure.'
 FROM pgreact_internal.agenda a CROSS JOIN pgreact_internal.operational_settings s
 WHERE a.state IN ('PENDING', 'RETRY_WAIT', 'LEASED')
 GROUP BY a.rule_version_id, s.max_pending_per_rule HAVING count(*) >= s.max_pending_per_rule * 0.8
 UNION ALL SELECT 'STANDBY', 'ERROR', 'database', 'workers cannot claim work on a physical standby',
   'Promote the database, then run prepare_recovery, rebuild_transient_metadata, reconciliation, and health_check.'
 WHERE pg_catalog.pg_is_in_recovery()
 UNION ALL SELECT 'DERIVED_FACT_INVALID', 'ERROR',
   f.relation_version_id::text || ':' || f.semantic_key,
   'derived fact support count or payload differs from active supports',
   'Run pgreact.reconcile_derived_relation for the affected relation version.'
 FROM pgreact_internal.derived_facts f
 LEFT JOIN LATERAL (
   SELECT count(*) AS support_count, count(DISTINCT s.fact::text) AS fact_count,
          min(s.fact::text)::jsonb AS fact
   FROM pgreact_internal.derived_supports s
   WHERE s.relation_version_id = f.relation_version_id
     AND s.semantic_key = f.semantic_key AND s.active
 ) expected ON true
 WHERE expected.support_count = 0 OR expected.fact_count <> 1
    OR expected.support_count <> f.support_count OR expected.fact IS DISTINCT FROM f.fact
 UNION ALL SELECT 'DERIVED_FACT_MISSING', 'ERROR',
   s.relation_version_id::text || ':' || s.semantic_key,
   'active supports have no current derived fact',
   'Run pgreact.reconcile_derived_relation for the affected relation version.'
 FROM pgreact_internal.derived_supports s
 WHERE s.active AND NOT EXISTS (
   SELECT 1 FROM pgreact_internal.derived_facts f
   WHERE f.relation_version_id = s.relation_version_id
     AND f.semantic_key = s.semantic_key
 )
 GROUP BY s.relation_version_id, s.semantic_key
$$;

REVOKE ALL ON ALL TABLES IN SCHEMA pgreact_internal FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA pgreact_internal FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA pgreact FROM PUBLIC;

COMMENT ON EXTENSION pg_react IS
    'M7 non-recursive maintained derived knowledge with durable supports and provenance';
