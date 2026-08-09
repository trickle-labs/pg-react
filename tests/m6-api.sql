\set ON_ERROR_STOP on

DO $$
DECLARE
    expected text := 'activation_context(activation_id uuid, episode_id bigint, rule_id uuid, rule_version_id uuid, generation bigint, revision bigint, event_kind text, attempt_no integer, event_at timestamp with time zone, worker_id text, idempotency_key text)';
    actual text;
BEGIN
    SELECT format('%s(%s)', t.typname,
             string_agg(format('%s %s', a.attname, format_type(a.atttypid, a.atttypmod)), ', ' ORDER BY a.attnum))
      INTO actual
      FROM pg_catalog.pg_type t
      JOIN pg_catalog.pg_namespace n ON n.oid = t.typnamespace
      JOIN pg_catalog.pg_attribute a ON a.attrelid = t.typrelid
       AND a.attnum > 0 AND NOT a.attisdropped
     WHERE n.nspname = 'pgreact' AND t.typname = 'activation_context'
     GROUP BY t.typname;
    IF actual IS DISTINCT FROM expected THEN
      RAISE EXCEPTION 'public pgreact activation_context changed: %', actual;
    END IF;
END $$;

-- Identity arguments alone do not include parameter names or defaults. Freeze
-- the complete callable declaration separately so named calls remain stable.
DO $$
DECLARE
    expected text := '16c2ae7a2cabe0326a6339f0b7ce51f1';
    actual text;
BEGIN
    SELECT md5(string_agg(
             format('%I(%s) -> %s', p.proname,
               pg_get_function_arguments(p.oid), pg_get_function_result(p.oid)),
             E'\n' ORDER BY p.proname, pg_get_function_identity_arguments(p.oid)))
      INTO actual
      FROM pg_catalog.pg_proc p
      JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'pgreact' AND p.prokind = 'f';
    IF actual IS DISTINCT FROM expected THEN
      RAISE EXCEPTION 'public pgreact parameter name/default inventory changed: %', actual;
    END IF;
END $$;

DO $$
DECLARE
    expected text[] := ARRAY[
      'agenda_status() -> SETOF pgreact.episodes',
      'batch_history(uuid) -> TABLE(batch_id uuid, rule_version_id uuid, event_kind text, worker_id text, signature jsonb, state text, diagnostic_code text, diagnostic jsonb, claimed_at timestamp with time zone, started_at timestamp with time zone, finished_at timestamp with time zone, items jsonb)',
      'begin_reconciliation(uuid) -> void',
      'begin_refresh(uuid, bigint) -> void',
      'bind_outbox_consequence(uuid, text, regprocedure, integer, integer, numeric, integer) -> void',
      'cancel_episode(bigint) -> void',
      'claim(text, integer, interval, text[]) -> TABLE(episode_id bigint, lease_token uuid, activation_id uuid, bindings jsonb, event_kind text, rule_version_id uuid)',
      'claim_batch(uuid, text, text, integer, interval) -> TABLE(batch_id uuid, item_order integer, episode_id bigint, lease_token uuid)',
      'claim_episode(uuid, text, integer) -> TABLE(episode_id bigint, lease_token uuid, activation_id uuid, bindings jsonb)',
      'clear_refresh_barrier(uuid) -> void',
      'configure_agenda_group(text, integer) -> void',
      'configure_operations(integer, integer, interval, integer) -> void',
      'create_rule(text, regclass, name[], text, regprocedure, regprocedure, regprocedure, text, name[], integer, text, name[], integer, integer, numeric, integer) -> uuid',
      'current_matches(text) -> TABLE(activation_id uuid, activation_key bigint, bindings jsonb, active_since timestamp with time zone)',
      'declare_batch_safe(uuid, text) -> void',
      'deploy_pack(jsonb, text, jsonb) -> uuid',
      'execute_claimed_batch(uuid, text) -> TABLE(episode_id bigint, status text, error_code text, error_message text)',
      'execute_claimed_episode(bigint, text, uuid) -> text',
      'execution_history() -> SETOF pgreact.attempts',
      'explain_activation(uuid, uuid) -> jsonb',
      'explain_episode(bigint) -> jsonb',
      'explain_pack(text) -> jsonb',
      'explain_rule(uuid) -> jsonb',
      'health_check() -> TABLE(code text, severity text, object_identity text, message text, hint text)',
      'heartbeat_episode(bigint, text, uuid, interval) -> timestamp with time zone',
      'metrics() -> jsonb',
      'pack_history(text) -> TABLE(pack_name text, version text, status text, definition_digest text, plan_digest text, deployed_at timestamp with time zone, deployed_by name, actions jsonb)',
      'pause_rule(text) -> void',
      'pause_rule(uuid) -> void',
      'prepare_recovery() -> bigint',
      'preview_pack(jsonb, jsonb) -> TABLE(plan_digest text, action_order integer, action text, rule_name text, dependencies text[], generated_object_changes jsonb, lifecycle_risks jsonb, details jsonb)',
      'preview_rule(regclass, name[]) -> TABLE(snapshot_at timestamp with time zone, semantic_key bigint, bindings jsonb)',
      'preview_rule(regclass, name[], text) -> TABLE(snapshot_at timestamp with time zone, semantic_key bigint, bindings jsonb)',
      'prune_payloads(timestamp with time zone) -> TABLE(lifecycle_payloads_cleared bigint, agenda_payloads_cleared bigint)',
      'rebuild_transient_metadata() -> TABLE(rebuilt_rules bigint, blocked_rules bigint)',
      'reconcile_rule(uuid, text) -> bigint',
      'refresh_rule(uuid) -> void',
      'register_outbox_sink(regprocedure) -> regprocedure',
      'release_refresh_lock() -> boolean',
      'remove_rule(uuid) -> void',
      'replace_rule(uuid, regclass, name[], regprocedure, text, regprocedure, regprocedure, text) -> uuid',
      'requeue_episode(bigint) -> void',
      'resume_rule(text) -> void',
      'resume_rule(uuid) -> void',
      'rule_status() -> SETOF pgreact.rules',
      'source_drift() -> TABLE(rule_version_id uuid, source_view_name text, status text)',
      'sweep_expired_leases(uuid) -> bigint',
      'validate_pack(jsonb, jsonb) -> TABLE(contract_version integer, code text, severity text, object_identity text, message text, hint text, details jsonb)',
      'validate_rule(regclass, name[], regprocedure) -> TABLE(contract_version integer, code text, severity text, object_identity text, message text, hint text, details jsonb)',
      'worker_protocol_compatible(integer) -> boolean'
    ];
    actual text[];
