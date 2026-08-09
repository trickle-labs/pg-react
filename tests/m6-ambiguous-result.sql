\set ON_ERROR_STOP on

DO $$
DECLARE actual jsonb;
BEGIN
    SELECT jsonb_build_object(
        'effects', (SELECT jsonb_agg(to_jsonb(e) ORDER BY episode_id)
                    FROM m6_concurrency.effects e),
        'batch', (SELECT jsonb_build_object('state', state, 'items', items)
                  FROM pgreact.batch_history() WHERE worker_id = 'm6-ambiguous'),
        'attempts', (SELECT jsonb_agg(jsonb_build_object(
            'episode_id', episode_id, 'attempt_no', attempt_no, 'status', status
        ) ORDER BY episode_id, attempt_no) FROM pgreact.attempts WHERE episode_id >= 3)
    ) INTO actual;
    IF actual IS DISTINCT FROM '{
      "effects":[
        {"episode_id":1,"fact_id":1},{"episode_id":2,"fact_id":2},
        {"episode_id":3,"fact_id":3},{"episode_id":4,"fact_id":4}
      ],
      "batch":{"state":"COMPLETED","items":[
        {"item_order":1,"episode_id":3,"attempt_no":1,"outcome":"COMPLETED","error_code":null,"error_message":null},
        {"item_order":2,"episode_id":4,"attempt_no":1,"outcome":"COMPLETED","error_code":null,"error_message":null}
      ]},
      "attempts":[
        {"episode_id":3,"attempt_no":1,"status":"COMPLETED"},
        {"episode_id":4,"attempt_no":1,"status":"COMPLETED"}
      ]
    }'::jsonb THEN RAISE EXCEPTION 'ambiguous disconnect recovery changed: %', actual; END IF;
END
$$;

SELECT 'M6 worker resolved ambiguous disconnect from public batch history' AS result;
