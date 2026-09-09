-- pg-react 0.43.3 correctness patch over the 0.43.2 runtime.

ALTER TABLE pgreact_internal.agenda
    ADD COLUMN IF NOT EXISTS state_changed_at timestamptz;

CREATE OR REPLACE FUNCTION pgreact_internal.validate_retry_policy()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $v0433$
BEGIN
    IF NEW.max_attempts NOT BETWEEN 1 AND 100
       OR NEW.initial_backoff_seconds NOT BETWEEN 1 AND 3600
       OR NEW.max_backoff_seconds NOT BETWEEN 1 AND 86400
       OR NEW.backoff_multiplier IS NULL
       OR NEW.backoff_multiplier::text = 'NaN'
       OR NEW.backoff_multiplier < 1 THEN
        RAISE EXCEPTION 'invalid retry policy';
    END IF;
    RETURN NEW;
END
$v0433$;

DROP TRIGGER IF EXISTS pgreact_validate_retry_policy
ON pgreact_internal.consequence_bindings;
CREATE TRIGGER pgreact_validate_retry_policy
BEFORE INSERT OR UPDATE ON pgreact_internal.consequence_bindings
FOR EACH ROW EXECUTE FUNCTION pgreact_internal.validate_retry_policy();

CREATE OR REPLACE FUNCTION pgreact_internal.agenda_state_timestamp()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $v0433$
BEGIN
    IF TG_OP = 'INSERT' THEN
        NEW.state_changed_at := clock_timestamp();
    ELSIF ROW(NEW.state, NEW.available_at, NEW.lease_token, NEW.worker_id,
              NEW.claimed_at, NEW.lease_expires_at, NEW.completed_at,
              NEW.attempt_count, NEW.last_error)
          IS DISTINCT FROM
          ROW(OLD.state, OLD.available_at, OLD.lease_token, OLD.worker_id,
              OLD.claimed_at, OLD.lease_expires_at, OLD.completed_at,
              OLD.attempt_count, OLD.last_error) THEN
        NEW.state_changed_at := clock_timestamp();
    END IF;
    RETURN NEW;
END
$v0433$;

DROP TRIGGER IF EXISTS pgreact_agenda_state_timestamp ON pgreact_internal.agenda;
CREATE TRIGGER pgreact_agenda_state_timestamp
BEFORE INSERT OR UPDATE ON pgreact_internal.agenda
FOR EACH ROW EXECUTE FUNCTION pgreact_internal.agenda_state_timestamp();

UPDATE pgreact_internal.agenda
SET state_changed_at = CASE
    WHEN state = 'LEASED' THEN claimed_at
    WHEN state IN ('COMPLETED', 'FAILED', 'SKIPPED', 'WITHDRAWN',
                   'CANCELLED', 'SUPERSEDED') THEN completed_at
END
WHERE state_changed_at IS NULL
  AND ((state = 'LEASED' AND claimed_at IS NOT NULL)
       OR (state IN ('COMPLETED', 'FAILED', 'SKIPPED', 'WITHDRAWN',
                     'CANCELLED', 'SUPERSEDED') AND completed_at IS NOT NULL));

CREATE OR REPLACE FUNCTION pgreact_internal.execute_claimed_episode_m7(
    target_episode_id bigint, expected_worker_id text, expected_lease_token uuid)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $v0433$
DECLARE
    episode pgreact_internal.agenda%ROWTYPE;
    event_row pgreact_internal.lifecycle_events%ROWTYPE;
    version_row pgreact_internal.rule_versions%ROWTYPE;
    binding pgreact_internal.consequence_bindings%ROWTYPE;
    context pgreact.activation_context;
    attempt integer;
    started timestamptz := clock_timestamp();
    dispatcher_call text;
    sink_call text;
    failure text;
    failure_code text;
    retry_seconds integer;
    retry_value numeric;
    step integer;
    eligible boolean;
    binding_found boolean;