BEGIN
    SELECT array_agg(
             format('%s(%s) -> %s', p.proname, oidvectortypes(p.proargtypes), pg_get_function_result(p.oid))
             ORDER BY p.proname, oidvectortypes(p.proargtypes)
           )
      INTO actual
      FROM pg_catalog.pg_proc p
      JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'pgreact' AND p.prokind = 'f';
    IF actual IS DISTINCT FROM expected THEN
      RAISE EXCEPTION 'public pgreact function inventory changed: %', to_jsonb(actual);
    END IF;
END $$;

DO $$
DECLARE
    expected text[] := ARRAY[
      'activations(rule_version_id uuid, activation_id uuid, semantic_key bigint, current_bindings jsonb, active boolean, generation bigint, first_seen_at timestamp with time zone, last_seen_at timestamp with time zone, deactivated_at timestamp with time zone, revision bigint)',
      'attempts(execution_id bigint, episode_id bigint, attempt_no integer, worker_id text, started_at timestamp with time zone, finished_at timestamp with time zone, status text, error_message text, error_code text, event_kind text)',
      'episodes(episode_id bigint, rule_id uuid, rule_version_id uuid, activation_id uuid, activation_generation bigint, state text, worker_id text, claimed_at timestamp with time zone, lease_expires_at timestamp with time zone, completed_at timestamp with time zone, idempotency_key text, activation_revision bigint, event_kind text, agenda_group text, salience integer, conflict_key text, attempt_count integer, max_attempts integer)',
      'operational_status(rule_name text, rule_version_id uuid, state text, agenda_group text, outstanding_episodes bigint, oldest_eligible_at timestamp with time zone, failed_episodes bigint, claims_blocked boolean)',
      'rules(rule_id uuid, rule_name text, rule_version_id uuid, owner name, source_view_name text, key_column name, consequence_identity text, bootstrap_policy text, state text, created_at timestamp with time zone)'
    ];
    actual text[];
BEGIN
    SELECT array_agg(signature ORDER BY signature)
      INTO actual
      FROM (
        SELECT format('%s(%s)', c.relname,
                 string_agg(format('%s %s', a.attname, format_type(a.atttypid, a.atttypmod)), ', ' ORDER BY a.attnum)
               ) AS signature
          FROM pg_catalog.pg_class c
          JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
          JOIN pg_catalog.pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
         WHERE n.nspname = 'pgreact' AND c.relkind IN ('v', 'm')
         GROUP BY c.relname
      ) views;
    IF actual IS DISTINCT FROM expected THEN
      RAISE EXCEPTION 'public pgreact view inventory changed: %', to_jsonb(actual);
    END IF;
END $$;

SELECT 'M6 public API inventory passed' AS result;
