\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';

SELECT pgreact_api.configure_roles(
    'm15_author', 'm15_operator', 'm15_worker', 'm15_reader', 'm15_advanced');
CREATE TEMP TABLE expected_identity AS TABLE m15_portable.identity_snapshot;
CREATE TEMP TABLE restored_source AS TABLE m15_portable.source;
TRUNCATE m15_portable.source;

SET SESSION AUTHORIZATION m15_author;
SELECT pgreact_api.author_rule(
    'm15.portable', 'm15_portable.condition', ARRAY['tenant', 'account_id']::name[],
    'm15_portable', 'activate');
RESET SESSION AUTHORIZATION;
INSERT INTO m15_portable.source SELECT * FROM restored_source;
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
WHERE rule.rule_name = 'm15.portable'
ON CONFLICT (semantic_key) DO UPDATE
SET canonical_key = EXCLUDED.canonical_key, public_key = EXCLUDED.public_key;

DO $$
DECLARE actual jsonb;
BEGIN
    SELECT jsonb_agg(to_jsonb(effect) ORDER BY public_key::text)
    INTO actual FROM m15_portable.effects effect;
    IF actual IS DISTINCT FROM jsonb_build_array(jsonb_build_object(
            'public_key', jsonb_build_array('north', 42), 'payload', 'portable'))
       OR pgreact_api.matches('m15.portable') #> '{matches,0,key}'
          IS DISTINCT FROM jsonb_build_array('north', 42)
       OR (SELECT jsonb_agg(to_jsonb(identity) ORDER BY semantic_key)
           FROM m15_portable.identity_snapshot identity)
          IS DISTINCT FROM (SELECT jsonb_agg(to_jsonb(identity) ORDER BY semantic_key)
                            FROM expected_identity identity) THEN
        RAISE EXCEPTION 'M15 logical restore changed typed identity or output: %', actual;
    END IF;
END
$$;

SELECT 'M15 logical dump and declaration replay passed';
