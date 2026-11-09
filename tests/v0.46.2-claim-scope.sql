\set ON_ERROR_STOP on

DO $v0462_claim_scope$
DECLARE function_definition text :=
    pg_get_functiondef('pgreact.claim_episode(uuid, text, integer)'::regprocedure);
BEGIN
    IF function_definition NOT LIKE '%agenda.worker_id = claim_episode.worker_id%'
       OR function_definition LIKE '%agenda.worker_id = worker_id%' THEN
        RAISE EXCEPTION 'M31 stale-scope withdrawal does not qualify its worker parameter';
    END IF;
END
$v0462_claim_scope$;

SELECT 'v0.46.2 M31 scoped-claim worker parameter passed' AS result;
