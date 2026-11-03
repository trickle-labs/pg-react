# pg-mdm stewardship adapter

The v0.47 package is a read-only policy layer over the approved
`MDM-STEWARDSHIP/1` projection. It validates an authorized case relation,
publishes immutable React-owned policy revisions, and exposes deterministic
routing, elapsed-time deadline, and fixed-population comparison reads. The
additive v0.48 worker package submits reviewed queue, due-date, and escalation
intents through pg-react's existing episode transaction.

The v0.47 read path never writes an MDM relation, calls `submit_policy_intent`,
creates React work, advances a lifecycle frontier, or invokes a refresh. The
v0.48 worker writes only through `mdm_steward.submit_policy_intent`; MDM remains
the authority for each action. Live v0.47 qualification passed against pg-mdm
v0.13.1 (extension version 0.14.0), which provides
`mdm_steward.policy_cases_v1`; fixture qualification uses a separate schema.
Support is limited to the approved 100-case pilot envelope. Production-scale
resource and recovery limits remain unsupported; see the
[v0.48.0 release notes](../../docs/v0.48.0-release-notes.md).

The v0.49 managed-escalation envelope has been selected but is not yet
release-qualified. Keep production activation disabled until the exact-artifact
qualification gates pass; see the [v0.49 qualification record](../../docs/v0.49-qualification.md).

Install the SQL files in order:

```text
integrations/pg-mdm/sql/policy-inputs.sql
integrations/pg-mdm/sql/routing.sql
integrations/pg-mdm/sql/deadline-preview.sql
integrations/pg-mdm/sql/comparison.sql
integrations/pg-mdm/sql/typed-flow.sql
integrations/pg-mdm/sql/request-store.sql
integrations/pg-mdm/sql/intent-worker.sql
integrations/pg-mdm/sql/retention-guard.sql  # run as superuser after the adapter files
```

For v0.49, install `retention-guard.sql` as a superuser after
`request-store.sql` and `intent-worker.sql`. It creates the isolated guard-owner
role and protects retained MDM history from early deletion and ordinary-owner
DDL removal. Do not disable or drop the guard as part of routine maintenance.

For an owner-preserving cross-cluster restore, provision the cluster role on the
target before restoring the database:

```sh
psql -d postgres -f integrations/pg-mdm/sql/retention-guard-role.sql
```

After the database restore and matching MDM helper configuration, run
`integrations/pg-mdm/sql/restore-adapter.sql` as a superuser, then reconcile the
restored MDM binding before reactivating managed work. See the v0.49
qualification record for the exact restore procedure and its remaining limits.

## Retention guard monitoring

Configure `PGSERVICEFILE` to a protected libpq service file and set
`PGSERVICE` to a monitor service with access to the PostgreSQL catalogs used by
`retention-guard-health.sql`. Schedule this check at least daily and after each
restore:

```sh
python3 integrations/pg-mdm/retention_guard_monitor.py
```

The command prints the guard JSON and exits nonzero if psql fails, the query
times out, the result is malformed, any guard is unhealthy, or the result does
not contain all eighteen expected guard entries. Treat any nonzero exit as a
retention incident; suspend pruning and entity deletion until the check is
healthy. This supplies a monitor command, not a deployed scheduler or proof of
90-day backup retention.

The health query checks the SHA-256 source, owner, `SECURITY DEFINER` setting,
and fixed `search_path` of all four guard functions. This detects a replaced
function body while its trigger remains attached; a superuser can still remove
or replace the monitor and its target objects. When a guard function changes,
update its pinned source hash in the health query and rerun the focused
history-retention regression before deployment; otherwise the monitor fails
closed.

