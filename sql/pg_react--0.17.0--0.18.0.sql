-- M21 retention and catalog scale.  Retention is disabled until an operator
-- explicitly configures and enables one policy.

CREATE TABLE pgreact_internal.retention_policies (
    singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton),
    policy_version bigint NOT NULL DEFAULT 1 CHECK (policy_version > 0),
    enabled boolean NOT NULL DEFAULT false,
    full_detail_horizon interval NOT NULL DEFAULT interval '0 seconds'
        CHECK (full_detail_horizon >= interval '0 seconds' AND full_detail_horizon <= interval '100 years'),
    minimum_audit_horizon interval NOT NULL DEFAULT interval '1 year'
        CHECK (minimum_audit_horizon >= interval '0 seconds' AND minimum_audit_horizon <= interval '100 years'),
    replay_horizon interval NOT NULL DEFAULT interval '1 year'
        CHECK (replay_horizon >= interval '0 seconds' AND replay_horizon <= interval '100 years'),
    rollback_horizon interval NOT NULL DEFAULT interval '1 year'
        CHECK (rollback_horizon >= interval '0 seconds' AND rollback_horizon <= interval '100 years'),
    deduplication_horizon interval NOT NULL DEFAULT interval '1 year'
        CHECK (deduplication_horizon >= interval '0 seconds' AND deduplication_horizon <= interval '100 years'),
    explanation_horizon interval NOT NULL DEFAULT interval '1 year'
        CHECK (explanation_horizon >= interval '0 seconds' AND explanation_horizon <= interval '100 years'),
    reconciliation_horizon interval NOT NULL DEFAULT interval '1 year'
        CHECK (reconciliation_horizon >= interval '0 seconds' AND reconciliation_horizon <= interval '100 years'),
    recovery_horizon interval NOT NULL DEFAULT interval '1 year'
        CHECK (recovery_horizon >= interval '0 seconds' AND recovery_horizon <= interval '100 years'),
    updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    updated_by name NOT NULL DEFAULT session_user
);
INSERT INTO pgreact_internal.retention_policies (singleton) VALUES (true);

CREATE TABLE pgreact_internal.retention_families (
    family text PRIMARY KEY,
    relation_name text NOT NULL,
    time_column text,
    classification text NOT NULL,
    lost_capabilities text[] NOT NULL,
    remediation text NOT NULL,
    layout text NOT NULL DEFAULT 'inherited' CHECK (layout IN ('inherited','partitioned','indexed')),
    benchmark_status text NOT NULL DEFAULT 'not_shipped',
    layout_evidence text NOT NULL DEFAULT 'No M18/M21 benchmark-backed advantage over the inherited layout.',
    enabled boolean NOT NULL DEFAULT true
);
INSERT INTO pgreact_internal.retention_families
    (family, relation_name, time_column, classification, lost_capabilities, remediation)
VALUES
    ('lifecycle_events', 'pgreact_internal.lifecycle_events', 'transitioned_at', 'lifecycle history',
     ARRAY['replay','explanation detail'], 'restore a verified backup containing the requested history'),
    ('executions', 'pgreact_internal.executions', 'finished_at', 'execution attempts',
     ARRAY['attempt detail'], 'inspect the retained execution audit or restore a verified backup'),
    ('agenda', 'pgreact_internal.agenda', 'completed_at', 'terminal work',
     ARRAY['replay','work detail'], 'restore a verified backup containing the terminal episode'),
    ('runtime_events', 'pgreact_internal.runtime_events', 'occurred_at', 'runtime history',
     ARRAY['runtime detail'], 'inspect the retained batch audit or restore a verified backup'),
    ('reconciliation_audit', 'pgreact_internal.reconciliation_audit', 'completed_at', 'reconciliation history',
     ARRAY['reconciliation detail'], 'restore a verified backup containing the reconciliation record'),
    ('metadata_rebuild_audits', 'pgreact_internal.metadata_rebuild_audits', 'completed_at', 'metadata maintenance',
     ARRAY['rebuild detail'], 'restore a verified backup containing the maintenance record'),
    ('derived_support_inputs', 'pgreact_internal.derived_support_inputs', NULL, 'support detail',
     ARRAY['support input detail'], 'inspect the surviving support identity or restore a verified backup'),
    ('derived_supports', 'pgreact_internal.derived_supports', 'invalidated_at', 'inactive support history',
     ARRAY['support detail','explanation detail'], 'restore a verified backup containing the support history'),
    ('derived_repair_diagnostics', 'pgreact_internal.derived_repair_diagnostics', NULL, 'derived repair detail',
     ARRAY['repair detail'], 'inspect the retained reconciliation audit or restore a verified backup'),
    ('derived_reconciliations', 'pgreact_internal.derived_reconciliations', 'completed_at', 'derived reconciliation history',
     ARRAY['reconciliation detail'], 'restore a verified backup containing the reconciliation record'),
    ('derivation_program_repair_diagnostics', 'pgreact_internal.derivation_program_repair_diagnostics', NULL, 'program repair detail',
     ARRAY['repair detail'], 'inspect the retained reconciliation audit or restore a verified backup'),
    ('derivation_program_iterations', 'pgreact_internal.derivation_program_iterations', 'completed_at', 'program iteration history',
     ARRAY['iteration detail'], 'restore a verified backup containing the iteration history'),
    ('derivation_program_runs', 'pgreact_internal.derivation_program_runs', 'completed_at', 'program run history',
     ARRAY['run detail'], 'restore a verified backup containing the run history'),
    ('negative_dependency_evidence', 'pgreact_internal.negative_dependency_evidence', 'invalidated_at', 'negative evidence history',
     ARRAY['negative evidence detail'], 'restore a verified backup containing the evidence'),
    ('aggregate_dependency_evidence', 'pgreact_internal.aggregate_dependency_evidence', 'invalidated_at', 'aggregate evidence history',
     ARRAY['aggregate evidence detail'], 'restore a verified backup containing the evidence'),
    ('window_corrections', 'pgreact_internal.window_corrections', 'created_at', 'window correction history',
     ARRAY['correction detail'], 'restore a verified backup containing the correction'),
    ('window_diagnostics', 'pgreact_internal.window_diagnostics', 'created_at', 'window diagnostics',
     ARRAY['diagnostic detail'], 'restore a verified backup containing the diagnostic'),
    ('window_audits', 'pgreact_internal.window_audits', 'created_at', 'window maintenance history',
     ARRAY['window audit detail'], 'restore a verified backup containing the audit'),
    ('clock_history', 'pgreact_internal.clock_history', 'advanced_at', 'clock frontier history',
     ARRAY['clock history detail'], 'restore a verified backup containing the clock history');

CREATE TABLE pgreact_internal.retention_batches (
    batch_id uuid PRIMARY KEY,
    policy_version bigint NOT NULL,
    requested_cutoff timestamptz NOT NULL,
    effective_cutoff timestamptz NOT NULL,
    requested_by name NOT NULL DEFAULT session_user,
    state text NOT NULL CHECK (state IN ('RUNNING','COMPLETED','PARTIAL','FAILED')),
    family_counts jsonb NOT NULL DEFAULT '{}'::jsonb,
    protected_reasons jsonb NOT NULL DEFAULT '{}'::jsonb,
    started_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    finished_at timestamptz,
    error jsonb
);
CREATE INDEX retention_batches_recent_idx
    ON pgreact_internal.retention_batches (started_at DESC);

