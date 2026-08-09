\set ON_ERROR_STOP on

DO $$
DECLARE
    manifest jsonb;
    environment_mappings jsonb;
    actual jsonb;
    expected jsonb;
    digest text;
BEGIN
    SELECT definition, mappings INTO manifest, environment_mappings
    FROM m5_fixture.manifests WHERE version = '2';
    SELECT min(plan_digest) INTO digest FROM pgreact.preview_pack(manifest, environment_mappings);
    IF digest !~ '^[0-9a-f]{64}$' THEN
        RAISE EXCEPTION 'invalid v2 preview digest: %', digest;
    END IF;
    SELECT jsonb_agg(jsonb_build_object(
        'order', action_order,
        'action', action,
        'rule', rule_name,
        'dependencies', dependencies,
        'create', COALESCE(generated_object_changes -> 'create', '[]'::jsonb),
        'retire_count', jsonb_array_length(COALESCE(generated_object_changes -> 'retire', '[]'::jsonb)),
        'lifecycle_risks', lifecycle_risks
    ) ORDER BY action_order) INTO actual
    FROM pgreact.preview_pack(manifest, environment_mappings);
    expected := jsonb_build_array(
        jsonb_build_object(
            'order', 1, 'action', 'REPLACE', 'rule', 'risk-command',
            'dependencies', jsonb_build_array(),
            'create', jsonb_build_array('match_relation', 'lifecycle_triggers', 'typed_dispatchers'),
            'retire_count', 1,
            'lifecycle_risks', jsonb_build_array('DRAIN_OLD applies to prior pending, retrying, and leased work')
        ),
        jsonb_build_object(
            'order', 2, 'action', 'REPLACE', 'rule', 'risk-outbox',
            'dependencies', jsonb_build_array('risk-command'),
            'create', jsonb_build_array('match_relation', 'lifecycle_triggers'),
            'retire_count', 1,
            'lifecycle_risks', jsonb_build_array('CANCEL_OLD applies to prior pending, retrying, and leased work')
        ),
        jsonb_build_object(
            'order', 3, 'action', 'REMOVE', 'rule', 'risk-base',
            'dependencies', jsonb_build_array(), 'create', jsonb_build_array(),
            'retire_count', 1,
            'lifecycle_risks', jsonb_build_array('CANCEL_OLD applies to pending, retrying, and leased work')
        )
    );
    IF actual IS DISTINCT FROM expected THEN
        RAISE EXCEPTION 'unexpected v2 preview: %', actual;
    END IF;
END
$$;

INSERT INTO m5_fixture.facts VALUES (1, 10, true);
SELECT rule_version_id AS old_command_version
FROM pgreact.rule_status() WHERE rule_name = 'risk-command' AND state = 'ACTIVE' \gset
SELECT pgreact.begin_refresh(:'old_command_version'::uuid, 50001);
BEGIN;
SELECT pgreact.refresh_rule(:'old_command_version'::uuid);
COMMIT;
SELECT pgreact.clear_refresh_barrier(:'old_command_version'::uuid);
SELECT pgreact.release_refresh_lock();
SELECT episode_id AS old_episode, lease_token AS old_lease
FROM pgreact.claim_episode(:'old_command_version'::uuid, 'm5-old', 60) \gset
SELECT rule_version_id AS old_outbox_version
FROM pgreact.rule_status() WHERE rule_name = 'risk-outbox' AND state = 'ACTIVE' \gset
SELECT pgreact.begin_refresh(:'old_outbox_version'::uuid, 50004);
BEGIN;
SELECT pgreact.refresh_rule(:'old_outbox_version'::uuid);
COMMIT;
SELECT pgreact.clear_refresh_barrier(:'old_outbox_version'::uuid);
SELECT pgreact.release_refresh_lock();

DO $$
DECLARE
    manifest jsonb;
    environment_mappings jsonb;
    digest text;
    phase text;
    failure text;
    actual jsonb;
    expected jsonb := jsonb_build_array(jsonb_build_object('version', '1', 'status', 'ACTIVE'));
    objects_before text[];
    objects_after text[];
