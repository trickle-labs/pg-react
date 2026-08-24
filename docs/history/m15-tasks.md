# M15 public tasks

## Install and operate

Install pg_trickle `0.81.0` and pg-react `0.12.0`, then configure PostgreSQL:

```conf
shared_preload_libraries = 'pg_trickle,pg_react'
pg_react.databases = 'appdb'
pg_react.worker_role = 'postgres'
pg_react.poll_interval_ms = 1000
pg_react.batch_size = 32
pg_react.max_pending_jobs = 10000
```

Restart, create both extensions, configure five distinct roles, and require the
exact ready envelope:

```sql
CREATE EXTENSION pg_trickle;
CREATE EXTENSION pg_react;
SELECT pgreact_api.configure_roles(
  'rule_author', 'rule_operator', 'rule_worker', 'rule_reader',
  'rule_advanced_reader');
SELECT pgreact_api.doctor();
-- {"status":"ready","diagnostics":[],"contract_version":5}
```

Use `managed_status()` for process, heartbeat, backlog, and protocol state. On
backpressure, fix or drain work before raising `max_pending_jobs`. On crash,
PostgreSQL restarts the process. On standby it makes no claims; after promotion
it attaches and resumes. A SIGHUP reloads the three runtime bounds.

## Author and explain typed keys

Use a deterministic C collation for text key columns and declare order explicitly:

```sql
SELECT pgreact_api.author_rule(
  'tenant.event', 'app.pending_event',
  ARRAY['tenant', 'event_id']::name[],
  'app_action', 'record_event');
SELECT pgreact_api.run();
SELECT pgreact_api.matches('tenant.event');
SELECT pgreact_api.explain(
  'tenant.event', '["north","123e4567-e89b-12d3-a456-426614174000"]'::jsonb);
```

`key_codecs()` publishes the frozen matrix. Null components, duplicate projected
keys, unsupported types, and unstable collations fail before identity state is
changed.

Derived programs use the same array overload for `declare_derived_relation`;
program rules still name the public definition view and public target. Internal
codec columns are generated and never belong in application SQL.

## Backup, restore, and upgrade

Stop claims, take and verify a physical backup, then follow
[`m15-upgrade.md`](m15-upgrade.md). Physical restore preserves managed and typed
state. For logical portability, dump application declarations and data, restore
extensions first, replay declarations, restore data, call `run`, and compare
`status`, `matches`, `jobs`, and `explain` to the captured exact outputs.

If upgrade or health checks fail, keep workers stopped and restore the verified
backup. Do not query private schemas or call raw worker functions to repair a
normal workflow.