CREATE TABLE pgreact_internal.retention_tombstones (
    tombstone_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    family text NOT NULL REFERENCES pgreact_internal.retention_families,
    historical_identity text NOT NULL,
    outcome text NOT NULL,
    detail_digest bytea NOT NULL,
    policy_version bigint NOT NULL,
    batch_id uuid NOT NULL REFERENCES pgreact_internal.retention_batches,
    pruned_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    UNIQUE (family, historical_identity)
);
CREATE INDEX retention_tombstones_family_idx
    ON pgreact_internal.retention_tombstones (family, pruned_at DESC);

CREATE FUNCTION pgreact_internal.retention_policy_json()
RETURNS jsonb
LANGUAGE SQL STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
    SELECT jsonb_build_object(
        'policy_version', policy_version,
        'enabled', enabled,
        'full_detail_horizon', full_detail_horizon::text,
        'minimum_audit_horizon', minimum_audit_horizon::text,
        'replay_horizon', replay_horizon::text,
        'rollback_horizon', rollback_horizon::text,
        'deduplication_horizon', deduplication_horizon::text,
        'explanation_horizon', explanation_horizon::text,
        'reconciliation_horizon', reconciliation_horizon::text,
        'recovery_horizon', recovery_horizon::text,
        'updated_at', updated_at,
        'updated_by', updated_by)
    FROM pgreact_internal.retention_policies
    WHERE singleton
$$;

CREATE FUNCTION pgreact_internal.retention_record_tombstone(
    target_family text, target_identity text, target_outcome text,
    target_detail jsonb, target_policy_version bigint, target_batch_id uuid)
RETURNS void
LANGUAGE SQL SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
    INSERT INTO pgreact_internal.retention_tombstones
        (family, historical_identity, outcome, detail_digest, policy_version, batch_id)
    VALUES ($1, $2, $3, sha256(convert_to($4::text, 'UTF8')), $5, $6)
    ON CONFLICT (family, historical_identity) DO NOTHING
$$;

CREATE FUNCTION pgreact_internal.retention_preview_data(
    target_cutoff timestamptz, target_batch_size integer)
RETURNS TABLE(
    family text, relation_name text, eligible_rows bigint, eligible_bytes bigint,
    protected_rows bigint, protected_bytes bigint, blocking_reasons jsonb,
    lost_capabilities text[], remediation text, has_more boolean)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE item record; candidate_rows bigint; candidate_bytes bigint;
    rows_ok bigint; bytes_ok bigint;