BEGIN
    SELECT definition, mappings INTO manifest, environment_mappings
    FROM m5_fixture.manifests WHERE version = '2';
    SELECT min(plan_digest) INTO digest FROM pgreact.preview_pack(manifest, environment_mappings);
    SELECT array_agg(object_identity ORDER BY object_identity) INTO objects_before
    FROM (
        SELECT 'relation:' || c.oid::regclass::text AS object_identity
        FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'pgreact_runtime'
        UNION ALL
        SELECT 'function:' || p.oid::regprocedure::text
        FROM pg_catalog.pg_proc p JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'pgreact_runtime'
    ) AS runtime_objects;
    FOREACH phase IN ARRAY ARRAY['catalog', 'rules', 'removals', 'activation'] LOOP
        failure := NULL;
        BEGIN
            PERFORM set_config('pgreact.test_fail_pack_phase', phase, true);
            PERFORM pgreact.deploy_pack(manifest, digest, environment_mappings);
        EXCEPTION WHEN OTHERS THEN
            GET STACKED DIAGNOSTICS failure = MESSAGE_TEXT;
        END;
        PERFORM set_config('pgreact.test_fail_pack_phase', '', true);
        IF failure IS DISTINCT FROM format('injected rule-pack failure after %s phase', phase) THEN
            RAISE EXCEPTION 'unexpected injected failure for %: %', phase, failure;
        END IF;
        SELECT jsonb_agg(jsonb_build_object('version', version, 'status', status) ORDER BY deployed_at)
          INTO actual FROM pgreact.pack_history('risk-pack');
        IF actual IS DISTINCT FROM expected THEN
            RAISE EXCEPTION 'failure after % changed public pack history: %', phase, actual;
        END IF;
        SELECT array_agg(object_identity ORDER BY object_identity) INTO objects_after
        FROM (
            SELECT 'relation:' || c.oid::regclass::text AS object_identity
            FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = 'pgreact_runtime'
            UNION ALL
            SELECT 'function:' || p.oid::regprocedure::text
            FROM pg_catalog.pg_proc p JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
            WHERE n.nspname = 'pgreact_runtime'
        ) AS runtime_objects;
        IF objects_after IS DISTINCT FROM objects_before THEN
            RAISE EXCEPTION 'failure after % left generated objects: before %, after %',
                phase, objects_before, objects_after;
        END IF;
        IF (SELECT min(plan_digest) FROM pgreact.preview_pack(manifest, environment_mappings)) <> digest THEN
            RAISE EXCEPTION 'failure after % changed the deployment plan', phase;
        END IF;
    END LOOP;
    PERFORM pgreact.deploy_pack(manifest, digest, environment_mappings);
END
$$;

DO $$
DECLARE
    actual jsonb;
    old_outbox_version uuid;
BEGIN
    SELECT jsonb_agg(state ORDER BY state) INTO actual
    FROM pgreact.rule_status() WHERE rule_name = 'risk-command';
    IF actual IS DISTINCT FROM '["ACTIVE", "DRAINING"]'::jsonb THEN
        RAISE EXCEPTION 'old leased work did not retain an exact draining version: %', actual;
    END IF;
    SELECT (action ->> 'old_rule_version_id')::uuid INTO old_outbox_version
    FROM pgreact.pack_history('risk-pack') h
    CROSS JOIN LATERAL jsonb_array_elements(h.actions) AS a(action)
    WHERE h.version = '2' AND action ->> 'rule' = 'risk-outbox';
    SELECT jsonb_agg(state ORDER BY episode_id) INTO actual
    FROM pgreact.agenda_status() WHERE rule_version_id = old_outbox_version;
    IF actual IS DISTINCT FROM '["CANCELLED"]'::jsonb THEN
        RAISE EXCEPTION 'CANCEL_OLD did not cancel the exact pending outbox work: %', actual;
    END IF;
END
$$;

SELECT pgreact.execute_claimed_episode(:old_episode, 'm5-old', :'old_lease'::uuid) = 'COMPLETED' AS old_completed \gset
\if :old_completed
\else
  \quit 1
\endif