For a systemd host, the [`systemd/`](systemd/) directory contains an optional
daily oneshot service and persistent timer. Install the integration under
`/opt/pg-react` or edit `ExecStart` to its read-only install path. Create the
`pgreact-monitor` operating-system account (with a matching group), then install
the environment template and libpq service file so only root and that account
can read them. The service file must use the approved monitor connection and
match the permissions required by the host's security policy. Copy both unit
files under `/etc/systemd/system/`, run `systemctl daemon-reload`, enable
`pg-react-retention-guard.timer`, and start
`pg-react-retention-guard.service` once immediately. Confirm its `Result=success`
and that the timer is listed by `systemctl list-timers`. Run the service again
after each restore, once the guards are reinstalled and before allowing pruning
or entity deletion. Connect nonzero service results and missed daily runs to the
host's alerting system; systemd records failures but does not send alerts by
itself. This is an installation example, not proof that a production host has
deployed or monitored the timer.

Before enabling the timer, create the account, configuration directory, and
service file for the approved monitor connection:

```sh
sudo useradd --system --user-group --no-create-home --shell /usr/sbin/nologin pgreact-monitor
sudo install -d -o root -g pgreact-monitor -m 0750 /etc/pg-react
sudoedit /etc/pg-react/retention-monitor.pg_service.conf
sudo chown root:pgreact-monitor /etc/pg-react/retention-monitor.pg_service.conf
sudo chmod 0640 /etc/pg-react/retention-monitor.pg_service.conf
sudo install -o root -g pgreact-monitor -m 0640 integrations/pg-mdm/systemd/retention-guard-monitor.env.example /etc/pg-react/retention-guard-monitor.env
```

Install the monitor and units, then enable and run the check once:

```sh
sudo install -o root -g root -m 0755 -d /opt/pg-react/integrations/pg-mdm/sql
sudo install -o root -g root -m 0644 integrations/pg-mdm/retention_guard_monitor.py /opt/pg-react/integrations/pg-mdm/retention_guard_monitor.py
sudo install -o root -g root -m 0644 integrations/pg-mdm/sql/retention-guard-health.sql /opt/pg-react/integrations/pg-mdm/sql/retention-guard-health.sql
sudo install -o root -g root -m 0644 integrations/pg-mdm/systemd/pg-react-retention-guard.service /etc/systemd/system/pg-react-retention-guard.service
sudo install -o root -g root -m 0644 integrations/pg-mdm/systemd/pg-react-retention-guard.timer /etc/systemd/system/pg-react-retention-guard.timer
sudo systemctl daemon-reload
sudo systemctl enable --now pg-react-retention-guard.timer
sudo systemctl start pg-react-retention-guard.service
sudo systemctl show --property=Result --value pg-react-retention-guard.service
sudo systemctl list-timers pg-react-retention-guard.timer
```

Keep the service file and environment file readable by the service account; do
not put passwords in the unit files. Select a root-controlled source revision
for the two installed program files and query; this example copies from the
current checkout.

The public seams are:

- `pgreact_mdm.validate_inputs(source_relation)` and
  `pgreact_mdm.policy_inputs(source_relation)` for the authorized projection.
- `pgreact_mdm.publish_package(policy_revision, package)` for immutable package
  publication and `pgreact_mdm.policy_document(policy_revision)` for review.
- `pgreact_mdm.route_cases(source_relation, policy_revision[, entity_name])`
  for winner, ambiguity, no-candidate, protection, and no-op explanations.
- `pgreact_mdm.route_cases(source_relation, policy_revision, entity_name, captured_at)`
  for the same read at one explicit finite database-time sample (`NULL` entity
  selects all entities). Equality with `due_at` counts as due. The existing
  overloads sample `statement_timestamp()` once; population comparison uses its
  supplied `captured_at` for both routing and deadline proposals. Its
  explanation records that sample, the current deadline and escalation level,
  the requested level, due status, and the specific ineligibility reason.
- `pgreact_mdm.deadline_preview(source_relation, policy_revision, captured_at[, entity_name])`
  for explicit-time deadline proposals.
- `pgreact_mdm.compare_population(...)` for complete or partial bounded
  comparisons with an explicit coverage manifest.

