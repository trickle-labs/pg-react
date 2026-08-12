\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';

CREATE SCHEMA m12_order;
CREATE TABLE m12_order.before_source (
    id bigint PRIMARY KEY,
    deadline timestamptz NOT NULL
);
CREATE TABLE m12_order.after_source (
    id bigint PRIMARY KEY,
    deadline timestamptz NOT NULL
);
CREATE VIEW m12_order.before_candidate AS
SELECT id, deadline FROM m12_order.before_source;
CREATE VIEW m12_order.after_candidate AS
SELECT id, deadline FROM m12_order.after_source;
INSERT INTO m12_order.before_source VALUES (1, '2026-03-01 00:00:00+00');

SELECT pgreact_api.author_deadline_rule(
    'source-before-clock', 'm12_order.before_candidate'::regclass,
    'id', 'deadline', 'CONSTRAINT') AS before_version \gset
SELECT pgreact_api.author_deadline_rule(
    'clock-before-source', 'm12_order.after_candidate'::regclass,
    'id', 'deadline', 'CONSTRAINT') AS after_version \gset
SELECT set_config('m12.before_version', :'before_version', false);
SELECT set_config('m12.after_version', :'after_version', false);

SELECT pgreact.begin_deadline_refresh(12201);
SELECT pgreact.advance_deadline_clock('2026-03-01 00:00:00+00');
SELECT pgreact.finish_deadline_refresh();
INSERT INTO m12_order.after_source VALUES (1, '2026-03-01 00:00:00+00');
SELECT pgreact_api.run_rule('clock-before-source');

DO $$
DECLARE before_state jsonb; after_state jsonb;
BEGIN
    SELECT jsonb_build_object(
        'activation', (SELECT jsonb_agg(jsonb_build_object(
            'semantic_key', semantic_key, 'active', active,
            'generation', generation, 'revision', revision,
            'bindings', current_bindings - '__pgt_row_id') ORDER BY semantic_key)
            FROM pgreact_internal.activation_state
            WHERE rule_version_id = current_setting('m12.before_version')::uuid),
        'history', (SELECT jsonb_agg(jsonb_build_object(
            'semantic_key', activation.semantic_key,
            'event_kind', event.event_kind,
            'generation', event.generation,
            'revision', event.revision,
            'deadline', deadline.declared_deadline,
            'frontier', deadline.observed_frontier) ORDER BY event.event_id)
            FROM pgreact_internal.lifecycle_events event
            JOIN pgreact_internal.deadline_lifecycle deadline USING (event_id)
            JOIN pgreact_internal.activation_state activation
              USING (rule_version_id, activation_id)
            WHERE event.rule_version_id = current_setting('m12.before_version')::uuid))
    INTO before_state;
    SELECT jsonb_build_object(
        'activation', (SELECT jsonb_agg(jsonb_build_object(
            'semantic_key', semantic_key, 'active', active,
            'generation', generation, 'revision', revision,
            'bindings', current_bindings - '__pgt_row_id') ORDER BY semantic_key)
            FROM pgreact_internal.activation_state
            WHERE rule_version_id = current_setting('m12.after_version')::uuid),
        'history', (SELECT jsonb_agg(jsonb_build_object(
            'semantic_key', activation.semantic_key,
            'event_kind', event.event_kind,
            'generation', event.generation,
            'revision', event.revision,
            'deadline', deadline.declared_deadline,
            'frontier', deadline.observed_frontier) ORDER BY event.event_id)
            FROM pgreact_internal.lifecycle_events event
            JOIN pgreact_internal.deadline_lifecycle deadline USING (event_id)
            JOIN pgreact_internal.activation_state activation
              USING (rule_version_id, activation_id)
            WHERE event.rule_version_id = current_setting('m12.after_version')::uuid))
    INTO after_state;
    IF before_state IS DISTINCT FROM after_state
       OR before_state IS DISTINCT FROM jsonb_build_object(
           'activation', jsonb_build_array(jsonb_build_object(
               'semantic_key', 1, 'active', true, 'generation', 1, 'revision', 0,
               'bindings', jsonb_build_object(
                   'id', 1, 'deadline', '2026-03-01T00:00:00+00:00'))),
           'history', jsonb_build_array(jsonb_build_object(
               'semantic_key', 1, 'event_kind', 'ACTIVATE',
               'generation', 1, 'revision', 0,
               'deadline', '2026-03-01 00:00:00+00'::timestamptz,
               'frontier', '2026-03-01 00:00:00+00'::timestamptz))) THEN
        RAISE EXCEPTION 'M12 equivalent ordering diverged: %, %', before_state, after_state;
    END IF;
END
$$;