DO $$
DECLARE actual jsonb;
BEGIN
    SELECT jsonb_agg(to_jsonb(a) - 'activation_id' ORDER BY label, value) INTO actual
    FROM m5_fixture.actions a;
    IF actual IS DISTINCT FROM '[{"label": "V1", "value": 10}]'::jsonb THEN
        RAISE EXCEPTION 'old work did not execute through its immutable v1 binding: %', actual;
    END IF;
END
$$;

INSERT INTO m5_fixture.facts VALUES (2, 20, true);
SELECT rule_version_id AS new_command_version
FROM pgreact.rule_status() WHERE rule_name = 'risk-command' AND state = 'ACTIVE' \gset
SELECT pgreact.begin_refresh(:'new_command_version'::uuid, 50002);
BEGIN;
SELECT pgreact.refresh_rule(:'new_command_version'::uuid);
COMMIT;
SELECT pgreact.clear_refresh_barrier(:'new_command_version'::uuid);
SELECT pgreact.release_refresh_lock();
SELECT episode_id AS new_episode, lease_token AS new_lease
FROM pgreact.claim_episode(:'new_command_version'::uuid, 'm5-new', 60) \gset
SELECT pgreact.execute_claimed_episode(:new_episode, 'm5-new', :'new_lease'::uuid) = 'COMPLETED' AS new_completed \gset
\if :new_completed
\else
  \quit 1
\endif

SELECT rule_version_id AS outbox_version
FROM pgreact.rule_status() WHERE rule_name = 'risk-outbox' AND state = 'ACTIVE' \gset
SELECT pgreact.begin_refresh(:'outbox_version'::uuid, 50003);
BEGIN;
SELECT pgreact.refresh_rule(:'outbox_version'::uuid);
COMMIT;
SELECT pgreact.clear_refresh_barrier(:'outbox_version'::uuid);
SELECT pgreact.release_refresh_lock();
SELECT episode_id AS outbox_episode, lease_token AS outbox_lease
FROM pgreact.claim_episode(:'outbox_version'::uuid, 'm5-outbox', 60) \gset
SELECT pgreact.execute_claimed_episode(:outbox_episode, 'm5-outbox', :'outbox_lease'::uuid) = 'COMPLETED' AS outbox_completed \gset
\if :outbox_completed
\else
  \quit 1
\endif

DO $$
DECLARE actual jsonb;
BEGIN
    SELECT jsonb_agg(to_jsonb(a) - 'activation_id' ORDER BY label, value) INTO actual
    FROM m5_fixture.actions a;
    IF actual IS DISTINCT FROM '[{"label": "V1", "value": 10}, {"label": "V2", "value": 20}]'::jsonb THEN
        RAISE EXCEPTION 'new work did not use the v2 binding: %', actual;
    END IF;
    SELECT jsonb_agg(
        jsonb_set(
            envelope - ARRAY[
                'rule_id', 'rule_version_id', 'activation_id', 'episode_id', 'idempotency_key'
            ],
            '{new}', (envelope -> 'new') - '__pgt_row_id'
        ) ORDER BY idempotency_key
    ) INTO actual FROM m5_fixture.outbox;
    IF actual IS DISTINCT FROM '[{"version": 1, "event_kind": "ACTIVATE", "generation": 1, "revision": 0, "old": null, "new": {"id": 2, "value": 20}}]'::jsonb THEN
        RAISE EXCEPTION 'outbox binding output changed: %', actual;
    END IF;
END
$$;

DO $$
DECLARE
    actual jsonb;
    expected jsonb;
