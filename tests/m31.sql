\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';

CREATE SCHEMA m31_reference;
CREATE TABLE m31_reference.orders (
    order_id bigint PRIMARY KEY,
    customer_id bigint NOT NULL,
    label text NOT NULL
);
INSERT INTO m31_reference.orders VALUES
    (100, 10, 'review'), (200, 20, 'review');
CREATE VIEW m31_reference.orders_match AS
SELECT order_id, customer_id, label FROM m31_reference.orders;
CREATE TABLE m31_reference.customer_gate (customer_id bigint PRIMARY KEY);
INSERT INTO m31_reference.customer_gate VALUES (10);
CREATE TABLE m31_reference.blocked_gate (customer_id bigint PRIMARY KEY);
INSERT INTO m31_reference.blocked_gate VALUES (20);

DO $m31$
DECLARE member pgreact_api.declaration;
    policy_set pgreact_api.declaration;
    member_preview jsonb;
    set_preview jsonb;
    deployed jsonb;
    status jsonb;
    refreshed jsonb;
    active_count bigint;
    support_count bigint;
    inactive_count bigint;
    generation bigint;
    sample_now timestamptz := clock_timestamp();
    expired jsonb;
    not_due jsonb;
    blocked jsonb;
    barrier_code text;
    removed jsonb;
    inspection jsonb;
    checksum_before text;
    checksum_after text;
    blocked_checksum_before text;
    blocked_checksum_after text;
    frontier_before timestamptz;
    frontier_after timestamptz;