BEGIN
    IF target_batch_size < 1 THEN RAISE EXCEPTION 'M21_RETENTION_BATCH_SIZE: must be positive'; END IF;
    FOR item IN SELECT * FROM pgreact_internal.retention_families WHERE enabled ORDER BY family LOOP
        candidate_rows := 0; candidate_bytes := 0; rows_ok := 0; bytes_ok := 0;
        IF item.family = 'lifecycle_events' THEN
            SELECT count(*), COALESCE(sum(pg_column_size(e)), 0) INTO candidate_rows, candidate_bytes
            FROM pgreact_internal.lifecycle_events e WHERE e.transitioned_at < target_cutoff;
            SELECT count(*), COALESCE(sum(pg_column_size(e)), 0) INTO rows_ok, bytes_ok
            FROM pgreact_internal.lifecycle_events e
            WHERE e.transitioned_at < target_cutoff
              AND NOT EXISTS (SELECT 1 FROM pgreact_internal.activation_state s
                              WHERE s.rule_version_id = e.rule_version_id
                                AND s.activation_id = e.activation_id AND s.active)
              AND NOT EXISTS (SELECT 1 FROM pgreact_internal.agenda a WHERE a.event_id = e.event_id)
              AND NOT EXISTS (SELECT 1 FROM pgreact_internal.deadline_lifecycle d WHERE d.event_id = e.event_id);
            blocking_reasons := jsonb_build_object(
                'active_state', (SELECT count(*) FROM pgreact_internal.lifecycle_events e
                    WHERE e.transitioned_at < target_cutoff AND EXISTS (SELECT 1 FROM pgreact_internal.activation_state s
                        WHERE s.rule_version_id=e.rule_version_id AND s.activation_id=e.activation_id AND s.active)),
                'work_reference', (SELECT count(*) FROM pgreact_internal.lifecycle_events e
                    WHERE e.transitioned_at < target_cutoff AND EXISTS (SELECT 1 FROM pgreact_internal.agenda a WHERE a.event_id=e.event_id)),
                'deadline_reference', (SELECT count(*) FROM pgreact_internal.lifecycle_events e
                    WHERE e.transitioned_at < target_cutoff AND EXISTS (SELECT 1 FROM pgreact_internal.deadline_lifecycle d WHERE d.event_id=e.event_id)));
        ELSIF item.family = 'executions' THEN
            SELECT count(*), COALESCE(sum(pg_column_size(e)), 0) INTO candidate_rows, candidate_bytes
            FROM pgreact_internal.executions e WHERE e.finished_at < target_cutoff;
            rows_ok := candidate_rows; bytes_ok := candidate_bytes;
            blocking_reasons := '{}'::jsonb;
        ELSIF item.family = 'agenda' THEN
            SELECT count(*), COALESCE(sum(pg_column_size(a)), 0) INTO candidate_rows, candidate_bytes
            FROM pgreact_internal.agenda a
            WHERE a.completed_at < target_cutoff
              AND a.state IN ('COMPLETED','FAILED','SKIPPED','WITHDRAWN','CANCELLED','SUPERSEDED');
            SELECT count(*), COALESCE(sum(pg_column_size(a)), 0) INTO rows_ok, bytes_ok
            FROM pgreact_internal.agenda a
            WHERE a.completed_at < target_cutoff
              AND a.state IN ('COMPLETED','FAILED','SKIPPED','WITHDRAWN','CANCELLED','SUPERSEDED')
              AND NOT EXISTS (SELECT 1 FROM pgreact_internal.executions e WHERE e.episode_id=a.episode_id)
              AND NOT EXISTS (SELECT 1 FROM pgreact_internal.execution_batch_items i WHERE i.episode_id=a.episode_id)
              AND NOT EXISTS (SELECT 1 FROM pgreact_internal.conflict_leases l WHERE l.episode_id=a.episode_id)
              AND NOT EXISTS (SELECT 1 FROM pgreact_internal.runtime_events r WHERE r.episode_id=a.episode_id);
            blocking_reasons := jsonb_build_object(
                'active_work', (SELECT count(*) FROM pgreact_internal.agenda a
                    WHERE a.completed_at < target_cutoff AND a.state NOT IN ('COMPLETED','FAILED','SKIPPED','WITHDRAWN','CANCELLED','SUPERSEDED')),
                'execution_reference', (SELECT count(*) FROM pgreact_internal.agenda a
                    WHERE a.completed_at < target_cutoff AND EXISTS (SELECT 1 FROM pgreact_internal.executions e WHERE e.episode_id=a.episode_id)),
                'batch_reference', (SELECT count(*) FROM pgreact_internal.agenda a
                    WHERE a.completed_at < target_cutoff AND EXISTS (SELECT 1 FROM pgreact_internal.execution_batch_items i WHERE i.episode_id=a.episode_id)),
                'runtime_reference', (SELECT count(*) FROM pgreact_internal.agenda a
                    WHERE a.completed_at < target_cutoff AND EXISTS (SELECT 1 FROM pgreact_internal.runtime_events r WHERE r.episode_id=a.episode_id)));
        ELSIF item.family = 'runtime_events' THEN
            SELECT count(*), COALESCE(sum(pg_column_size(r)), 0) INTO candidate_rows, candidate_bytes
            FROM pgreact_internal.runtime_events r WHERE r.occurred_at < target_cutoff;
            rows_ok := candidate_rows; bytes_ok := candidate_bytes; blocking_reasons := '{}'::jsonb;
        ELSIF item.family = 'reconciliation_audit' THEN
            SELECT count(*), COALESCE(sum(pg_column_size(r)), 0) INTO candidate_rows, candidate_bytes
            FROM pgreact_internal.reconciliation_audit r
            WHERE r.completed_at < target_cutoff AND r.status = 'COMPLETED';
            rows_ok := candidate_rows; bytes_ok := candidate_bytes; blocking_reasons := jsonb_build_object('running', 0);
        ELSIF item.family = 'metadata_rebuild_audits' THEN
            SELECT count(*), COALESCE(sum(pg_column_size(r)), 0) INTO candidate_rows, candidate_bytes
            FROM pgreact_internal.metadata_rebuild_audits r
            WHERE r.completed_at < target_cutoff AND r.status = 'COMPLETED';
            rows_ok := candidate_rows; bytes_ok := candidate_bytes; blocking_reasons := jsonb_build_object('running', 0);
        ELSIF item.family = 'derived_support_inputs' THEN
            SELECT count(*), COALESCE(sum(pg_column_size(i)), 0) INTO candidate_rows, candidate_bytes
            FROM pgreact_internal.derived_support_inputs i JOIN pgreact_internal.derived_supports s USING (support_id)
            WHERE NOT s.active AND s.invalidated_at < target_cutoff;
            rows_ok := candidate_rows; bytes_ok := candidate_bytes; blocking_reasons := jsonb_build_object('active_support', 0);
        ELSIF item.family = 'derived_supports' THEN
            SELECT count(*), COALESCE(sum(pg_column_size(s)), 0) INTO candidate_rows, candidate_bytes
            FROM pgreact_internal.derived_supports s WHERE NOT s.active AND s.invalidated_at < target_cutoff;
            SELECT count(*), COALESCE(sum(pg_column_size(s)), 0) INTO rows_ok, bytes_ok
            FROM pgreact_internal.derived_supports s
            WHERE NOT s.active AND s.invalidated_at < target_cutoff
              AND NOT EXISTS (SELECT 1 FROM pgreact_internal.derived_support_inputs i WHERE i.support_id=s.support_id);
            blocking_reasons := jsonb_build_object('support_inputs', (SELECT count(*) FROM pgreact_internal.derived_supports s
                WHERE NOT s.active AND s.invalidated_at < target_cutoff
                  AND EXISTS (SELECT 1 FROM pgreact_internal.derived_support_inputs i WHERE i.support_id=s.support_id)));
        ELSIF item.family = 'derived_repair_diagnostics' THEN
            SELECT count(*), COALESCE(sum(pg_column_size(d)), 0) INTO candidate_rows, candidate_bytes
            FROM pgreact_internal.derived_repair_diagnostics d JOIN pgreact_internal.derived_reconciliations r USING (reconciliation_id)
            WHERE r.completed_at < target_cutoff AND r.status = 'COMPLETED';
            rows_ok := candidate_rows; bytes_ok := candidate_bytes; blocking_reasons := '{}'::jsonb;
        ELSIF item.family = 'derived_reconciliations' THEN
            SELECT count(*), COALESCE(sum(pg_column_size(r)), 0) INTO candidate_rows, candidate_bytes
            FROM pgreact_internal.derived_reconciliations r WHERE r.completed_at < target_cutoff AND r.status = 'COMPLETED';
            SELECT count(*), COALESCE(sum(pg_column_size(r)), 0) INTO rows_ok, bytes_ok
            FROM pgreact_internal.derived_reconciliations r
            WHERE r.completed_at < target_cutoff AND r.status = 'COMPLETED'
              AND NOT EXISTS (SELECT 1 FROM pgreact_internal.derived_repair_diagnostics d WHERE d.reconciliation_id=r.reconciliation_id);
            blocking_reasons := jsonb_build_object('diagnostics', (SELECT count(*) FROM pgreact_internal.derived_reconciliations r
                WHERE r.completed_at < target_cutoff AND r.status = 'COMPLETED'
                  AND EXISTS (SELECT 1 FROM pgreact_internal.derived_repair_diagnostics d WHERE d.reconciliation_id=r.reconciliation_id)));
        ELSIF item.family = 'derivation_program_repair_diagnostics' THEN
            SELECT count(*), COALESCE(sum(pg_column_size(d)), 0) INTO candidate_rows, candidate_bytes
            FROM pgreact_internal.derivation_program_repair_diagnostics d
            JOIN pgreact_internal.derivation_program_reconciliations r USING (reconciliation_id)
            WHERE r.completed_at < target_cutoff AND r.status = 'COMPLETED';
            rows_ok := candidate_rows; bytes_ok := candidate_bytes; blocking_reasons := '{}'::jsonb;
        ELSIF item.family = 'derivation_program_iterations' THEN
            SELECT count(*), COALESCE(sum(pg_column_size(i)), 0) INTO candidate_rows, candidate_bytes
            FROM pgreact_internal.derivation_program_iterations i WHERE i.completed_at < target_cutoff;
            rows_ok := candidate_rows; bytes_ok := candidate_bytes; blocking_reasons := '{}'::jsonb;
        ELSIF item.family = 'derivation_program_runs' THEN
            SELECT count(*), COALESCE(sum(pg_column_size(r)), 0) INTO candidate_rows, candidate_bytes
            FROM pgreact_internal.derivation_program_runs r
            WHERE r.completed_at < target_cutoff AND r.status IN ('COMPLETED','NOOP','FAILED');
            SELECT count(*), COALESCE(sum(pg_column_size(r)), 0) INTO rows_ok, bytes_ok
            FROM pgreact_internal.derivation_program_runs r
            WHERE r.completed_at < target_cutoff AND r.status IN ('COMPLETED','NOOP','FAILED')
              AND NOT EXISTS (SELECT 1 FROM pgreact_internal.derivation_program_iterations i WHERE i.run_id=r.run_id);
            blocking_reasons := jsonb_build_object('iterations', (SELECT count(*) FROM pgreact_internal.derivation_program_runs r
                WHERE r.completed_at < target_cutoff AND r.status IN ('COMPLETED','NOOP','FAILED')
                  AND EXISTS (SELECT 1 FROM pgreact_internal.derivation_program_iterations i WHERE i.run_id=r.run_id)));
        ELSIF item.family = 'negative_dependency_evidence' THEN
            SELECT count(*), COALESCE(sum(pg_column_size(e)), 0) INTO candidate_rows, candidate_bytes
            FROM pgreact_internal.negative_dependency_evidence e WHERE NOT e.active AND e.invalidated_at < target_cutoff;
            rows_ok := candidate_rows; bytes_ok := candidate_bytes; blocking_reasons := jsonb_build_object('active', 0);
        ELSIF item.family = 'aggregate_dependency_evidence' THEN
            SELECT count(*), COALESCE(sum(pg_column_size(e)), 0) INTO candidate_rows, candidate_bytes
            FROM pgreact_internal.aggregate_dependency_evidence e WHERE NOT e.active AND e.invalidated_at < target_cutoff;
            rows_ok := candidate_rows; bytes_ok := candidate_bytes; blocking_reasons := jsonb_build_object('active', 0);
        ELSIF item.family = 'window_corrections' THEN
            SELECT count(*), COALESCE(sum(pg_column_size(c)), 0) INTO candidate_rows, candidate_bytes
            FROM pgreact_internal.window_corrections c WHERE c.created_at < target_cutoff;
            SELECT count(*), COALESCE(sum(pg_column_size(c)), 0) INTO rows_ok, bytes_ok
            FROM pgreact_internal.window_corrections c JOIN pgreact_internal.window_programs p USING (program_version_id)
            WHERE c.created_at < target_cutoff AND NOT p.active;
            blocking_reasons := jsonb_build_object('active_program', (SELECT count(*) FROM pgreact_internal.window_corrections c
                JOIN pgreact_internal.window_programs p USING (program_version_id) WHERE c.created_at < target_cutoff AND p.active));
        ELSIF item.family = 'window_diagnostics' THEN
            SELECT count(*), COALESCE(sum(pg_column_size(d)), 0) INTO candidate_rows, candidate_bytes
            FROM pgreact_internal.window_diagnostics d WHERE d.created_at < target_cutoff;
            SELECT count(*), COALESCE(sum(pg_column_size(d)), 0) INTO rows_ok, bytes_ok
            FROM pgreact_internal.window_diagnostics d JOIN pgreact_internal.window_programs p USING (program_version_id)
            WHERE d.created_at < target_cutoff AND NOT p.active;
            blocking_reasons := jsonb_build_object('active_program', (SELECT count(*) FROM pgreact_internal.window_diagnostics d
                JOIN pgreact_internal.window_programs p USING (program_version_id) WHERE d.created_at < target_cutoff AND p.active));
        ELSIF item.family = 'window_audits' THEN
            SELECT count(*), COALESCE(sum(pg_column_size(a)), 0) INTO candidate_rows, candidate_bytes
            FROM pgreact_internal.window_audits a WHERE a.created_at < target_cutoff;
            SELECT count(*), COALESCE(sum(pg_column_size(a)), 0) INTO rows_ok, bytes_ok
            FROM pgreact_internal.window_audits a LEFT JOIN pgreact_internal.window_programs p USING (program_version_id)
            WHERE a.created_at < target_cutoff AND (p.program_version_id IS NULL OR NOT p.active);
            blocking_reasons := jsonb_build_object('active_program', (SELECT count(*) FROM pgreact_internal.window_audits a
                JOIN pgreact_internal.window_programs p USING (program_version_id) WHERE a.created_at < target_cutoff AND p.active));
        ELSIF item.family = 'clock_history' THEN
            SELECT count(*), COALESCE(sum(pg_column_size(h)), 0) INTO candidate_rows, candidate_bytes
            FROM pgreact_internal.clock_history h WHERE h.advanced_at < target_cutoff;
            rows_ok := candidate_rows; bytes_ok := candidate_bytes; blocking_reasons := '{}'::jsonb;
        END IF;
        family := item.family; relation_name := item.relation_name;
        eligible_rows := rows_ok; eligible_bytes := bytes_ok;
        protected_rows := candidate_rows - rows_ok; protected_bytes := candidate_bytes - bytes_ok;
        lost_capabilities := item.lost_capabilities; remediation := item.remediation;
        has_more := rows_ok > target_batch_size;
        RETURN NEXT;
    END LOOP;