BEGIN
    SELECT jsonb_agg(jsonb_build_object(
        'version', version,
        'status', status,
        'actions', (
            SELECT jsonb_agg(value - 'old_rule_version_id' - 'new_rule_version_id' ORDER BY value ->> 'order')
            FROM jsonb_array_elements(actions) AS a(value)
        )
    ) ORDER BY deployed_at) INTO actual
    FROM pgreact.pack_history('risk-pack');
    expected := jsonb_build_array(
        jsonb_build_object('version', '1', 'status', 'SUPERSEDED', 'actions', jsonb_build_array(
            jsonb_build_object('order', 1, 'action', 'ADD', 'rule', 'risk-base', 'old_work_policy', 'DRAIN_OLD',
                'details', jsonb_build_object('source', 'logical.base', 'dependencies', jsonb_build_array())),
            jsonb_build_object('order', 2, 'action', 'ADD', 'rule', 'risk-command', 'old_work_policy', 'DRAIN_OLD',
                'details', jsonb_build_object('source', 'logical.command', 'dependencies', jsonb_build_array('risk-base'))),
            jsonb_build_object('order', 3, 'action', 'ADD', 'rule', 'risk-outbox', 'old_work_policy', 'DRAIN_OLD',
                'details', jsonb_build_object('source', 'logical.command', 'dependencies', jsonb_build_array('risk-command')))
        )),
        jsonb_build_object('version', '2', 'status', 'ACTIVE', 'actions', jsonb_build_array(
            jsonb_build_object('order', 1, 'action', 'REPLACE', 'rule', 'risk-command', 'old_work_policy', 'DRAIN_OLD',
                'details', jsonb_build_object('source', 'logical.command', 'dependencies', jsonb_build_array())),
            jsonb_build_object('order', 2, 'action', 'REPLACE', 'rule', 'risk-outbox', 'old_work_policy', 'CANCEL_OLD',
                'details', jsonb_build_object('source', 'logical.command', 'dependencies', jsonb_build_array('risk-command'))),
            jsonb_build_object('order', 3, 'action', 'REMOVE', 'rule', 'risk-base', 'old_work_policy', 'CANCEL_OLD',
                'details', '{}'::jsonb)
        ))
    );
    IF actual IS DISTINCT FROM expected THEN
        RAISE EXCEPTION 'unexpected two-version history: %', actual;
    END IF;
    SELECT jsonb_agg(jsonb_build_object(
        'rule', value ->> 'rule', 'state', value ->> 'state',
        'source_drift', value ->> 'source_drift',
        'outstanding_work', (value ->> 'outstanding_work')::integer
    ) ORDER BY value ->> 'rule') INTO actual
    FROM jsonb_array_elements(pgreact.explain_pack('risk-pack') -> 'members') AS member(value);
    expected := '[
        {"rule": "risk-command", "state": "ACTIVE", "source_drift": "CURRENT", "outstanding_work": 0},
        {"rule": "risk-outbox", "state": "ACTIVE", "source_drift": "CURRENT", "outstanding_work": 0}
    ]'::jsonb;
    IF actual IS DISTINCT FROM expected THEN
        RAISE EXCEPTION 'unexpected pack diagnostics: %', actual;
    END IF;
END
$$;

CREATE TEMP TABLE m5_stale_preview AS
SELECT min(plan_digest) AS plan_digest
FROM pgreact.preview_pack(
    (SELECT definition FROM m5_fixture.manifests WHERE version = '3'),
    (SELECT mappings FROM m5_fixture.manifests WHERE version = '3')
);
SELECT format(
    'CREATE OR REPLACE VIEW %1$I.command_v2 AS SELECT id, value FROM %1$I.facts WHERE enabled AND value >= -1',
    :'actual_schema'
) \gexec

DO $$
DECLARE
    manifest jsonb;
    environment_mappings jsonb;
    stale_digest text;
    failure text;
BEGIN
    SELECT definition, mappings INTO manifest, environment_mappings
    FROM m5_fixture.manifests WHERE version = '3';
    SELECT plan_digest INTO stale_digest FROM m5_stale_preview;
    BEGIN
        PERFORM pgreact.deploy_pack(manifest, stale_digest, environment_mappings);
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS failure = MESSAGE_TEXT;
    END;
    IF failure IS DISTINCT FROM 'rule-pack preview is stale' THEN
        RAISE EXCEPTION 'stale preview was not rejected exactly: %', failure;
    END IF;
    IF EXISTS (SELECT 1 FROM pgreact.pack_history('risk-pack') WHERE version = '3') THEN
        RAISE EXCEPTION 'stale deployment changed history';
    END IF;
    SELECT min(plan_digest) INTO failure FROM pgreact.preview_pack(manifest, environment_mappings);
    PERFORM pgreact.deploy_pack(manifest, failure, environment_mappings);