BEGIN
    PERFORM pg_catalog.pg_advisory_xact_lock_shared(5788046901200000);
    PERFORM pg_catalog.pg_advisory_xact_lock_shared(5788046901200001);
    SELECT * INTO STRICT episode
    FROM pgreact_internal.agenda
    WHERE episode_id = target_episode_id
    FOR UPDATE;
    IF episode.state <> 'LEASED'
       OR episode.worker_id <> expected_worker_id
       OR episode.lease_token <> expected_lease_token THEN
        RAISE EXCEPTION 'lease is no longer valid for episode %', target_episode_id;
    END IF;
    attempt := episode.attempt_count;

    BEGIN
        IF episode.lease_expires_at <= clock_timestamp() THEN
            RAISE EXCEPTION 'lease is no longer valid for episode %', target_episode_id;
        END IF;
        SELECT * INTO STRICT version_row
        FROM pgreact_internal.rule_versions
        WHERE rule_version_id = episode.rule_version_id;
        SELECT * INTO STRICT event_row
        FROM pgreact_internal.lifecycle_events
        WHERE event_id = episode.event_id;
        SELECT * INTO binding
        FROM pgreact_internal.consequence_bindings
        WHERE rule_version_id = episode.rule_version_id
          AND event_kind = episode.event_kind;
        binding_found := FOUND;
        eligible := NOT EXISTS (
                SELECT 1 FROM pgreact_internal.rule_barriers
                WHERE rule_version_id = episode.rule_version_id)
            AND version_row.state IN ('ACTIVE', 'DRAINING')
            AND CASE episode.event_kind
                WHEN 'ACTIVATE' THEN EXISTS (
                    SELECT 1 FROM pgreact_internal.activation_state state
                    WHERE state.rule_version_id = episode.rule_version_id
                      AND state.activation_id = episode.activation_id
                      AND state.active
                      AND state.generation = episode.activation_generation)
                WHEN 'CHANGE' THEN EXISTS (
                    SELECT 1 FROM pgreact_internal.activation_state state
                    WHERE state.rule_version_id = episode.rule_version_id
                      AND state.activation_id = episode.activation_id
                      AND state.active
                      AND state.generation = episode.activation_generation
                      AND state.revision = episode.activation_revision)
                ELSE NOT EXISTS (
                    SELECT 1 FROM pgreact_internal.activation_state state
                    WHERE state.rule_version_id = episode.rule_version_id
                      AND state.activation_id = episode.activation_id
                      AND state.active
                      AND state.generation > episode.activation_generation)
            END;
        IF NOT eligible THEN
            INSERT INTO pgreact_internal.executions (
                episode_id, attempt_no, worker_id, lease_token, started_at,
                finished_at, status, event_kind, transaction_id)
            VALUES (
                target_episode_id, attempt, expected_worker_id,
                expected_lease_token, started, clock_timestamp(), 'SKIPPED',
                episode.event_kind, pg_current_xact_id());
            UPDATE pgreact_internal.agenda
            SET state = 'SKIPPED', completed_at = clock_timestamp(),
                lease_token = NULL, worker_id = NULL, lease_expires_at = NULL
            WHERE episode_id = target_episode_id
              AND state = 'LEASED'
              AND worker_id = expected_worker_id
              AND lease_token = expected_lease_token;
            IF NOT FOUND THEN
                RAISE EXCEPTION 'lease lost for episode %', target_episode_id;
            END IF;
            DELETE FROM pgreact_internal.conflict_leases
            WHERE episode_id = target_episode_id
              AND lease_token = expected_lease_token;
            RETURN 'SKIPPED';
        END IF;
        IF pgreact_internal.source_row_signature(version_row.source_view_oid)
           IS DISTINCT FROM version_row.source_row_signature THEN
            RAISE EXCEPTION
                'pg-react source row signature drift for rule version %; pause, drain, and replace it',
                episode.rule_version_id;
        END IF;
        IF NOT binding_found THEN
            binding.consequence_kind := 'DATABASE_TYPED';
            binding.function_oid := version_row.consequence_oid;
            binding.function_digest := version_row.consequence_digest;
            binding.dispatcher_oid := version_row.dispatcher_oid;
            binding.dispatcher_digest := version_row.dispatcher_digest;
        END IF;
        IF binding.function_oid IS NULL
           OR NOT EXISTS (
               SELECT 1 FROM pg_catalog.pg_proc
               WHERE oid = binding.function_oid)
           OR sha256(convert_to(pg_get_functiondef(binding.function_oid), 'UTF8'))
              <> binding.function_digest
           OR (binding.dispatcher_oid IS NOT NULL AND (
               NOT EXISTS (
                   SELECT 1 FROM pg_catalog.pg_proc
                   WHERE oid = binding.dispatcher_oid)
               OR sha256(convert_to(pg_get_functiondef(binding.dispatcher_oid), 'UTF8'))
                  <> binding.dispatcher_digest)) THEN
            RAISE EXCEPTION 'pg-react consequence or dispatcher drift for rule version %',
                episode.rule_version_id;
        END IF;
        context := ROW(
            episode.activation_id, episode.episode_id, episode.rule_id,
            episode.rule_version_id, episode.activation_generation,
            episode.activation_revision, episode.event_kind, attempt,
            event_row.transitioned_at, expected_worker_id,
            episode.idempotency_key)::pgreact.activation_context;
        IF binding.consequence_kind = 'OUTBOX' THEN
            SELECT format('%I.%I', namespace.nspname, proc_row.proname)
            INTO STRICT sink_call
            FROM pg_catalog.pg_proc proc_row
            JOIN pg_catalog.pg_namespace namespace
              ON namespace.oid = proc_row.pronamespace
            WHERE proc_row.oid = binding.function_oid;
            EXECUTE format('SELECT %s($1, $2)', sink_call)
            USING context, jsonb_build_object(
                'version', 1, 'rule_id', episode.rule_id,
                'rule_version_id', episode.rule_version_id,
                'event_kind', episode.event_kind,
                'activation_id', episode.activation_id,
                'generation', episode.activation_generation,
                'revision', episode.activation_revision,
                'episode_id', episode.episode_id,
                'idempotency_key', episode.idempotency_key,
                'old', episode.old_bindings, 'new', episode.new_bindings);
        ELSIF binding.dispatcher_oid = version_row.dispatcher_oid THEN
            SELECT format('%I.%I', namespace.nspname, proc_row.proname)
            INTO STRICT dispatcher_call
            FROM pg_catalog.pg_proc proc_row
            JOIN pg_catalog.pg_namespace namespace
              ON namespace.oid = proc_row.pronamespace
            WHERE proc_row.oid = binding.dispatcher_oid;
            EXECUTE format('SELECT %s($1, $2)', dispatcher_call)
            USING context, episode.new_bindings;
        ELSE
            SELECT format('%I.%I', namespace.nspname, proc_row.proname)
            INTO STRICT dispatcher_call
            FROM pg_catalog.pg_proc proc_row
            JOIN pg_catalog.pg_namespace namespace
              ON namespace.oid = proc_row.pronamespace
            WHERE proc_row.oid = binding.dispatcher_oid;
            EXECUTE format('SELECT %s($1, $2, $3)', dispatcher_call)
            USING context, episode.old_bindings, episode.new_bindings;
        END IF;
        INSERT INTO pgreact_internal.executions (
            episode_id, attempt_no, worker_id, lease_token, started_at,
            finished_at, status, event_kind, transaction_id)
        VALUES (
            target_episode_id, attempt, expected_worker_id,
            expected_lease_token, started, clock_timestamp(), 'COMPLETED',
            episode.event_kind, pg_current_xact_id());
        UPDATE pgreact_internal.agenda
        SET state = 'COMPLETED', completed_at = clock_timestamp(),
            lease_token = NULL, worker_id = NULL, lease_expires_at = NULL
        WHERE episode_id = target_episode_id
          AND lease_token = expected_lease_token
          AND worker_id = expected_worker_id
          AND state = 'LEASED';
        IF NOT FOUND THEN
            RAISE EXCEPTION 'lease lost for episode %', target_episode_id;
        END IF;
        DELETE FROM pgreact_internal.conflict_leases
        WHERE episode_id = target_episode_id
          AND lease_token = expected_lease_token;
        RETURN 'COMPLETED';
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS
            failure = MESSAGE_TEXT,
            failure_code = RETURNED_SQLSTATE;
        IF failure_code !~ '^(28|42)'
           AND attempt < episode.max_attempts
           AND episode.retry_multiplier IS NOT NULL
           AND episode.retry_multiplier::text <> 'NaN'
           AND episode.retry_multiplier >= 1 THEN
            retry_value := episode.retry_initial_seconds::numeric;
            IF retry_value < episode.retry_max_seconds THEN
                IF episode.retry_multiplier >
                   episode.retry_max_seconds::numeric / retry_value THEN
                    retry_value := episode.retry_max_seconds;
                ELSE
                    FOR step IN 2..LEAST(attempt, 100) LOOP
                        EXIT WHEN retry_value >= episode.retry_max_seconds;
                        IF retry_value > episode.retry_max_seconds::numeric /
                           episode.retry_multiplier THEN
                            retry_value := episode.retry_max_seconds;
                            EXIT;
                        END IF;
                        retry_value := retry_value * episode.retry_multiplier;
                    END LOOP;
                END IF;
            END IF;
            retry_seconds := LEAST(
                episode.retry_max_seconds,
                GREATEST(1, floor(retry_value))::integer);
            INSERT INTO pgreact_internal.executions (
                episode_id, attempt_no, worker_id, lease_token, started_at,
                finished_at, status, error_message, error_code, event_kind,
                transaction_id)
            VALUES (
                target_episode_id, attempt, expected_worker_id,
                expected_lease_token, started, clock_timestamp(),
                'RETRY_WAIT', failure, failure_code, episode.event_kind,
                pg_current_xact_id());
            UPDATE pgreact_internal.agenda
            SET state = 'RETRY_WAIT',
                available_at = clock_timestamp() + make_interval(secs => retry_seconds),
                lease_token = NULL, worker_id = NULL, lease_expires_at = NULL,
                last_error = jsonb_build_object('code', failure_code, 'message', failure)
            WHERE episode_id = target_episode_id
              AND state = 'LEASED'
              AND worker_id = expected_worker_id
              AND lease_token = expected_lease_token;
            IF FOUND THEN
                DELETE FROM pgreact_internal.conflict_leases
                WHERE episode_id = target_episode_id
                  AND lease_token = expected_lease_token;
            END IF;
            RETURN 'RETRY_WAIT';
        END IF;
        INSERT INTO pgreact_internal.executions (
            episode_id, attempt_no, worker_id, lease_token, started_at,
            finished_at, status, error_message, error_code, event_kind,
            transaction_id)
        VALUES (
            target_episode_id, attempt, expected_worker_id,
            expected_lease_token, started, clock_timestamp(), 'FAILED',
            failure, failure_code, episode.event_kind, pg_current_xact_id());
        UPDATE pgreact_internal.agenda
        SET state = 'FAILED', completed_at = clock_timestamp(),
            lease_token = NULL, worker_id = NULL, lease_expires_at = NULL,
            last_error = jsonb_build_object('code', failure_code, 'message', failure)
        WHERE episode_id = target_episode_id
          AND state = 'LEASED'
          AND worker_id = expected_worker_id
          AND lease_token = expected_lease_token;
        IF FOUND THEN
            DELETE FROM pgreact_internal.conflict_leases
            WHERE episode_id = target_episode_id
              AND lease_token = expected_lease_token;
        END IF;
        RETURN 'FAILED';
    END;
