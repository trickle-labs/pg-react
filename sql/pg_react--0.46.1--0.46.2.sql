-- 0.46.2: qualify the worker parameter in M31's stale-scope withdrawal.
CREATE OR REPLACE FUNCTION pgreact.claim_episode(
    target_version_id uuid, worker_id text, lease_seconds integer DEFAULT 60)
RETURNS TABLE(episode_id bigint, lease_token uuid, activation_id uuid, bindings jsonb)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $m31$
DECLARE claimed record;
    episode pgreact_internal.agenda%ROWTYPE;
    rule_name text;
    scoped boolean;
    execution_time timestamptz;
BEGIN
    PERFORM pg_advisory_xact_lock_shared(5788046901200000);
    PERFORM pg_advisory_xact_lock(hashtextextended(
        'm31:rule:' || target_version_id::text, 5788046901200005));
    LOOP
        SELECT * INTO claimed
        FROM pgreact.claim_episode_m31_base(target_version_id, worker_id, lease_seconds);
        IF NOT FOUND THEN RETURN; END IF;
    SELECT agenda.* INTO STRICT episode
    FROM pgreact_internal.agenda agenda
    WHERE agenda.episode_id = claimed.episode_id
    FOR UPDATE;
    execution_time := clock_timestamp();
    SELECT rule.rule_name INTO rule_name
    FROM pgreact_internal.rules rule
    JOIN pgreact_internal.rule_versions version USING (rule_id)
    WHERE version.rule_version_id = episode.rule_version_id;
    SELECT EXISTS (
        SELECT 1
        FROM pgreact_internal.policy_set_members member
        JOIN pgreact_internal.policy_set_versions version
          USING (policy_set_version_id)
        WHERE member.member_kind = 'rule' AND member.member_name = rule_name
          AND member.scope_mode = 'POLICY_SET_REQUIRED'
          AND member.member_version IN ('1', target_version_id::text)
          AND version.state = 'DEPLOYED'
    ) INTO scoped;
    IF scoped AND NOT pgreact_internal.m31_has_effective_rule_support(
        episode.activation_id, rule_name, target_version_id, execution_time) THEN
        UPDATE pgreact_internal.agenda
        SET state = 'WITHDRAWN', completed_at = clock_timestamp(),
            lease_token = NULL, worker_id = NULL, lease_expires_at = NULL
        WHERE agenda.episode_id = claimed.episode_id
          AND agenda.state = 'LEASED'
          AND agenda.worker_id = claim_episode.worker_id
          AND agenda.lease_token = claimed.lease_token;
        IF FOUND THEN CONTINUE; END IF;
    END IF;
    RETURN QUERY SELECT claimed.episode_id, claimed.lease_token,
                        claimed.activation_id, claimed.bindings;
    RETURN;
    END LOOP;
END
$m31$;
