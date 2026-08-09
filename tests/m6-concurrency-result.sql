\set ON_ERROR_STOP on

DO $$
DECLARE actual jsonb;
BEGIN
    SELECT jsonb_build_object(
        'batch_state', state,
        'items', items,
        'episodes', (SELECT jsonb_agg(jsonb_build_object(
            'episode_id', episode_id, 'state', state, 'worker_id', worker_id,
            'attempt_count', attempt_count
        ) ORDER BY episode_id) FROM pgreact.episodes),
        'effects', (SELECT COALESCE(jsonb_agg(to_jsonb(e) ORDER BY episode_id), '[]'::jsonb)
                    FROM m6_concurrency.effects e)
    ) INTO actual
    FROM pgreact.batch_history((SELECT batch_id FROM m6_concurrency.control));
    IF actual IS DISTINCT FROM '{
      "batch_state":"CLAIMED",
      "items":[
        {"item_order":1,"episode_id":1,"attempt_no":1,"outcome":null,"error_code":null,"error_message":null},
        {"item_order":2,"episode_id":2,"attempt_no":1,"outcome":null,"error_code":null,"error_message":null}
      ],
      "episodes":[
        {"episode_id":1,"state":"LEASED","worker_id":"m6-concurrency","attempt_count":1},
        {"episode_id":2,"state":"LEASED","worker_id":"m6-concurrency","attempt_count":1}
      ],
      "effects":[]
    }'::jsonb THEN RAISE EXCEPTION 'disconnected transaction did not roll back exactly: %', actual; END IF;
END
$$;

UPDATE m6_concurrency.control SET sleep_enabled = false;
SELECT * FROM pgreact.execute_claimed_batch(
    (SELECT batch_id FROM m6_concurrency.control), 'm6-concurrency'
);

DO $$
DECLARE actual jsonb;
BEGIN
    SELECT jsonb_build_object(
        'batch_state', state,
        'items', items,
        'effects', (SELECT jsonb_agg(to_jsonb(e) ORDER BY episode_id)
                    FROM m6_concurrency.effects e)
    ) INTO actual
    FROM pgreact.batch_history((SELECT batch_id FROM m6_concurrency.control));
    IF actual IS DISTINCT FROM '{
      "batch_state":"COMPLETED",
      "items":[
        {"item_order":1,"episode_id":1,"attempt_no":1,"outcome":"COMPLETED","error_code":null,"error_message":null},
        {"item_order":2,"episode_id":2,"attempt_no":1,"outcome":"COMPLETED","error_code":null,"error_message":null}
      ],
      "effects":[{"episode_id":1,"fact_id":1},{"episode_id":2,"fact_id":2}]
    }'::jsonb THEN RAISE EXCEPTION 'recovered execution changed: %', actual; END IF;
END
$$;

SELECT 'M6 execution concurrency and disconnect recovery passed' AS result;