END
$v0433$;

CREATE OR REPLACE FUNCTION pgreact.claim(
    worker_id text,
    max_items integer DEFAULT 1,
    lease_for interval DEFAULT interval '60 seconds',
    agenda_groups text[] DEFAULT NULL)
RETURNS TABLE(
    episode_id bigint, lease_token uuid, activation_id uuid, bindings jsonb,
    event_kind text, rule_version_id uuid)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $v0433$
DECLARE
    candidate record;
    claimed record;
    version_id uuid;
    count_claimed integer := 0;
    seconds integer := extract(epoch FROM lease_for)::integer;
    fairness interval;
    claim_limit integer;
BEGIN
    PERFORM pg_catalog.pg_advisory_xact_lock_shared(5788046901200000);
    SELECT fairness_window, max_claims INTO fairness, claim_limit
    FROM pgreact_internal.operational_settings;
    IF max_items NOT BETWEEN 1 AND claim_limit THEN
        RAISE EXCEPTION 'max_items must be between 1 and %', claim_limit;
    END IF;
    IF seconds < 1 THEN
        RAISE EXCEPTION 'lease_for must be at least one second';
    END IF;
    FOR version_id IN
        SELECT rule_version_id
        FROM pgreact_internal.rule_versions
        WHERE state IN ('ACTIVE', 'DRAINING')
        ORDER BY rule_version_id
    LOOP
        PERFORM pgreact.sweep_expired_leases(version_id);
    END LOOP;
    FOR candidate IN
        SELECT agenda.rule_version_id
        FROM pgreact_internal.agenda agenda
        JOIN pgreact_internal.rule_versions version USING (rule_version_id)
        WHERE agenda.state IN ('PENDING', 'RETRY_WAIT')
          AND agenda.available_at <= clock_timestamp()
          AND version.state IN ('ACTIVE', 'DRAINING')
          AND NOT EXISTS (
              SELECT 1 FROM pgreact_internal.rule_barriers barrier
              WHERE barrier.rule_version_id = agenda.rule_version_id)
          AND (agenda_groups IS NULL OR agenda.agenda_group = ANY(agenda_groups))
        ORDER BY CASE WHEN agenda.available_at <= clock_timestamp() - fairness
                      THEN 0 ELSE 1 END,
                 agenda.available_at, agenda.salience DESC, agenda.episode_id
    LOOP
        SELECT * INTO claimed
        FROM pgreact.claim_episode(candidate.rule_version_id, worker_id, seconds);
        IF FOUND THEN
            SELECT agenda.event_kind INTO event_kind
            FROM pgreact_internal.agenda agenda
            WHERE agenda.episode_id = claimed.episode_id;
            episode_id := claimed.episode_id;
            lease_token := claimed.lease_token;
            activation_id := claimed.activation_id;
            bindings := claimed.bindings;
            rule_version_id := candidate.rule_version_id;
            RETURN NEXT;
            count_claimed := count_claimed + 1;
            EXIT WHEN count_claimed >= max_items;
        END IF;
    END LOOP;