END
$$;

CREATE FUNCTION pgreact_internal.retention_apply_family(
    target_family text, target_cutoff timestamptz, target_batch_size integer,
    target_policy_version bigint, target_batch_id uuid)
RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE item record; removed bigint := 0;
BEGIN
    IF target_family = 'runtime_events' THEN
        FOR item IN SELECT r.runtime_event_id, r.event_type, r.occurred_at FROM pgreact_internal.runtime_events r
                    WHERE r.occurred_at < target_cutoff ORDER BY r.runtime_event_id LIMIT target_batch_size LOOP
            PERFORM pgreact_internal.retention_record_tombstone(target_family, item.runtime_event_id::text, item.event_type,
                to_jsonb(item), target_policy_version, target_batch_id);
            DELETE FROM pgreact_internal.runtime_events WHERE runtime_event_id=item.runtime_event_id; removed := removed+1;
        END LOOP;
    ELSIF target_family = 'executions' THEN
        FOR item IN SELECT e.execution_id, e.episode_id, e.status, e.finished_at FROM pgreact_internal.executions e
                    WHERE e.finished_at < target_cutoff ORDER BY e.execution_id LIMIT target_batch_size LOOP
            PERFORM pgreact_internal.retention_record_tombstone(target_family, item.execution_id::text, item.status,
                to_jsonb(item), target_policy_version, target_batch_id);
            DELETE FROM pgreact_internal.executions WHERE execution_id=item.execution_id; removed := removed+1;
        END LOOP;
    ELSIF target_family = 'derived_support_inputs' THEN
        FOR item IN SELECT i.support_id, i.input_order FROM pgreact_internal.derived_support_inputs i
                    JOIN pgreact_internal.derived_supports s USING (support_id)
                    WHERE NOT s.active AND s.invalidated_at < target_cutoff
                    ORDER BY i.support_id, i.input_order LIMIT target_batch_size LOOP
            PERFORM pgreact_internal.retention_record_tombstone(target_family, item.support_id::text || ':' || item.input_order,
                'support_input', to_jsonb(item), target_policy_version, target_batch_id);
            DELETE FROM pgreact_internal.derived_support_inputs WHERE support_id=item.support_id AND input_order=item.input_order; removed := removed+1;
        END LOOP;
    ELSIF target_family = 'negative_dependency_evidence' THEN
        FOR item IN SELECT e.evidence_id, e.active, e.invalidated_at FROM pgreact_internal.negative_dependency_evidence e
                    WHERE NOT e.active AND e.invalidated_at < target_cutoff ORDER BY e.evidence_id LIMIT target_batch_size LOOP
            PERFORM pgreact_internal.retention_record_tombstone(target_family, item.evidence_id::text, 'negative_evidence', to_jsonb(item), target_policy_version, target_batch_id);
            DELETE FROM pgreact_internal.negative_dependency_evidence WHERE evidence_id=item.evidence_id; removed := removed+1;
        END LOOP;
    ELSIF target_family = 'aggregate_dependency_evidence' THEN
        FOR item IN SELECT e.evidence_id, e.active, e.invalidated_at FROM pgreact_internal.aggregate_dependency_evidence e
                    WHERE NOT e.active AND e.invalidated_at < target_cutoff ORDER BY e.evidence_id LIMIT target_batch_size LOOP
            PERFORM pgreact_internal.retention_record_tombstone(target_family, item.evidence_id::text, 'aggregate_evidence', to_jsonb(item), target_policy_version, target_batch_id);
            DELETE FROM pgreact_internal.aggregate_dependency_evidence WHERE evidence_id=item.evidence_id; removed := removed+1;
        END LOOP;
    ELSIF target_family = 'derived_supports' THEN
        FOR item IN SELECT s.support_id, s.active, s.invalidated_at FROM pgreact_internal.derived_supports s
                    WHERE NOT s.active AND s.invalidated_at < target_cutoff
                      AND NOT EXISTS (SELECT 1 FROM pgreact_internal.derived_support_inputs i WHERE i.support_id=s.support_id)
                    ORDER BY s.support_id LIMIT target_batch_size LOOP
            PERFORM pgreact_internal.retention_record_tombstone(target_family, item.support_id::text, 'inactive_support', to_jsonb(item), target_policy_version, target_batch_id);
            DELETE FROM pgreact_internal.derived_supports WHERE support_id=item.support_id; removed := removed+1;
        END LOOP;
    ELSIF target_family = 'derived_repair_diagnostics' THEN
        FOR item IN SELECT d.reconciliation_id, d.diagnostic_order, d.code FROM pgreact_internal.derived_repair_diagnostics d
                    JOIN pgreact_internal.derived_reconciliations r USING (reconciliation_id)
                    WHERE r.completed_at < target_cutoff AND r.status='COMPLETED'
                    ORDER BY d.reconciliation_id, d.diagnostic_order LIMIT target_batch_size LOOP
            PERFORM pgreact_internal.retention_record_tombstone(target_family, item.reconciliation_id::text || ':' || item.diagnostic_order, item.code, to_jsonb(item), target_policy_version, target_batch_id);
            DELETE FROM pgreact_internal.derived_repair_diagnostics WHERE reconciliation_id=item.reconciliation_id AND diagnostic_order=item.diagnostic_order; removed := removed+1;
        END LOOP;
    ELSIF target_family = 'derived_reconciliations' THEN
        FOR item IN SELECT r.reconciliation_id, r.status, r.completed_at FROM pgreact_internal.derived_reconciliations r
                    WHERE r.completed_at < target_cutoff AND r.status='COMPLETED'
                      AND NOT EXISTS (SELECT 1 FROM pgreact_internal.derived_repair_diagnostics d WHERE d.reconciliation_id=r.reconciliation_id)
                    ORDER BY r.reconciliation_id LIMIT target_batch_size LOOP
            PERFORM pgreact_internal.retention_record_tombstone(target_family, item.reconciliation_id::text, item.status, to_jsonb(item), target_policy_version, target_batch_id);
            DELETE FROM pgreact_internal.derived_reconciliations WHERE reconciliation_id=item.reconciliation_id; removed := removed+1;
        END LOOP;
    ELSIF target_family = 'derivation_program_repair_diagnostics' THEN
        FOR item IN SELECT d.reconciliation_id, d.diagnostic_order, d.code FROM pgreact_internal.derivation_program_repair_diagnostics d
                    JOIN pgreact_internal.derivation_program_reconciliations r USING (reconciliation_id)
                    WHERE r.completed_at < target_cutoff AND r.status='COMPLETED'
                    ORDER BY d.reconciliation_id, d.diagnostic_order LIMIT target_batch_size LOOP
            PERFORM pgreact_internal.retention_record_tombstone(target_family, item.reconciliation_id::text || ':' || item.diagnostic_order, item.code, to_jsonb(item), target_policy_version, target_batch_id);
            DELETE FROM pgreact_internal.derivation_program_repair_diagnostics WHERE reconciliation_id=item.reconciliation_id AND diagnostic_order=item.diagnostic_order; removed := removed+1;
        END LOOP;
    ELSIF target_family = 'derivation_program_iterations' THEN
        FOR item IN SELECT i.run_id, i.component_id, i.iteration, i.completed_at FROM pgreact_internal.derivation_program_iterations i
                    WHERE i.completed_at < target_cutoff ORDER BY i.run_id, i.component_id, i.iteration LIMIT target_batch_size LOOP
            PERFORM pgreact_internal.retention_record_tombstone(target_family, item.run_id::text || ':' || item.component_id::text || ':' || item.iteration, 'iteration', to_jsonb(item), target_policy_version, target_batch_id);
            DELETE FROM pgreact_internal.derivation_program_iterations WHERE run_id=item.run_id AND component_id=item.component_id AND iteration=item.iteration; removed := removed+1;
        END LOOP;
    ELSIF target_family = 'derivation_program_runs' THEN
        FOR item IN SELECT r.run_id, r.status, r.completed_at FROM pgreact_internal.derivation_program_runs r
                    WHERE r.completed_at < target_cutoff AND r.status IN ('COMPLETED','NOOP','FAILED')
                      AND NOT EXISTS (SELECT 1 FROM pgreact_internal.derivation_program_iterations i WHERE i.run_id=r.run_id)
                    ORDER BY r.run_id LIMIT target_batch_size LOOP
            PERFORM pgreact_internal.retention_record_tombstone(target_family, item.run_id::text, item.status, to_jsonb(item), target_policy_version, target_batch_id);
            DELETE FROM pgreact_internal.derivation_program_runs WHERE run_id=item.run_id; removed := removed+1;
        END LOOP;
    ELSIF target_family = 'window_corrections' THEN
        FOR item IN SELECT c.correction_order, c.correction_identity, c.created_at FROM pgreact_internal.window_corrections c
                    JOIN pgreact_internal.window_programs p USING (program_version_id)
                    WHERE c.created_at < target_cutoff AND NOT p.active ORDER BY c.correction_order LIMIT target_batch_size LOOP
            PERFORM pgreact_internal.retention_record_tombstone(target_family, item.correction_identity, 'window_correction', to_jsonb(item), target_policy_version, target_batch_id);
            DELETE FROM pgreact_internal.window_corrections WHERE correction_order=item.correction_order; removed := removed+1;
        END LOOP;
    ELSIF target_family = 'window_diagnostics' THEN
        FOR item IN SELECT d.diagnostic_order, d.code, d.created_at FROM pgreact_internal.window_diagnostics d
                    JOIN pgreact_internal.window_programs p USING (program_version_id)
                    WHERE d.created_at < target_cutoff AND NOT p.active ORDER BY d.diagnostic_order LIMIT target_batch_size LOOP
            PERFORM pgreact_internal.retention_record_tombstone(target_family, item.diagnostic_order::text, item.code, to_jsonb(item), target_policy_version, target_batch_id);
            DELETE FROM pgreact_internal.window_diagnostics WHERE diagnostic_order=item.diagnostic_order; removed := removed+1;
        END LOOP;
    ELSIF target_family = 'window_audits' THEN
        FOR item IN SELECT a.audit_order, a.operation, a.created_at FROM pgreact_internal.window_audits a
                    LEFT JOIN pgreact_internal.window_programs p USING (program_version_id)
                    WHERE a.created_at < target_cutoff AND (p.program_version_id IS NULL OR NOT p.active)
                    ORDER BY a.audit_order LIMIT target_batch_size LOOP
            PERFORM pgreact_internal.retention_record_tombstone(target_family, item.audit_order::text, item.operation, to_jsonb(item), target_policy_version, target_batch_id);
            DELETE FROM pgreact_internal.window_audits WHERE audit_order=item.audit_order; removed := removed+1;
        END LOOP;
    ELSIF target_family = 'clock_history' THEN
        FOR item IN SELECT h.clock_event_id, h.frontier, h.advanced_at FROM pgreact_internal.clock_history h
                    WHERE h.advanced_at < target_cutoff ORDER BY h.clock_event_id LIMIT target_batch_size LOOP
            PERFORM pgreact_internal.retention_record_tombstone(target_family, item.clock_event_id::text, 'clock_frontier', to_jsonb(item), target_policy_version, target_batch_id);
            DELETE FROM pgreact_internal.clock_history WHERE clock_event_id=item.clock_event_id; removed := removed+1;
        END LOOP;
    ELSIF target_family = 'reconciliation_audit' THEN
        FOR item IN SELECT r.reconciliation_id, r.status, r.completed_at FROM pgreact_internal.reconciliation_audit r
                    WHERE r.completed_at < target_cutoff AND r.status='COMPLETED' ORDER BY r.reconciliation_id LIMIT target_batch_size LOOP
            PERFORM pgreact_internal.retention_record_tombstone(target_family, item.reconciliation_id::text, rtrim(item.status), to_jsonb(item), target_policy_version, target_batch_id);
            DELETE FROM pgreact_internal.reconciliation_audit WHERE reconciliation_id=item.reconciliation_id; removed := removed+1;
        END LOOP;
    ELSIF target_family = 'metadata_rebuild_audits' THEN
        FOR item IN SELECT r.metadata_rebuild_id, r.status, r.completed_at FROM pgreact_internal.metadata_rebuild_audits r
                    WHERE r.completed_at < target_cutoff AND r.status='COMPLETED' ORDER BY r.metadata_rebuild_id LIMIT target_batch_size LOOP
            PERFORM pgreact_internal.retention_record_tombstone(target_family, item.metadata_rebuild_id::text, item.status, to_jsonb(item), target_policy_version, target_batch_id);
            DELETE FROM pgreact_internal.metadata_rebuild_audits WHERE metadata_rebuild_id=item.metadata_rebuild_id; removed := removed+1;
        END LOOP;
    ELSIF target_family = 'agenda' THEN
        FOR item IN SELECT a.episode_id, a.state, a.completed_at FROM pgreact_internal.agenda a
                    WHERE a.completed_at < target_cutoff AND a.state IN ('COMPLETED','FAILED','SKIPPED','WITHDRAWN','CANCELLED','SUPERSEDED')
                      AND NOT EXISTS (SELECT 1 FROM pgreact_internal.executions e WHERE e.episode_id=a.episode_id)
                      AND NOT EXISTS (SELECT 1 FROM pgreact_internal.execution_batch_items i WHERE i.episode_id=a.episode_id)
                      AND NOT EXISTS (SELECT 1 FROM pgreact_internal.conflict_leases l WHERE l.episode_id=a.episode_id)
                      AND NOT EXISTS (SELECT 1 FROM pgreact_internal.runtime_events r WHERE r.episode_id=a.episode_id)
                    ORDER BY a.episode_id LIMIT target_batch_size LOOP
            PERFORM pgreact_internal.retention_record_tombstone(target_family, item.episode_id::text, item.state, to_jsonb(item), target_policy_version, target_batch_id);
            DELETE FROM pgreact_internal.agenda WHERE episode_id=item.episode_id; removed := removed+1;
        END LOOP;
    ELSIF target_family = 'lifecycle_events' THEN
        FOR item IN SELECT e.event_id, e.event_kind, e.transitioned_at FROM pgreact_internal.lifecycle_events e
                    WHERE e.transitioned_at < target_cutoff
                      AND NOT EXISTS (SELECT 1 FROM pgreact_internal.activation_state s WHERE s.rule_version_id=e.rule_version_id AND s.activation_id=e.activation_id AND s.active)
                      AND NOT EXISTS (SELECT 1 FROM pgreact_internal.agenda a WHERE a.event_id=e.event_id)
                      AND NOT EXISTS (SELECT 1 FROM pgreact_internal.deadline_lifecycle d WHERE d.event_id=e.event_id)
                    ORDER BY e.event_id LIMIT target_batch_size LOOP
            PERFORM pgreact_internal.retention_record_tombstone(target_family, item.event_id::text, item.event_kind, to_jsonb(item), target_policy_version, target_batch_id);
            DELETE FROM pgreact_internal.lifecycle_events WHERE event_id=item.event_id; removed := removed+1;
        END LOOP;
    END IF;
    RETURN removed;