BEGIN
    member := pgreact_api.declaration('rule', 'm31-order-rule', jsonb_build_object(
        'condition', 'm31_reference.orders_match', 'semantic_key', 'order_id',
        'kind', 'CONSTRAINT', 'delegate', true));
    member_preview := pgreact_api.preview(member);
    deployed := pgreact_api.deploy(member, jsonb_build_object(
        'preview_digest', member_preview -> 'summary' ->> 'preview_digest'));
    IF deployed ->> 'state' <> 'deployed' THEN
        RAISE EXCEPTION 'M31 rule adapter did not deploy: %', deployed;
    END IF;

    policy_set := pgreact_api.declaration('policy_set', 'm31-customers', jsonb_build_object(
        'version', '1',
        'members', jsonb_build_array(jsonb_build_object(
            'kind', 'rule', 'name', 'm31-order-rule', 'version', '1',
            'match_keys', jsonb_build_array('order_id'),
            'subject_keys', jsonb_build_array('customer_id'),
            'scope_mode', 'POLICY_SET_REQUIRED')),
        'applicability', jsonb_build_object(
            'source_kind', 'relation', 'relation', 'm31_reference.customer_gate',
            'subject_keys', jsonb_build_array('customer_id')),
        'valid_from', '2026-01-01 00:00:00+00', 'evidence_limit', 10));
    set_preview := pgreact_api.preview(policy_set);
    IF set_preview ->> 'state' <> 'ready'
       OR set_preview -> 'summary' ->> 'eligible_subject_count' <> '1' THEN
        RAISE EXCEPTION 'M31 policy-set preview mismatch: %', set_preview;
    END IF;
    deployed := pgreact_api.deploy(policy_set, jsonb_build_object(
        'preview_digest', set_preview -> 'summary' ->> 'preview_digest'));
    status := pgreact_api.status(pgreact_api.target('policy_set', 'm31-customers', '1'));
    SELECT count(*) INTO active_count
    FROM pgreact.activations activation
    JOIN pgreact.rules rule USING (rule_version_id)
    WHERE rule.rule_name = 'm31-order-rule' AND activation.active;
    SELECT count(*) INTO inactive_count
    FROM pgreact.activations activation
    JOIN pgreact.rules rule USING (rule_version_id)
    WHERE rule.rule_name = 'm31-order-rule' AND NOT activation.active;
    SELECT count(*) INTO support_count FROM pgreact.policy_set_scope_supports
    WHERE set_name = 'm31-customers';
    IF deployed -> 'runtime' ->> 'runtime_state' <> 'AUTHORITATIVE'
       OR status -> 'summary' ->> 'runtime_state' <> 'AUTHORITATIVE'
       OR active_count <> 1 OR inactive_count <> 1 OR support_count <> 1 THEN
        RAISE EXCEPTION 'M31 initial gating mismatch: % / % / % / %',
            deployed, status, active_count, support_count;
    END IF;

    INSERT INTO m31_reference.customer_gate VALUES (20);
    refreshed := pgreact_api.run(
        pgreact_api.target('policy_set', 'm31-customers', '1'),
        '2026-02-01 00:00:00+00');
    IF refreshed ->> 'scope' <> 'global'
       OR refreshed -> 'target' ->> 'kind' <> 'policy_set'
       OR refreshed -> 'clock' ->> 'sampled_time' <> '2026-02-01T00:00:00+00:00'
       OR refreshed ->> 'frontier' IS NULL
       OR refreshed -> 'frontier_invariant' ->> 'frontier'
          IS DISTINCT FROM refreshed ->> 'frontier'
       OR jsonb_array_length(refreshed -> 'policy_sets') <> 1 THEN
        RAISE EXCEPTION 'M31 target run did not report one global sampled frontier: %', refreshed;
    END IF;
    SELECT count(*) INTO active_count
    FROM pgreact.activations activation
    JOIN pgreact.rules rule USING (rule_version_id)
    WHERE rule.rule_name = 'm31-order-rule' AND activation.active;
    SELECT count(*) INTO support_count FROM pgreact.policy_set_scope_supports
    WHERE set_name = 'm31-customers';
    IF refreshed -> 'runtime' ->> 'runtime_state' <> 'AUTHORITATIVE'
       OR active_count <> 2 OR support_count <> 2 THEN
        RAISE EXCEPTION 'M31 eligibility entry mismatch: % / % / %',
            refreshed, active_count, support_count;
    END IF;

    DELETE FROM m31_reference.customer_gate WHERE customer_id = 10;
    PERFORM pgreact_api.run(
        pgreact_api.target('policy_set', 'm31-customers', '1'),
        '2026-03-01 00:00:00+00');
    SELECT count(*) INTO active_count
    FROM pgreact.activations activation
    JOIN pgreact.rules rule USING (rule_version_id)
    WHERE rule.rule_name = 'm31-order-rule' AND activation.active;
    SELECT count(*) INTO support_count FROM pgreact.policy_set_scope_supports
    WHERE set_name = 'm31-customers';
    IF active_count <> 1 OR support_count <> 1 THEN
        RAISE EXCEPTION 'M31 eligibility exit mismatch: % / %', active_count, support_count;
    END IF;

    policy_set := pgreact_api.declaration('policy_set', 'm31-customers-2', jsonb_build_object(
        'version', '1',
        'members', jsonb_build_array(jsonb_build_object(
            'kind', 'rule', 'name', 'm31-order-rule', 'version', '1',
            'match_keys', jsonb_build_array('order_id'),
            'subject_keys', jsonb_build_array('customer_id'),
            'scope_mode', 'POLICY_SET_REQUIRED')),
        'applicability', jsonb_build_object(
            'source_kind', 'relation', 'relation', 'm31_reference.customer_gate',
            'subject_keys', jsonb_build_array('customer_id')),
        'valid_from', '2026-01-01 00:00:00+00'));
    set_preview := pgreact_api.preview(policy_set);
    PERFORM pgreact_api.deploy(policy_set, jsonb_build_object(
        'preview_digest', set_preview -> 'summary' ->> 'preview_digest'));
    SELECT count(*) INTO active_count
    FROM pgreact.activations activation
    JOIN pgreact.rules rule USING (rule_version_id)
    WHERE rule.rule_name = 'm31-order-rule' AND activation.active;
    SELECT count(*) INTO support_count FROM pgreact.policy_set_scope_supports
    WHERE member_name = 'm31-order-rule' AND activation_id IS NOT NULL;
    IF active_count <> 1 OR support_count <> 2 THEN
        RAISE EXCEPTION 'M31 overlapping-set mismatch: % / %', active_count, support_count;
    END IF;

    DELETE FROM m31_reference.orders WHERE order_id = 200;
    PERFORM pgreact_api.run(
        pgreact_api.target('policy_set', 'm31-customers-2', '1'), clock_timestamp());
    SELECT count(*) INTO active_count
    FROM pgreact.activations activation
    JOIN pgreact.rules rule USING (rule_version_id)
    WHERE rule.rule_name = 'm31-order-rule' AND activation.active;
    SELECT count(*) INTO support_count
    FROM pgreact.policy_set_scope_supports
    WHERE member_name = 'm31-order-rule';
    IF active_count <> 0 OR support_count <> 0 THEN
        RAISE EXCEPTION 'M31 disappeared-match mismatch: % / %', active_count, support_count;
    END IF;
    INSERT INTO m31_reference.orders VALUES (200, 20, 'review');
    PERFORM pgreact_api.run(
        pgreact_api.target('policy_set', 'm31-customers-2', '1'), clock_timestamp());
    SELECT count(*) INTO active_count
    FROM pgreact.activations activation
    JOIN pgreact.rules rule USING (rule_version_id)
    WHERE rule.rule_name = 'm31-order-rule' AND activation.active;
    SELECT count(*) INTO support_count
    FROM pgreact.policy_set_scope_supports
    WHERE member_name = 'm31-order-rule';
    IF active_count <> 1 OR support_count <> 2 THEN
        RAISE EXCEPTION 'M31 disappeared-match reentry mismatch: % / %', active_count, support_count;
    END IF;

    SELECT encode(sha256(convert_to(COALESCE(string_agg(row_data, E'\n'
        ORDER BY row_data), ''), 'UTF8')), 'hex')
    INTO checksum_before
    FROM (
        SELECT 'policy_version:' || to_jsonb(psv)::text AS row_data
        FROM pgreact_internal.policy_set_versions psv
        JOIN pgreact_internal.policy_sets ps USING (policy_set_id)
        WHERE ps.set_name IN ('m31-customers', 'm31-customers-2')
        UNION ALL
        SELECT 'member:' || to_jsonb(psm)::text
        FROM pgreact_internal.policy_set_members psm
        JOIN pgreact_internal.policy_set_versions psv USING (policy_set_version_id)
        JOIN pgreact_internal.policy_sets ps USING (policy_set_id)
        WHERE ps.set_name IN ('m31-customers', 'm31-customers-2')
        UNION ALL
        SELECT 'eligibility:' || to_jsonb(pse)::text AS row_data
        FROM pgreact_internal.policy_set_eligibility pse
        JOIN pgreact_internal.policy_set_versions psv USING (policy_set_version_id)
        JOIN pgreact_internal.policy_sets ps USING (policy_set_id)
        WHERE ps.set_name = 'm31-customers'
        UNION ALL
        SELECT 'support:' || to_jsonb(pss)::text
        FROM pgreact_internal.policy_set_scope_supports pss
        JOIN pgreact_internal.policy_set_versions psv USING (policy_set_version_id)
        JOIN pgreact_internal.policy_sets ps USING (policy_set_id)
        WHERE ps.set_name IN ('m31-customers', 'm31-customers-2')
        UNION ALL
        SELECT 'support_history:' || to_jsonb(psh)::text
        FROM pgreact_internal.policy_set_scope_support_history psh
        JOIN pgreact_internal.policy_set_versions psv USING (policy_set_version_id)
        JOIN pgreact_internal.policy_sets ps USING (policy_set_id)
        WHERE ps.set_name IN ('m31-customers', 'm31-customers-2')
        UNION ALL
        SELECT 'activation:' || to_jsonb(act)::text
        FROM pgreact_internal.activation_state act
        JOIN pgreact_internal.rule_versions rv USING (rule_version_id)
        JOIN pgreact_internal.rules r USING (rule_id)
        WHERE r.rule_name = 'm31-order-rule'
        UNION ALL
        SELECT 'lifecycle:' || to_jsonb(le)::text
        FROM pgreact_internal.lifecycle_events le
        JOIN pgreact_internal.rules r USING (rule_id)
        WHERE r.rule_name = 'm31-order-rule'
        UNION ALL
        SELECT 'agenda:' || to_jsonb(ag)::text
        FROM pgreact_internal.agenda ag
        JOIN pgreact_internal.rules r USING (rule_id)
        WHERE r.rule_name = 'm31-order-rule'
    ) state_rows;
    PERFORM pgreact_api.validate(policy_set);
    PERFORM pgreact_api.preview(policy_set);
    PERFORM pgreact_api.status(pgreact_api.target('policy_set', 'm31-customers', '1'));
    PERFORM pgreact_api.explain(
        pgreact_api.target('policy_set', 'm31-customers', '1'),
        jsonb_build_object('customer_id', 20));
    PERFORM pgreact_api.doctor(pgreact_api.target('policy_set', 'm31-customers', '1'));
    SELECT encode(sha256(convert_to(COALESCE(string_agg(row_data, E'\n'
        ORDER BY row_data), ''), 'UTF8')), 'hex')
    INTO checksum_after
    FROM (
        SELECT 'policy_version:' || to_jsonb(psv)::text AS row_data
        FROM pgreact_internal.policy_set_versions psv
        JOIN pgreact_internal.policy_sets ps USING (policy_set_id)
        WHERE ps.set_name IN ('m31-customers', 'm31-customers-2')
        UNION ALL
        SELECT 'member:' || to_jsonb(psm)::text
        FROM pgreact_internal.policy_set_members psm
        JOIN pgreact_internal.policy_set_versions psv USING (policy_set_version_id)
        JOIN pgreact_internal.policy_sets ps USING (policy_set_id)
        WHERE ps.set_name IN ('m31-customers', 'm31-customers-2')
        UNION ALL
        SELECT 'eligibility:' || to_jsonb(pse)::text AS row_data
        FROM pgreact_internal.policy_set_eligibility pse
        JOIN pgreact_internal.policy_set_versions psv USING (policy_set_version_id)
        JOIN pgreact_internal.policy_sets ps USING (policy_set_id)
        WHERE ps.set_name = 'm31-customers'
        UNION ALL
        SELECT 'support:' || to_jsonb(pss)::text
        FROM pgreact_internal.policy_set_scope_supports pss
        JOIN pgreact_internal.policy_set_versions psv USING (policy_set_version_id)
        JOIN pgreact_internal.policy_sets ps USING (policy_set_id)
        WHERE ps.set_name IN ('m31-customers', 'm31-customers-2')
        UNION ALL
        SELECT 'support_history:' || to_jsonb(psh)::text
        FROM pgreact_internal.policy_set_scope_support_history psh
        JOIN pgreact_internal.policy_set_versions psv USING (policy_set_version_id)
        JOIN pgreact_internal.policy_sets ps USING (policy_set_id)
        WHERE ps.set_name IN ('m31-customers', 'm31-customers-2')
        UNION ALL
        SELECT 'activation:' || to_jsonb(act)::text
        FROM pgreact_internal.activation_state act
        JOIN pgreact_internal.rule_versions rv USING (rule_version_id)
        JOIN pgreact_internal.rules r USING (rule_id)
        WHERE r.rule_name = 'm31-order-rule'
        UNION ALL
        SELECT 'lifecycle:' || to_jsonb(le)::text
        FROM pgreact_internal.lifecycle_events le
        JOIN pgreact_internal.rules r USING (rule_id)
        WHERE r.rule_name = 'm31-order-rule'
        UNION ALL
        SELECT 'agenda:' || to_jsonb(ag)::text
        FROM pgreact_internal.agenda ag
        JOIN pgreact_internal.rules r USING (rule_id)
        WHERE r.rule_name = 'm31-order-rule'
    ) state_rows;
    IF checksum_before IS DISTINCT FROM checksum_after THEN
        RAISE EXCEPTION 'M31 read-only façade changed authoritative state: % / %',
            checksum_before, checksum_after;
    END IF;

    CREATE TABLE m31_reference.multi_orders (
        order_id bigint PRIMARY KEY, customer_id bigint NOT NULL, region text NOT NULL);
    CREATE VIEW m31_reference.multi_orders_match AS
    SELECT order_id, customer_id, region FROM m31_reference.multi_orders;
    INSERT INTO m31_reference.multi_orders VALUES (300, 10, 'north');
    CREATE TABLE m31_reference.multi_gate (
        customer_id bigint NOT NULL, region text NOT NULL,
        PRIMARY KEY (customer_id, region));
    INSERT INTO m31_reference.multi_gate VALUES (10, 'north');
    member := pgreact_api.declaration('rule', 'm31-multi-rule', jsonb_build_object(
        'condition', 'm31_reference.multi_orders_match', 'semantic_key', 'order_id',
        'kind', 'CONSTRAINT', 'delegate', true));
    member_preview := pgreact_api.preview(member);
    PERFORM pgreact_api.deploy(member, jsonb_build_object(
        'preview_digest', member_preview -> 'summary' ->> 'preview_digest'));
    policy_set := pgreact_api.declaration('policy_set', 'm31-multi-scope', jsonb_build_object(
        'version', '1',
        'members', jsonb_build_array(jsonb_build_object(
            'kind', 'rule', 'name', 'm31-multi-rule', 'version', '1',
            'match_keys', jsonb_build_array('order_id'),
            'subject_keys', jsonb_build_array('customer_id', 'region'),
            'scope_mode', 'POLICY_SET_REQUIRED')),
        'applicability', jsonb_build_object(
            'source_kind', 'relation', 'relation', 'm31_reference.multi_gate',
            'subject_keys', jsonb_build_array('customer_id', 'region')),
        'valid_from', '2026-01-01 00:00:00+00'));
    set_preview := pgreact_api.preview(policy_set);
    PERFORM pgreact_api.deploy(policy_set, jsonb_build_object(
        'preview_digest', set_preview -> 'summary' ->> 'preview_digest'));
    inspection := pgreact_api.explain(
        pgreact_api.target('policy_set', 'm31-multi-scope', '1'),
        jsonb_build_object('customer_id', 10, 'region', 'north'));
    IF inspection -> 'evidence' ->> 'effective_match' <> 'true'
       OR pgreact_api.explain(
              pgreact_api.target('policy_set', 'm31-multi-scope', '1'),
              jsonb_build_object('customer_id', 10, 'region', 'south'))
              -> 'evidence' ->> 'effective_match' <> 'false' THEN
        RAISE EXCEPTION 'M31 multi-key explanation mismatch: %', inspection;
    END IF;

    member := pgreact_api.declaration('rule', 'm31-expiring-rule', jsonb_build_object(
        'condition', 'm31_reference.orders_match', 'semantic_key', 'order_id',
        'kind', 'CONSTRAINT', 'delegate', true));
    member_preview := pgreact_api.preview(member);
    PERFORM pgreact_api.deploy(member, jsonb_build_object(
        'preview_digest', member_preview -> 'summary' ->> 'preview_digest'));
    policy_set := pgreact_api.declaration('policy_set', 'm31-expiring', jsonb_build_object(
        'version', '1',
        'members', jsonb_build_array(jsonb_build_object(
            'kind', 'rule', 'name', 'm31-expiring-rule', 'version', '1',
            'match_keys', jsonb_build_array('order_id'),
            'subject_keys', jsonb_build_array('customer_id'),
            'scope_mode', 'POLICY_SET_REQUIRED')),
        'applicability', jsonb_build_object(
            'source_kind', 'relation', 'relation', 'm31_reference.customer_gate',
            'subject_keys', jsonb_build_array('customer_id')),
        'valid_from', sample_now - interval '1 day',
        'valid_to', sample_now + interval '1 day'));
    set_preview := pgreact_api.preview(policy_set);
    PERFORM pgreact_api.deploy(policy_set, jsonb_build_object(
        'preview_digest', set_preview -> 'summary' ->> 'preview_digest'));
    SELECT count(*) INTO active_count
    FROM pgreact.activations activation
    JOIN pgreact.rules rule USING (rule_version_id)
    WHERE rule.rule_name = 'm31-expiring-rule' AND activation.active;
    IF active_count <> 1 THEN
        RAISE EXCEPTION 'M31 expiry setup mismatch: %', active_count;
    END IF;
    SELECT pgreact_internal.m31_expire_policy_set(
               version.policy_set_version_id, sample_now)
    INTO not_due
    FROM pgreact_internal.policy_set_versions version
    JOIN pgreact_internal.policy_sets set USING (policy_set_id)
    WHERE set.set_name = 'm31-expiring' AND version.version = '1';
    SELECT count(*) INTO support_count
    FROM pgreact.policy_set_scope_supports
    WHERE set_name = 'm31-expiring';
    IF not_due ->> 'runtime_state' <> 'BLOCKED'
       OR not_due ->> 'reason' <> 'expiry_not_due'
       OR support_count <> 1 THEN
        RAISE EXCEPTION 'M31 premature expiry mutated authoritative state: % / %',
            not_due, support_count;
    END IF;
    expired := pgreact_api.run(
        pgreact_api.target('policy_set', 'm31-expiring', '1'),
        sample_now + interval '2 days');
    SELECT count(*) INTO active_count
    FROM pgreact.activations activation
    JOIN pgreact.rules rule USING (rule_version_id)
    WHERE rule.rule_name = 'm31-expiring-rule' AND activation.active;
    SELECT count(*) INTO support_count
    FROM pgreact.policy_set_scope_supports
    WHERE set_name = 'm31-expiring';
    IF expired -> 'runtime' ->> 'runtime_state' <> 'AUTHORITATIVE'
       OR active_count <> 0 OR support_count <> 0 THEN
        RAISE EXCEPTION 'M31 expiry mismatch: % / % / %', expired, active_count, support_count;
    END IF;
    PERFORM pgreact_api.run(
        pgreact_api.target('policy_set', 'm31-expiring', '1'), sample_now);
    SELECT activation.generation INTO generation
    FROM pgreact_internal.activation_state activation
    JOIN pgreact_internal.rules rule ON rule.rule_id = (
        SELECT rule_id FROM pgreact_internal.rule_versions version
        WHERE version.rule_version_id = activation.rule_version_id)
    WHERE rule.rule_name = 'm31-expiring-rule' AND activation.active;
    IF generation <> 2 THEN
        RAISE EXCEPTION 'M31 reentry generation mismatch: %', generation;
    END IF;
    removed := pgreact_api.remove(pgreact_api.target('policy_set', 'm31-expiring', '1'));
    SELECT count(*) INTO active_count
    FROM pgreact.activations activation
    JOIN pgreact.rules rule USING (rule_version_id)
    WHERE rule.rule_name = 'm31-expiring-rule' AND activation.active;
    SELECT count(*) INTO support_count
    FROM pgreact.policy_set_scope_supports
    WHERE set_name = 'm31-expiring';
    IF removed ->> 'state' <> 'removed' OR active_count <> 1 OR support_count <> 0 THEN
        RAISE EXCEPTION 'M31 removal mismatch: % / % / %', removed, active_count, support_count;
    END IF;

    member := pgreact_api.declaration('rule', 'm31-blocked-rule', jsonb_build_object(
        'condition', 'm31_reference.orders_match', 'semantic_key', 'order_id',
        'kind', 'CONSTRAINT', 'delegate', true));
    member_preview := pgreact_api.preview(member);
    PERFORM pgreact_api.deploy(member, jsonb_build_object(
        'preview_digest', member_preview -> 'summary' ->> 'preview_digest'));
    policy_set := pgreact_api.declaration('policy_set', 'm31-blocked', jsonb_build_object(
        'version', '1',
        'members', jsonb_build_array(jsonb_build_object(
            'kind', 'rule', 'name', 'm31-blocked-rule', 'version', '1',
            'match_keys', jsonb_build_array('order_id'),
            'subject_keys', jsonb_build_array('customer_id'),
            'scope_mode', 'POLICY_SET_REQUIRED')),
        'applicability', jsonb_build_object(
            'source_kind', 'relation', 'relation', 'm31_reference.blocked_gate',
            'subject_keys', jsonb_build_array('customer_id')),
        'valid_from', sample_now - interval '1 day'));
    set_preview := pgreact_api.preview(policy_set);
    PERFORM pgreact_api.deploy(policy_set, jsonb_build_object(
        'preview_digest', set_preview -> 'summary' ->> 'preview_digest'));
    SELECT version.complete_frontier INTO frontier_before
    FROM pgreact_internal.policy_set_versions version
    JOIN pgreact_internal.policy_sets set USING (policy_set_id)
    WHERE set.set_name = 'm31-blocked' AND version.version = '1';
    SELECT encode(sha256(convert_to(COALESCE(string_agg(row_data, E'\n'
        ORDER BY row_data), ''), 'UTF8')), 'hex')
    INTO blocked_checksum_before
    FROM (
        SELECT 'eligibility:' || to_jsonb(eligibility)::text AS row_data
        FROM pgreact_internal.policy_set_eligibility eligibility
        JOIN pgreact_internal.policy_set_versions version
          USING (policy_set_version_id)
        JOIN pgreact_internal.policy_sets set USING (policy_set_id)
        WHERE set.set_name = 'm31-blocked'
        UNION ALL
        SELECT 'support:' || to_jsonb(support)::text
        FROM pgreact_internal.policy_set_scope_supports support
        JOIN pgreact_internal.policy_set_versions version
          USING (policy_set_version_id)
        JOIN pgreact_internal.policy_sets set USING (policy_set_id)
        WHERE set.set_name = 'm31-blocked'
    ) state_rows;
    DROP TABLE m31_reference.blocked_gate;
    blocked := pgreact_api.run(
        pgreact_api.target('policy_set', 'm31-blocked', '1'), sample_now);
    status := pgreact_api.status(pgreact_api.target('policy_set', 'm31-blocked', '1'));
    SELECT count(*) INTO support_count
    FROM pgreact.policy_set_scope_supports
    WHERE set_name = 'm31-blocked';
    SELECT count(*) INTO active_count
    FROM pgreact.activations activation
    JOIN pgreact.rules rule USING (rule_version_id)
    WHERE rule.rule_name = 'm31-blocked-rule' AND activation.active;
    SELECT version.complete_frontier INTO frontier_after
    FROM pgreact_internal.policy_set_versions version
    JOIN pgreact_internal.policy_sets set USING (policy_set_id)
    WHERE set.set_name = 'm31-blocked' AND version.version = '1';
    SELECT encode(sha256(convert_to(COALESCE(string_agg(row_data, E'\n'
        ORDER BY row_data), ''), 'UTF8')), 'hex')
    INTO blocked_checksum_after
    FROM (
        SELECT 'eligibility:' || to_jsonb(eligibility)::text AS row_data
        FROM pgreact_internal.policy_set_eligibility eligibility
        JOIN pgreact_internal.policy_set_versions version
          USING (policy_set_version_id)
        JOIN pgreact_internal.policy_sets set USING (policy_set_id)
        WHERE set.set_name = 'm31-blocked'
        UNION ALL
        SELECT 'support:' || to_jsonb(support)::text
        FROM pgreact_internal.policy_set_scope_supports support
        JOIN pgreact_internal.policy_set_versions version
          USING (policy_set_version_id)
        JOIN pgreact_internal.policy_sets set USING (policy_set_id)
        WHERE set.set_name = 'm31-blocked'
    ) state_rows;
    IF blocked -> 'runtime' ->> 'runtime_state' <> 'BLOCKED'
       OR status -> 'summary' ->> 'runtime_state' <> 'BLOCKED'
       OR active_count <> 1 OR support_count <> 1
       OR blocked_checksum_after IS DISTINCT FROM blocked_checksum_before
       OR frontier_after IS DISTINCT FROM frontier_before THEN
        RAISE EXCEPTION 'M31 barrier/atomicity preservation mismatch: % / % / % / % / % / % / % / %',
            blocked, status, active_count, support_count,
            blocked_checksum_before, blocked_checksum_after,
            frontier_before, frontier_after;
    END IF;

    CREATE TABLE m31_reference.rls_gate (subject bigint PRIMARY KEY);
    INSERT INTO m31_reference.rls_gate VALUES (20);
    policy_set := pgreact_api.declaration('policy_set', 'm31-rls', jsonb_build_object(
        'version', '1',
        'members', jsonb_build_array(jsonb_build_object(
            'kind', 'rule', 'name', 'm31-order-rule', 'version', '1',
            'match_keys', jsonb_build_array('order_id'),
            'subject_keys', jsonb_build_array('customer_id'),
            'scope_mode', 'POLICY_SET_REQUIRED')),
        'applicability', jsonb_build_object(
            'source_kind', 'relation', 'relation', 'm31_reference.rls_gate',
            'subject_keys', jsonb_build_array('subject')),
        'valid_from', '2026-01-01 00:00:00+00'));
    set_preview := pgreact_api.preview(policy_set);
    PERFORM pgreact_api.deploy(policy_set, jsonb_build_object(
        'preview_digest', set_preview -> 'summary' ->> 'preview_digest'));
    ALTER TABLE m31_reference.rls_gate ENABLE ROW LEVEL SECURITY;
    blocked := pgreact_api.run(
        pgreact_api.target('policy_set', 'm31-rls', '1'), clock_timestamp());
    status := pgreact_api.status(pgreact_api.target('policy_set', 'm31-rls', '1'));
    SELECT barrier.code INTO barrier_code
    FROM pgreact_internal.policy_set_runtime_barriers barrier
    JOIN pgreact_internal.policy_set_versions version
      ON version.policy_set_version_id = barrier.policy_set_version_id
    JOIN pgreact_internal.policy_sets set USING (policy_set_id)
    WHERE set.set_name = 'm31-rls' AND barrier.cleared_at IS NULL;
    SELECT count(*) INTO support_count
    FROM pgreact.policy_set_scope_supports WHERE set_name = 'm31-rls';
    IF blocked -> 'runtime' ->> 'runtime_state' <> 'BLOCKED'
       OR status -> 'summary' ->> 'runtime_state' <> 'BLOCKED'
       OR support_count <> 1 OR barrier_code <> 'M31_SOURCE_RLS_PROTECTED' THEN
        RAISE EXCEPTION 'M31 RLS barrier mismatch: % / % / % / %',
            blocked, status, support_count, barrier_code;
    END IF;
    ALTER TABLE m31_reference.rls_gate DISABLE ROW LEVEL SECURITY;
    PERFORM pgreact_api.run(
        pgreact_api.target('policy_set', 'm31-rls', '1'), clock_timestamp());
    SELECT count(*) INTO support_count
    FROM pgreact.policy_set_scope_supports WHERE set_name = 'm31-rls';
    status := pgreact_api.status(pgreact_api.target('policy_set', 'm31-rls', '1'));
    IF status -> 'summary' ->> 'runtime_state' <> 'AUTHORITATIVE'
       OR support_count <> 1 THEN
        RAISE EXCEPTION 'M31 RLS barrier recovery mismatch: %', support_count;
    END IF;

    CREATE TABLE m31_reference.duplicate_gate (subject bigint NOT NULL);
    INSERT INTO m31_reference.duplicate_gate VALUES (20);
    policy_set := pgreact_api.declaration('policy_set', 'm31-duplicate', jsonb_build_object(
        'version', '1',
        'members', jsonb_build_array(jsonb_build_object(
            'kind', 'rule', 'name', 'm31-order-rule', 'version', '1',
            'match_keys', jsonb_build_array('order_id'),
            'subject_keys', jsonb_build_array('customer_id'),
            'scope_mode', 'POLICY_SET_REQUIRED')),
        'applicability', jsonb_build_object(
            'source_kind', 'relation', 'relation', 'm31_reference.duplicate_gate',
            'subject_keys', jsonb_build_array('subject')),
        'valid_from', '2026-01-01 00:00:00+00'));
    set_preview := pgreact_api.preview(policy_set);
    PERFORM pgreact_api.deploy(policy_set, jsonb_build_object(
        'preview_digest', set_preview -> 'summary' ->> 'preview_digest'));
    INSERT INTO m31_reference.duplicate_gate VALUES (20);
    blocked := pgreact_api.run(
        pgreact_api.target('policy_set', 'm31-duplicate', '1'), clock_timestamp());
    SELECT barrier.code INTO barrier_code
    FROM pgreact_internal.policy_set_runtime_barriers barrier
    JOIN pgreact_internal.policy_set_versions version
      ON version.policy_set_version_id = barrier.policy_set_version_id
    JOIN pgreact_internal.policy_sets set USING (policy_set_id)
    WHERE set.set_name = 'm31-duplicate' AND barrier.cleared_at IS NULL;
    SELECT count(*) INTO support_count
    FROM pgreact.policy_set_scope_supports WHERE set_name = 'm31-duplicate';
    IF blocked -> 'runtime' ->> 'runtime_state' <> 'BLOCKED'
       OR support_count <> 1 OR barrier_code <> 'M31_SOURCE_DUPLICATE' THEN
        RAISE EXCEPTION 'M31 duplicate barrier mismatch: % / % / %',
            blocked, support_count, barrier_code;
    END IF;
    DELETE FROM m31_reference.duplicate_gate
    WHERE ctid IN (
        SELECT ctid FROM m31_reference.duplicate_gate WHERE subject = 20 LIMIT 1);
    PERFORM pgreact_api.run(
        pgreact_api.target('policy_set', 'm31-duplicate', '1'), clock_timestamp());
    SELECT count(*) INTO support_count
    FROM pgreact.policy_set_scope_supports WHERE set_name = 'm31-duplicate';
    status := pgreact_api.status(pgreact_api.target('policy_set', 'm31-duplicate', '1'));
    IF status -> 'summary' ->> 'runtime_state' <> 'AUTHORITATIVE'
       OR support_count <> 1 THEN
        RAISE EXCEPTION 'M31 duplicate barrier recovery mismatch: % / % / %',
            blocked, status, support_count;
    END IF;

    ALTER TABLE m31_reference.duplicate_gate ADD COLUMN drift_marker integer;
    blocked := pgreact_api.run(
        pgreact_api.target('policy_set', 'm31-duplicate', '1'), clock_timestamp());
    status := pgreact_api.status(pgreact_api.target('policy_set', 'm31-duplicate', '1'));
    SELECT barrier.code INTO barrier_code
    FROM pgreact_internal.policy_set_runtime_barriers barrier
    JOIN pgreact_internal.policy_set_versions version
      ON version.policy_set_version_id = barrier.policy_set_version_id
    JOIN pgreact_internal.policy_sets set USING (policy_set_id)
    WHERE set.set_name = 'm31-duplicate' AND barrier.cleared_at IS NULL;
    SELECT count(*) INTO support_count
    FROM pgreact.policy_set_scope_supports WHERE set_name = 'm31-duplicate';
    IF blocked -> 'runtime' ->> 'runtime_state' <> 'BLOCKED'
       OR status -> 'summary' ->> 'runtime_state' <> 'BLOCKED'
       OR support_count <> 1 OR barrier_code <> 'M31_SOURCE_DRIFT' THEN
        RAISE EXCEPTION 'M31 definition-drift barrier mismatch: % / % / %',
            blocked, status, support_count;
    END IF;
    ALTER TABLE m31_reference.duplicate_gate DROP COLUMN drift_marker;
    PERFORM pgreact_api.run(
        pgreact_api.target('policy_set', 'm31-duplicate', '1'), clock_timestamp());
    status := pgreact_api.status(pgreact_api.target('policy_set', 'm31-duplicate', '1'));
    SELECT count(*) INTO support_count
    FROM pgreact.policy_set_scope_supports WHERE set_name = 'm31-duplicate';
    IF status -> 'summary' ->> 'runtime_state' <> 'AUTHORITATIVE'
       OR support_count <> 1 THEN
        RAISE EXCEPTION 'M31 definition-drift recovery mismatch: % / %',
            status, support_count;
    END IF;

    CREATE TABLE m31_reference.incomplete_gate (subject bigint);
    INSERT INTO m31_reference.incomplete_gate VALUES (20);
    policy_set := pgreact_api.declaration('policy_set', 'm31-incomplete', jsonb_build_object(
        'version', '1',
        'members', jsonb_build_array(jsonb_build_object(
            'kind', 'rule', 'name', 'm31-order-rule', 'version', '1',
            'match_keys', jsonb_build_array('order_id'),
            'subject_keys', jsonb_build_array('customer_id'),
            'scope_mode', 'POLICY_SET_REQUIRED')),
        'applicability', jsonb_build_object(
            'source_kind', 'relation', 'relation', 'm31_reference.incomplete_gate',
            'subject_keys', jsonb_build_array('subject')),
        'valid_from', '2026-01-01 00:00:00+00'));
    set_preview := pgreact_api.preview(policy_set);
    PERFORM pgreact_api.deploy(policy_set, jsonb_build_object(
        'preview_digest', set_preview -> 'summary' ->> 'preview_digest'));
    INSERT INTO m31_reference.incomplete_gate VALUES (NULL);
    blocked := pgreact_api.run(
        pgreact_api.target('policy_set', 'm31-incomplete', '1'), clock_timestamp());
    SELECT barrier.code INTO barrier_code
    FROM pgreact_internal.policy_set_runtime_barriers barrier
    JOIN pgreact_internal.policy_set_versions version
      ON version.policy_set_version_id = barrier.policy_set_version_id
    JOIN pgreact_internal.policy_sets set USING (policy_set_id)
    WHERE set.set_name = 'm31-incomplete' AND barrier.cleared_at IS NULL;
    SELECT count(*) INTO support_count
    FROM pgreact.policy_set_scope_supports WHERE set_name = 'm31-incomplete';
    IF blocked -> 'runtime' ->> 'runtime_state' <> 'BLOCKED'
       OR support_count <> 1 OR barrier_code <> 'M31_SOURCE_INCOMPLETE' THEN
        RAISE EXCEPTION 'M31 incomplete barrier mismatch: % / % / %',
            blocked, support_count, barrier_code;
    END IF;

    CREATE TABLE m31_reference.malformed_gate (subject bigint PRIMARY KEY);
    INSERT INTO m31_reference.malformed_gate VALUES (20);
    policy_set := pgreact_api.declaration('policy_set', 'm31-malformed', jsonb_build_object(
        'version', '1',
        'members', jsonb_build_array(jsonb_build_object(
            'kind', 'rule', 'name', 'm31-order-rule', 'version', '1',
            'match_keys', jsonb_build_array('order_id'),
            'subject_keys', jsonb_build_array('customer_id'),
            'scope_mode', 'POLICY_SET_REQUIRED')),
        'applicability', jsonb_build_object(
            'source_kind', 'relation', 'relation', 'm31_reference.malformed_gate',
            'subject_keys', jsonb_build_array('subject')),
        'valid_from', '2026-01-01 00:00:00+00'));
    set_preview := pgreact_api.preview(policy_set);
    PERFORM pgreact_api.deploy(policy_set, jsonb_build_object(
        'preview_digest', set_preview -> 'summary' ->> 'preview_digest'));
    ALTER TABLE m31_reference.malformed_gate
        ALTER COLUMN subject TYPE numeric USING subject::numeric;
    blocked := pgreact_api.run(
        pgreact_api.target('policy_set', 'm31-malformed', '1'), clock_timestamp());
    SELECT barrier.code INTO barrier_code
    FROM pgreact_internal.policy_set_runtime_barriers barrier
    JOIN pgreact_internal.policy_set_versions version
      ON version.policy_set_version_id = barrier.policy_set_version_id
    JOIN pgreact_internal.policy_sets set USING (policy_set_id)
    WHERE set.set_name = 'm31-malformed' AND barrier.cleared_at IS NULL;
    SELECT count(*) INTO support_count
    FROM pgreact.policy_set_scope_supports WHERE set_name = 'm31-malformed';
    IF blocked -> 'runtime' ->> 'runtime_state' <> 'BLOCKED'
       OR support_count <> 1 OR barrier_code <> 'M31_SOURCE_MALFORMED' THEN
        RAISE EXCEPTION 'M31 malformed barrier mismatch: % / % / %',
            blocked, support_count, barrier_code;
    END IF;

    CREATE TABLE m31_reference.over_limit_gate (subject bigint PRIMARY KEY);
    INSERT INTO m31_reference.over_limit_gate VALUES (1);
    policy_set := pgreact_api.declaration('policy_set', 'm31-over-limit', jsonb_build_object(
        'version', '1',
        'members', jsonb_build_array(jsonb_build_object(
            'kind', 'rule', 'name', 'm31-order-rule', 'version', '1',
            'match_keys', jsonb_build_array('order_id'),
            'subject_keys', jsonb_build_array('customer_id'),
            'scope_mode', 'POLICY_SET_REQUIRED')),
        'applicability', jsonb_build_object(
            'source_kind', 'relation', 'relation', 'm31_reference.over_limit_gate',
            'subject_keys', jsonb_build_array('subject')),
        'valid_from', '2026-01-01 00:00:00+00'));
    set_preview := pgreact_api.preview(policy_set);
    PERFORM pgreact_api.deploy(policy_set, jsonb_build_object(
        'preview_digest', set_preview -> 'summary' ->> 'preview_digest'));
    INSERT INTO m31_reference.over_limit_gate
    SELECT generate_series(2, 100001);
    blocked := pgreact_api.run(
        pgreact_api.target('policy_set', 'm31-over-limit', '1'), clock_timestamp());
    SELECT barrier.code INTO barrier_code
    FROM pgreact_internal.policy_set_runtime_barriers barrier
    JOIN pgreact_internal.policy_set_versions version
      ON version.policy_set_version_id = barrier.policy_set_version_id
    JOIN pgreact_internal.policy_sets set USING (policy_set_id)
    WHERE set.set_name = 'm31-over-limit' AND barrier.cleared_at IS NULL;
    SELECT count(*) INTO support_count
    FROM pgreact.policy_set_scope_supports WHERE set_name = 'm31-over-limit';
    IF blocked -> 'runtime' ->> 'runtime_state' <> 'BLOCKED'
       OR support_count <> 0 OR barrier_code <> 'M31_SOURCE_OVER_LIMIT' THEN
        RAISE EXCEPTION 'M31 over-limit barrier mismatch: % / % / %',
            blocked, support_count, barrier_code;
    END IF;

    IF (pgreact_api.status(pgreact_api.target('policy_set', 'm31-customers', '1'))
        -> 'summary' ->> 'runtime_state') <> 'AUTHORITATIVE'
       OR (pgreact_api.doctor(pgreact_api.target('policy_set', 'm31-customers', '1'))
           -> 'diagnostics' -> 0 ->> 'code') <> 'M31_RUNTIME_READY' THEN
        RAISE EXCEPTION 'M31 inspection is not truthful';
    END IF;

    inspection := pgreact_api.explain(
        pgreact_api.target('rule', 'm31-order-rule', NULL),
        jsonb_build_object('customer_id', 10));
    IF inspection -> 'runtime' ->> 'runtime_state' IS NULL THEN
        RAISE EXCEPTION 'M31 rule explanation omitted runtime state: %', inspection;
    END IF;
    inspection := pgreact_api.doctor(
        pgreact_api.target('rule', 'm31-order-rule', NULL));
    IF inspection -> 'runtime' ->> 'runtime_state' IS NULL THEN
        RAISE EXCEPTION 'M31 rule doctor omitted runtime state: %', inspection;
    END IF;

    removed := pgreact_api.remove(pgreact_api.target('rule', 'm31-order-rule', NULL));
    SELECT count(*) INTO active_count
    FROM pgreact.activations activation
    JOIN pgreact.rules rule USING (rule_version_id)
    WHERE rule.rule_name = 'm31-order-rule' AND activation.active;
    SELECT count(*) INTO support_count
    FROM pgreact.policy_set_scope_supports
    WHERE member_kind = 'rule' AND member_name = 'm31-order-rule';
    IF active_count <> 0 OR support_count <> 0 THEN
        RAISE EXCEPTION 'M31 generic rule removal mismatch: % / % / %',
            removed, active_count, support_count;
    END IF;
