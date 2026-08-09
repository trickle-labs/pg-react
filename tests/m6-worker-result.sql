\set ON_ERROR_STOP on

DO $$
DECLARE actual jsonb;
BEGIN
    SELECT jsonb_agg(jsonb_build_object(
        'episode_id', episode_id, 'event_kind', event_kind, 'fact_id', fact_id,
        'old_value', old_value, 'new_value', new_value
    ) ORDER BY episode_id) INTO actual FROM m6_worker.effects;
    IF actual IS DISTINCT FROM '[
      {"episode_id":1,"event_kind":"ACTIVATE","fact_id":1,"old_value":null,"new_value":"a"},
      {"episode_id":2,"event_kind":"ACTIVATE","fact_id":2,"old_value":null,"new_value":"b"},
      {"episode_id":3,"event_kind":"CHANGE","fact_id":1,"old_value":"a","new_value":"aa"},
      {"episode_id":4,"event_kind":"CHANGE","fact_id":2,"old_value":"b","new_value":"bb"},
      {"episode_id":5,"event_kind":"DEACTIVATE","fact_id":1,"old_value":"aa","new_value":null},
      {"episode_id":6,"event_kind":"DEACTIVATE","fact_id":2,"old_value":"bb","new_value":null},
      {"episode_id":7,"event_kind":"ACTIVATE","fact_id":3,"old_value":null,"new_value":"c"}
    ]'::jsonb THEN RAISE EXCEPTION 'worker effects changed: %', actual; END IF;

    SELECT jsonb_agg(jsonb_build_object(
        'event_kind', event_kind, 'state', state,
        'outcomes', (SELECT jsonb_agg(item ->> 'outcome' ORDER BY item ->> 'item_order')
                     FROM jsonb_array_elements(items) AS item)
    ) ORDER BY claimed_at) INTO actual FROM pgreact.batch_history();
    IF actual IS DISTINCT FROM '[
      {"event_kind":"ACTIVATE","state":"COMPLETED","outcomes":["COMPLETED","COMPLETED"]},
      {"event_kind":"CHANGE","state":"COMPLETED","outcomes":["COMPLETED","COMPLETED"]},
      {"event_kind":"DEACTIVATE","state":"COMPLETED","outcomes":["COMPLETED","COMPLETED"]}
    ]'::jsonb THEN RAISE EXCEPTION 'worker batch history changed: %', actual; END IF;

    SELECT jsonb_build_object(
        'state', state,
        'attempts', (SELECT jsonb_agg(jsonb_build_object('attempt_no', attempt_no, 'status', status)
                                     ORDER BY attempt_no)
                     FROM pgreact.attempts WHERE episode_id = 7),
        'batches', explain -> 'batches'
    ) INTO actual
    FROM pgreact.episodes e
    CROSS JOIN LATERAL (SELECT pgreact.explain_episode(e.episode_id) AS explain) x
    WHERE e.episode_id = 7;
    IF actual IS DISTINCT FROM '{
      "state":"COMPLETED","attempts":[{"attempt_no":1,"status":"COMPLETED"}],"batches":[]
    }'::jsonb THEN RAISE EXCEPTION 'worker singleton fallback changed: %', actual; END IF;
END
$$;

SELECT 'M6 protocol-2 worker lifecycle and singleton fallback passed' AS result;