END
$$;

CREATE FUNCTION pgreact_api.retention_configure(
    full_detail_horizon interval, minimum_audit_horizon interval, replay_horizon interval,
    rollback_horizon interval, deduplication_horizon interval, explanation_horizon interval,
    reconciliation_horizon interval, recovery_horizon interval, enabled boolean DEFAULT false)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
    IF NOT pgreact_internal.is_operator_admin() THEN RAISE EXCEPTION 'M21_RETENTION_FORBIDDEN: operator role required'; END IF;
    IF full_detail_horizon < interval '0 seconds' OR minimum_audit_horizon < interval '0 seconds'
       OR replay_horizon < interval '0 seconds' OR rollback_horizon < interval '0 seconds'
       OR deduplication_horizon < interval '0 seconds' OR explanation_horizon < interval '0 seconds'
       OR reconciliation_horizon < interval '0 seconds' OR recovery_horizon < interval '0 seconds'
       OR full_detail_horizon > interval '100 years' OR minimum_audit_horizon > interval '100 years'
       OR replay_horizon > interval '100 years' OR rollback_horizon > interval '100 years'
       OR deduplication_horizon > interval '100 years' OR explanation_horizon > interval '100 years'
       OR reconciliation_horizon > interval '100 years' OR recovery_horizon > interval '100 years'
    THEN RAISE EXCEPTION 'M21_RETENTION_HORIZON: horizons must be between zero and one hundred years'; END IF;
    UPDATE pgreact_internal.retention_policies SET
        policy_version = policy_version + 1, enabled = retention_configure.enabled,
        full_detail_horizon = retention_configure.full_detail_horizon,
        minimum_audit_horizon = retention_configure.minimum_audit_horizon,
        replay_horizon = retention_configure.replay_horizon,
        rollback_horizon = retention_configure.rollback_horizon,
        deduplication_horizon = retention_configure.deduplication_horizon,
        explanation_horizon = retention_configure.explanation_horizon,
        reconciliation_horizon = retention_configure.reconciliation_horizon,
        recovery_horizon = retention_configure.recovery_horizon,
        updated_at = clock_timestamp(), updated_by = session_user
    WHERE singleton;
    RETURN pgreact_internal.retention_policy_json();
