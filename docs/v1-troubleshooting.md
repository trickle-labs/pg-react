# v1 troubleshooting

For package deployment issues in `0.42.0`, start with the returned finding code
and re-run `pgreact.preview()` before retrying a stale plan.

Use public SQL only. Never edit private catalogs, delete barriers directly, or
repair an internal UUID by hand.

Every repair follows:

```text
observe -> diagnose -> repair prerequisite -> invoke public operation -> verify
```

## First response

1. **Observe**

   ```sql
   SELECT pgreact.doctor();
   SELECT * FROM pgreact.health ORDER BY blocking DESC, severity, code, target;
   SELECT pgreact_api.managed_status();
   SELECT * FROM pgreact.rules ORDER BY name, version;
   SELECT kind, name, version, work_id, state, claimable, updated_at
   FROM pgreact.work
   ORDER BY updated_at DESC NULLS LAST, kind, name, work_id;
   SELECT execution_id, episode_id, attempt_no, started_at, finished_at,
          status, error_code, error_message, name
   FROM pgreact.attempts
   ORDER BY started_at DESC, execution_id DESC;
   ```

2. **Diagnose** — classify the problem below.
3. **Repair prerequisite** — repair the reported external/public object or
   environment before invoking work.
4. **Invoke public operation** — use only the operation named for that class.
5. **Verify** — repeat the first-response queries and the target-specific
   `pgreact.status(name)`/`pgreact.explain(name)` call.

## Unsupported environment

1. **Observe** — run `pgreact.doctor()`, `SHOW shared_preload_libraries`,
   `SHOW pg_react.databases`, and `pgreact_api.managed_status()`.
2. **Diagnose** — identify the exact PostgreSQL, pg_trickle, preload,
   isolation, architecture, role, database-list, or RLS finding.
3. **Repair prerequisite** — correct that condition. Postmaster settings
   require a PostgreSQL restart.
4. **Invoke public operation** — restart PostgreSQL; do not use `run()` to
   conceal an unsupported environment.
5. **Verify** — `doctor().state` is `ready`, health has no blocking row, and
   managed status is configured and ready.

## Managed runtime failures

| Symptom | Likely cause | Safe repair |
| --- | --- | --- |
| `configured = false` | Current database is absent from `pg_react.databases` | Add it and restart PostgreSQL |
| `process` is null | Worker was not started, preload is missing, or database is not configured | Correct preload/database settings and restart |
| `process.state = 'error'` | `process.detail` contains the SQLSTATE/message from the managed cycle | Repair the reported source, role, work, or barrier prerequisite |
| Heartbeat stops | Worker/backend failure | Confirm the old backend is gone; PostgreSQL restarts the managed worker |
| Coordination stops but old work drains | `pg_react.max_pending_jobs` backpressure threshold reached | Drain/repair backlog or raise the reviewed threshold |
| Extension is not `0.31.0` | Current managed runtime version gate does not match | Keep workers stopped; use only a qualified packaged upgrade path |

1. **Observe** — inspect `pgreact_api.managed_status()`, configuration, and the
   exact `process.detail`.
2. **Diagnose** — map the symptom to the table above.
3. **Repair prerequisite** — repair configuration, roles, backlog, source,
   consequence, or version qualification.
4. **Invoke public operation** — restart PostgreSQL for postmaster changes, or
   let the repaired managed worker poll.
5. **Verify** — managed status is ready and doctor/health contain no blocking
   finding.

## Source or consequence drift

1. **Observe**

   ```sql
   SELECT * FROM pgreact.health
   WHERE details ->> 'source_code'
         IN ('SOURCE_DRIFT', 'CONSEQUENCE_DRIFT');
   SELECT pgreact.doctor('<rule-name>');
   SELECT pgreact.explain('<rule-name>');
   ```

2. **Diagnose** — determine whether the source relation/shape changed or the
   exact consequence/dispatcher definition is missing or changed.
3. **Repair prerequisite** — restore the intended public object, or construct
   and compare an explicit replacement declaration.