END
$m31$;

DO $m31$
DECLARE invalid jsonb;
    unsupported jsonb;
BEGIN
    invalid := pgreact_api.validate(pgreact_api.declaration(
        'decision_analysis', 'm31-unsupported', '{}'::jsonb));
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(invalid -> 'findings') finding
                   WHERE finding ->> 'code' = 'M31_UNSUPPORTED_KIND') THEN
        RAISE EXCEPTION 'M31 generic adapter accepted unsupported kind: %', invalid;
    END IF;
    unsupported := pgreact_api.status(pgreact_api.target('derived_program', 'm31-unsupported', NULL));
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(unsupported -> 'findings') finding
                   WHERE finding ->> 'code' = 'M31_UNSUPPORTED_KIND') THEN
        RAISE EXCEPTION 'M31 generic status accepted unsupported kind: %', unsupported;
    END IF;
    unsupported := pgreact_api.explain(
        pgreact_api.target('derived_program', 'm31-unsupported', NULL));
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(unsupported -> 'findings') finding
                   WHERE finding ->> 'code' = 'M31_UNSUPPORTED_KIND') THEN
        RAISE EXCEPTION 'M31 generic explain accepted unsupported kind: %', unsupported;
    END IF;
    unsupported := pgreact_api.doctor(
        pgreact_api.target('derived_program', 'm31-unsupported', NULL));
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(unsupported -> 'diagnostics') finding
                   WHERE finding ->> 'code' = 'M31_UNSUPPORTED_KIND') THEN
        RAISE EXCEPTION 'M31 generic doctor accepted unsupported kind: %', unsupported;
    END IF;