END
$v0433$;

CREATE OR REPLACE FUNCTION pgreact.sweep_expired_leases(rule_name text)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $v0433$
DECLARE
    target_owner oid;
    recovered bigint := 0;
    version_row record;
BEGIN
    SELECT version.owner_oid
    INTO target_owner
    FROM pgreact_internal.rules rule
    JOIN pgreact_internal.rule_versions version USING (rule_id)
    WHERE rule.rule_name = sweep_expired_leases.rule_name
      AND version.state IN ('ACTIVE', 'PAUSED', 'DRAINING')
    ORDER BY version.created_at
    LIMIT 1;
    IF target_owner IS NULL
       OR (target_owner <> (
           SELECT oid FROM pg_catalog.pg_roles WHERE rolname = session_user)
           AND NOT pgreact_internal.is_operator_admin()) THEN
        RAISE EXCEPTION
            'M54_TARGET_UNAVAILABLE: named rule is missing, ambiguous, or unauthorized';
    END IF;
    FOR version_row IN
        SELECT version.rule_version_id
        FROM pgreact_internal.rules rule
        JOIN pgreact_internal.rule_versions version USING (rule_id)
        WHERE rule.rule_name = sweep_expired_leases.rule_name
          AND version.state IN ('ACTIVE', 'PAUSED', 'DRAINING')
        ORDER BY version.created_at, version.rule_version_id
    LOOP
        recovered := recovered + pgreact.sweep_expired_leases(version_row.rule_version_id);
    END LOOP;
    RETURN recovered;
