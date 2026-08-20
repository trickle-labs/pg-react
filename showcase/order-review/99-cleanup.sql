\set ON_ERROR_STOP on

DO $$
DECLARE
    pending_work record;
BEGIN
    IF EXISTS (SELECT 1 FROM pgreact.policy_sets WHERE name = 'order-review-policy') THEN
        PERFORM pgreact.remove('order-review-policy');
    END IF;
    IF EXISTS (SELECT 1 FROM pgreact.decisions WHERE name = 'order-review-route') THEN
        PERFORM pgreact.remove('order-review-route');
    END IF;
    FOR pending_work IN
        SELECT work_id::bigint AS episode_id
        FROM pgreact.work
        WHERE kind = 'rule'
          AND name = 'order-review-work'
          AND state IN ('PENDING', 'RETRY_WAIT')
    LOOP
        PERFORM pgreact.cancel_episode(pending_work.episode_id);
    END LOOP;
    IF EXISTS (SELECT 1 FROM pgreact.rules WHERE name = 'order-review-work') THEN
        PERFORM pgreact.pause_rule('order-review-work');
        PERFORM pgreact.remove('order-review-work');
    END IF;
    IF EXISTS (SELECT 1 FROM pgreact.rules WHERE name = 'order-review-required') THEN
        PERFORM pgreact.pause_rule('order-review-required');
        PERFORM pgreact.remove('order-review-required');
    END IF;
END $$;

DROP SCHEMA IF EXISTS rule_action CASCADE;
DROP SCHEMA IF EXISTS rule_def CASCADE;
DROP SCHEMA IF EXISTS app CASCADE;