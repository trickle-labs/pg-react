\set ON_ERROR_STOP on

BEGIN;
SELECT * FROM pgreact.execute_claimed_batch(
    (SELECT batch_id FROM m6_concurrency.control), 'm6-concurrency'
);
COMMIT;