END
$v0433$;

CREATE OR REPLACE VIEW pgreact.work AS
SELECT 'rule'::text AS kind, rule.rule_name AS name, rule.version,
       episode.episode_id::text AS work_id, episode.state,
       episode.state IN ('PENDING', 'RETRY_WAIT')
       AND episode.available_at <= clock_timestamp()
       AND version.state IN ('ACTIVE', 'DRAINING')
       AND NOT EXISTS (
           SELECT 1 FROM pgreact_internal.rule_barriers barrier
           WHERE barrier.rule_version_id = episode.rule_version_id)
       AND (episode.conflict_key IS NULL OR NOT EXISTS (
           SELECT 1 FROM pgreact_internal.conflict_leases lease
           WHERE lease.rule_version_id = episode.rule_version_id
             AND lease.conflict_key = episode.conflict_key
             AND lease.lease_expires_at > clock_timestamp()))
       AND (NOT EXISTS (
           SELECT 1 FROM pgreact_internal.agenda_group_limits limit_row
           WHERE limit_row.agenda_group = episode.agenda_group)
            OR (SELECT count(*)
                FROM pgreact_internal.agenda leased
                WHERE leased.agenda_group = episode.agenda_group
                  AND leased.state = 'LEASED'
                  AND leased.lease_expires_at > clock_timestamp()) < (
                    SELECT limit_row.max_leases
                    FROM pgreact_internal.agenda_group_limits limit_row
                    WHERE limit_row.agenda_group = episode.agenda_group))
       AND CASE episode.event_kind
           WHEN 'ACTIVATE' THEN EXISTS (
               SELECT 1 FROM pgreact_internal.activation_state state
               WHERE state.rule_version_id = episode.rule_version_id
                 AND state.activation_id = episode.activation_id
                 AND state.active
                 AND state.generation = episode.activation_generation)
           WHEN 'CHANGE' THEN EXISTS (
               SELECT 1 FROM pgreact_internal.activation_state state
               WHERE state.rule_version_id = episode.rule_version_id
                 AND state.activation_id = episode.activation_id
                 AND state.active
                 AND state.generation = episode.activation_generation
                 AND state.revision = episode.activation_revision)
           ELSE NOT EXISTS (
               SELECT 1 FROM pgreact_internal.activation_state state
               WHERE state.rule_version_id = episode.rule_version_id
                 AND state.activation_id = episode.activation_id
                 AND state.active
                 AND state.generation > episode.activation_generation)
       END AS claimable,
       episode.state_changed_at AS updated_at