The explicit-time routing read is preparatory work for
[managed bounded escalation #11](https://github.com/trickle-labs/pg-react/issues/11). It does not
register a managed escalation policy or certify delivery. The
[implementation status](../../docs/v0.49-issue-11-status.md) records the
owner-confirmed semantics, satisfied MDM fixture prerequisite, and remaining
managed-runtime gates.

After the core extension is installed, load `typed-flow.sql` and pass the
returned `pgreact_api.declaration` to `pgreact.validate`, `pgreact.preview`,
`pgreact.review_token`, and `pgreact.compare`. The bridge adds the signed MDM
source as a typed policy support relation. The typed version includes the
published package digest, so route or deadline changes require a new revision
and declaration review. It does not deploy or run the declaration.
Run `tests/integrations/pg-mdm/v0.47-typed.sql` after the fixture test in a
database with the core extension installed to check that identity.

For v0.48, publish a canonical intent package with
`pgreact_mdm.publish_intent_package(policy_revision, package)`. Run
`pgreact_mdm.intent_declaration`, review its preview, then deploy it through
`pgreact.deploy` before creating any binding. pg-react checks that the runner
owns the candidate views and callback functions. After installing the adapter,
a DBA grants `pgreact_mdm_worker` to a non-superuser runner login with
`SET TRUE, INHERIT FALSE`, then calls
`pgreact_mdm.configure_intent_deployer(login_role)`. The runner must have no
membership in the MDM helper or entity execution roles. pg-react also needs its
login to read `mdm_steward.policy_cases_v1` when it creates the evaluation stream;
it receives no MDM binding or receipt access. The selected NOLOGIN worker reads
only the authorized case projection. The runner owns the intent views and
callbacks, which invoke the worker-owned submission function. After deploying
the three rules, call `configure_intent_deployer(login_role)` again; this leaves
rule review and refresh owned by the runner and assigns the generated episode
dispatchers to the worker.

After deployment, the entity execution role creates or replaces a binding with
`pgreact_mdm.create_intent_binding` or
`pgreact_mdm.replace_intent_binding`. Grant that role `USAGE` on `pgreact_mdm`
so it can call these adapter routines. Each operation activates or reconciles
the MDM binding and makes its local runtime eligible. The runner then calls
`pgreact_mdm.sync_intent_case_identities()` and refreshes the three rules before
processing episodes. Run `pgreact_mdm.execute_intent_episode` with the runner
session set to `pgreact_mdm_worker`; refresh rules as the runner because pg-react
checks rule ownership. The adapter stores a stable bigint identity for each
entity and case pair. The pinned MDM implementation allocates case keys from its
[database-wide sequence](https://github.com/trickle-labs/pg-mdm/blob/ad2597f72ee657cb946c5bbd7ae5eb2bfd1ac1b3/src/api/policy.rs#L442).
The adapter's identity map keeps entity scope explicit. Run the sync before
manual refresh whenever MDM may have new cases. The ordinary managed
worker now runs this same authorized sync before its refresh/time evaluation,
so a new MDM occurrence needs no manual enrollment. Sync does not activate a
binding or grant the worker access to producer-private catalogs. After a restore, the entity
execution role must call
`pgreact_mdm.reconcile_intent_binding(binding_id, 0)` before the runner syncs
identities and refreshes rules. Use `pgreact_mdm.pause_intent_binding` to pause
a live binding.

The worker role is `pgreact_mdm_worker`: `NOLOGIN`, `NOSUPERUSER`,
`NOBYPASSRLS`, and `NOINHERIT`. It can read the authorized case projection and
execute `submit_policy_intent`; it has no direct access to MDM binding or
receipt tables, and no membership path to `mdm_helper_owner` or the entity
execution role. MDM rejects its calls to human decision, refresh, rebuild, and
identity APIs. The adapter helper is owned by `mdm_helper_owner` and restores
only the narrow worker grants after binding creation, replacement, or
reconciliation.

The read-only `pgreact_mdm.delivery_inspection_v1` view reports the current
deadline and escalation level beside the requested level and the level recorded
in an applied MDM receipt. It also carries binding and policy versions,
delivery state, receipt outcome, and remediation reason. The receipt level is
historical; the current case level may change after a later human action.

Run `tests/integrations/pg-mdm/v0.48-codec.sql` after the fixture test, then
run `tests/integrations/pg-mdm/v0.47-live-setup.sql` to create the second MDM
entity used to exercise escalation. Run
`tests/integrations/pg-mdm/v0.48-live.sql` and
`tests/integrations/pg-mdm/v0.48-security.sql` in the joint pg-mdm 0.14 /
pg-react database. The scripts expect the MDM `foundation` E2E setup, including
the non-superuser `mdm_legacy_login` and `mdm_test_login`. The live script
creates a test-only `mdm_m2_runner` login that can set only the worker role;
each entity execution role creates its own binding. Run
`tests/integrations/pg-mdm/v0.48-restore.sh` only in a disposable joint cluster;
it pauses the source binding and recreates the worker role to qualify logical
restore, stale database and role OIDs, and entity-role reconciliation. The
checked-in v0.48 SQL checks passed on the local pg-mdm 0.14.0 image. T48.04-T48.10
and the retention approval remain open. See [the qualification evidence](../../tests/integrations/pg-mdm/evidence/v0.48.0.md)
for the results and remaining gates.
The image carries the matching pg-mdm `configure_helper.sql`; when running the
restore script from a host checkout, set `MDM_HELPER_CONFIG` to that file so
restored MDM helpers regain their protected ownership before reconciliation.

For installed MDM M1 qualification, bootstrap the upstream image with
`/tests/e2e.sql` and `/tests/e2e_policy.sql`, then run
`tests/integrations/pg-mdm/v0.47-live-setup.sql` followed by
`tests/integrations/pg-mdm/v0.47-live.sql` in a disposable joint database.

The package is adapter-owned and optional; the core pg-react extension remains
usable without it.

For the managed-deadline candidate, see the [v0.49 qualification profile and
operator procedure](../../docs/v0.49-qualification.md). It records prospective
limits, focused upgrade/recovery proofs and the remaining release gates.

## Bounded JSONL producer

The selected producer interface for the v0.49 envelope is the installable
`pg-react-bounded-refresh-producer` CLI. It consumes an application's immutable
JSONL batch and invokes the v0.49 source admission contract. It requires Python
3.10 or later and `psql` on `PATH`; it has no runtime Python dependencies.

Build the wheel from the exact React source revision intended for deployment,
then install that wheel into the producer's virtual environment:

```sh
python3 -m pip wheel --no-deps --wheel-dir dist integrations/pg-mdm
python3 -m venv /opt/pg-react/producer-venv
/opt/pg-react/producer-venv/bin/pip install --no-deps dist/pg_react_bounded_refresh_producer-0.49.0-py3-none-any.whl
```

The installed command is suitable for an application that can write an
immutable batch file and invoke a process with the settings below. Before public
release, build the wheel from the release-candidate source and install that
unpublished wheel in staging; no public 0.49.0 package is needed for this step.
The current local wheel and paired workload runs exercise this contract through
the pg-mdm staging harness, but they use a dirty worktree and do not prove a
separate production application's adoption. Bind the final clean-commit wheel
to CI and staging evidence before publication. Production application adoption
is a post-release rollout gate.

The 2026-11-01 current-source wheel has SHA-256
`879d56a2285d9a4ad9d8c102286b8ab407c4016cf42708b28a25f79c5910243a`; its
installed module SHA-256 matches producer source
`6022c7c51e33cb798fd0fb75a399221358b50e90960b7fc0f48f127757df9d7e`. The
installed CLI passed the focused ARM64 audit, including a live five-admission
commit/refresh and idempotent replay, a PostgreSQL stop/start retry, and a
300-admission run at 59.999 offered and 59.844 completed admissions/minute.
That run committed 1,200 source rows through 60 refreshes. The exact wheel and
observations are retained in
[`v0.49-bounded-producer-installed-wheel-current-local-20261101-r3`](../../tests/integrations/pg-mdm/evidence/v0.49-bounded-producer-installed-wheel-current-local-20261101-r3/).
This is local reference-producer evidence. The exact installed-wheel paired
selected-profile outage run now covers the 1,000-case due burst; deployed
application adoption, final-artifact qualification, 90-day coherent retention,
and release qualification remain open (`release_qualified=false`).

The earlier 2026-11-02 total-input-cap wheel has SHA-256
`8ca9bfbe299ad81c96bc5ba0b96be7a8ea5fa207fbda6ec8c3af761a81541e9c`; its
module matches producer source SHA-256
`055935d936ad7884298ca356b48991205dc74b0a8a568b9f17556530ceadd61a`. The
installed CLI enforces a 19,661,400-byte total JSONL input cap, in addition to
the per-admission limits above. Exact-boundary checks passed on the wheel. The
same wheel passed the local candidate/control paired workload with 300
admissions, 1,000 due cases, and a planned outage: both arms passed 34/34
checks, delivered 58.894/59.193 cases/minute against the 40/minute floor,
stayed below the 120-second outage and 180-second recovery limits, and
remained within the memory, WAL, write, and storage caps. Full measurements are in the
[paired wheel observations](../../tests/integrations/pg-mdm/evidence/v0.49-bounded-producer-total-input-cap-installed-wheel-local-20261102-r1/observations.json).
This remains local reference-producer evidence: the repository has no
deployed application caller, and the `showcase/mdm-stewardship` package is
intentionally read-only. The owner-confirmed negative outcomes live in merged
[pg-mdm PR #19](https://github.com/trickle-labs/pg-mdm/pull/19), whose final
`test` and `e2e` CI run passed; these React workload arms do not exercise those
fixtures. The pair's raw `INPUT_BLOCKED` status remains valid: it records local
candidate evidence, while final-artifact activation, deployed application
adoption, and actual 90-day recovery remain open.

The current-source JSON-replay wheel has producer source SHA-256
`0e623079900017b7b4dbcf24417166be0b50721046dff64566a702d740eab95b` and wheel
SHA-256 `e62f1a59de54d0fa177dcebebdca7b61bd9a0147c05d353886ceb995ca2e8c7e`.
It passed all 18 focused checks, including identical PostgreSQL `json` replay
and rejection of a conflicting same-key replay with SQLSTATE `23505`. Its
300-admission lane offered 59.999862/minute and completed 59.851792/minute,
writing 1,200 rows in 60 separate refreshes. See the [summary](../../tests/integrations/pg-mdm/evidence/v0.49-bounded-producer-current-source-wheel-local-20261102-r5/summary.json)
and [source-bound manifest](../../tests/integrations/pg-mdm/evidence/v0.49-bounded-producer-current-source-wheel-local-20261102-r5/manifest.json).

That same wheel passed the current-source candidate/control planned-outage
pair: 34/34 checks per arm, all 300 admissions completed, all 1,000 due receipts
delivered, and zero future-case receipts. Producer completion rates were
59.548/59.576 admissions per minute; due-receipt p95/max were 95.234/97.121
and 95.313/97.313 seconds. Outages were 110.168/110.237 seconds and recovery
plus backlog drain took 46.456/58.478 seconds. WAL, row-write, memory, and
storage checks passed. The raw entry decisions remain `INPUT_BLOCKED` and
`release_qualified=false` because these local measurements do not close the
application, final-artifact, or 90-day recovery gates. See the [paired summary](../../tests/integrations/pg-mdm/evidence/v0.49-current-source-json-replay-paired-outage-local-20261102-r1/summary.json)
and [artifact manifest](../../tests/integrations/pg-mdm/evidence/v0.49-current-source-json-replay-paired-outage-local-20261102-r1/manifest.json).

After host disk space was freed, the candidate/control workload was rebuilt
from the current worktree and rerun with the current installed wheel. Both
ARM64 arms passed 34 checks with 300 admissions, 1,000 due receipts, and zero
future-case receipts. Producer completion was 59.525/59.555 admissions per
minute; observed case throughput was 59.110/58.944 per minute. Due-receipt
p95/max was 95.259/97.204 and 98.044/100.273 seconds. Outages were
110.241/111.590 seconds and recovery plus backlog drain took 46.972/48.967
seconds. Resource limits passed. This wheel's producer source SHA-256 is
`0e623079900017b7b4dbcf24417166be0b50721046dff64566a702d740eab95b`; wheel
SHA-256 is `0b752e8721531ecd2155e9d813c75f9dab7b2b3b5c4fe923588b998d3d1d258a`.
The [paired summary](../../tests/integrations/pg-mdm/evidence/v0.49-current-source-wheel-paired-outage-local-20261102-r1/summary.json)
and [source-bound manifest](../../tests/integrations/pg-mdm/evidence/v0.49-current-source-wheel-paired-outage-local-20261102-r1/manifest.json)
retain the exact source, image and wheel identities. Both raw decisions remain
`INPUT_BLOCKED` and `release_qualified=false`; deployed application adoption,
final artifacts, production restore/clone activation, and actual 90-day
recovery remain open.

The current-source [retention boundary regression](../../tests/integrations/pg-mdm/evidence/v0.49-history-retention-current-source-arm64-local-20261101-r1/observations.json)
passed all five checks. It verified that deletion is blocked at a simulated
89-day case age when a receipt is 91 days old, then permits pruning and entity
drop at a simulated 91-day case age. The fixture advances timestamps; it does
not demonstrate 90 elapsed days or a coherent backup and matching-binary
restore across that period, so the archival gate remains open.

Each JSONL line is one logical admission: either one source
row object or an object such as `{"rows":[...]}` containing multiple source
rows. Each admission may contain at most four rows and 65,536 UTF-8 payload
bytes, excluding its line ending. Every row must contain all configured source
columns, and the key columns must match a unique or primary key on the source
table. Finite JSON decimal numbers are parsed without binary-float conversion,
including numbers nested in JSON values; `NaN` and `Infinity` are rejected.
The producer commits up to five admissions (20 source rows) in one
transaction, then calls `mdm.refresh(entity_name, full_policy)` through a
separate libpq service.
Both services must connect to the same database. Each service's effective role
needs `EXECUTE` on `pg_catalog.pg_control_system()` so the producer can verify
the PostgreSQL cluster identity before source writes and refresh calls. The
producer pins the refresh service's database name and cluster system identifier
on the first batch; every later batch, retry, source write, and refresh must
match. Changes to either pinned value fail closed. A physical clone can preserve
both values, so this guard does not distinguish it; keep clone activation and
endpoint isolation controls in place. Review the protected service file before
restarting a failed run. The source service also needs temporary-table,
source-table `SELECT`, and `INSERT` privileges; the refresh service must use the
entity execution role. Identical replayed rows are idempotent; a key collision
with different row values fails.

Set `PGSERVICEFILE` to a protected service file, then run:

```sh
/opt/pg-react/producer-venv/bin/pg-react-bounded-refresh-producer \
  --source-service batch_source \
  --refresh-service mdm_refresh \
  --table public.source_records \
  --columns id,name,email,updated_at \
  --key-columns id \
  --entity customer \
  --policy ALLOW \
  --input admissions.jsonl \
  --batch-size 5 \
  --rate-per-minute 60
```

The offered-input clock continues while refresh runs. The runner bounds its
pending queue at 300 admissions; if refresh falls further behind, input pacing
is backpressured. Each invocation validates the complete JSONL input and rejects
more than 300 total admissions or more than 19,661,400 total bytes before
any database calls. The byte cap is 300 times the 65,536-byte payload limit
plus a maximum two-byte line ending. The application still has to pace repeated
invocations to the selected five-minute envelope.
A lost psql connection, client timeout, or retryable `40P01`/
`40001` transaction failure retries the current batch within the same 300-second
window, using a 10-second connection timeout. Transaction backoff is capped at
the remaining window; other SQL errors fail immediately. If the retry window
expires, restart with the same unchanged JSONL file; committed rows are accepted
only when their full values match.
Its output reports offered and completed rates, roles, database, transaction
IDs, and per-batch refresh results. The local `r11` audit passed 300 case
admissions at 59.998747 offered/minute and 59.660099 completed/minute over
301.709 seconds: 1,200 source rows committed in 60 batches of five cases, with
a separate refresh for each batch. It verified exact source, case and review
vectors, with requests, receipts and attempts unchanged. A five-row replay,
telemetry backpressure regression, and live PostgreSQL stop/start retry also
passed; the outage case retried once and completed one refresh. The
[source-hashed audit evidence](../../tests/integrations/pg-mdm/evidence/v0.49-bounded-producer-connection-retry-local-20261031-r11/observations.json)
records producer SHA-256 `da369abd78d1ef43aa4e7475ff8f946a26b48194cf34379b6467891d8cd9a5ee`.
This is local CLI evidence only; it does not prove application deployment,
include the 1,000-case due burst, or qualify the release or 90-day retention.

The current bounded-producer follow-up (`source payload cap r1`) accepts four
source rows per admission and a 65,536-byte UTF-8 payload, excluding the line
ending. It rejects a fifth row or one byte over the payload cap before parsing
or opening either database service. Its real-cluster check also rejected
services connected to separate PostgreSQL instances with the same database name
(`s1_idle`) and different system identifiers before writing a source row or
calling refresh; the source row remained absent and the refresh sentinel stayed
at zero. Replay, backpressure, and stop/start retry checks passed. The run
processed 300 admissions at 59.998171 offered/minute and 59.656194
completed/minute over 301.729 seconds: 1,200 source rows in 60 batches of five.
The [follow-up evidence](../../tests/integrations/pg-mdm/evidence/v0.49-bounded-producer-source-payload-cap-local-20261031-r1/observations.json)
records producer SHA-256
`6313d7671a2539f71611e0280313ed8274878b14b8f0057c18adefc4d0f57d6c`. Release
qualification remains false; this does not qualify production adoption or the
90-day coherent retention horizon.

The historical [paired mixed-workload and outage run](../../tests/integrations/pg-mdm/evidence/v0.49-reference-producer-current-mixed-outage-local-20261031-r1/summary.json)
passed 34 checks on candidate pg-trickle 0.108.4 and control 0.108.3, but used
producer SHA-256
`da369abd78d1ef43aa4e7475ff8f946a26b48194cf34379b6467891d8cd9a5ee`.

The 2026-10-31 focused-audit producer SHA-256 was
`b0fe91a0c4f1a917343c3118d80776d5cba419716db4fef8ade97c52c383b013`. Its
[focused audit](../../tests/integrations/pg-mdm/evidence/v0.49-bounded-producer-current-exact-local-20261031-r3/observations.json)
passed all 14 checks and processed 300 admissions at 59.998 offered and
59.664 completed admissions/minute, committing 1,200 source rows in 60 batches.
The initial mixed-workload attempt [reproduced](../../tests/integrations/pg-mdm/evidence/v0.49-reference-producer-current-mixed-outage-local-20261031-r2/summary.json)
an unsupported `Path.write_text` newline argument in the CSV path; the producer
now uses `Path.open`.

The source-matched [paired mixed-workload and outage run](../../tests/integrations/pg-mdm/evidence/v0.49-reference-producer-current-mixed-outage-local-20261031-r3/summary.json)
passed all 34 checks on candidate pg-trickle 0.108.4 and control 0.108.3 with
that 2026-10-31 producer hash. Both runs offered 300 admissions near 60/minute and
completed above the 40/minute floor. Due-receipt p95/max was 95.202/97.191
seconds on candidate and 95.306/97.306 on control. The 1,000-case PostgreSQL
outages lasted 110.174/110.348 seconds; backlog drain after PostgreSQL became
ready took 59.805/61.245 seconds. Both stayed within the memory, storage, WAL
and row-write limits. The planned outage ended before producer startup; the
producer then overlapped the due backlog. The separate focused audit covers
live stop/start retry. The
[manifest](../../tests/integrations/pg-mdm/evidence/v0.49-reference-producer-current-mixed-outage-local-20261031-r3/manifest.json)
records source and image hashes. Production application adoption and actual
90-day coherent retention remain unqualified; `release_qualified=false`.

The producer SHA-256 used by the earlier selected-profile outage pair is
`97762a8bc138271299486e8f8c48f67f25f13c3bfb38cfb1aa9f86b962861f70`. Its
selected-profile [outage pair](../../docs/v0.49-qualification.md) passed 32/32
local harness checks on candidate and control. The planned outage spanned the
due deadline, then the producer completed 300 admissions above the 40/minute
floor; backlog recovery stayed within the selected envelope. No admissions
were attempted while PostgreSQL was down. This remains harness evidence, not
production-path or release qualification; final-artifact recovery and 90-day
coherent retention remain open.

The 2026-11-01 retry-deadline follow-up caps a retryable transaction backoff to
the remaining per-batch window. Its [focused evidence](../../tests/integrations/pg-mdm/evidence/v0.49-bounded-producer-retry-deadline-current-local-20261101-r1/observations.json)
records one passing helper check: with 0.0625 seconds left in a simulated
0.25-second window, the retry slept only for the remaining time, then stopped
before another source transaction or refresh. The current producer SHA-256 is
`6022c7c51e33cb798fd0fb75a399221358b50e90960b7fc0f48f127757df9d7e`. The helper
mocks psql/database calls; the change has not been rerun through the 300-case
workload and does not qualify production adoption or release.

The subsequent [paired current-producer run](../../tests/integrations/pg-mdm/evidence/v0.49-reference-producer-retry-deadline-paired-outage-local-20261101-r1/summary.json)
used that exact producer hash and the selected profile on candidate pg-trickle
0.108.4 and matched 0.108.3 control images. Both arms passed 34 checks with 300
admissions, 1,000 due cases, and a planned outage spanning the due deadline.
They offered 59.998 admissions/minute, completed 59.555/59.561 admissions per
minute, and drained the backlog within 63.615/63.338 seconds after PostgreSQL
readiness. Resource and due-latency measurements stayed within the profile
limits. This strengthens local workload and recovery evidence; it still does
not show adoption by a deployed application producer, qualify final artifacts,
or prove the 90-day coherent retention horizon. `release_qualified=false`.

The current ARM64 [bounded-producer audit](../../tests/integrations/pg-mdm/evidence/v0.49-bounded-producer-retry-deadline-current-local-20261101-r6/observations.json)
then passed all 16 checks with the same producer hash. It exercised admission
limits, cluster identity, ambiguous-commit and transaction retries, live
PostgreSQL restart, exact source replay, and a 300-admission run on a 10-CPU
ARM64 host. That run committed 1,200 source rows through 60 refreshes at
59.998 offered and 59.846 completed admissions/minute, with requests, receipts
and attempts unchanged. The evidence binds producer SHA-256
`6022c7c51e33cb798fd0fb75a399221358b50e90960b7fc0f48f127757df9d7e`, profile
SHA-256 `2bb14739e1d967dfa126add232b2119527d2e6637b1c7ff886ee77816682e852`,
and image `sha256:294f92b904d6461c575a36e33881f2c34ebfe5900e5a1fb9d4706e321e08b727`.
This remains reference-producer qualification; deployed application adoption,
final-artifact qualification and 90-day recovery remain open.

The exact installed-wheel [paired selected-profile outage run](../../tests/integrations/pg-mdm/evidence/v0.49-installed-wheel-paired-outage-local-20261101-r1/summary.json)
used wheel SHA-256
`879d56a2285d9a4ad9d8c102286b8ab407c4016cf42708b28a25f79c5910243a` and the
approved profile on matched candidate/control images. Both arms passed 34/34
checks with 300 admissions at about 60/minute offered and 1,000 simultaneously
due cases; observed case throughput was 59.182/59.216 per minute against the
40/minute floor. Due-receipt p95/max was 95.161/97.126 seconds on candidate and
96.890/98.386 on control. The planned PostgreSQL outages lasted 110.137/110.147
seconds, with backlog drain in 63.634/66.047 seconds after PostgreSQL was ready.
Memory, storage, WAL, and row writes remained within the selected limits. The
[manifest](../../tests/integrations/pg-mdm/evidence/v0.49-installed-wheel-paired-outage-local-20261101-r1/manifest.json)
records wheel, source, profile, image, and run hashes. The raw observations
remain `INPUT_BLOCKED` and `release_qualified=false`; deployed application
adoption, final-artifact activation, and actual 90-day coherent backup/restore
remain unproven.
