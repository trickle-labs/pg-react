-- M11 PostgreSQL-facing API redesign.  The M0-M10 engine remains private.
CREATE SCHEMA pgreact_api;
REVOKE ALL ON SCHEMA pgreact_api FROM PUBLIC;
CREATE FUNCTION pgreact_api.validate_rule(condition regclass, semantic_key name,
                                          on_activate text DEFAULT NULL)
RETURNS TABLE(contract_version integer, code text, severity text,
              object_identity text, message text, hint text, details jsonb)
LANGUAGE SQL SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT * FROM pgreact.validate_rule($1, ARRAY[$2], $3::regprocedure)
$$;
CREATE FUNCTION pgreact_api.validate_rule(definition jsonb,
                                          mappings jsonb DEFAULT '{}'::jsonb)
RETURNS TABLE(contract_version integer, code text, severity text,
              object_identity text, message text, hint text, details jsonb)
LANGUAGE SQL SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT * FROM pgreact.validate_pack($1, $2)
$$;
CREATE FUNCTION pgreact_api.author_rule(
    rule_name text, condition regclass, semantic_key name, kind text DEFAULT NULL,
    on_activate text DEFAULT NULL, on_deactivate text DEFAULT NULL,
    on_change text DEFAULT NULL, bootstrap_policy text DEFAULT 'SEED_CURRENT',
    change_columns name[] DEFAULT NULL, salience integer DEFAULT 0,
    agenda_group text DEFAULT 'default', conflict_key_columns name[] DEFAULT NULL,
    max_attempts integer DEFAULT 1, initial_backoff_seconds integer DEFAULT 1,
    backoff_multiplier numeric DEFAULT 2, max_backoff_seconds integer DEFAULT 60
) RETURNS uuid
LANGUAGE SQL SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT pgreact.create_rule($1, $2, ARRAY[$3], $4, $5::regprocedure, $6::regprocedure,
                              $7::regprocedure, $8, $9, $10,
                              $11, $12, $13, $14, $15, $16)
$$;
CREATE FUNCTION pgreact_api.author_rule(definition jsonb,
                                        mappings jsonb DEFAULT '{}'::jsonb)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE digest text;
BEGIN
  SELECT min(plan_digest) INTO digest FROM pgreact.preview_pack(definition, mappings);
  IF digest IS NULL THEN RAISE EXCEPTION 'M11_PACK_EMPTY: preview produced no deployable plan'; END IF;
  RETURN pgreact.deploy_pack(definition, digest, mappings);
END
$$;
CREATE FUNCTION pgreact_api.rule_status(name text DEFAULT NULL::text) RETURNS jsonb
LANGUAGE SQL SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT jsonb_build_object('contract_version', 1,
    'rules', COALESCE((SELECT jsonb_agg(to_jsonb(r) ORDER BY r.rule_name)
                       FROM pgreact.rules r WHERE $1 IS NULL OR r.rule_name = $1), '[]'::jsonb),
    'health', COALESCE((SELECT jsonb_agg(to_jsonb(h) ORDER BY h.code, h.object_identity)
                        FROM pgreact.health_check() h), '[]'::jsonb))
$$;
CREATE FUNCTION pgreact_api.explain_rule(name text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE version_id uuid;
BEGIN
  SELECT r.rule_version_id INTO version_id FROM pgreact.rules r
  WHERE r.rule_name = explain_rule.name ORDER BY r.created_at DESC LIMIT 1;
  IF version_id IS NULL THEN RAISE EXCEPTION 'M11_RULE_NOT_FOUND: %', name; END IF;
  RETURN pgreact.explain_rule(version_id);
END
$$;
CREATE FUNCTION pgreact_api.run_rule(name text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE version_id uuid;
BEGIN
  SELECT r.rule_version_id INTO version_id FROM pgreact.rules r
  WHERE r.rule_name = run_rule.name ORDER BY r.created_at DESC LIMIT 1;
  IF version_id IS NULL THEN RAISE EXCEPTION 'M11_RULE_NOT_FOUND: %', name; END IF;
  PERFORM pgreact.refresh_rule(version_id);
END
$$;
CREATE FUNCTION pgreact_api.health() RETURNS jsonb
LANGUAGE SQL SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT jsonb_build_object('contract_version', 1, 'diagnostics',
    COALESCE((SELECT jsonb_agg(to_jsonb(h) ORDER BY h.code, h.object_identity)
              FROM pgreact.health_check() h), '[]'::jsonb))
$$;
CREATE FUNCTION pgreact_api.claim(worker_id text, max_items integer DEFAULT 1,
                                  lease_for interval DEFAULT interval '60 seconds')
RETURNS TABLE(episode_id bigint, lease_token uuid, activation_id uuid, bindings jsonb,
              event_kind text, rule_version_id uuid)
LANGUAGE SQL SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT * FROM pgreact.claim($1, $2, $3)
$$;
CREATE FUNCTION pgreact_api.execute(episode_id bigint, worker_id text, lease_token uuid)
RETURNS text
LANGUAGE SQL SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT pgreact.execute_claimed_episode($1, $2, $3)
$$;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA pgreact_api FROM PUBLIC;
COMMENT ON EXTENSION pg_react IS
    'M11 PostgreSQL-first author, operator, and worker API over M0-M10 behavior';