FROM pgreact_internal.agenda episode
JOIN pgreact.rules rule USING (rule_version_id)
JOIN pgreact_internal.rule_versions version USING (rule_version_id)
UNION ALL
SELECT 'decision'::text, program.program_name, version.version_no::text,
       work.subject_key::text, state.state, work.claimable, work.updated_at
FROM pgreact_internal.decision_work work
JOIN pgreact_internal.decision_programs program USING (program_id)
JOIN pgreact_internal.decision_program_versions version
  ON version.program_id = work.program_id
JOIN pgreact_internal.decision_subject_state state
  ON state.program_id = work.program_id
 AND state.subject_key = work.subject_key
 AND version.version_id = state.version_id;

COMMENT ON COLUMN pgreact.work.claimable IS
    'Advisory claimability; a concurrent transaction may claim after this read.';
COMMENT ON COLUMN pgreact.work.updated_at IS
    'Last persisted agenda/work activity; pre-0.43.3 agenda history may be NULL.';

CREATE OR REPLACE FUNCTION pgreact.execute_claimed_batch(
    target_batch_id uuid, expected_worker_id text)
RETURNS TABLE(episode_id bigint, status text, error_code text, error_message text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $v0433$
DECLARE
    batch_row pgreact_internal.execution_batches%ROWTYPE;
    item_row record;
    item_status text;
    item_error_code text;
    item_error_message text;
    total_items integer;
BEGIN
    PERFORM pg_catalog.pg_advisory_xact_lock_shared(5788046901200000);
    PERFORM pg_catalog.pg_advisory_xact_lock_shared(5788046901200001);
    SELECT * INTO STRICT batch_row
    FROM pgreact_internal.execution_batches
    WHERE batch_id = target_batch_id
    FOR UPDATE;
    IF batch_row.worker_id <> expected_worker_id THEN
        RAISE EXCEPTION 'batch % is owned by worker %, not %',
            target_batch_id, batch_row.worker_id, expected_worker_id;
    END IF;
    IF batch_row.state <> 'CLAIMED' THEN
        RAISE EXCEPTION 'batch % is not claimable in state %',
            target_batch_id, batch_row.state;
    END IF;
    SELECT count(*) INTO total_items
    FROM pgreact_internal.execution_batch_items
    WHERE batch_id = target_batch_id;
    IF total_items NOT BETWEEN 2 AND 32 OR total_items > batch_row.max_items THEN
        UPDATE pgreact_internal.execution_batches
        SET state = 'REJECTED', diagnostic_code = 'OVERSIZED_OR_EMPTY',
            diagnostic = jsonb_build_object('items', total_items,
                                             'max_items', batch_row.max_items),
            finished_at = clock_timestamp()
        WHERE batch_id = target_batch_id;
        UPDATE pgreact_internal.execution_batch_items
        SET outcome = 'REJECTED', error_code = 'OVERSIZED_OR_EMPTY',
            error_message = 'batch rejected before consequence invocation'
        WHERE batch_id = target_batch_id;
        RETURN QUERY
        SELECT item.episode_id, item.outcome, item.error_code, item.error_message
        FROM pgreact_internal.execution_batch_items item
        WHERE item.batch_id = target_batch_id
        ORDER BY item.item_order;
        RETURN;
    END IF;
    UPDATE pgreact_internal.execution_batches
    SET state = 'RUNNING', started_at = clock_timestamp()
    WHERE batch_id = target_batch_id;
    FOR item_row IN
        SELECT item_order, episode_id, lease_token
        FROM pgreact_internal.execution_batch_items
        WHERE batch_id = target_batch_id
        ORDER BY item_order
    LOOP
        item_status := NULL;
        item_error_code := NULL;
        item_error_message := NULL;
        BEGIN
            SELECT pgreact.execute_claimed_episode(
                item_row.episode_id, expected_worker_id, item_row.lease_token)
            INTO STRICT item_status;
        EXCEPTION WHEN OTHERS THEN
            item_status := 'FAILED';
            item_error_code := SQLSTATE;
            item_error_message := SQLERRM;
            UPDATE pgreact_internal.agenda
            SET state = 'FAILED', completed_at = clock_timestamp(),
                lease_token = NULL, worker_id = NULL, lease_expires_at = NULL,
                last_error = jsonb_build_object('code', item_error_code,
                                                 'message', item_error_message)
            WHERE episode_id = item_row.episode_id
              AND state = 'LEASED'
              AND worker_id = expected_worker_id
              AND lease_token = item_row.lease_token;
        END;
        SELECT agenda.last_error ->> 'code', agenda.last_error ->> 'message'
        INTO item_error_code, item_error_message
        FROM pgreact_internal.agenda agenda
        WHERE agenda.episode_id = item_row.episode_id;
        UPDATE pgreact_internal.execution_batch_items
        SET outcome = item_status,
            error_code = CASE WHEN item_status IN ('FAILED', 'RETRY_WAIT')
                              THEN item_error_code END,
            error_message = CASE WHEN item_status IN ('FAILED', 'RETRY_WAIT')
                                 THEN item_error_message END
        WHERE batch_id = target_batch_id
          AND episode_id = item_row.episode_id;
    END LOOP;
    UPDATE pgreact_internal.execution_batches
    SET state = CASE WHEN EXISTS (
            SELECT 1 FROM pgreact_internal.execution_batch_items item
            WHERE item.batch_id = target_batch_id
              AND item.outcome IN ('FAILED', 'RETRY_WAIT'))
        THEN 'PARTIAL' ELSE 'COMPLETED' END,
        diagnostic_code = CASE WHEN EXISTS (
            SELECT 1 FROM pgreact_internal.execution_batch_items item
            WHERE item.batch_id = target_batch_id
              AND item.outcome IN ('FAILED', 'RETRY_WAIT'))
            THEN 'ITEM_FAILURE' END,
        finished_at = clock_timestamp()
    WHERE batch_id = target_batch_id;
    RETURN QUERY
    SELECT item.episode_id, item.outcome, item.error_code, item.error_message
    FROM pgreact_internal.execution_batch_items item
    WHERE item.batch_id = target_batch_id
    ORDER BY item.item_order;
END
$v0433$;

CREATE OR REPLACE FUNCTION pgreact_internal.managed_cycle(process_pid integer)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $v0433$
DECLARE
    worker text := format('pg-react-managed/%s/%s', current_database(), process_pid);
    batch_limit integer := current_setting('pg_react.batch_size')::integer;
    claim_limit integer := least(batch_limit, 100);
    pending_limit integer := current_setting('pg_react.max_pending_jobs')::integer;
    pending bigint;
    processed bigint := 0;
    claimed record;
    runtime_state text := 'ready';
    process_detail text;
    run_result jsonb;
    blocked boolean := false;
BEGIN
    SELECT count(*) INTO pending
    FROM pgreact_internal.agenda job
    WHERE job.state IN ('PENDING', 'LEASED', 'RETRY_WAIT');
    INSERT INTO pgreact_internal.managed_processes (
        database_oid, database_name, backend_pid, state, protocol, pending_jobs)
    VALUES (
        (SELECT oid FROM pg_database WHERE datname = current_database()),
        current_database(), process_pid, 'ready', 2, pending)
    ON CONFLICT (database_oid) DO UPDATE
    SET database_name = EXCLUDED.database_name,
        backend_pid = EXCLUDED.backend_pid,
        state = EXCLUDED.state,
        protocol = EXCLUDED.protocol,
        pending_jobs = EXCLUDED.pending_jobs,
        started_at = CASE
            WHEN pgreact_internal.managed_processes.backend_pid = EXCLUDED.backend_pid
            THEN pgreact_internal.managed_processes.started_at
            ELSE clock_timestamp() END,
        heartbeat_at = clock_timestamp(), detail = NULL;

    IF pg_is_in_recovery() THEN
        runtime_state := 'standby';
    ELSIF NOT pgreact.worker_protocol_compatible(2) THEN
        runtime_state := 'error';
        process_detail := 'worker protocol 2 is incompatible';
    ELSE
        IF pending >= pending_limit THEN
            runtime_state := 'backpressure';
        ELSE
            BEGIN
                run_result := pgreact_api.run();
            EXCEPTION WHEN OTHERS THEN
                run_result := jsonb_build_object(
                    'runtime_state', 'BLOCKED',
                    'error', SQLSTATE || ': ' || SQLERRM);
            END;
            blocked := COALESCE(run_result ->> 'runtime_state', '') = 'BLOCKED'
                OR COALESCE(run_result #>> '{target_status,summary,runtime_state}', '') = 'BLOCKED'
                OR EXISTS (
                    SELECT 1
                    FROM jsonb_array_elements(
                        CASE WHEN jsonb_typeof(run_result -> 'policy_sets') = 'array'
                             THEN run_result -> 'policy_sets'
                             ELSE '[]'::jsonb END) item
                    WHERE item -> 'runtime' ->> 'runtime_state' = 'BLOCKED');
            IF blocked THEN
                runtime_state := 'error';
                process_detail := COALESCE(run_result ->> 'error', run_result::text);
            END IF;
        END IF;
        FOR claimed IN
            SELECT * FROM pgreact_api.claim(worker, claim_limit, interval '60 seconds')
        LOOP
            PERFORM pgreact_api.execute(
                claimed.episode_id, worker, claimed.lease_token);
            processed := processed + 1;
        END LOOP;
    END IF;
    SELECT count(*) INTO pending
    FROM pgreact_internal.agenda job
    WHERE job.state IN ('PENDING', 'LEASED', 'RETRY_WAIT');
    UPDATE pgreact_internal.managed_processes
    SET state = runtime_state,
        pending_jobs = pending,
        processed_jobs = processed_jobs + processed,
        heartbeat_at = clock_timestamp(),
        detail = process_detail
    WHERE database_oid = (
        SELECT oid FROM pg_database WHERE datname = current_database());
    RETURN jsonb_build_object(
        'state', runtime_state, 'pending_jobs', pending,
        'processed_jobs', processed, 'run', run_result,
        'runtime_state', CASE WHEN blocked THEN 'BLOCKED' END);
EXCEPTION WHEN OTHERS THEN
    INSERT INTO pgreact_internal.managed_processes (
        database_oid, database_name, backend_pid, state, protocol, detail)
    VALUES (
        (SELECT oid FROM pg_database WHERE datname = current_database()),
        current_database(), process_pid, 'error', 2, SQLSTATE || ': ' || SQLERRM)
    ON CONFLICT (database_oid) DO UPDATE
    SET backend_pid = EXCLUDED.backend_pid,
        state = 'error', heartbeat_at = clock_timestamp(), detail = EXCLUDED.detail;
    RETURN jsonb_build_object(
        'state', 'error', 'sqlstate', SQLSTATE, 'message', SQLERRM);
END
$v0433$;

COMMENT ON COLUMN pgreact_internal.agenda.state_changed_at IS
    'Accurate activity timestamp from 0.43.3 onward; NULL means pre-upgrade history is unknown.';

COMMENT ON EXTENSION pg_react IS
    '0.43.3 correctness patch for bounded retries, isolated execution, lease recovery, and operator state';