END
$$;

CREATE FUNCTION pgreact_api.retention_remove()
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
    IF NOT pgreact_internal.is_operator_admin() THEN RAISE EXCEPTION 'M21_RETENTION_FORBIDDEN: operator role required'; END IF;
    UPDATE pgreact_internal.retention_policies SET enabled=false, policy_version=policy_version+1,
        updated_at=clock_timestamp(), updated_by=session_user WHERE singleton;
    RETURN pgreact_internal.retention_policy_json();
END
$$;

CREATE FUNCTION pgreact_api.retention_preview(requested_cutoff timestamptz, batch_size integer DEFAULT 1000)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE policy_row record; effective_cutoff timestamptz; families jsonb; totals jsonb;
BEGIN
    IF NOT pgreact_internal.is_operator_admin() THEN RAISE EXCEPTION 'M21_RETENTION_FORBIDDEN: operator role required'; END IF;
    IF requested_cutoff >= clock_timestamp() THEN RAISE EXCEPTION 'M21_RETENTION_CUTOFF: cutoff must be in the past'; END IF;
    IF batch_size NOT BETWEEN 1 AND 10000 THEN RAISE EXCEPTION 'M21_RETENTION_BATCH_SIZE: must be between 1 and 10000'; END IF;
    SELECT * INTO STRICT policy_row FROM pgreact_internal.retention_policies WHERE singleton;
    effective_cutoff := greatest(requested_cutoff, clock_timestamp() - GREATEST(
        policy_row.full_detail_horizon, policy_row.minimum_audit_horizon,
        policy_row.replay_horizon, policy_row.rollback_horizon,
        policy_row.deduplication_horizon, policy_row.explanation_horizon,
        policy_row.reconciliation_horizon, policy_row.recovery_horizon));
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'family', family, 'relation', relation_name, 'eligible_rows', eligible_rows,
        'eligible_bytes', eligible_bytes, 'protected_rows', protected_rows,
        'protected_bytes', protected_bytes, 'effective_cutoff', effective_cutoff,
        'blocking_reasons', blocking_reasons, 'lost_capabilities', lost_capabilities,
        'remediation', remediation, 'has_more', has_more) ORDER BY family), '[]'::jsonb),
        jsonb_build_object('eligible_rows', COALESCE(sum(eligible_rows),0),
            'eligible_bytes', COALESCE(sum(eligible_bytes),0),
            'protected_rows', COALESCE(sum(protected_rows),0),
            'protected_bytes', COALESCE(sum(protected_bytes),0))
    INTO families, totals FROM pgreact_internal.retention_preview_data(effective_cutoff, batch_size);
    RETURN jsonb_build_object('contract_version', 9, 'policy', pgreact_internal.retention_policy_json(),
        'requested_cutoff', requested_cutoff, 'effective_cutoff', effective_cutoff,
        'batch_size', batch_size, 'mutation', CASE WHEN policy_row.enabled THEN 'enabled' ELSE 'disabled' END,
        'families', families, 'totals', totals,
        'remediation', 'Apply only after reviewing protected reasons, lost capabilities, and the verified-backup boundary.');
