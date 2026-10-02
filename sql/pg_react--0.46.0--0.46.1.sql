-- 0.46.1: disambiguate the shared generic claim sweep from its OUT parameter.
CREATE OR REPLACE FUNCTION pgreact.claim(
    worker_id text,
    max_items integer DEFAULT 1,
    lease_for interval DEFAULT interval '60 seconds',
    agenda_groups text[] DEFAULT NULL)
RETURNS TABLE(
    episode_id bigint, lease_token uuid, activation_id uuid, bindings jsonb,
    event_kind text, rule_version_id uuid)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $v0433$
DECLARE
    candidate record;
    claimed record;
    version_id uuid;
    count_claimed integer := 0;
    seconds integer := extract(epoch FROM lease_for)::integer;
    fairness interval;
    claim_limit integer;
BEGIN
    PERFORM pg_catalog.pg_advisory_xact_lock_shared(5788046901200000);
    SELECT fairness_window, max_claims INTO fairness, claim_limit
    FROM pgreact_internal.operational_settings;
    IF max_items NOT BETWEEN 1 AND claim_limit THEN
        RAISE EXCEPTION 'max_items must be between 1 and %', claim_limit;
    END IF;
    IF seconds < 1 THEN
        RAISE EXCEPTION 'lease_for must be at least one second';
    END IF;
    FOR version_id IN
        SELECT version.rule_version_id
        FROM pgreact_internal.rule_versions AS version
        WHERE version.state IN ('ACTIVE', 'DRAINING')
        ORDER BY version.rule_version_id
    LOOP
        PERFORM pgreact.sweep_expired_leases(version_id);
    END LOOP;
    FOR candidate IN
        SELECT agenda.rule_version_id
        FROM pgreact_internal.agenda agenda
        JOIN pgreact_internal.rule_versions version USING (rule_version_id)
        WHERE agenda.state IN ('PENDING', 'RETRY_WAIT')
          AND agenda.available_at <= clock_timestamp()
          AND version.state IN ('ACTIVE', 'DRAINING')
          AND NOT EXISTS (
              SELECT 1 FROM pgreact_internal.rule_barriers barrier
              WHERE barrier.rule_version_id = agenda.rule_version_id)
          AND (agenda_groups IS NULL OR agenda.agenda_group = ANY(agenda_groups))
        ORDER BY CASE WHEN agenda.available_at <= clock_timestamp() - fairness
                      THEN 0 ELSE 1 END,
                 agenda.available_at, agenda.salience DESC, agenda.episode_id
    LOOP
        SELECT * INTO claimed
        FROM pgreact.claim_episode(candidate.rule_version_id, worker_id, seconds);
        IF FOUND THEN
            SELECT agenda.event_kind INTO event_kind
            FROM pgreact_internal.agenda agenda
            WHERE agenda.episode_id = claimed.episode_id;
            episode_id := claimed.episode_id;
            lease_token := claimed.lease_token;
            activation_id := claimed.activation_id;
            bindings := claimed.bindings;
            rule_version_id := candidate.rule_version_id;
            RETURN NEXT;
            count_claimed := count_claimed + 1;
            EXIT WHEN count_claimed >= max_items;
        END IF;
    END LOOP;
END
$v0433$;
-- Grant managed-worker access only to React-generated stream tables.
CREATE OR REPLACE FUNCTION pgreact_internal.m54_sync_grants(old_roles oid[] DEFAULT ARRAY[]::oid[])
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m54$
DECLARE
    author_oid oid;
    operator_oid oid;
    reader_oid oid;
    worker_oid oid;
    role_oid oid;
    stream_row record;
