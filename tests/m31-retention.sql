\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';

CREATE SCHEMA m31_retention_reference;
CREATE TABLE m31_retention_reference.orders (
    order_id bigint PRIMARY KEY,
    customer_id bigint NOT NULL,
    label text NOT NULL
);
INSERT INTO m31_retention_reference.orders VALUES
    (100, 900, 'current'), (101, 901, 'current');
CREATE VIEW m31_retention_reference.orders_match AS
SELECT order_id, customer_id, label FROM m31_retention_reference.orders;
CREATE TABLE m31_retention_reference.customer_gate (customer_id bigint PRIMARY KEY);
INSERT INTO m31_retention_reference.customer_gate VALUES (902);

CREATE FUNCTION m31_retention_reference.activate(
    context pgreact.activation_context, match m31_retention_reference.orders_match)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    NULL;
END
$$;

DO $m31retention$
DECLARE member pgreact_api.declaration;
    policy_set pgreact_api.declaration;
    preview jsonb;
    deployed jsonb;
    configured jsonb;
    applied jsonb;
    rerun jsonb;
    family jsonb;
    target pgreact_api.target;
    rule_version uuid;
    set_version uuid;
    historical_activation uuid;
    historical_subject_identity bytea;
    historical_activate_event bigint;
    historical_deactivate_event bigint;
    historical_episode bigint;
    lease_token uuid;
    execution_result text;
    cutoff timestamptz;
    old_at timestamptz := clock_timestamp() - interval '2 hours';
    eligibility_before jsonb;
    supports_before jsonb;
    lifecycle_before jsonb;
    work_before jsonb;
    support_history_before jsonb;
    policy_history_before jsonb;
    support_history_after jsonb;
    policy_history_after jsonb;
    eligibility_after jsonb;
    supports_after jsonb;
    eligibility_retained jsonb;
    supports_retained jsonb;
    lifecycle_retained jsonb;
    work_retained jsonb;
    active_count bigint;
    eligible_count bigint;
    support_count bigint;
    current_lifecycle_count bigint;
    current_work_count bigint;
    barrier_count bigint;
    tombstone_count bigint;