END
$$;

CREATE FUNCTION pgreact_api.retention_apply(requested_cutoff timestamptz, batch_size integer DEFAULT 1000)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE policy_row record; effective_cutoff timestamptz; new_batch_id uuid; family_name text;
    removed bigint; total_removed bigint := 0; counts jsonb := '{}'::jsonb; preview jsonb;
    remaining bigint; batch_state text;
BEGIN
    IF NOT pgreact_internal.is_operator_admin() THEN RAISE EXCEPTION 'M21_RETENTION_FORBIDDEN: operator role required'; END IF;
    IF requested_cutoff >= clock_timestamp() THEN RAISE EXCEPTION 'M21_RETENTION_CUTOFF: cutoff must be in the past'; END IF;
    IF batch_size NOT BETWEEN 1 AND 10000 THEN RAISE EXCEPTION 'M21_RETENTION_BATCH_SIZE: must be between 1 and 10000'; END IF;
    PERFORM pg_advisory_xact_lock(5788046901200021);
    SELECT * INTO STRICT policy_row FROM pgreact_internal.retention_policies WHERE singleton;
    IF NOT policy_row.enabled THEN RAISE EXCEPTION 'M21_RETENTION_DISABLED: enable a policy before apply'; END IF;
    effective_cutoff := greatest(requested_cutoff, clock_timestamp() - GREATEST(
        policy_row.full_detail_horizon, policy_row.minimum_audit_horizon,
        policy_row.replay_horizon, policy_row.rollback_horizon,
        policy_row.deduplication_horizon, policy_row.explanation_horizon,
        policy_row.reconciliation_horizon, policy_row.recovery_horizon));
    preview := pgreact_api.retention_preview(requested_cutoff, batch_size);
    IF (preview #>> '{totals,eligible_rows}')::bigint = 0 THEN
        RETURN preview || jsonb_build_object('outcome','NOOP','batch_id',NULL);
    END IF;
    new_batch_id := gen_random_uuid();
    INSERT INTO pgreact_internal.retention_batches(
        batch_id,policy_version,requested_cutoff,effective_cutoff,state,protected_reasons)
    VALUES(new_batch_id,policy_row.policy_version,requested_cutoff,effective_cutoff,'RUNNING',
        COALESCE((SELECT jsonb_object_agg(item.value ->> 'family', item.value -> 'blocking_reasons')
                  FROM jsonb_array_elements(preview -> 'families') item), '{}'::jsonb));
    -- ponytail: one database-wide retention lock; use per-family locks if maintenance throughput matters.
    BEGIN
        FOREACH family_name IN ARRAY ARRAY[
            'runtime_events','executions','derived_support_inputs','negative_dependency_evidence',
            'aggregate_dependency_evidence','derived_supports','derived_repair_diagnostics',
            'derived_reconciliations','derivation_program_repair_diagnostics','derivation_program_iterations',
            'derivation_program_runs','window_corrections','window_diagnostics','window_audits',
            'clock_history','reconciliation_audit','metadata_rebuild_audits','agenda','lifecycle_events'] LOOP
            removed := pgreact_internal.retention_apply_family(family_name,effective_cutoff,batch_size,
                policy_row.policy_version,new_batch_id);
            IF removed > 0 THEN total_removed := total_removed + removed; END IF;
            counts := counts || jsonb_build_object(family_name, removed);
        END LOOP;
        SELECT COALESCE(sum(eligible_rows),0) INTO remaining
        FROM pgreact_internal.retention_preview_data(effective_cutoff,batch_size);
        batch_state := CASE WHEN remaining = 0 THEN 'COMPLETED' ELSE 'PARTIAL' END;
        UPDATE pgreact_internal.retention_batches SET state=batch_state, family_counts=counts,
            finished_at=clock_timestamp() WHERE retention_batches.batch_id=new_batch_id;
        RETURN preview || jsonb_build_object('outcome',lower(batch_state),'batch_id',new_batch_id,
            'removed_rows',total_removed,'family_counts',counts,'remaining_eligible_rows',remaining);
    EXCEPTION WHEN OTHERS THEN
        UPDATE pgreact_internal.retention_batches SET state='FAILED', family_counts=counts,
            finished_at=clock_timestamp(), error=jsonb_build_object('sqlstate',SQLSTATE,'message',SQLERRM)
        WHERE retention_batches.batch_id=new_batch_id;
        RETURN jsonb_build_object('contract_version',9,'outcome','failed','batch_id',new_batch_id,
            'family_counts',counts,'error',jsonb_build_object('sqlstate',SQLSTATE,'message',SQLERRM));
    END;
END
$$;

CREATE FUNCTION pgreact_api.retention_status()
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE policy_row record; cutoff timestamptz; backlog jsonb; layouts jsonb; vacuum jsonb;
BEGIN
    SELECT * INTO STRICT policy_row FROM pgreact_internal.retention_policies WHERE singleton;
    cutoff := clock_timestamp() - GREATEST(policy_row.full_detail_horizon, policy_row.minimum_audit_horizon,
        policy_row.replay_horizon, policy_row.rollback_horizon, policy_row.deduplication_horizon,
        policy_row.explanation_horizon, policy_row.reconciliation_horizon, policy_row.recovery_horizon);
    SELECT jsonb_build_object('eligible_rows',COALESCE(sum(eligible_rows),0),
        'eligible_bytes',COALESCE(sum(eligible_bytes),0),
        'protected_rows',COALESCE(sum(protected_rows),0),
        'protected_bytes',COALESCE(sum(protected_bytes),0)) INTO backlog
    FROM pgreact_internal.retention_preview_data(cutoff,10000);
    SELECT COALESCE(jsonb_object_agg(family,jsonb_build_object(
        'relation',relation_name,'layout',layout,'benchmark_status',benchmark_status,
        'evidence',layout_evidence) ORDER BY family),'{}'::jsonb) INTO layouts
    FROM pgreact_internal.retention_families;
    SELECT COALESCE(jsonb_object_agg(relname,jsonb_build_object(
        'live_rows',n_live_tup,'dead_rows',n_dead_tup,'last_vacuum',last_vacuum,
        'last_autovacuum',last_autovacuum,'last_analyze',last_analyze,
        'last_autoanalyze',last_autoanalyze) ORDER BY relname),'{}'::jsonb) INTO vacuum
    FROM pg_stat_all_tables WHERE schemaname='pgreact_internal'
      AND relname IN ('retention_batches','retention_tombstones','retention_policies');
    RETURN jsonb_build_object('contract_version',9,'policy',pgreact_internal.retention_policy_json(),
        'cutoff_for_status',cutoff,'backlog',backlog,
        'last_batch',(SELECT to_jsonb(b) FROM pgreact_internal.retention_batches b ORDER BY b.started_at DESC LIMIT 1),
        'failed_maintenance',(SELECT count(*) FROM pgreact_internal.retention_batches WHERE state='FAILED'),
        'oldest_tombstone',(SELECT min(pruned_at) FROM pgreact_internal.retention_tombstones),
        'oldest_retained_detail',jsonb_build_object(
            'lifecycle_events',(SELECT min(transitioned_at) FROM pgreact_internal.lifecycle_events),
            'executions',(SELECT min(finished_at) FROM pgreact_internal.executions),
            'agenda',(SELECT min(completed_at) FROM pgreact_internal.agenda WHERE completed_at IS NOT NULL),
            'runtime_events',(SELECT min(occurred_at) FROM pgreact_internal.runtime_events)),
        'table_and_index_growth',jsonb_build_object(
            'catalog_bytes',(SELECT COALESCE(sum(pg_total_relation_size(c.oid)),0)
                FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
                WHERE n.nspname='pgreact_internal' AND c.relkind IN ('r','m')),
            'retention_table_bytes',pg_total_relation_size('pgreact_internal.retention_batches'::regclass)
                + pg_total_relation_size('pgreact_internal.retention_tombstones'::regclass),
            'retention_index_bytes',pg_indexes_size('pgreact_internal.retention_batches'::regclass)
                + pg_indexes_size('pgreact_internal.retention_tombstones'::regclass)),
        'vacuum_analyze',vacuum,'layout_decisions',layouts);
END
$$;

CREATE FUNCTION pgreact_api.retention_metrics()
RETURNS jsonb
LANGUAGE SQL STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
    SELECT jsonb_build_object('contract_version',9,
        'policy_enabled',(SELECT enabled FROM pgreact_internal.retention_policies WHERE singleton),
        'batches_by_state',COALESCE((SELECT jsonb_object_agg(state,count) FROM
            (SELECT state,count(*) FROM pgreact_internal.retention_batches GROUP BY state) q),'{}'::jsonb),
        'tombstones_by_family',COALESCE((SELECT jsonb_object_agg(family,count) FROM
            (SELECT family,count(*) FROM pgreact_internal.retention_tombstones GROUP BY family) q),'{}'::jsonb),
        'failed_maintenance',(SELECT count(*) FROM pgreact_internal.retention_batches WHERE state='FAILED'),
        'eligible_bytes',(SELECT COALESCE(sum(eligible_bytes),0) FROM pgreact_internal.retention_preview_data(
            clock_timestamp() - interval '1 year',10000)),
        'protected_rows',(SELECT COALESCE(sum(protected_rows),0) FROM pgreact_internal.retention_preview_data(
            clock_timestamp() - interval '1 year',10000)),
        'retention_catalog_bytes',COALESCE(pg_total_relation_size('pgreact_internal.retention_batches'::regclass),0)
            + COALESCE(pg_total_relation_size('pgreact_internal.retention_tombstones'::regclass),0),
        'table_and_index_bytes',jsonb_build_object(
            'tables',pg_total_relation_size('pgreact_internal.retention_batches'::regclass)
                + pg_total_relation_size('pgreact_internal.retention_tombstones'::regclass),
            'indexes',pg_indexes_size('pgreact_internal.retention_batches'::regclass)
                + pg_indexes_size('pgreact_internal.retention_tombstones'::regclass)))
$$;

CREATE FUNCTION pgreact_api.retention_doctor()
RETURNS jsonb
LANGUAGE SQL STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
    WITH diagnostics AS (
        SELECT jsonb_build_object('code','M21_EXTENSION_VERSION','severity','ERROR',
            'message','pg_react extension version is not 0.18.0','hint','Install matching extension files and run ALTER EXTENSION UPDATE.') diagnostic
        WHERE NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname='pg_react' AND extversion='0.18.0')
        UNION ALL
        SELECT jsonb_build_object('code','M21_RETENTION_BATCH_FAILED','severity','ERROR',
            'message','a retention batch failed','hint','Inspect retention_audit and retry after resolving the recorded error.')
        WHERE EXISTS (SELECT 1 FROM pgreact_internal.retention_batches WHERE state='FAILED')
        UNION ALL
        SELECT jsonb_build_object('code','M21_RETENTION_DISABLED','severity','INFO',
            'message','retention is disabled by default','hint','Configure and enable one operator-owned retention policy before pruning.')
        WHERE NOT (SELECT enabled FROM pgreact_internal.retention_policies WHERE singleton)
    )
    SELECT jsonb_build_object('contract_version',9,
        'status',CASE WHEN EXISTS (SELECT 1 FROM diagnostics WHERE diagnostic->>'severity'='ERROR') THEN 'attention' ELSE 'ready' END,
        'diagnostics',COALESCE((SELECT jsonb_agg(diagnostic) FROM diagnostics),'[]'::jsonb))