END
$$;

DO $$
DECLARE
    base jsonb;
    environment_mappings jsonb;
    invalid jsonb;
    actual text[];
BEGIN
    SELECT definition, mappings INTO base, environment_mappings
    FROM m5_fixture.manifests WHERE version = '4';

    invalid := jsonb_set(jsonb_set(base, '{version}', '"bad-missing"'::jsonb),
        '{rules,0,depends_on}', '["absent"]'::jsonb);
    SELECT array_agg(code ORDER BY code) INTO actual
    FROM pgreact.validate_pack(invalid, environment_mappings) WHERE severity = 'ERROR';
    IF actual IS DISTINCT FROM ARRAY['DEPENDENCY_MISSING'] THEN
        RAISE EXCEPTION 'missing-dependency diagnostics changed: %', actual;
    END IF;

    invalid := jsonb_set(jsonb_set(base, '{version}', '"bad-cycle"'::jsonb),
        '{rules,0,depends_on}', '["risk-outbox"]'::jsonb);
    SELECT array_agg(code ORDER BY code) INTO actual
    FROM pgreact.validate_pack(invalid, environment_mappings) WHERE severity = 'ERROR';
    IF actual IS DISTINCT FROM ARRAY['DEPENDENCY_CYCLE', 'DEPENDENCY_ORDER_INVALID'] THEN
        RAISE EXCEPTION 'cycle/order diagnostics changed: %', actual;
    END IF;

    invalid := jsonb_set(jsonb_set(base, '{version}', '"bad-binding"'::jsonb),
        '{rules,0,on_activate}', '"logical.missing(pgreact.activation_context,logical.command)"'::jsonb);
    SELECT array_agg(code ORDER BY code) INTO actual
    FROM pgreact.validate_pack(invalid, environment_mappings) WHERE severity = 'ERROR';
    IF actual IS DISTINCT FROM ARRAY['CONSEQUENCE_NOT_FOUND'] THEN
        RAISE EXCEPTION 'binding diagnostics changed: %', actual;
    END IF;

    invalid := jsonb_set(jsonb_set(base, '{version}', '"bad-owner"'::jsonb),
        '{owner}', '"not-the-session-owner"'::jsonb);
    SELECT array_agg(code ORDER BY code) INTO actual
    FROM pgreact.validate_pack(invalid, environment_mappings) WHERE severity = 'ERROR';
    IF actual IS DISTINCT FROM ARRAY['PACK_OWNER_UNSAFE'] THEN
        RAISE EXCEPTION 'ownership diagnostics changed: %', actual;
    END IF;

    invalid := jsonb_set(jsonb_set(base, '{version}', '"bad-source"'::jsonb),
        '{rules,0,definition}', '"logical.missing_source"'::jsonb);
    SELECT array_agg(code ORDER BY code) INTO actual
    FROM pgreact.validate_pack(invalid, environment_mappings) WHERE severity = 'ERROR';
    IF actual IS DISTINCT FROM ARRAY['SOURCE_NOT_FOUND'] THEN
        RAISE EXCEPTION 'source diagnostics changed: %', actual;
    END IF;

    invalid := jsonb_build_object(
        'format_version', 1, 'pack', 'risk-pack', 'version', 'bad-removal-order',
        'owner', 'author', 'rules', jsonb_build_array(base -> 'rules' -> 1),
        'remove', jsonb_build_array(jsonb_build_object(
            'name', 'risk-command', 'old_work_policy', 'DRAIN_OLD'))
    );
    SELECT array_agg(code ORDER BY code) INTO actual
    FROM pgreact.validate_pack(invalid, environment_mappings) WHERE severity = 'ERROR';
    IF actual IS DISTINCT FROM ARRAY['DEPENDENCY_MISSING'] THEN
        RAISE EXCEPTION 'removal-order diagnostics changed: %', actual;
    END IF;
END
$$;

SELECT 'M5 atomic deployment, replacement, drift, binding, and diagnostics checks passed' AS result;
