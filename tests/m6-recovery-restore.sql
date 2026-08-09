\set ON_ERROR_STOP on

DO $$
DECLARE expected m6_recovery.snapshot%ROWTYPE; actual m6_recovery.snapshot%ROWTYPE;
BEGIN
    SELECT * INTO STRICT expected FROM m6_recovery.snapshot;
    SELECT
        (SELECT jsonb_agg(to_jsonb(e) ORDER BY episode_id) FROM pgreact.episodes e),
        (SELECT COALESCE(jsonb_agg(to_jsonb(a) ORDER BY episode_id, attempt_no), '[]'::jsonb)
         FROM pgreact.attempts a),
        (SELECT jsonb_agg(to_jsonb(b) ORDER BY claimed_at, batch_id) FROM pgreact.batch_history() b),
        (SELECT jsonb_agg(to_jsonb(e) ORDER BY episode_id) FROM m6_recovery.effects e)
    INTO actual;
    IF actual IS DISTINCT FROM expected THEN
        RAISE EXCEPTION 'M6 durable state changed during physical recovery: %', to_jsonb(actual);
    END IF;
END
$$;

SELECT pgreact.prepare_recovery() = 1 AS recovery_barriered \gset
\if :recovery_barriered
\else
  SELECT 1 / 0;
\endif
SELECT rebuilt_rules = 1 AND blocked_rules = 0 AS metadata_rebuilt
FROM pgreact.rebuild_transient_metadata() \gset
\if :metadata_rebuilt
\else
  SELECT 1 / 0;
\endif
SELECT pgreact.reconcile_rule(rule_version_id, 'STATE_ONLY') >= 0 AS reconciled
FROM m6_recovery.control \gset
\if :reconciled
\else
  SELECT 1 / 0;
\endif
SELECT * FROM pgreact.execute_claimed_batch(
    (SELECT pending_batch_id FROM m6_recovery.control), 'm6-recovery-pending'
);

INSERT INTO m6_recovery.facts VALUES (5), (6);
SELECT pgreact.begin_refresh(rule_version_id, 6402) FROM m6_recovery.control;
BEGIN;
SELECT pgreact.refresh_rule(rule_version_id) FROM m6_recovery.control;
COMMIT;
SELECT pgreact.clear_refresh_barrier(rule_version_id) FROM m6_recovery.control;
SELECT pgreact.release_refresh_lock();
CREATE TEMP TABLE restored_claim AS
SELECT b.* FROM m6_recovery.control c
CROSS JOIN LATERAL pgreact.claim_batch(
    c.rule_version_id, 'ACTIVATE', 'm6-recovery-restored', 2, interval '120 seconds'
) b;
SELECT batch_id::text AS restored_batch_id FROM restored_claim ORDER BY item_order LIMIT 1 \gset
SELECT * FROM pgreact.execute_claimed_batch(:'restored_batch_id'::uuid, 'm6-recovery-restored');

DO $$
DECLARE actual jsonb; expected jsonb;
BEGIN
    SELECT jsonb_build_object(
        'effects', (SELECT jsonb_agg(to_jsonb(e) ORDER BY episode_id)
                    FROM m6_recovery.effects e WHERE fact_id <= 4),
        'batches', (SELECT jsonb_agg(jsonb_build_object(
            'event_kind', event_kind, 'worker_id', worker_id, 'state', state, 'items', items
        ) ORDER BY claimed_at) FROM pgreact.batch_history()
        WHERE worker_id <> 'm6-recovery-restored')
    ) INTO actual;
    IF actual IS DISTINCT FROM '{
      "effects":[
        {"episode_id":1,"fact_id":1},{"episode_id":2,"fact_id":2},
        {"episode_id":3,"fact_id":3},{"episode_id":4,"fact_id":4}
      ],
      "batches":[
        {"event_kind":"ACTIVATE","worker_id":"m6-recovery-completed","state":"COMPLETED","items":[
          {"item_order":1,"episode_id":1,"attempt_no":1,"outcome":"COMPLETED","error_code":null,"error_message":null},
          {"item_order":2,"episode_id":2,"attempt_no":1,"outcome":"COMPLETED","error_code":null,"error_message":null}
        ]},
        {"event_kind":"ACTIVATE","worker_id":"m6-recovery-pending","state":"COMPLETED","items":[
          {"item_order":1,"episode_id":3,"attempt_no":1,"outcome":"COMPLETED","error_code":null,"error_message":null},
          {"item_order":2,"episode_id":4,"attempt_no":1,"outcome":"COMPLETED","error_code":null,"error_message":null}
        ]}
      ]
    }'::jsonb THEN RAISE EXCEPTION 'restored batch history changed: %', actual; END IF;

    SELECT jsonb_build_object(
        'batch', (SELECT jsonb_build_object(
            'event_kind', event_kind, 'worker_id', worker_id, 'state', state, 'items', items
        ) FROM pgreact.batch_history() WHERE worker_id = 'm6-recovery-restored'),
        'effects', (SELECT jsonb_agg(to_jsonb(e) ORDER BY episode_id)
                    FROM m6_recovery.effects e WHERE fact_id > 4)
    ) INTO actual;
    SELECT jsonb_build_object(
        'batch', jsonb_build_object(
            'event_kind', 'ACTIVATE', 'worker_id', 'm6-recovery-restored', 'state', 'COMPLETED',
            'items', jsonb_agg(jsonb_build_object(
                'item_order', item_order, 'episode_id', episode_id, 'attempt_no', 1,
                'outcome', 'COMPLETED', 'error_code', NULL, 'error_message', NULL
            ) ORDER BY item_order)
        ),
        'effects', jsonb_agg(jsonb_build_object(
            'episode_id', episode_id, 'fact_id', item_order + 4
        ) ORDER BY episode_id)
    ) INTO expected FROM restored_claim;
    IF actual IS DISTINCT FROM expected THEN
        RAISE EXCEPTION 'post-restore batch continuation changed: %', actual;
    END IF;
END
$$;

SELECT 'M6 physical recovery preserved and continued exact batch execution' AS result;