$$;

CREATE FUNCTION pgreact_api.retention_audit(limit_count integer DEFAULT 100)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
    IF NOT pgreact_internal.is_operator_admin() THEN RAISE EXCEPTION 'M21_RETENTION_FORBIDDEN: operator role required'; END IF;
    IF limit_count NOT BETWEEN 1 AND 1000 THEN RAISE EXCEPTION 'M21_RETENTION_LIMIT: must be between 1 and 1000'; END IF;
    RETURN jsonb_build_object('contract_version',9,
        'batches',COALESCE((SELECT jsonb_agg(to_jsonb(b) ORDER BY b.started_at DESC)
            FROM (SELECT * FROM pgreact_internal.retention_batches ORDER BY started_at DESC LIMIT limit_count) b),'[]'::jsonb),
        'tombstones',COALESCE((SELECT jsonb_agg(to_jsonb(t) ORDER BY t.pruned_at DESC)
            FROM (SELECT * FROM pgreact_internal.retention_tombstones ORDER BY pruned_at DESC LIMIT limit_count) t),'[]'::jsonb));
END
$$;

CREATE FUNCTION pgreact_api.retention_detail(target_family text, target_identity text)
RETURNS jsonb
LANGUAGE SQL STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
    SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM pgreact_internal.retention_families WHERE family=target_family)
        THEN jsonb_build_object('contract_version',9,'retained',false,
            'diagnostic',jsonb_build_object('code','M21_RETENTION_FAMILY_UNKNOWN',
                'message','the requested retention family is not supported'))
        WHEN EXISTS (SELECT 1 FROM pgreact_internal.retention_tombstones
                     WHERE family=target_family AND historical_identity=target_identity)
        THEN jsonb_build_object('contract_version',9,'retained',false,
            'diagnostic',jsonb_build_object('code','M21_HISTORY_NOT_RETAINED',
                'message','requested historical detail is outside retained coverage',
                'family',target_family,'historical_identity',target_identity,
                'remediation','restore a verified backup or use the surviving audit identity'))
        ELSE jsonb_build_object('contract_version',9,'retained',true,
            'family',target_family,'historical_identity',target_identity)
    END
$$;

REVOKE ALL ON FUNCTION pgreact_api.retention_configure(interval,interval,interval,interval,interval,interval,interval,interval,boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact_api.retention_remove() FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact_api.retention_preview(timestamptz,integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact_api.retention_apply(timestamptz,integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact_api.retention_status() FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact_api.retention_metrics() FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact_api.retention_doctor() FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact_api.retention_audit(integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact_api.retention_detail(text,text) FROM PUBLIC;

CREATE OR REPLACE FUNCTION pgreact_api.configure_roles(
    author_role regrole, operator_role regrole, worker_role regrole,
    reader_role regrole, advanced_reader_role regrole)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
    PERFORM pgreact_api.configure_roles(author_role, operator_role, worker_role, reader_role);
    EXECUTE format('GRANT EXECUTE ON FUNCTION pgreact_api.retention_configure(interval,interval,interval,interval,interval,interval,interval,interval,boolean), pgreact_api.retention_remove(), pgreact_api.retention_preview(timestamptz,integer), pgreact_api.retention_apply(timestamptz,integer), pgreact_api.retention_audit(integer) TO %I', operator_role::text);
    EXECUTE format('GRANT EXECUTE ON FUNCTION pgreact_api.retention_status(), pgreact_api.retention_metrics(), pgreact_api.retention_doctor(), pgreact_api.retention_detail(text,text) TO %I', reader_role::text);
END
$$;

COMMENT ON EXTENSION pg_react IS
    'M21 audited dependency-aware retention and measured catalog scale over the M20 platform';
