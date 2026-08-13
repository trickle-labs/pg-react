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
    expected text;
    actual text;
BEGIN
    SELECT CASE extversion
             WHEN '0.6.0' THEN '761285a533a4e144b2db05309c10892a'
             WHEN '0.7.0' THEN '761285a533a4e144b2db05309c10892a'
             WHEN '0.8.0' THEN '761285a533a4e144b2db05309c10892a'
             WHEN '0.9.0' THEN '1f95ee30f336e8ee108ed8824606a45a'
             WHEN '0.10.0' THEN '1f95ee30f336e8ee108ed8824606a45a'
             WHEN '0.11.0' THEN '1f95ee30f336e8ee108ed8824606a45a'
             WHEN '0.12.0' THEN '1f95ee30f336e8ee108ed8824606a45a'
             WHEN '0.5.0' THEN '761285a533a4e144b2db05309c10892a'
             WHEN '0.4.0' THEN 'bc3843191affe863a5dfb916761a9a2d'
             ELSE '16c2ae7a2cabe0326a6339f0b7ce51f1'
           END INTO expected
      FROM pg_catalog.pg_extension WHERE extname = 'pg_react';
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
    missing text[];
    unexpected text[];
BEGIN
    IF (SELECT extversion FROM pg_catalog.pg_extension WHERE extname = 'pg_react') IN ('0.4.0', '0.5.0', '0.6.0', '0.7.0', '0.8.0', '0.9.0', '0.10.0', '0.11.0', '0.12.0') THEN
      SELECT array_agg(signature ORDER BY signature) INTO expected
      FROM unnest(expected || ARRAY[
        'create_derivation_rule(text, regclass, name[], uuid, integer, text) -> uuid',
        'create_derived_relation(text, regtype, name[], integer) -> uuid',
        'current_facts(uuid, bigint) -> SETOF pgreact.derived_facts',
        'explain_fact(uuid, bigint) -> jsonb',
        'reconcile_derived_relation(uuid) -> bigint',
        'refresh_derived_relation(uuid) -> bigint',
        'remove_derivation_rule(uuid) -> void',
        'remove_derived_relation(uuid) -> void',
        'replace_derivation_rule(uuid, regclass, name[], integer, text) -> uuid',
        'validate_derivation_rule(regclass, uuid, name[], integer) -> TABLE(contract_version integer, code text, severity text, object_identity text, message text, hint text, details jsonb)',
        'validate_derived_relation(text, regtype, name[], integer) -> TABLE(contract_version integer, code text, severity text, object_identity text, message text, hint text, details jsonb)'
      ]) signature;
    END IF;
    IF (SELECT extversion FROM pg_catalog.pg_extension WHERE extname = 'pg_react') IN ('0.5.0', '0.6.0', '0.7.0', '0.8.0', '0.9.0', '0.10.0', '0.11.0', '0.12.0') THEN
      SELECT array_agg(signature ORDER BY signature) INTO expected
      FROM unnest(expected || ARRAY[
        'explain_recursive_fact(uuid, uuid, bigint) -> jsonb',
        'reconcile_derivation_program(uuid) -> bigint',
        'refresh_derivation_program(uuid) -> bigint',
        'remove_derivation_program(uuid) -> void',
        'validate_derivation_program(jsonb) -> TABLE(contract_version integer, code text, severity text, object_identity text, message text, hint text, details jsonb)'
      ]) signature;
    END IF;
    IF (SELECT extversion FROM pg_catalog.pg_extension WHERE extname = 'pg_react') IN ('0.9.0', '0.10.0', '0.11.0', '0.12.0') THEN
      SELECT array_agg(signature ORDER BY signature) INTO expected
      FROM unnest(expected || ARRAY[
        'advance_deadline_clock(timestamp with time zone) -> jsonb',
        'begin_deadline_refresh(bigint) -> void',
        'create_deadline_rule(text, regclass, name[], name, text, regprocedure, regprocedure, regprocedure, text, name[], integer, text, name[], integer, integer, numeric, integer) -> uuid',
        'finish_deadline_refresh() -> boolean'
      ]) signature;
    END IF;
    SELECT array_agg(
             format('%s(%s) -> %s', p.proname, oidvectortypes(p.proargtypes), pg_get_function_result(p.oid))
             ORDER BY p.proname, oidvectortypes(p.proargtypes)
           )
      INTO actual
      FROM pg_catalog.pg_proc p
      JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'pgreact' AND p.prokind = 'f';
    SELECT array_agg(signature ORDER BY signature) INTO missing
    FROM (SELECT unnest(expected) signature EXCEPT SELECT unnest(actual)) diff;
    SELECT array_agg(signature ORDER BY signature) INTO unexpected
    FROM (SELECT unnest(actual) signature EXCEPT SELECT unnest(expected)) diff;
    IF missing IS NOT NULL OR unexpected IS NOT NULL
       OR cardinality(actual) <> cardinality(expected) THEN
      RAISE EXCEPTION 'public pgreact function inventory changed; missing %, unexpected %',
        to_jsonb(missing), to_jsonb(unexpected);
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
    IF (SELECT extversion FROM pg_catalog.pg_extension WHERE extname = 'pg_react') IN ('0.4.0', '0.5.0', '0.6.0', '0.7.0', '0.8.0', '0.9.0', '0.10.0', '0.11.0', '0.12.0') THEN
      SELECT array_agg(signature ORDER BY signature) INTO expected
      FROM unnest(expected || ARRAY[
        'derived_facts(relation_version_id uuid, relation_name text, relation_version integer, fact_id uuid, semantic_key bigint, fact jsonb, support_count bigint, first_frontier bigint, last_frontier bigint, first_derived_at timestamp with time zone, last_changed_at timestamp with time zone)',
        'derived_relations(relation_id uuid, relation_name text, relation_version_id uuid, relation_version integer, owner name, row_type text, key_column name, public_view_name text, state text, created_at timestamp with time zone)',
        'derived_repair_diagnostics(reconciliation_id bigint, relation_version_id uuid, relation_name text, relation_version integer, diagnostic_order integer, code text, object_identity text, details jsonb, started_at timestamp with time zone, completed_at timestamp with time zone)',
        'support_history(support_id uuid, relation_version_id uuid, relation_name text, relation_version integer, rule_name text, rule_version integer, rule_version_id uuid, activation_id uuid, activation_generation bigint, activation_revision bigint, semantic_key bigint, fact jsonb, source_binding jsonb, active boolean, first_frontier bigint, last_frontier bigint, created_at timestamp with time zone, invalidated_at timestamp with time zone)'
      ]) signature;
    END IF;
    IF (SELECT extversion FROM pg_catalog.pg_extension WHERE extname = 'pg_react') IN ('0.5.0', '0.6.0', '0.7.0', '0.8.0', '0.9.0', '0.10.0', '0.11.0', '0.12.0') THEN
      SELECT array_agg(signature ORDER BY signature) INTO expected
      FROM unnest(expected || ARRAY[
        'derivation_components(program_version_id uuid, component_id uuid, component_order integer, cyclic boolean, rule_names text[], target_relations text[], frontier bigint, iterations integer, fact_count bigint, support_count bigint, fingerprint text, committed_at timestamp with time zone)',
        'derivation_iterations(run_id bigint, program_version_id uuid, component_id uuid, iteration integer, fact_count bigint, support_count bigint, fingerprint text, completed_at timestamp with time zone)',
        'derivation_program_repair_diagnostics(reconciliation_id bigint, program_version_id uuid, program_name text, program_version integer, diagnostic_order integer, code text, object_identity text, details jsonb, started_at timestamp with time zone, completed_at timestamp with time zone)',
        'derivation_program_runs(run_id bigint, program_version_id uuid, program_name text, program_version integer, started_at timestamp with time zone, completed_at timestamp with time zone, prior_frontier bigint, committed_frontier bigint, iterations integer, fact_count bigint, support_count bigint, status text, error_sqlstate text, error_message text, error_detail text, error_hint text, requested_by name)',
        'derivation_programs(program_id uuid, program_name text, program_version_id uuid, program_version integer, owner name, state text, max_iterations integer, max_facts bigint, frontier bigint, created_at timestamp with time zone)',
        'recursive_support_inputs(support_id uuid, input_order integer, relation_version_id uuid, relation_name text, semantic_key bigint, fact_id uuid)'
      ]) signature;
    END IF;
    IF (SELECT extversion FROM pg_catalog.pg_extension WHERE extname = 'pg_react') IN ('0.6.0', '0.7.0', '0.8.0', '0.9.0', '0.10.0', '0.11.0', '0.12.0') THEN
      SELECT array_agg(signature ORDER BY signature) INTO expected
      FROM unnest(expected || ARRAY[
        'derivation_dependency_graph(program_version_id uuid, program_name text, program_version integer, dependency_id uuid, rule_name text, input_order integer, polarity text, source_relation text, target_relation text, source_component_id uuid, target_component_id uuid, source_stratum integer, target_stratum integer)',
        'derivation_strata(program_version_id uuid, program_name text, program_version integer, component_id uuid, stratum integer, component_order integer, cyclic boolean, rule_names text[], target_relations text[], frontier bigint, iterations integer, fact_count bigint, support_count bigint, committed_at timestamp with time zone)',
        'negative_dependency_evidence(evidence_id uuid, program_version_id uuid, program_name text, program_version integer, rule_version_id uuid, rule_name text, input_order integer, support_id uuid, semantic_key bigint, checked_relation text, source_stratum integer, target_stratum integer, lower_frontier bigint)'
      ]) signature;
    END IF;
    IF (SELECT extversion FROM pg_catalog.pg_extension WHERE extname = 'pg_react') IN ('0.7.0', '0.8.0', '0.9.0', '0.10.0', '0.11.0', '0.12.0') THEN
      SELECT array_agg(signature ORDER BY signature) INTO expected
      FROM unnest(expected || ARRAY[
        'aggregate_dependency_evidence(evidence_id uuid, program_version_id uuid, program_name text, program_version integer, rule_version_id uuid, rule_name text, group_key bigint, counted_relation text, exact_count bigint, comparison text, threshold bigint, source_stratum integer, target_stratum integer, lower_frontier bigint)'
      ]) signature;
    END IF;
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
