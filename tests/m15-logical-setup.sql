\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';

CREATE SCHEMA m15_portable AUTHORIZATION m15_author;
CREATE TABLE m15_portable.source (
    tenant text COLLATE "C" NOT NULL,
    account_id bigint NOT NULL,
    payload text NOT NULL,
    PRIMARY KEY (tenant, account_id)
);
CREATE VIEW m15_portable.condition AS SELECT * FROM m15_portable.source;
CREATE TABLE m15_portable.effects (
    public_key jsonb PRIMARY KEY,
    payload text NOT NULL
);
CREATE TABLE m15_portable.identity_snapshot (
    semantic_key bigint PRIMARY KEY,
    canonical_key text NOT NULL,
    public_key jsonb NOT NULL
);
CREATE FUNCTION m15_portable.activate(row_value m15_portable.condition)
RETURNS void LANGUAGE SQL AS $$
    INSERT INTO m15_portable.effects VALUES (
        jsonb_build_array(row_value.tenant, row_value.account_id), row_value.payload)
$$;
CREATE FUNCTION m15_portable.activate_portable(row_value jsonb)
RETURNS void LANGUAGE SQL AS $$
    INSERT INTO m15_portable.effects VALUES (
        jsonb_build_array(row_value -> 'tenant', row_value -> 'account_id'),
        row_value ->> 'payload')
$$;
ALTER TABLE m15_portable.source OWNER TO m15_author;
ALTER VIEW m15_portable.condition OWNER TO m15_author;
ALTER TABLE m15_portable.effects OWNER TO m15_author;
ALTER TABLE m15_portable.identity_snapshot OWNER TO m15_author;
ALTER FUNCTION m15_portable.activate(m15_portable.condition) OWNER TO m15_author;
ALTER FUNCTION m15_portable.activate_portable(jsonb) OWNER TO m15_author;
SET SESSION AUTHORIZATION m15_author;
SELECT pgreact_api.author_rule(
    'm15.portable', 'm15_portable.condition', ARRAY['tenant', 'account_id']::name[],
    'm15_portable', 'activate');
RESET SESSION AUTHORIZATION;
INSERT INTO m15_portable.source VALUES ('north', 42, 'portable');
SET SESSION AUTHORIZATION m15_operator;
SELECT pgreact_api.run();
RESET SESSION AUTHORIZATION;
SET SESSION AUTHORIZATION m15_worker;
SELECT pgreact_api.managed_cycle();
RESET SESSION AUTHORIZATION;

INSERT INTO m15_portable.identity_snapshot
SELECT identity.semantic_key, encode(identity.canonical_key, 'hex'), identity.public_key
FROM pgreact_internal.semantic_key_identities identity
JOIN pgreact_internal.rule_versions version USING (rule_version_id)
JOIN pgreact_internal.rules rule USING (rule_id)
WHERE rule.rule_name = 'm15.portable';

DO $$
DECLARE actual jsonb;
BEGIN
    SELECT jsonb_agg(to_jsonb(effect) ORDER BY public_key::text)
    INTO actual FROM m15_portable.effects effect;
    IF actual IS DISTINCT FROM jsonb_build_array(jsonb_build_object(
            'public_key', jsonb_build_array('north', 42), 'payload', 'portable'))
       OR pgreact_api.matches('m15.portable') #> '{matches,0,key}'
          IS DISTINCT FROM jsonb_build_array('north', 42)
       OR (SELECT count(*) FROM m15_portable.identity_snapshot) <> 1 THEN
        RAISE EXCEPTION 'M15 logical source qualification changed: %', actual;
    END IF;
END
$$;

SELECT 'M15 logical source qualification passed';