4. **Invoke public operation** — deploy the reviewed replacement. For the
   advanced compatibility path, pause by name before replacement:

   ```sql
   SELECT pgreact.pause_rule('<rule-name>');
   ```

5. **Verify** — `pgreact.status(name)` is healthy and the drift finding is
   absent. Do not resume a rule while a barrier remains.

## Applicability drift or policy barrier

1. **Observe**

   ```sql
   SELECT pgreact.status('<policy-set-name>');
   SELECT pgreact.doctor('<policy-set-name>');
   ```

2. **Diagnose** — installed runtime barriers distinguish missing/drifted
   source, RLS protection, duplicate subjects, null/incomplete subjects,
   malformed key types, and source-size limits.
3. **Repair prerequisite** — restore a readable non-RLS applicability source
   with complete, unique, correctly typed subjects within the declared bound.
4. **Invoke public operation**

   ```sql
   SELECT pgreact.run();
   ```

5. **Verify** — target status returns to `AUTHORITATIVE`; prior eligibility and
   supports remain unchanged until the repaired run succeeds.

## Failed work and retry exhaustion

1. **Observe**

   ```sql
   SELECT w.*, a.attempt_no, a.started_at, a.finished_at, a.status,
          a.error_code, a.error_message
   FROM pgreact.work AS w
   LEFT JOIN pgreact.attempts AS a ON a.episode_id::text = w.work_id
   WHERE w.state IN ('FAILED', 'CANCELLED', 'WITHDRAWN')
   ORDER BY w.updated_at DESC NULLS LAST, a.attempt_no DESC;
   ```

2. **Diagnose** — use the complete attempt status and error fields to identify
   the consequence failure. Confirm whether an external delivery may already
   have occurred.
3. **Repair prerequisite** — repair the consequence and make replay
   idempotent. External delivery is at least once.
4. **Invoke public operation** — advanced rule episodes only:

   ```sql
   SELECT pgreact.requeue_episode(<work_id>::bigint);
   ```

5. **Verify** — a new attempt completes and the terminal work row clears or
   reaches the intended terminal state.

There is no generic retry façade. Decision work and other advanced work kinds
must use their owning public operation rather than casting every `work_id` to
an episode.

## Stale lease

1. **Observe** — inspect `pgreact.health` where
   `details ->> 'source_code' = 'STALE_LEASE'`,
   `pgreact_api.managed_status()`, and the leased row in `pgreact.work`.
2. **Diagnose** — prove the previous worker is no longer executing.
3. **Repair prerequisite** — wait for actual expiry or restore worker health.
4. **Invoke public operation**

   ```sql
   SELECT pgreact.sweep_expired_leases(
     (SELECT rule_version_id
      FROM pgreact.rules
      WHERE name = '<rule-name>'
      ORDER BY created_at DESC
      LIMIT 1));
   ```

5. **Verify** — the finding disappears and the episode is pending or
   completed.

## Recovery barrier

1. **Observe**

   ```sql
   SELECT * FROM pgreact.health
   WHERE details ->> 'source_code' = 'BARRIER' OR blocking;
   SELECT pgreact.doctor();
   ```

2. **Diagnose** — preserve state and keep managed workers stopped. Determine
   whether the trigger was restore, promotion, source drift, invalid keys, or
   consequence drift.
3. **Repair prerequisite** — restore all public dependencies and verify the
   database is no longer a standby.
4. **Invoke public operation**

   ```sql
   SELECT pgreact.prepare_recovery();
   SELECT pgreact.reconcile_rule(
     (SELECT rule_version_id
      FROM pgreact.rules
      WHERE name = '<affected-standalone-rule>'
      ORDER BY created_at DESC
      LIMIT 1),
     'STATE_ONLY');
   ```

5. **Verify** — doctor/health are clean and matches/status agree before managed
   workers resume.

`prepare_recovery()` creates barriers broadly. Reconcile every affected
standalone rule and use the owning public reconcile operation for advanced
declaration families.

## Comparison failures and findings

M34 comparison accepts only rule, decision-program, and policy-set proposals
against a same-kind, same-name deployed target. It compares current facts
only. Rule comparison specifically requires one `bigint` key even though
other advanced rule surfaces can support broader typed identities.