END
$m31$;

DO $m31$
DECLARE decision_version uuid;
    base_time timestamptz;
    decision_set pgreact_api.declaration;
    set_preview jsonb;
    actual jsonb;
    expected jsonb;
    runtime jsonb;
    support_count bigint;
    inspection jsonb;
    decision_checksum_before text;
    decision_checksum_after text;
BEGIN
    base_time := clock_timestamp();
    CREATE TABLE m31_reference.decision_candidates (
        subject bigint NOT NULL,
        candidate bigint NOT NULL,
        priority bigint NOT NULL,
        result text NOT NULL,
        PRIMARY KEY (subject, candidate)
    );
    INSERT INTO m31_reference.decision_candidates VALUES
        (10, 1001, 20, 'fallback'),
        (10, 1002, 10, 'preferred'),
        (20, 2001, 5, 'other');
    CREATE TABLE m31_reference.decision_gate (subject bigint PRIMARY KEY);
    INSERT INTO m31_reference.decision_gate VALUES (10);

    decision_version := pgreact_api.author_decision_program(
        'm31-decision', 'm31_reference.decision_candidates'::regclass,
        'subject', 'candidate', 'priority', ARRAY['result']::name[],
        base_time - interval '1 minute', NULL, 10);
    decision_set := pgreact_api.declaration('policy_set', 'm31-decision-scope',
        jsonb_build_object(
            'version', '1',
            'members', jsonb_build_array(jsonb_build_object(
                'kind', 'decision_program', 'name', 'm31-decision',
                'version', decision_version::text,
                'match_keys', jsonb_build_array('candidate'),
                'subject_keys', jsonb_build_array('subject'),
                'scope_mode', 'POLICY_SET_REQUIRED')),
            'applicability', jsonb_build_object(
                'source_kind', 'relation', 'relation', 'm31_reference.decision_gate',
                'subject_keys', jsonb_build_array('subject')),
            'valid_from', base_time - interval '1 minute'));
    set_preview := pgreact_api.preview(decision_set);
    IF set_preview ->> 'state' <> 'ready' THEN
        RAISE EXCEPTION 'M31 decision policy-set preview mismatch: %', set_preview;
    END IF;
    runtime := pgreact_api.deploy(decision_set, jsonb_build_object(
        'preview_digest', set_preview -> 'summary' ->> 'preview_digest'));

    SELECT jsonb_agg(jsonb_build_object(
        'subject', subject_key, 'state', state, 'candidate', winner_candidate,
        'claimable', claimable) ORDER BY subject_key)
    INTO actual
    FROM pgreact.decision_winners
    WHERE program_name = 'm31-decision';
    expected := jsonb_build_array(
        jsonb_build_object('subject', 10, 'state', 'WINNER', 'candidate', 1002,
                           'claimable', true),
        jsonb_build_object('subject', 20, 'state', 'WINNER', 'candidate', 2001,
                           'claimable', false));
    SELECT count(*) INTO support_count
    FROM pgreact.policy_set_scope_supports
    WHERE set_name = 'm31-decision-scope';
    IF runtime -> 'runtime' ->> 'runtime_state' <> 'AUTHORITATIVE'
       OR actual IS DISTINCT FROM expected OR support_count <> 1 THEN
        RAISE EXCEPTION 'M31 decision initial matrix mismatch: % / % / %',
            runtime, actual, support_count;
    END IF;

    SELECT encode(sha256(convert_to(COALESCE(string_agg(row_data, E'\n'
        ORDER BY row_data), ''), 'UTF8')), 'hex')
    INTO decision_checksum_before
    FROM (
        SELECT 'program:' || to_jsonb(dp)::text AS row_data
        FROM pgreact_internal.decision_programs dp
        WHERE dp.program_name = 'm31-decision'
        UNION ALL
        SELECT 'version:' || to_jsonb(dpv)::text
        FROM pgreact_internal.decision_program_versions dpv
        JOIN pgreact_internal.decision_programs dp USING (program_id)
        WHERE dp.program_name = 'm31-decision'
        UNION ALL
        SELECT 'state:' || to_jsonb(dss)::text
        FROM pgreact_internal.decision_subject_state dss
        JOIN pgreact_internal.decision_programs dp USING (program_id)
        WHERE dp.program_name = 'm31-decision'
        UNION ALL
        SELECT 'work:' || to_jsonb(dw)::text
        FROM pgreact_internal.decision_work dw
        JOIN pgreact_internal.decision_programs dp USING (program_id)
        WHERE dp.program_name = 'm31-decision'
        UNION ALL
        SELECT 'support:' || to_jsonb(pss)::text
        FROM pgreact_internal.policy_set_scope_supports pss
        JOIN pgreact_internal.policy_set_versions psv USING (policy_set_version_id)
        JOIN pgreact_internal.policy_sets ps USING (policy_set_id)
        WHERE ps.set_name = 'm31-decision-scope'
    ) state_rows;
    inspection := pgreact_api.status(
        pgreact_api.target('decision_program', 'm31-decision', NULL));
    IF inspection -> 'summary' ->> 'runtime_state' <> 'AUTHORITATIVE' THEN
        RAISE EXCEPTION 'M31 decision status is not authoritative: %', inspection;
    END IF;
    inspection := pgreact_api.explain(
        pgreact_api.target('decision_program', 'm31-decision', NULL),
        jsonb_build_object('subject', 10));
    IF inspection -> 'runtime' ->> 'runtime_state' <> 'AUTHORITATIVE' THEN
        RAISE EXCEPTION 'M31 decision explanation is not authoritative: %', inspection;
    END IF;
    inspection := pgreact_api.doctor(
        pgreact_api.target('decision_program', 'm31-decision', NULL));
    IF inspection -> 'runtime' ->> 'runtime_state' <> 'AUTHORITATIVE' THEN
        RAISE EXCEPTION 'M31 decision doctor is not authoritative: %', inspection;
    END IF;
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(inspection -> 'diagnostics') diagnostic
               WHERE diagnostic ->> 'code' = 'M26_EXTENSION_VERSION') THEN
        RAISE EXCEPTION 'M31 decision doctor retained a stale extension-version error: %',
            inspection;
    END IF;
    SELECT encode(sha256(convert_to(COALESCE(string_agg(row_data, E'\n'
        ORDER BY row_data), ''), 'UTF8')), 'hex')
    INTO decision_checksum_after
    FROM (
        SELECT 'program:' || to_jsonb(dp)::text AS row_data
        FROM pgreact_internal.decision_programs dp
        WHERE dp.program_name = 'm31-decision'
        UNION ALL
        SELECT 'version:' || to_jsonb(dpv)::text
        FROM pgreact_internal.decision_program_versions dpv
        JOIN pgreact_internal.decision_programs dp USING (program_id)
        WHERE dp.program_name = 'm31-decision'
        UNION ALL
        SELECT 'state:' || to_jsonb(dss)::text
        FROM pgreact_internal.decision_subject_state dss
        JOIN pgreact_internal.decision_programs dp USING (program_id)
        WHERE dp.program_name = 'm31-decision'
        UNION ALL
        SELECT 'work:' || to_jsonb(dw)::text
        FROM pgreact_internal.decision_work dw
        JOIN pgreact_internal.decision_programs dp USING (program_id)
        WHERE dp.program_name = 'm31-decision'
        UNION ALL
        SELECT 'support:' || to_jsonb(pss)::text
        FROM pgreact_internal.policy_set_scope_supports pss
        JOIN pgreact_internal.policy_set_versions psv USING (policy_set_version_id)
        JOIN pgreact_internal.policy_sets ps USING (policy_set_id)
        WHERE ps.set_name = 'm31-decision-scope'
    ) state_rows;
    IF decision_checksum_before IS DISTINCT FROM decision_checksum_after THEN
        RAISE EXCEPTION 'M31 decision read-only façade changed authoritative state: % / %',
            decision_checksum_before, decision_checksum_after;
    END IF;

    DELETE FROM m31_reference.decision_candidates
    WHERE subject = 10 AND candidate = 1002;
    runtime := pgreact_api.run(
        pgreact_api.target('policy_set', 'm31-decision-scope', '1'), base_time);
    SELECT jsonb_agg(jsonb_build_object(
        'subject', subject_key, 'state', state, 'candidate', winner_candidate,
        'claimable', claimable) ORDER BY subject_key)
    INTO actual
    FROM pgreact.decision_winners
    WHERE program_name = 'm31-decision';
    SELECT count(*) INTO support_count
    FROM pgreact.policy_set_scope_supports
    WHERE set_name = 'm31-decision-scope';
    IF actual IS DISTINCT FROM jsonb_build_array(
           jsonb_build_object('subject', 10, 'state', 'WINNER', 'candidate', 1001,
                              'claimable', true),
           jsonb_build_object('subject', 20, 'state', 'WINNER', 'candidate', 2001,
                              'claimable', false))
       OR support_count <> 1
       OR NOT EXISTS (
           SELECT 1
           FROM pgreact.policy_set_scope_supports support
           JOIN pgreact.decision_winners winner
             ON winner.program_name = 'm31-decision'
            AND winner.subject_key = 10
           WHERE support.set_name = 'm31-decision-scope'
             AND support.activation_id = winner.activation_id
             AND support.match_identity = encode(
                 pgreact_internal.m30_key_identity(
                     ARRAY['bigint']::text[], jsonb_build_array(1001)), 'hex')) THEN
        RAISE EXCEPTION 'M31 decision winner replacement mismatch: % / % / %',
            runtime, actual, support_count;
    END IF;

    DELETE FROM m31_reference.decision_gate WHERE subject = 10;
    runtime := pgreact_api.run(
        pgreact_api.target('policy_set', 'm31-decision-scope', '1'), base_time);
    SELECT jsonb_build_object('candidate', winner_candidate, 'claimable', claimable)
    INTO actual
    FROM pgreact.decision_winners
    WHERE program_name = 'm31-decision' AND subject_key = 10;
    SELECT count(*) INTO support_count
    FROM pgreact.policy_set_scope_supports
    WHERE set_name = 'm31-decision-scope';
    IF actual IS DISTINCT FROM jsonb_build_object(
           'candidate', 1001, 'claimable', false)
       OR support_count <> 0 THEN
        RAISE EXCEPTION 'M31 decision support removal mismatch: % / % / %',
            runtime, actual, support_count;
    END IF;

    INSERT INTO m31_reference.decision_gate VALUES (10);
    PERFORM pgreact_api.run(
        pgreact_api.target('policy_set', 'm31-decision-scope', '1'), base_time);
    IF NOT EXISTS (
        SELECT 1 FROM pgreact.decision_winners
        WHERE program_name = 'm31-decision' AND subject_key = 10 AND claimable)
       OR (SELECT count(*) FROM pgreact.policy_set_scope_supports
           WHERE set_name = 'm31-decision-scope') <> 1 THEN
        RAISE EXCEPTION 'M31 decision support reentry mismatch';
    END IF;

    DROP TABLE m31_reference.decision_candidates;
    runtime := pgreact_api.run(
        pgreact_api.target('policy_set', 'm31-decision-scope', '1'), base_time);
    SELECT jsonb_build_object('candidate', winner_candidate, 'claimable', claimable)
    INTO actual
    FROM pgreact.decision_winners
    WHERE program_name = 'm31-decision' AND subject_key = 10;
    SELECT count(*) INTO support_count
    FROM pgreact.policy_set_scope_supports
    WHERE set_name = 'm31-decision-scope';
    IF runtime -> 'runtime' ->> 'runtime_state' <> 'BLOCKED'
       OR actual IS DISTINCT FROM jsonb_build_object(
           'candidate', 1001, 'claimable', false)
       OR support_count <> 1
       OR NOT EXISTS (
           SELECT 1
           FROM pgreact_internal.policy_set_runtime_barriers barrier
           JOIN pgreact_internal.policy_set_versions version
             USING (policy_set_version_id)
           JOIN pgreact_internal.policy_sets set USING (policy_set_id)
           WHERE set.set_name = 'm31-decision-scope'
             AND barrier.code = 'M31_DECISION_UNAVAILABLE'
             AND barrier.cleared_at IS NULL) THEN
        RAISE EXCEPTION 'M31 decision barrier preservation mismatch: % / % / %',
            runtime, actual, support_count;
    END IF;

    runtime := pgreact_api.remove(
        pgreact_api.target('decision_program', 'm31-decision', NULL));
    SELECT count(*) INTO support_count
    FROM pgreact.policy_set_scope_supports
    WHERE member_kind = 'decision_program' AND member_name = 'm31-decision';
    IF support_count <> 0
       OR EXISTS (
           SELECT 1
           FROM pgreact_internal.decision_programs program
           WHERE program.program_name = 'm31-decision'
             AND program.state <> 'REMOVED')
       OR EXISTS (
           SELECT 1
           FROM pgreact_internal.decision_work work
           JOIN pgreact_internal.decision_programs program USING (program_id)
           WHERE program.program_name = 'm31-decision') THEN
        RAISE EXCEPTION 'M31 generic decision removal mismatch: % / %',
            runtime, support_count;
    END IF;

END
$m31$;

SELECT 'M31_AUTHORITATIVE_RUNTIME_OK' AS result;
