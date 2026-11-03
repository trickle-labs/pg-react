WITH expected(schema_name, relation_name, trigger_name, function_name, trigger_type) AS (
    VALUES
        ('mdm_steward', 'policy_receipts_v1', 'pgreact_mdm_receipts_retention',
         'pgreact_mdm.guard_policy_history_retention()', 11),
        ('mdm_steward', 'policy_receipts_v1', 'pgreact_mdm_receipts_no_truncate',
         'pgreact_mdm.guard_policy_history_retention()', 34),
        ('mdm_steward', 'policy_cases_v1', 'pgreact_mdm_cases_retention',
         'pgreact_mdm.guard_policy_history_retention()', 11),
        ('mdm_steward', 'policy_cases_v1', 'pgreact_mdm_cases_no_truncate',
         'pgreact_mdm.guard_policy_history_retention()', 34),
        ('pgreact_mdm', 'policy_intent_bindings', 'intent_bindings_retained',
         'pgreact_mdm.guard_intent_retention_markers()', 27),
        ('pgreact_mdm', 'policy_intent_bindings', 'intent_bindings_no_truncate',
         'pgreact_mdm.guard_intent_retention_markers()', 34),
        ('pgreact_mdm', 'intent_case_identities', 'intent_case_identities_retained',
         'pgreact_mdm.guard_intent_retention_markers()', 27),
        ('pgreact_mdm', 'intent_case_identities', 'intent_case_identities_no_truncate',
         'pgreact_mdm.guard_intent_retention_markers()', 34),
        ('pgreact_mdm', 'intent_requests', 'intent_requests_retained',
         'pgreact_mdm.reject_intent_record_mutation()', 27),
        ('pgreact_mdm', 'intent_requests', 'intent_requests_no_truncate',
         'pgreact_mdm.reject_intent_record_mutation()', 34),
        ('pgreact_mdm', 'intent_attempts', 'intent_attempts_retained',
         'pgreact_mdm.reject_intent_record_mutation()', 27),
        ('pgreact_mdm', 'intent_attempts', 'intent_attempts_no_truncate',
         'pgreact_mdm.reject_intent_record_mutation()', 34)
), expected_functions(function_identity, source_sha256, owner_name, security_definer) AS (
    VALUES
        ('pgreact_mdm.guard_policy_history_retention()',
         '09712a3b522ce9fe2bc4c05a883658e8b214efec3f922ee5223e9d6649b0caa7',
         'mdm_helper_owner', true),
        ('pgreact_mdm.guard_intent_retention_markers()',
         '46424a1833d4314f9facd74770254c6699930c65873ce083db24d05781d28a5c',
         'mdm_retention_guard_owner', true),
        ('pgreact_mdm.enforce_history_guard_ddl()',
         '3408c158b7b6f28db0b27a51f7f31fac43a99c19f07845504521d453806d00ab',
         'mdm_retention_guard_owner', true),
        ('pgreact_mdm.reject_intent_record_mutation()',
         'a366cc2d23c09dc290f093757def50713127fc0c0e57e2d48faea66a96c0f82c',
         'mdm_helper_owner', false)
), row_guards AS (
    SELECT pg_catalog.format('%I.%I/%I', e.schema_name, e.relation_name,
                             e.trigger_name) AS guard,
           COALESCE(
               t.oid IS NOT NULL
               AND t.tgfoid = pg_catalog.to_regprocedure(e.function_name)
               AND t.tgtype = e.trigger_type
               AND t.tgenabled = 'O'
               AND NOT t.tgisinternal
               AND t.tgqual IS NULL,
               false) AS healthy
    FROM expected AS e
    LEFT JOIN pg_catalog.pg_trigger AS t
      ON t.tgrelid = pg_catalog.to_regclass(
             pg_catalog.format('%I.%I', e.schema_name, e.relation_name))
     AND t.tgname = e.trigger_name
), guards AS (
    SELECT guard, healthy FROM row_guards
    UNION ALL
    SELECT pg_catalog.format('function/%s', expected.function_identity),
           COALESCE(
               function_row.oid IS NOT NULL
               AND pg_catalog.encode(
                   pg_catalog.sha256(pg_catalog.convert_to(function_row.prosrc, 'UTF8')),
                   'hex') = expected.source_sha256
               AND pg_catalog.pg_get_userbyid(function_row.proowner) = expected.owner_name
               AND function_row.prosecdef = expected.security_definer
               AND function_row.proconfig = ARRAY['search_path=pg_catalog, pg_temp']::text[],
               false)
      FROM expected_functions AS expected
      LEFT JOIN pg_catalog.pg_proc AS function_row
        ON function_row.oid = pg_catalog.to_regprocedure(expected.function_identity)
    UNION ALL
    SELECT 'event-trigger/pgre_mdm_history_guard_ddl', EXISTS (
        SELECT 1
        FROM pg_catalog.pg_event_trigger AS et
        WHERE et.evtname = 'pgre_mdm_history_guard_ddl'
          AND et.evtevent = 'ddl_command_end'
          AND et.evtenabled = 'O'
          AND et.evtfoid = pg_catalog.to_regprocedure(
              'pgreact_mdm.enforce_history_guard_ddl()')
          AND et.evttags @> ARRAY[
              'ALTER TABLE', 'CREATE TRIGGER', 'DROP TRIGGER', 'DROP TABLE',
              'DROP OWNED', 'CREATE FUNCTION', 'ALTER FUNCTION', 'DROP FUNCTION',
              'ALTER SCHEMA', 'DROP SCHEMA', 'ALTER EXTENSION', 'DROP EXTENSION']
          AND ARRAY[
              'ALTER TABLE', 'CREATE TRIGGER', 'DROP TRIGGER', 'DROP TABLE',
              'DROP OWNED', 'CREATE FUNCTION', 'ALTER FUNCTION', 'DROP FUNCTION',
              'ALTER SCHEMA', 'DROP SCHEMA', 'ALTER EXTENSION', 'DROP EXTENSION']
              @> et.evttags)
    UNION ALL
    SELECT 'role/mdm_retention_guard_owner', EXISTS (
        SELECT 1
        FROM pg_catalog.pg_roles AS r
        WHERE r.rolname = 'mdm_retention_guard_owner'
          AND NOT (r.rolcanlogin OR r.rolsuper OR r.rolcreatedb OR r.rolcreaterole
                   OR r.rolinherit OR r.rolreplication OR r.rolbypassrls)
          AND NOT EXISTS (
              SELECT 1 FROM pg_catalog.pg_auth_members AS m
              WHERE m.roleid = r.oid OR m.member = r.oid))
)
SELECT jsonb_build_object(
    'all_healthy', bool_and(healthy),
    'guards', jsonb_agg(
        jsonb_build_object('guard', guard, 'healthy', healthy) ORDER BY guard))
FROM guards;