CREATE TEMP TABLE before_reconcile AS
SELECT pgreact_internal.deadline_history('clock-before-source') AS history;
DELETE FROM pgreact_internal.activation_state
WHERE rule_version_id = current_setting('m12.after_version')::uuid;
DO $$
DECLARE repaired bigint; actual jsonb; expected jsonb;
BEGIN
    repaired := pgreact_api.reconcile_rule('clock-before-source');
    SELECT jsonb_build_object(
        'repaired', repaired,
        'activation', (SELECT jsonb_agg(jsonb_build_object(
            'semantic_key', semantic_key, 'active', active,
            'generation', generation, 'revision', revision,
            'bindings', current_bindings - '__pgt_row_id') ORDER BY semantic_key)
            FROM pgreact_internal.activation_state
            WHERE rule_version_id = current_setting('m12.after_version')::uuid),
        'history', pgreact_internal.deadline_history('clock-before-source'),
        'audit', (SELECT jsonb_agg(jsonb_build_object(
            'mode', mode, 'rows_repaired', rows_repaired,
            'events_emitted', events_emitted, 'status', status)
            ORDER BY reconciliation_id)
            FROM pgreact_internal.reconciliation_audit
            WHERE rule_version_id = current_setting('m12.after_version')::uuid))
    INTO actual;
    SELECT history INTO expected FROM before_reconcile;
    IF actual IS DISTINCT FROM jsonb_build_object(
        'repaired', 1,
        'activation', jsonb_build_array(jsonb_build_object(
            'semantic_key', 1, 'active', true, 'generation', 1, 'revision', 0,
            'bindings', jsonb_build_object(
                'id', 1, 'deadline', '2026-03-01T00:00:00+00:00'))),
        'history', expected,
        'audit', jsonb_build_array(jsonb_build_object(
            'mode', 'STATE_ONLY', 'rows_repaired', 1,
            'events_emitted', 0, 'status', 'COMPLETED'))) THEN
        RAISE EXCEPTION 'M12 state-only reconciliation changed: %', actual;
    END IF;
END
$$;

CREATE TABLE m12_order.replace_source (
    id bigint PRIMARY KEY,
    deadline timestamptz NOT NULL
);
CREATE VIEW m12_order.replace_v1 AS
SELECT id, deadline FROM m12_order.replace_source;
CREATE VIEW m12_order.replace_v2 AS
SELECT id, deadline FROM m12_order.replace_source WHERE id > 0;
INSERT INTO m12_order.replace_source VALUES (7, '2026-02-01 00:00:00+00');
SELECT pgreact_api.author_deadline_rule(
    'replace-deadline', 'm12_order.replace_v1'::regclass,
    'id', 'deadline', 'CONSTRAINT');
SELECT pgreact_api.replace_deadline_rule(
    'replace-deadline', 'm12_order.replace_v2'::regclass,
    'id', 'deadline') AS replacement_version \gset

DO $$
DECLARE actual jsonb;
BEGIN
    SELECT jsonb_agg(jsonb_build_object(
        'state', version.state,
        'source', version.source_view_name,
        'deadline_column', deadline.deadline_column,
        'active_matches', (SELECT count(*)
            FROM pgreact_internal.activation_state activation
            WHERE activation.rule_version_id = version.rule_version_id
              AND activation.active)) ORDER BY version.created_at)
    INTO actual
    FROM pgreact_internal.rules rule
    JOIN pgreact_internal.rule_versions version USING (rule_id)
    JOIN pgreact_internal.deadline_rules deadline USING (rule_version_id)
    WHERE rule.rule_name = 'replace-deadline';
    IF actual IS DISTINCT FROM jsonb_build_array(
        jsonb_build_object('state', 'REMOVED',
            'source', 'm12_order.replace_v1',
            'deadline_column', 'deadline', 'active_matches', 1),
        jsonb_build_object('state', 'ACTIVE',
            'source', 'm12_order.replace_v2',
            'deadline_column', 'deadline', 'active_matches', 1)) THEN
        RAISE EXCEPTION 'M12 replacement state changed: %', actual;
    END IF;
END
$$;

SELECT pgreact_api.pause_rule('replace-deadline');
SELECT pgreact_api.remove_rule('replace-deadline');
DO $$
DECLARE actual jsonb;
BEGIN
    SELECT jsonb_build_object(
        'versions', (SELECT jsonb_agg(version.state ORDER BY version.created_at)
            FROM pgreact_internal.rules rule
            JOIN pgreact_internal.rule_versions version USING (rule_id)
            WHERE rule.rule_name = 'replace-deadline'),
        'scheduled', (SELECT COALESCE(jsonb_agg(rule.rule_name), '[]'::jsonb)
            FROM pgreact_internal.rules rule
            JOIN pgreact_internal.rule_versions version USING (rule_id)
            JOIN pgreact_internal.deadline_rules deadline USING (rule_version_id)
            WHERE rule.rule_name = 'replace-deadline' AND version.state = 'ACTIVE'),
        'status', pgreact_internal.deadline_status('replace-deadline'))
    INTO actual;
    IF actual IS DISTINCT FROM jsonb_build_object(
        'versions', jsonb_build_array('REMOVED', 'REMOVED'),
        'scheduled', '[]'::jsonb,
        'status', '[]'::jsonb) THEN
        RAISE EXCEPTION 'M12 removal left scheduled state: %', actual;
    END IF;
END
$$;

SELECT 'M12 ordering, reconciliation, replacement, and removal passed';
