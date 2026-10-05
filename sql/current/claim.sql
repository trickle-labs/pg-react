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