| Code | Failure category | Remediation |
| --- | --- | --- |
| `M34_INVALID_DECLARATION` | Proposal is absent or invalid | Supply a declaration and fix every blocking `pgreact.validate()` finding |
| `M34_OPTIONS` | Options are not a JSON object, or `sampled_time` is not an RFC3339 string | Pass a JSON object with correctly typed fields |
| `M34_TARGET_NOT_FOUND` | Target is missing, stale, or lacks kind/name | Select a currently deployed target with `pgreact_api.target(...)` |
| `M34_TARGET_KIND` | Proposal and target kinds differ | Use the same supported kind on both sides |
| `M34_TARGET_NAME` | Proposal and target names differ | Keep the deployed stable name in the proposal |
| `M34_TARGET_VERSION` | Unsupported deployed version selected | For non-policy declarations select deployed version `1`; for a policy set select its actual deployed version |
| `M34_UNAUTHORIZED_TARGET` | Caller may not inspect the target | Run as the owner, configured reader, or operator; do not expose redacted evidence manually |
| `M34_UNAUTHORIZED_SOURCE` | Caller lacks `SELECT` on a source | Grant only the required source access or use an authorized review role |
| `M34_RLS_UNSUPPORTED` | A compared source has RLS enabled | Use a permitted non-RLS review relation; comparison does not bypass RLS |
| `M34_SOURCE_DRIFT` | Source is missing, contains null identities, or no longer matches required shape | Restore/rebuild the public source and keys, then rerun |
| `M34_PROPOSAL_DUPLICATE` | Proposed rule source contains duplicate keys | Make the proposed comparison key unique |
| `M34_WRONG_KEY_TYPE` | Rule comparison key is not `bigint` | Use a comparable `bigint` rule key; do not generalize this limit to every advanced rule API |
| `M34_RESOURCE_LIMIT` | `evidence_limit` is outside the installed bound | Set `evidence_limit` from `1` through `1000` |
| `M34_SAMPLED_TIME` | Requested time differs from the current authoritative frontier | Omit `sampled_time` or use the exact current frontier; use the M35 hypothetical overload or M36 replay for other inputs |
| `M34_UNSUPPORTED_KIND` | Proposal kind is outside rule, decision program, or policy set | Use a supported kind |
| `M34_AUTHORITATIVE_CHANGED` | Production state changed during comparison | Retry after concurrent activity settles; never accept the stale result |
| `M34_COMPARISON_INCOMPLETE` | Bounded evidence is partial | Rerun with a higher `evidence_limit` up to `1000`; `compare_results()` has the same bound and no hidden continuation |
| `M34_NO_EFFECT` | Informational proof that comparison did not mutate covered authoritative state | No repair; review the result and choose whether to deploy |

For a partial result:

```sql
SELECT pgreact.compare(
  <proposed-declaration>,
  pgreact_api.target('<kind>', '<name>', '<version-if-policy-set>'),
  '{"evidence_limit":1000}'::jsonb);
```

Do not treat `partial`, `truncated = true`, or `counts_exact = false` as a
complete review.

## Comparison authorization, RLS, and stale targets

1. **Observe** — record the exact M34 code; do not log protected result data.
2. **Diagnose** — distinguish target authorization, source authorization, RLS,
   stale target/name/version, source drift, and authoritative concurrency.
3. **Repair prerequisite** — correct roles or public source/target selection;
   never bypass RLS or private grants.
4. **Invoke public operation** — rerun `pgreact.compare()` with current target
   identity and current-only `sampled_time`.
5. **Verify** — result is `ready`, or explicitly `partial`; authorization
   failures reveal no comparison rows.

## When to stop

Keep workers stopped and escalate when:

- recovery provenance is uncertain;
- a blocking barrier remains after its public reconciliation procedure;
- the consequence may have produced an unsafe non-idempotent external effect;
- the only proposed repair is a private-catalog change;
- an upgrade or restore requires rollback to the verified physical backup.
