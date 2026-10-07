# pg-react performance findings and follow-up work

Investigation date: 2026-10-07. The filename follows the requested name.
This note records read-only investigation results and recommendations; it does
not record implementation or approval of the proposed changes.

## Context and evidence

The workload was a 1,000-case simultaneous deadline burst on PostgreSQL
18.4, pg-react 0.46.1, pg-mdm 0.14.1 and pg-trickle 0.108.3. One managed
worker served the database with a one-second polling interval and 60-second
job leases. Runs used either batch size 1 or 32.

The inspected Git workspace was:

```text
/Users/grove/.p2p/executions/pg-react-27ebf0235562b8cf/v0-49-0-managed-deadlines-and-bounded-escalation-temporal-audit/runtime/workspace
```

Evidence paths below are relative to that workspace, not this checkout:

- R29: `.p2p/work/v0-49-0-managed-deadlines-and-bounded-escalation-temporal-audit/evidence/qualification-v0141-workload-r29-20261007/observations.json`
- R30C: `.p2p/work/issue-8-core-claim-maintenance/evidence/qualification-v0141-workload-r30c-batch1-20261007/observations.json`
- R31: `.p2p/work/issue-8-core-claim-maintenance/evidence/qualification-v0141-route-mat-r31-batch32-20261007/observations.json`

Live read-only PostgreSQL inspection and standalone `EXPLAIN ANALYZE` queries
also supplied evidence. Those query-plan results were returned in the
conversation and were not saved as separate artifacts. The qualification
containers ended during both investigations, limiting further comparisons.

| Run | Routing implementation | Batch | Result |
| --- | --- | --- | --- |
| R29 | Original | 32 | 98 burst receipts at 875.092 seconds after due; harness timed out |
| R30C | Original | 1 | 83 burst receipts; 900-second harness timeout |
| R31 | `summarized AS MATERIALIZED` | 32 | 995 burst receipts visible by 446.047 seconds after due; five terminal failures prevented completion |

R31's successful burst executions averaged 0.407418 seconds, with a median
of 0.406260 seconds and maximum of 0.484237 seconds. The earlier batch-1
run averaged about 8.8 seconds per execution. The routing change therefore
reduced observed execution time by roughly 22 times.

The 995 receipts in 446 seconds correspond to about 134 receipts/minute for
this burst. This is an observation, not a sustained capacity guarantee. The
complete churn phase did not run because the harness required 1,000 receipts.

## 1. Scope routing to the case being executed

**Priority: high. Evidence: measured.**

Locations:

- `integrations/pg-mdm/sql/routing.sql`: `pgreact_mdm.route_cases()`.
- `integrations/pg-mdm/sql/intent-worker.sql`: `intent_escalation_candidates`,
  `submit_escalation_intent()` and `submit_intent()`.

The original routing plan estimated one source row but received 1,006. It
recomputed the grouped routing result 1,006 times, taking approximately
4.9 seconds for one routing SELECT. Materializing `summarized` removed that
repeated aggregation and has already been implemented in the inspected
qualification workspace.

The remaining plan still performs approximately million-row nested-loop
comparisons. The adapter evaluates population routing once to select the
case's candidate and again during submission validation. An outer case-key
filter on the candidate view does not constrain the population query inside
the PL/pgSQL routing function.

A standalone comparison applied `case_key = 900` inside `source_rows`:

| Query | Execution time |
| --- | --- |
| Installed population routing SELECT | 260.444 ms |
| Same SELECT scoped to one case inside `source_rows` | 12.434 ms |

These measurements used `EXPLAIN (ANALYZE, BUFFERS, TIMING OFF, FORMAT JSON)`.
Planning took approximately 33-35 ms separately. The case-scoped comparison
measured the underlying SELECT, not the entire routing function, input
validation, submission or receipt transaction. It does not establish a
20-times improvement in complete execution time.

Further CTE materialization was also compared with per-node timing enabled:

| Variant | Execution time |
| --- | --- |
| Installed `summarized` materialization | 385.322 ms |
| Also materialize `best` | 451.558 ms |
| Also materialize `decided` | 390.111 ms |
| Also materialize both | 451.536 ms |