BEGIN
    SELECT application_role.role_oid INTO author_oid
    FROM pgreact_internal.application_roles AS application_role
    WHERE application_role.role_kind = 'author';
    SELECT application_role.role_oid INTO operator_oid
    FROM pgreact_internal.application_roles AS application_role
    WHERE application_role.role_kind = 'operator';
    SELECT application_role.role_oid INTO reader_oid
    FROM pgreact_internal.application_roles AS application_role
    WHERE application_role.role_kind = 'reader';
    SELECT application_role.role_oid INTO worker_oid
    FROM pgreact_internal.application_roles AS application_role
    WHERE application_role.role_kind = 'worker';
    FOREACH role_oid IN ARRAY COALESCE(old_roles, ARRAY[]::oid[]) LOOP
        CONTINUE WHEN role_oid IS NULL OR NOT EXISTS (SELECT 1 FROM pg_roles WHERE oid = role_oid);
        EXECUTE format('REVOKE EXECUTE ON FUNCTION pgreact_api.managed_cycle() FROM %I', role_oid::regrole::text);
        EXECUTE format('REVOKE ALL ON FUNCTION pgreact.review_token(jsonb), pgreact.deploy(pgreact_api.declaration,text,jsonb), pgreact_api.deploy(pgreact_api.declaration,text,jsonb), pgreact.reconcile_rule(text,text), pgreact.sweep_expired_leases(text), pgreact.requeue_episode(text,text) FROM %I', role_oid::regrole::text);
        FOR stream_row IN
            SELECT DISTINCT pg_catalog.to_regclass(version.match_name) AS relation
            FROM pgreact_internal.rule_versions AS version
            WHERE pg_catalog.to_regclass(version.match_name) IS NOT NULL
        LOOP
            EXECUTE format('REVOKE MAINTAIN ON TABLE %s FROM %I',
                           stream_row.relation, role_oid::regrole::text);
        END LOOP;
    END LOOP;
    IF worker_oid IS NOT NULL THEN
        EXECUTE format('GRANT EXECUTE ON FUNCTION pgreact_api.managed_cycle() TO %I', worker_oid::regrole::text);
        FOR stream_row IN
            SELECT DISTINCT pg_catalog.to_regclass(version.match_name) AS relation
            FROM pgreact_internal.rule_versions AS version
            WHERE pg_catalog.to_regclass(version.match_name) IS NOT NULL
        LOOP
            EXECUTE format('GRANT MAINTAIN ON TABLE %s TO %I',
                           stream_row.relation, worker_oid::regrole::text);
        END LOOP;
    END IF;
    IF author_oid IS NOT NULL THEN
        EXECUTE format('GRANT EXECUTE ON FUNCTION pgreact.review_token(jsonb), pgreact.deploy(pgreact_api.declaration,text,jsonb), pgreact_api.deploy(pgreact_api.declaration,text,jsonb), pgreact.validate(pgreact_api.declaration), pgreact.preview(pgreact_api.declaration,jsonb), pgreact.deploy(pgreact_api.declaration,jsonb), pgreact.export(text,text,text) TO %I', author_oid::regrole::text);
    END IF;
    IF reader_oid IS NOT NULL THEN
        EXECUTE format('GRANT EXECUTE ON FUNCTION pgreact.review_token(jsonb), pgreact.validate(pgreact_api.declaration), pgreact.export(text,text,text) TO %I', reader_oid::regrole::text);
    END IF;
    IF operator_oid IS NOT NULL THEN
        EXECUTE format('GRANT EXECUTE ON FUNCTION pgreact.reconcile_rule(text,text), pgreact.sweep_expired_leases(text), pgreact.requeue_episode(text,text) TO %I', operator_oid::regrole::text);
    END IF;
    FOREACH role_oid IN ARRAY ARRAY[author_oid, operator_oid, reader_oid] LOOP
        CONTINUE WHEN role_oid IS NULL;
        EXECUTE format('GRANT EXECUTE ON FUNCTION pgreact.compare(pgreact_api.declaration,pgreact_api.target,jsonb), pgreact.compare_results(pgreact_api.declaration,pgreact_api.target,jsonb), pgreact_internal.m54_read_rule_model(name,name,name,text,boolean,integer), pgreact_internal.m54_read_decision_model(name,name,name,name,name,name[],integer,text,integer), pgreact_internal.m54_decision_result(jsonb,name[]) TO %I', role_oid::regrole::text);
        EXECUTE format('GRANT EXECUTE ON FUNCTION pgreact_internal.m34_authoritative_checksum(), pgreact_internal.m34_delta(jsonb,jsonb), pgreact_internal.m34_raw_rows(jsonb,bigint,integer), pgreact_internal.m34_finding(text,text,text,text,text,text,jsonb) TO %I', role_oid::regrole::text);
    END LOOP;
END
$m54$;

-- Repair an already configured predecessor without changing its role mapping.
DO $maintenance$
BEGIN
    PERFORM pgreact_internal.m54_sync_grants();
END
$maintenance$;

-- Keep each generated stream owned by its author while delegating refresh
-- only to the currently configured managed worker.
CREATE OR REPLACE FUNCTION pgreact_internal.create_m0_stream(name text, query text)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m0$
DECLARE
    worker_oid oid;
    stream_relation regclass;
BEGIN
    PERFORM pgreact_internal.assert_m0_compatibility();
    PERFORM pgtrickle.create_stream_table(
        name => create_m0_stream.name,
        query => create_m0_stream.query,
        schedule => '1h',
        refresh_mode => 'DIFFERENTIAL',
        initialize => true
    );

    SELECT application_role.role_oid INTO worker_oid
    FROM pgreact_internal.application_roles AS application_role
    WHERE application_role.role_kind = 'worker';
    IF worker_oid IS NOT NULL THEN
        stream_relation := pg_catalog.to_regclass(name);
        EXECUTE format('GRANT MAINTAIN ON TABLE %s TO %I',
                       stream_relation, worker_oid::regrole::text);
    END IF;
END
$m0$;