BEGIN
    member := pgreact_api.declaration('rule', 'm31-retention-rule', jsonb_build_object(
        'condition', 'm31_retention_reference.orders_match', 'semantic_key', 'order_id',
        'kind', 'COMMAND', 'delegate', true,
        'on_activate', 'm31_retention_reference.activate(pgreact.activation_context,m31_retention_reference.orders_match)'));
    preview := pgreact_api.preview(member);
    IF preview ->> 'state' <> 'ready' THEN
        RAISE EXCEPTION 'M31 retention rule preview mismatch: %', preview;
    END IF;
    deployed := pgreact_api.deploy(member, jsonb_build_object(
        'preview_digest', preview -> 'summary' ->> 'preview_digest'));
    IF deployed ->> 'state' <> 'deployed' THEN
        RAISE EXCEPTION 'M31 retention rule deployment mismatch: %', deployed;
    END IF;
    SELECT delegated_id INTO rule_version
    FROM pgreact_internal.api_declarations
    WHERE kind = 'rule' AND object_name = 'm31-retention-rule' AND state = 'DEPLOYED';
    IF rule_version IS NULL THEN
        RAISE EXCEPTION 'M31 retention rule did not produce a deployed version';
    END IF;
    PERFORM pgreact.declare_batch_safe(rule_version, 'ACTIVATE');
    PERFORM pgreact_api.run_rule('m31-retention-rule');
    INSERT INTO m31_retention_reference.orders VALUES (102, 902, 'historical');
    PERFORM pgreact_api.run_rule('m31-retention-rule');

    policy_set := pgreact_api.declaration('policy_set', 'm31-retention-set', jsonb_build_object(
        'version', '1',
        'members', jsonb_build_array(jsonb_build_object(
            'kind', 'rule', 'name', 'm31-retention-rule', 'version', '1',
            'match_keys', jsonb_build_array('order_id'),
            'subject_keys', jsonb_build_array('customer_id'),
            'scope_mode', 'POLICY_SET_REQUIRED')),
        'applicability', jsonb_build_object(
            'source_kind', 'relation', 'relation', 'm31_retention_reference.customer_gate',
            'subject_keys', jsonb_build_array('customer_id')),
        'valid_from', '2026-01-01 00:00:00+00'));
    preview := pgreact_api.preview(policy_set);
    IF preview ->> 'state' <> 'ready'
       OR preview -> 'summary' ->> 'eligible_subject_count' <> '1' THEN
        RAISE EXCEPTION 'M31 retention policy-set preview mismatch: %', preview;
    END IF;
    deployed := pgreact_api.deploy(policy_set, jsonb_build_object(
        'preview_digest', preview -> 'summary' ->> 'preview_digest'));
    target := pgreact_api.target('policy_set', 'm31-retention-set', '1');
    SELECT version.policy_set_version_id INTO set_version
    FROM pgreact_internal.policy_set_versions version
    JOIN pgreact_internal.policy_sets set USING (policy_set_id)
    WHERE set.set_name = 'm31-retention-set' AND version.version = '1';
    IF set_version IS NULL OR deployed ->> 'state' <> 'deployed' THEN
        RAISE EXCEPTION 'M31 retention policy-set deployment mismatch: % / %',
            deployed, set_version;
    END IF;

    SELECT activation_id INTO historical_activation
    FROM pgreact_internal.activation_state
    WHERE rule_version_id = rule_version AND semantic_key = 102;
    SELECT episode_id INTO historical_episode
    FROM pgreact_internal.agenda
    WHERE rule_version_id = rule_version AND activation_id = historical_activation
      AND state = 'PENDING';
    IF historical_activation IS NULL OR historical_episode IS NULL THEN
        RAISE EXCEPTION 'M31 retention historical work setup mismatch: % / %',
            historical_activation, historical_episode;
    END IF;
    SELECT claim.lease_token INTO lease_token
    FROM pgreact.claim_episode(rule_version, 'm31-retention-worker', 60) claim
    WHERE claim.episode_id = historical_episode;
    IF lease_token IS NULL THEN
        RAISE EXCEPTION 'M31 retention historical work was not claimable';
    END IF;
    SELECT pgreact.execute_claimed_episode(
        historical_episode, 'm31-retention-worker', lease_token)
    INTO execution_result;
    IF execution_result <> 'COMPLETED' THEN
        RAISE EXCEPTION 'M31 retention historical work completion mismatch: %', execution_result;
    END IF;

    INSERT INTO m31_retention_reference.customer_gate VALUES (900), (901);
    PERFORM pgreact_api.run(target, clock_timestamp());
    DELETE FROM m31_retention_reference.customer_gate WHERE customer_id = 902;
    rerun := pgreact_api.run(target, clock_timestamp());
    IF rerun -> 'runtime' ->> 'runtime_state' <> 'AUTHORITATIVE' THEN
        RAISE EXCEPTION 'M31 retention historical transition was not authoritative: %', rerun;
    END IF;
    SELECT event_id INTO historical_activate_event
    FROM pgreact_internal.lifecycle_events
    WHERE rule_version_id = rule_version AND activation_id = historical_activation
      AND event_kind = 'ACTIVATE';
    SELECT event_id INTO historical_deactivate_event
    FROM pgreact_internal.lifecycle_events
    WHERE rule_version_id = rule_version AND activation_id = historical_activation
      AND event_kind = 'DEACTIVATE';
    SELECT subject_identity INTO historical_subject_identity
    FROM pgreact_internal.policy_set_scope_support_history
    WHERE policy_set_version_id = set_version AND event_kind = 'REMOVED'
    ORDER BY event_id DESC LIMIT 1;
    IF historical_activate_event IS NULL OR historical_deactivate_event IS NULL
       OR historical_subject_identity IS NULL THEN
        RAISE EXCEPTION 'M31 retention historical rows were not created: % / % / %',
            historical_activate_event, historical_deactivate_event,
            historical_subject_identity;
    END IF;

    UPDATE pgreact_internal.lifecycle_events
    SET transitioned_at = old_at
    WHERE event_id IN (historical_activate_event, historical_deactivate_event);
    UPDATE pgreact_internal.agenda
    SET available_at = old_at, completed_at = old_at
    WHERE episode_id = historical_episode AND state = 'COMPLETED';
    UPDATE pgreact_internal.executions
    SET started_at = old_at, finished_at = old_at
    WHERE episode_id = historical_episode;
    UPDATE pgreact_internal.policy_set_scope_support_history
    SET occurred_at = old_at
    WHERE policy_set_version_id = set_version
      AND subject_identity = historical_subject_identity;
    UPDATE pgreact_internal.policy_set_history
    SET occurred_at = old_at
    WHERE policy_set_version_id = set_version;

    SELECT count(*) INTO eligible_count
    FROM pgreact_internal.policy_set_eligibility
    WHERE policy_set_version_id = set_version;
    SELECT count(*) INTO support_count
    FROM pgreact_internal.policy_set_scope_supports
    WHERE policy_set_version_id = set_version;
    SELECT count(*) INTO active_count
    FROM pgreact_internal.activation_state
    WHERE rule_version_id = rule_version AND active;
    SELECT count(*) INTO current_lifecycle_count
    FROM pgreact_internal.lifecycle_events event
    JOIN pgreact_internal.activation_state activation
      ON activation.rule_version_id = event.rule_version_id
     AND activation.activation_id = event.activation_id
    WHERE event.rule_version_id = rule_version
      AND event.event_kind = 'ACTIVATE' AND activation.active;
    SELECT count(*) INTO current_work_count
    FROM pgreact_internal.agenda episode
    JOIN pgreact_internal.activation_state activation
      ON activation.rule_version_id = episode.rule_version_id
     AND activation.activation_id = episode.activation_id
     AND activation.generation = episode.activation_generation
    WHERE episode.rule_version_id = rule_version
      AND activation.active AND episode.state IN ('PENDING', 'LEASED');
    IF eligible_count <> 2 OR support_count <> 2 OR active_count <> 2
       OR current_lifecycle_count <> 2 OR current_work_count <> 2 THEN
        RAISE EXCEPTION 'M31 retention current authority setup mismatch: % / % / % / % / %',
            eligible_count, support_count, active_count,
            current_lifecycle_count, current_work_count;
    END IF;

    SELECT COALESCE(jsonb_agg(item.row_data), '[]'::jsonb)
    INTO eligibility_before
    FROM (
        SELECT jsonb_build_object(
            'subject_identity', encode(eligibility.subject_identity, 'hex'),
            'subject_values', eligibility.subject_values,
            'key_types', eligibility.key_types,
            'key_codec_version', eligibility.key_codec_version,
            'complete_frontier', eligibility.complete_frontier,
            'source_fingerprint', eligibility.source_fingerprint) AS row_data
        FROM pgreact_internal.policy_set_eligibility eligibility
        WHERE eligibility.policy_set_version_id = set_version
        ORDER BY encode(eligibility.subject_identity, 'hex')) item;
    SELECT COALESCE(jsonb_agg(item.row_data), '[]'::jsonb)
    INTO supports_before
    FROM (
        SELECT jsonb_build_object(
            'scope_support_id', support.scope_support_id,
            'match_identity', encode(support.match_identity, 'hex'),
            'subject_identity', encode(support.subject_identity, 'hex'),
            'subject_values', support.subject_values,
            'support_generation', support.support_generation,
            'complete_frontier', support.complete_frontier) AS row_data
        FROM pgreact_internal.policy_set_scope_supports support
        WHERE support.policy_set_version_id = set_version
        ORDER BY encode(support.match_identity, 'hex')) item;
    SELECT COALESCE(jsonb_agg(item.row_data), '[]'::jsonb)
    INTO lifecycle_before
    FROM (
        SELECT jsonb_build_object(
            'event_id', event.event_id, 'activation_id', event.activation_id,
            'generation', event.generation, 'event_kind', event.event_kind,
            'transitioned_at', event.transitioned_at,
            'old_bindings', event.old_bindings, 'new_bindings', event.new_bindings) AS row_data
        FROM pgreact_internal.lifecycle_events event
        JOIN pgreact_internal.activation_state activation
          ON activation.rule_version_id = event.rule_version_id
         AND activation.activation_id = event.activation_id
        WHERE event.rule_version_id = rule_version
          AND event.event_kind = 'ACTIVATE' AND activation.active
        ORDER BY event.event_id) item;
    SELECT COALESCE(jsonb_agg(item.row_data), '[]'::jsonb)
    INTO work_before
    FROM (
        SELECT jsonb_build_object(
            'episode_id', episode.episode_id, 'event_id', episode.event_id,
            'activation_id', episode.activation_id,
            'activation_generation', episode.activation_generation,
            'state', episode.state, 'new_bindings', episode.new_bindings,
            'completed_at', episode.completed_at) AS row_data
        FROM pgreact_internal.agenda episode
        JOIN pgreact_internal.activation_state activation
          ON activation.rule_version_id = episode.rule_version_id
         AND activation.activation_id = episode.activation_id
         AND activation.generation = episode.activation_generation
        WHERE episode.rule_version_id = rule_version
          AND activation.active AND episode.state IN ('PENDING', 'LEASED')
        ORDER BY episode.episode_id) item;
    SELECT COALESCE(jsonb_agg(item.row_data), '[]'::jsonb)
    INTO support_history_before
    FROM (
        SELECT jsonb_build_object(
            'event_id', history.event_id, 'scope_support_id', history.scope_support_id,
            'member_kind', history.member_kind, 'member_name', history.member_name,
            'member_version', history.member_version,
            'match_identity', encode(history.match_identity, 'hex'),
            'subject_identity', encode(history.subject_identity, 'hex'),
            'event_kind', history.event_kind, 'complete_frontier', history.complete_frontier,
            'details', history.details, 'occurred_at', history.occurred_at) AS row_data
        FROM pgreact_internal.policy_set_scope_support_history history
        WHERE history.policy_set_version_id = set_version
        ORDER BY history.event_id) item;
    SELECT COALESCE(jsonb_agg(item.row_data), '[]'::jsonb)
    INTO policy_history_before
    FROM (
        SELECT jsonb_build_object(
            'event_id', history.event_id, 'event_kind', history.event_kind,
            'frontier', history.frontier, 'details', history.details,
            'occurred_at', history.occurred_at) AS row_data
        FROM pgreact_internal.policy_set_history history
        WHERE history.policy_set_version_id = set_version
        ORDER BY history.event_id) item;
    IF jsonb_array_length(support_history_before) <> 4
       OR jsonb_array_length(policy_history_before) < 1 THEN
        RAISE EXCEPTION 'M31 retention history setup mismatch: % / %',
            support_history_before, policy_history_before;
    END IF;

    configured := pgreact_api.retention_configure(
        interval '1 hour', interval '1 hour', interval '1 hour', interval '1 hour',
        interval '1 hour', interval '1 hour', interval '1 hour', interval '1 hour', true);
    IF configured ->> 'enabled' <> 'true' THEN
        RAISE EXCEPTION 'M31 retention policy was not enabled: %', configured;
    END IF;
    cutoff := clock_timestamp() - interval '1 hour';
    preview := pgreact_api.retention_preview(cutoff, 2);
    IF preview ->> 'contract_version' <> '9'
       OR (preview -> 'totals' ->> 'eligible_rows')::bigint <> 2 THEN
        RAISE EXCEPTION 'M31 retention total preview mismatch: %', preview;
    END IF;
    SELECT item.value INTO family
    FROM jsonb_array_elements(preview -> 'families') item
    WHERE item.value ->> 'family' = 'executions';
    IF family IS NULL OR family ->> 'eligible_rows' <> '1'
       OR family ->> 'protected_rows' <> '0' THEN
        RAISE EXCEPTION 'M31 retention execution preview mismatch: %', family;
    END IF;
    SELECT item.value INTO family
    FROM jsonb_array_elements(preview -> 'families') item
    WHERE item.value ->> 'family' = 'agenda';
    IF family IS NULL OR family ->> 'eligible_rows' <> '0'
       OR family ->> 'protected_rows' <> '1'
       OR family -> 'blocking_reasons' ->> 'execution_reference' <> '1' THEN
        RAISE EXCEPTION 'M31 retention work-protection preview mismatch: %', family;
    END IF;
    SELECT item.value INTO family
    FROM jsonb_array_elements(preview -> 'families') item
    WHERE item.value ->> 'family' = 'lifecycle_events';
    IF family IS NULL OR family ->> 'eligible_rows' <> '1'
       OR family ->> 'protected_rows' <> '1'
       OR family -> 'blocking_reasons' ->> 'work_reference' <> '1' THEN
        RAISE EXCEPTION 'M31 retention lifecycle preview mismatch: %', family;
    END IF;
    IF EXISTS (
        SELECT 1 FROM jsonb_array_elements(preview -> 'families') item
        WHERE item.value ->> 'family' IN (
            'policy_set_scope_support_history', 'policy_set_history')) THEN
        RAISE EXCEPTION 'M31 retention preview claimed ownership of M31 history: %', preview;
    END IF;

    applied := pgreact_api.retention_apply(cutoff, 2);
    IF applied ->> 'outcome' <> 'completed'
       OR applied ->> 'removed_rows' <> '4'
       OR applied ->> 'remaining_eligible_rows' <> '0'
       OR applied -> 'family_counts' ->> 'executions' <> '1'
       OR applied -> 'family_counts' ->> 'agenda' <> '1'
       OR applied -> 'family_counts' ->> 'lifecycle_events' <> '2' THEN
        RAISE EXCEPTION 'M31 retention bounded apply mismatch: %', applied;
    END IF;
    SELECT count(*) INTO tombstone_count
    FROM pgreact_internal.retention_tombstones tombstone
    WHERE tombstone.batch_id = (applied ->> 'batch_id')::uuid
      AND tombstone.family IN ('executions', 'agenda', 'lifecycle_events');
    IF tombstone_count <> 4 THEN
        RAISE EXCEPTION 'M31 retention tombstone count mismatch: %', tombstone_count;
    END IF;
    IF EXISTS (SELECT 1 FROM pgreact_internal.executions WHERE episode_id = historical_episode)
       OR EXISTS (SELECT 1 FROM pgreact_internal.agenda WHERE episode_id = historical_episode)
       OR EXISTS (SELECT 1 FROM pgreact_internal.lifecycle_events
                  WHERE event_id IN (historical_activate_event, historical_deactivate_event)) THEN
        RAISE EXCEPTION 'M31 retention did not prune the aged historical lifecycle/work rows';
    END IF;

    SELECT COALESCE(jsonb_agg(item.row_data), '[]'::jsonb)
    INTO eligibility_retained
    FROM (
        SELECT jsonb_build_object(
            'subject_identity', encode(eligibility.subject_identity, 'hex'),
            'subject_values', eligibility.subject_values,
            'key_types', eligibility.key_types,
            'key_codec_version', eligibility.key_codec_version,
            'complete_frontier', eligibility.complete_frontier,
            'source_fingerprint', eligibility.source_fingerprint) AS row_data
        FROM pgreact_internal.policy_set_eligibility eligibility
        WHERE eligibility.policy_set_version_id = set_version
        ORDER BY encode(eligibility.subject_identity, 'hex')) item;
    SELECT COALESCE(jsonb_agg(item.row_data), '[]'::jsonb)
    INTO supports_retained
    FROM (
        SELECT jsonb_build_object(
            'scope_support_id', support.scope_support_id,
            'match_identity', encode(support.match_identity, 'hex'),
            'subject_identity', encode(support.subject_identity, 'hex'),
            'subject_values', support.subject_values,
            'support_generation', support.support_generation,
            'complete_frontier', support.complete_frontier) AS row_data
        FROM pgreact_internal.policy_set_scope_supports support
        WHERE support.policy_set_version_id = set_version
        ORDER BY encode(support.match_identity, 'hex')) item;
    SELECT COALESCE(jsonb_agg(item.row_data), '[]'::jsonb)
    INTO lifecycle_retained
    FROM (
        SELECT jsonb_build_object(
            'event_id', event.event_id, 'activation_id', event.activation_id,
            'generation', event.generation, 'event_kind', event.event_kind,
            'transitioned_at', event.transitioned_at,
            'old_bindings', event.old_bindings, 'new_bindings', event.new_bindings) AS row_data
        FROM pgreact_internal.lifecycle_events event
        JOIN pgreact_internal.activation_state activation
          ON activation.rule_version_id = event.rule_version_id
         AND activation.activation_id = event.activation_id
        WHERE event.rule_version_id = rule_version
          AND event.event_kind = 'ACTIVATE' AND activation.active
        ORDER BY event.event_id) item;
    SELECT COALESCE(jsonb_agg(item.row_data), '[]'::jsonb)
    INTO work_retained
    FROM (
        SELECT jsonb_build_object(
            'episode_id', episode.episode_id, 'event_id', episode.event_id,
            'activation_id', episode.activation_id,
            'activation_generation', episode.activation_generation,
            'state', episode.state, 'new_bindings', episode.new_bindings,
            'completed_at', episode.completed_at) AS row_data
        FROM pgreact_internal.agenda episode
        JOIN pgreact_internal.activation_state activation
          ON activation.rule_version_id = episode.rule_version_id
         AND activation.activation_id = episode.activation_id
         AND activation.generation = episode.activation_generation
        WHERE episode.rule_version_id = rule_version
          AND activation.active AND episode.state IN ('PENDING', 'LEASED')
        ORDER BY episode.episode_id) item;
    IF eligibility_retained IS DISTINCT FROM eligibility_before
       OR supports_retained IS DISTINCT FROM supports_before
       OR lifecycle_retained IS DISTINCT FROM lifecycle_before
       OR work_retained IS DISTINCT FROM work_before THEN
        RAISE EXCEPTION 'M31 retention changed current authoritative rows: % / % / % / % / % / % / % / %',
            eligibility_before, eligibility_retained,
            supports_before, supports_retained,
            lifecycle_before, lifecycle_retained,
            work_before, work_retained;
    END IF;

    SELECT COALESCE(jsonb_agg(item.row_data), '[]'::jsonb)
    INTO support_history_after
    FROM (
        SELECT jsonb_build_object(
            'event_id', history.event_id, 'scope_support_id', history.scope_support_id,
            'member_kind', history.member_kind, 'member_name', history.member_name,
            'member_version', history.member_version,
            'match_identity', encode(history.match_identity, 'hex'),
            'subject_identity', encode(history.subject_identity, 'hex'),
            'event_kind', history.event_kind, 'complete_frontier', history.complete_frontier,
            'details', history.details, 'occurred_at', history.occurred_at) AS row_data
        FROM pgreact_internal.policy_set_scope_support_history history
        WHERE history.policy_set_version_id = set_version
        ORDER BY history.event_id) item;
    SELECT COALESCE(jsonb_agg(item.row_data), '[]'::jsonb)
    INTO policy_history_after
    FROM (
        SELECT jsonb_build_object(
            'event_id', history.event_id, 'event_kind', history.event_kind,
            'frontier', history.frontier, 'details', history.details,
            'occurred_at', history.occurred_at) AS row_data
        FROM pgreact_internal.policy_set_history history
        WHERE history.policy_set_version_id = set_version
        ORDER BY history.event_id) item;
    IF support_history_after IS DISTINCT FROM support_history_before
       OR policy_history_after IS DISTINCT FROM policy_history_before THEN
        RAISE EXCEPTION 'M31 retention removed protected M31 history: % / %',
            support_history_before, support_history_after;
    END IF;
    IF (pgreact_api.retention_detail('lifecycle_events', historical_deactivate_event::text)
        -> 'diagnostic' ->> 'code') <> 'M21_HISTORY_NOT_RETAINED'
       OR (pgreact_api.retention_detail(
               'policy_set_scope_support_history',
               (SELECT event_id::text FROM pgreact_internal.policy_set_scope_support_history
                WHERE policy_set_version_id = set_version ORDER BY event_id LIMIT 1))
           -> 'diagnostic' ->> 'code') <> 'M21_RETENTION_FAMILY_UNKNOWN'
       OR (pgreact_api.retention_detail(
               'policy_set_history',
               (SELECT event_id::text FROM pgreact_internal.policy_set_history
                WHERE policy_set_version_id = set_version ORDER BY event_id LIMIT 1))
           -> 'diagnostic' ->> 'code') <> 'M21_RETENTION_FAMILY_UNKNOWN' THEN
        RAISE EXCEPTION 'M31 retention detail contract mismatch';
    END IF;

    configured := pgreact_api.retention_remove();
    IF configured ->> 'enabled' <> 'false' THEN
        RAISE EXCEPTION 'M31 retention cleanup mismatch: %', configured;
    END IF;
    rerun := pgreact_api.run(target, clock_timestamp());
    SELECT count(*) INTO eligible_count
    FROM pgreact_internal.policy_set_eligibility
    WHERE policy_set_version_id = set_version;
    SELECT count(*) INTO support_count
    FROM pgreact_internal.policy_set_scope_supports
    WHERE policy_set_version_id = set_version;
    SELECT count(*) INTO active_count
    FROM pgreact_internal.activation_state
    WHERE rule_version_id = rule_version AND active;
    SELECT count(*) INTO current_work_count
    FROM pgreact_internal.agenda episode
    JOIN pgreact_internal.activation_state activation
      ON activation.rule_version_id = episode.rule_version_id
     AND activation.activation_id = episode.activation_id
     AND activation.generation = episode.activation_generation
    WHERE episode.rule_version_id = rule_version
      AND activation.active AND episode.state IN ('PENDING', 'LEASED');
    SELECT count(*) INTO barrier_count
    FROM pgreact_internal.policy_set_runtime_barriers
    WHERE policy_set_version_id = set_version AND cleared_at IS NULL;
    SELECT COALESCE(jsonb_agg(item.subject_values), '[]'::jsonb)
    INTO eligibility_after
    FROM (
        SELECT eligibility.subject_values
        FROM pgreact_internal.policy_set_eligibility eligibility
        WHERE eligibility.policy_set_version_id = set_version
        ORDER BY eligibility.subject_values::text) item;
    SELECT COALESCE(jsonb_agg(item.subject_values), '[]'::jsonb)
    INTO supports_after
    FROM (
        SELECT support.subject_values
        FROM pgreact_internal.policy_set_scope_supports support
        WHERE support.policy_set_version_id = set_version
        ORDER BY support.subject_values::text) item;
    IF rerun -> 'runtime' ->> 'runtime_state' <> 'AUTHORITATIVE'
       OR eligible_count <> 2 OR support_count <> 2 OR active_count <> 2
       OR current_work_count <> 2 OR barrier_count <> 0
       OR eligibility_after IS DISTINCT FROM '[[900], [901]]'::jsonb
       OR supports_after IS DISTINCT FROM '[[900], [901]]'::jsonb THEN
        RAISE EXCEPTION 'M31 retention post-apply reconciliation mismatch: % / % / % / % / % / % / % / %',
            rerun, eligible_count, support_count, active_count, current_work_count,
            barrier_count, eligibility_after, supports_after;
    END IF;
    RAISE NOTICE 'M31 retention interaction passed: bounded apply preserved current policy-set authority and reconciliation restored AUTHORITATIVE state';
END
$m31retention$;