Do not compare these absolute times with the timing-disabled measurements.
The additional materializations did not improve their own baseline.

**Recommendation:** provide a case-scoped routing path and apply the key
predicate before population joins and aggregation. Retain the existing
population API for population inspection. Preserve authorization, duplicate
key validation, policy applicability, freshness and idempotency checks.

**Validation:** compare exact routing results with the existing API for
eligible, protected, ineligible and ambiguous cases; inspect plans for a
single case; then measure complete execution and burst drain. Retain query
plans, planning time and execution time separately.

## 2. Report PostgreSQL statistics from the managed worker

**Priority: high. Evidence: confirmed code omission and observed stale counters.**

Location: `src/managed.rs`, `pg_react_managed_main()`.

The worker commits through `BackgroundWorker::transaction()` and then waits
on its latch. Neither the worker nor the inspected pgrx 0.18.0 transaction
and latch helpers calls `pgstat_report_stat()`. They also do not report
running/idle activity, explaining the worker's blank query and state in
`pg_stat_activity`.

During R31, counters reported only four activation inserts after the
1,000-case cohort had activated. The sampled database `rows_changed` value
only moved from 77,282 to 77,807 despite thousands of worker writes. Several
populated worker tables had `reltuples = -1` and no recorded analyze.

PostgreSQL requires processes performing DML, including SPI workers, to
flush pending statistics. Its example worker reports statistics after
commit. Autovacuum uses the reported insert, dead-tuple and modification
counts to decide whether to vacuum or analyze. Missing reports can therefore
hide work from monitoring and suppress normal maintenance thresholds.
See the [statistics implementation](https://github.com/postgres/postgres/blob/REL_18_STABLE/src/backend/utils/activity/pgstat.c#L633),
[SPI worker example](https://github.com/postgres/postgres/blob/REL_18_STABLE/src/test/modules/worker_spi/worker_spi.c#L265)
and [autovacuum implementation](https://github.com/postgres/postgres/blob/REL_18_STABLE/src/backend/postmaster/autovacuum.c#L2875).

**Recommendation:** call the native statistics reporter after each committed
cycle, outside the transaction. `pgstat_report_stat(false)` provides normal
throttled reporting. Report worker activity around execution and idle waits.
Then check whether autoanalyze catches up and refresh existing statistics
where necessary.

Reporting alone may not fix every estimate: routing also casts
`entity_name` to text in its source predicate, while statistics exist on the
native `name` column. Examine that predicate and binding/runtime table
statistics when investigating the one-row estimate.

**Validation:** compare exact work/attempt rows with reported insert/update
counts over several committed cycles; verify visible worker activity and
eventual analyze/vacuum activity. Recheck routing and queue plans. A controlled
runtime comparison of statistics reporting was not performed in this audit.

## 3. Shorten batch transaction scope before adding workers

**Priority: medium-high. Evidence: code and observed visibility latency.**

Locations:

- `src/managed.rs`: one transaction surrounds `managed_cycle()`.
- `sql/pg_react--0.46.1.sql`: managed coordination calls global `run()`,
  then claims and executes the batch serially.
- Global coordination acquires advisory transaction lock `5788046901200000`.

The lock remains held through batch execution and commit. Increasing worker
count without changing transaction/lock scope would constrain concurrency.
Case locks and successful writes also remain held until the batch commits.

At R31's mean execution time, 32 executions alone take approximately
13 seconds. The first receipts became visible to the harness 18.051 seconds
after due, although the earliest receipt timestamp was about 0.597 seconds
after due. Receipt timestamps were shared by groups, with a median group
size of 32; they are not per-item commit-visibility timestamps.

**Recommendation:** evaluate separating coordination from execution and
committing smaller execution units. Preserve the atomicity of each intent,
case control, receipt and attempt. Avoid simply adding workers while the
global transaction lock spans all consequence execution.

**Validation:** measure actual receipt visibility, transaction duration and
lock waits under concurrent work. Exercise rollback, lease recovery and
idempotent retries across the proposed commit boundaries.

At the original 8.8-second execution time, a batch of 32 needed about
282 seconds, exceeding its 60-second leases. That was a plausible retry
amplifier, not a proven explanation for every R29 attempt. R30C remained
slow with batch size 1, establishing an independent execution cost. The
improved batch now fits much more comfortably within the lease, but batch
sizing should use measured wall-clock tails rather than averages alone.

## 4. Avoid polling sleeps while eligible work remains

**Priority: medium. Evidence: measured execution gaps and worker code.**

Location: `src/managed.rs`, unconditional `BackgroundWorker::wait_latch()`
after each cycle.

R31's gaps between successful executions totalled approximately 36 seconds.
Within a batch the median gap was about 0.00034 seconds; batch boundaries
typically added about 1.1 seconds. These gaps also include other work, so the
entire 36 seconds should not be attributed to sleep alone.

**Recommendation:** immediately continue draining after successful batches
when eligible work remains. Retain polling waits when idle and appropriate
backoff for blocked/error states. Preserve signal handling and avoid spinning
on terminal failures or work that is not yet available.

**Validation:** compare complete burst drain with identical batch settings;
check idle CPU, shutdown responsiveness and blocked-state behavior. This
optimization matters more after per-case routing becomes cheaper.

## 5. Index attempt-history lookups by request identity

**Priority: medium as retained history grows. Evidence: code-level scaling risk.**

Locations in `integrations/pg-mdm/sql/intent-worker.sql`:

- `submit_intent()` checks prior receipts by `(binding_id, request_key)`.
- `delivery_inspection_v1` finds the latest matching attempt using a lateral
  lookup for each request.

The inspected schema has no matching index on `intent_attempts`. Its original
primary key was `(episode_id, attempt_no)`; the current source changes that
to `(work_ref, attempt_no)`. Neither supports these request-identity lookups.
Submission and population delivery inspection can repeatedly scan growing
retained history.

**Recommendation:** profile an index on `(binding_id, request_key)` first.
That supports both paths without introducing another abstraction. Add
ordering columns only if latest-attempt sorting is measurably expensive.

**Validation:** inspect both plans on a realistically sized retained ledger,
compare exact delivery-inspection results, and measure submission latency and
additional index write cost. This path was not separately timed in R31.

## 6. Avoid repeated queue selection and lease sweeping

**Priority: medium for larger queues/rule counts. Evidence: code-level scaling risk.**

Locations:

- `sql/current/claim.sql`: `pgreact.claim()`.
- Inherited `claim_episode()` implementations in the assembled extension SQL.

The outer claim query sorts eligible candidates, but each iteration calls a
function that selects the next episode again. That path also sweeps expired
leases. The batch-level function already sweeps active/draining rule versions,
so a batch can repeat selection, sorting and sweeping for the same rule.

**Recommendation:** after statistics reporting is repaired, profile the
actual claim chain. Claim from selected rows and avoid repeated sweeps within
one batch where the lease protocol permits it. Preserve fairness, conflict
keys, agenda-group limits, policy support and `SKIP LOCKED` behavior.

**Validation:** retain queue plans at several backlog sizes; measure claim
time separately from coordination and consequence execution; compare exact
claimed identities and ordering, including contention and expired leases.

## 7. Use typed key predicates in deadline reconciliation

**Priority: medium for larger due bursts. Evidence: code-level scaling risk.**

Locations in `sql/pg_react--0.46.1.sql`: `reconcile_deadline_key()` and related
deadline reconciliation queries.

The per-key lookup uses an expression such as
`(to_jsonb(candidate) ->> 'case_key')::bigint` in its predicate. An ordinary
key-column index cannot directly serve that expression. Repeating it for
every due key can repeatedly scan and serialize the match population.
Deadline rules already create a `(deadline, key)` index, but that does not
make the JSON key predicate an ordinary indexed lookup.

R31's 1,000 recorded activations span approximately 1.665 seconds, and the
first recorded consequence execution started 4.047 seconds after due. These
are timing context, not an isolated measurement of this particular query.

**Recommendation:** reference the actual typed key column in dynamic SQL,
using safely quoted identifiers. Inspect the resulting plan and add a
key-leading index only if the existing stream indexes do not support it.

**Validation:** verify exact activation/lifecycle output, duplicate-key
detection and deadline boundaries. Profile increasingly large simultaneous
bursts and distinguish reconciliation from subsequent execution time.

## 8. Bound temporal maintenance and observation writes

**Priority: high when substantial temporal populations are enabled.
Evidence: code-level scaling risk; not exercised by this run.**

Locations in `sql/pg_react--0.46.1.sql`: `reconcile_temporal_frontier()`,
`reconcile_temporal_rule()` and `reconcile_temporal_key()`.

Each pass visits all retained temporal keys. Reconciliation updates each
key's state and inserts a history row even when there is no lifecycle change;
the history event is then `OBSERVE`. Deadline and cooldown indexes already
exist, but the frontier reconciliation enumerates the whole population.

At 1,000 keys and one pass per second, this produces 86.4 million observation
history rows per day, plus state updates. This is arithmetic for that assumed
cadence, not an observed operating rate. R31 had no temporal keys.

**Recommendation:** process source changes and due deadline/cooldown keys
using the existing indexes. Establish the required observation-history
granularity before changing retention or emission semantics. Preserve
duration, absence, hysteresis, recovery and frontier correctness.

**Validation:** measure idle temporal populations as well as changing ones;
verify exact transition histories and boundary behavior; track WAL, history
growth and vacuum activity over a meaningful duration.

## Qualification blockers and measurement corrections

### Retained attempt-key collisions

R31 reached zero pending/claimable work but only 995 burst receipts. Cases
18, 21, 34, 62 and 64 failed with `intent_attempts_pkey` violations. Their
episode/attempt numbers collided with retained attempts belonging to other
rule versions and cases.

The harness recreates the pg-react extension in a disposable clone while
retaining adapter request/attempt history. Bare episode numbers are therefore
insufficient identities across the reset. The current source already contains
the migration to primary key `(work_ref, attempt_no)` in
`integrations/pg-mdm/sql/request-store.sql`; that correction was not installed
in R31.

Verify the migration, retained history and exact 1,000-case completion in the
next run. Do not interpret the long plateau at 995 as continued throughput
work. The harness can also detect terminal failures while collecting the
required evidence, instead of waiting until the synchronization timeout.

### Failure-injection work contaminates capacity measurement

The active `s1-callback-failure` rule shares the workload source and generated
1,001 injected failed jobs. R31 processed 2,002 jobs overall, including this
extra lane. Each injected failure was cheap, but it still incurred admission,
claim, execution, polling and history work.

After proving callback failure and role restoration, pause the injected-failure
rule before measuring capacity. Preserve its evidence and use a separate
failure/recovery measurement when that behavior is the subject of the test.

### Measure visibility and write volume accurately

Use observer-visible receipts and pending progression for latency/drain
measurements. Receipt creation timestamps shared across a batch cannot
substitute for commit visibility.

From R31's first queue sample to its first 995-receipt sample, WAL grew by
149,759,537 bytes and database size by 10,838,016 bytes. This interval includes
other fixture and admission writes, so it is not a per-receipt write-cost
measurement. No storage/I/O bottleneck was established by this investigation.

Repair worker statistics reporting before relying on cumulative row-change
counters. Subsequent runs should retain the exact image/candidate identity,
settings, query plans, phase timings, observer-visible receipt progression,
terminal errors and resource measurements.

## Recommended order

1. Verify the attempt-key correction and isolate failure-injection work so a
   complete burst and churn run can finish.
2. Add native worker statistics/activity reporting and recheck maintenance
   and planner estimates.
3. Implement and measure case-scoped routing; this has the strongest measured
   remaining query improvement.
4. Remove unnecessary waits while eligible work remains.
5. Evaluate transaction/lock scope if receipt visibility or concurrency still
   falls short of the selected workload's requirements.
6. Profile retained-ledger lookups, claim selection and deadline key access at
   larger sizes; address temporal observation growth before enabling a large
   temporal population.
