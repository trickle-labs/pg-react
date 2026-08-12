\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';

CREATE SCHEMA m12_upgrade;
CREATE TABLE m12_upgrade.m11_source (
    id bigint PRIMARY KEY,
    enabled boolean NOT NULL DEFAULT false
);
CREATE VIEW m12_upgrade.m11_candidate AS
SELECT id FROM m12_upgrade.m11_source WHERE enabled;
CREATE FUNCTION m12_upgrade.activate(
    context pgreact.activation_context,
    candidate m12_upgrade.m11_candidate
)
RETURNS void LANGUAGE SQL AS $$ SELECT $$;
INSERT INTO m12_upgrade.m11_source VALUES (1, false);
SELECT pgreact_api.author_rule(
    'preserved-m11', 'm12_upgrade.m11_candidate'::regclass,
    'id', 'COMMAND',
    'm12_upgrade.activate(pgreact.activation_context,m12_upgrade.m11_candidate)'
) AS m11_version \gset
UPDATE m12_upgrade.m11_source SET enabled = true WHERE id = 1;
SELECT pgreact_api.run_rule('preserved-m11');
SELECT set_config('m12.m11_version', :'m11_version', false);

CREATE TABLE m12_upgrade.deadline_source (
    id bigint PRIMARY KEY,
    deadline timestamptz NOT NULL
);
CREATE VIEW m12_upgrade.deadline_candidate AS
SELECT id, deadline FROM m12_upgrade.deadline_source;
INSERT INTO m12_upgrade.deadline_source VALUES
    (10, '2026-03-31 00:00:00+00'),
    (11, '2026-04-01 00:00:00+00');

CREATE TEMP TABLE m12_before AS
SELECT jsonb_build_object(
    'rule', (SELECT to_jsonb(version)
        FROM pgreact_internal.rule_versions version
        WHERE rule_version_id = current_setting('m12.m11_version')::uuid),
    'activations', (SELECT jsonb_agg(to_jsonb(activation)
                                     ORDER BY activation.semantic_key)
        FROM pgreact_internal.activation_state activation
        WHERE rule_version_id = current_setting('m12.m11_version')::uuid),
    'events', (SELECT jsonb_agg(to_jsonb(event) ORDER BY event.event_id)
        FROM pgreact_internal.lifecycle_events event
        WHERE rule_version_id = current_setting('m12.m11_version')::uuid),
    'agenda', (SELECT jsonb_agg(to_jsonb(agenda) ORDER BY agenda.episode_id)
        FROM pgreact_internal.agenda agenda
        WHERE rule_version_id = current_setting('m12.m11_version')::uuid)
) AS state;

ALTER EXTENSION pg_react UPDATE TO '0.9.0';

DO $$
DECLARE actual jsonb; expected jsonb;
BEGIN
    SELECT jsonb_build_object(
        'rule', (SELECT to_jsonb(version)
            FROM pgreact_internal.rule_versions version
            WHERE rule_version_id = current_setting('m12.m11_version')::uuid),
        'activations', (SELECT jsonb_agg(to_jsonb(activation)
                                         ORDER BY activation.semantic_key)
            FROM pgreact_internal.activation_state activation
            WHERE rule_version_id = current_setting('m12.m11_version')::uuid),
        'events', (SELECT jsonb_agg(to_jsonb(event) ORDER BY event.event_id)
            FROM pgreact_internal.lifecycle_events event
            WHERE rule_version_id = current_setting('m12.m11_version')::uuid),
        'agenda', (SELECT jsonb_agg(to_jsonb(agenda) ORDER BY agenda.episode_id)
            FROM pgreact_internal.agenda agenda
            WHERE rule_version_id = current_setting('m12.m11_version')::uuid)
    )
    INTO actual;
    SELECT state INTO STRICT expected FROM m12_before;
    IF actual IS DISTINCT FROM expected
       OR (SELECT extversion FROM pg_catalog.pg_extension WHERE extname = 'pg_react') <> '0.9.0'
       OR (SELECT to_jsonb(clock) - ARRAY['last_sampled_time', 'last_advanced_at']
           FROM pgreact_internal.clock_frontier clock)
          IS DISTINCT FROM jsonb_build_object('singleton', true, 'frontier', '-infinity'::timestamptz)
       OR EXISTS (SELECT 1 FROM pgreact_internal.deadline_rules) THEN
        RAISE EXCEPTION 'M12 upgrade changed populated M11 state: %, %', actual, expected;
    END IF;
END
$$;

SELECT pgreact_api.author_deadline_rule(
    'upgraded-deadline', 'm12_upgrade.deadline_candidate'::regclass,
    'id', 'deadline', 'CONSTRAINT') AS deadline_version \gset
SELECT set_config('m12.deadline_version', :'deadline_version', false);
SELECT pgreact.begin_deadline_refresh(12301);
SELECT pgreact.advance_deadline_clock('2026-04-01 00:00:00+00');
SELECT pgreact.finish_deadline_refresh();

DO $$
DECLARE actual jsonb;
BEGIN
    SELECT jsonb_build_object(
        'm11', (SELECT jsonb_build_object(
            'active', activation.active,
            'generation', activation.generation,
            'agenda_state', agenda.state,
            'event_kind', agenda.event_kind)
            FROM pgreact_internal.activation_state activation
            JOIN pgreact_internal.agenda agenda
              USING (rule_version_id, activation_id)
            WHERE activation.rule_version_id = current_setting('m12.m11_version')::uuid),
        'm12', (SELECT jsonb_agg(jsonb_build_object(
            'semantic_key', activation.semantic_key,
            'active', activation.active,
            'generation', activation.generation,
            'deadline', deadline.declared_deadline,
            'frontier', deadline.observed_frontier)
            ORDER BY activation.semantic_key)
            FROM pgreact_internal.activation_state activation
            JOIN pgreact_internal.lifecycle_events event
              USING (rule_version_id, activation_id)
            JOIN pgreact_internal.deadline_lifecycle deadline USING (event_id)
            WHERE activation.rule_version_id = current_setting('m12.deadline_version')::uuid),
        'clock', (SELECT jsonb_build_object(
            'frontier', frontier,
            'sampled_time', last_sampled_time)
            FROM pgreact_internal.clock_frontier))
    INTO actual;
    IF actual IS DISTINCT FROM jsonb_build_object(
        'm11', jsonb_build_object(
            'active', true, 'generation', 1,
            'agenda_state', 'PENDING', 'event_kind', 'ACTIVATE'),
        'm12', jsonb_build_array(
            jsonb_build_object('semantic_key', 10, 'active', true, 'generation', 1,
                'deadline', '2026-03-31 00:00:00+00'::timestamptz,
                'frontier', '2026-04-01 00:00:00+00'::timestamptz),
            jsonb_build_object('semantic_key', 11, 'active', true, 'generation', 1,
                'deadline', '2026-04-01 00:00:00+00'::timestamptz,
                'frontier', '2026-04-01 00:00:00+00'::timestamptz)),
        'clock', jsonb_build_object(
            'frontier', '2026-04-01 00:00:00+00'::timestamptz,
            'sampled_time', '2026-04-01 00:00:00+00'::timestamptz)) THEN
        RAISE EXCEPTION 'M12 upgraded first-pass state changed: %', actual;
    END IF;
END
$$;

SELECT 'M12 direct 0.8.0 to 0.9.0 upgrade preserved M11 and caught up deadlines';
