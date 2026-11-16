# SQL API reference

[Reference](reference/index.md) · [Authoring guide](authoring.md)

This reference describes the ordinary public SQL interface in the qualified **pg-react 0.46.0 core profile**. It is organized by the work you do: construct a declaration, inspect it, deploy it, and observe its results. Specialized advanced and administrative interfaces remain installed where documented; the [advanced learning guide](explanation/advanced-use.md) and the [machine-readable API inventory](api-inventory.json) help you choose them deliberately.

## Ordinary

The main constructors return `pgreact_api.declaration`, a typed value that can be passed between ordinary operations. Constructor calls do not deploy an object. Public names are stable application identities; callers do not need private UUIDs to validate, preview, deploy, inspect, or explain an ordinary target.

### `pgreact.rule`

```sql
pgreact.rule(
    name text,
    condition regclass,
    semantic_key name,
    kind text DEFAULT 'CONSTRAINT',
    on_activate regprocedure DEFAULT NULL,
    on_deactivate regprocedure DEFAULT NULL,
    on_change regprocedure DEFAULT NULL,
    bootstrap_policy text DEFAULT 'SEED_CURRENT',
    change_columns name[] DEFAULT NULL,
    salience integer DEFAULT 0,
    agenda_group text DEFAULT 'default',
    conflict_key_columns name[] DEFAULT NULL,
    max_attempts integer DEFAULT 1,
    initial_backoff_seconds integer DEFAULT 1,
    backoff_multiplier numeric DEFAULT 2,
    max_backoff_seconds integer DEFAULT 60
) RETURNS pgreact_api.declaration
```

| Parameter group | Contract |
| --- | --- |
| `name`, `condition`, `semantic_key` | Stable rule name, schema-qualified condition relation, and one non-null unique `bigint` key for the ordinary rule path. |
| `kind` | `CONSTRAINT` records matches without consequences; `COMMAND` permits executable consequences. |
| `on_activate`, `on_deactivate` | Exact function identity accepting `pgreact.activation_context` and the condition row type, returning `void`. |
| `on_change` | Exact function identity accepting the context, old condition row, and new condition row, returning `void`. |
| `bootstrap_policy` | `SEED_CURRENT` seeds existing match state without activation work; `REQUIRE_EMPTY` requires an empty initial condition. |
| `change_columns` | `NULL` watches all projected non-key columns; an empty array watches none; a subset must name projected non-key columns. |
| `conflict_key_columns` | Projected columns used to express conflict grouping; subject to source-view validation. |
| Retry fields | Attempt limit and bounded exponential backoff configuration; inspect validation findings for invalid values. |

The signature's `max_attempts = 1` means a consequence does not automatically gain multiple attempts just because retries are supported. Configure the retry policy you intend, and make the effect idempotent. Separate advanced typed-key APIs support broader shapes; that does not change this constructor's ordinary codec or comparison boundary.

### `pgreact.decision`

```sql
pgreact.decision(
    name text,
    candidate_relation regclass,
    subject_key name,
    candidate_key name,
    priority name,
    results name[],
    valid_from timestamptz DEFAULT clock_timestamp(),
    valid_to timestamptz DEFAULT NULL,
    max_candidates integer DEFAULT 1000
) RETURNS pgreact_api.declaration
```

The declaration kind is `decision_program`. The lowest numeric priority wins; tied best candidates produce `AMBIGUOUS`. Subject and candidate identities must be valid for the decision boundary, candidate pairs must be unique, and evaluated candidates must fit the configured bound. Preserve an explicit `valid_from` when reconstructing a declaration for review, because a changing default timestamp changes its identity.

### `pgreact.policy_set`

The basic constructor groups rule and decision members with an applicability relation:

```sql
pgreact.policy_set(
    name text,
    version text,
    members pgreact_api.declaration[],
    applicability regclass,
    subject_keys name[],
    valid_from timestamptz DEFAULT clock_timestamp(),
    valid_to timestamptz DEFAULT NULL,
    evidence_limit integer DEFAULT 100
) RETURNS pgreact_api.declaration
```

The package overload also includes support declarations and explicit dependencies:

```sql
pgreact.policy_set(
    name text,
    version text,
    members pgreact_api.declaration[],
    applicability regclass,
    subject_keys name[],
    support pgreact_api.declaration[],
    dependencies jsonb DEFAULT '[]',
    valid_from timestamptz DEFAULT clock_timestamp(),
    valid_to timestamptz DEFAULT NULL,
    evidence_limit integer DEFAULT 100
) RETURNS pgreact_api.declaration
```

Members are rule or decision declarations. Package support accepts shared-condition and parameter-family declarations; dependency objects identify their `from` and `on` endpoints by typed public identity. Policy-set version identity is immutable. Validation checks membership, applicability, dependency endpoints and cycles, declaration size, and evidence bounds before deployment.

## Validate, preview, deploy, and remove

Unless noted otherwise, these operations return `jsonb` envelopes. Their findings contain `code`, `severity`, `blocking`, `target`, `field`, `message`, `hint`, and `details`. Treat the operation state and findings as part of the result: successful SQL execution alone does not mean that a proposal was accepted.

| Function | Arguments | Result and purpose |
| --- | --- | --- |
| `pgreact.validate` | `declaration pgreact_api.declaration` | `jsonb`; normalize and validate without deployment. |
| `pgreact.preview` | `declaration`, `options jsonb DEFAULT '{}'` | `jsonb`; inspect the planned operation and blocking conditions. |
| `pgreact.review_token` | `preview_result jsonb` | `text`; opaque token from a successful recognized preview. Maximum 4096 bytes. |
| `pgreact.deploy` | `declaration`, `review_token text`, `preconditions jsonb DEFAULT '{}'` | `jsonb`; deploy the exact reviewed plan after rechecking current state and authorization. |
| `pgreact.deploy` | `declaration`, `preconditions jsonb DEFAULT '{}'` | `jsonb`; supported JSON-preconditions overload. |
| `pgreact.remove` | `name text`, `preconditions jsonb DEFAULT '{}'` | `jsonb`; remove the uniquely named ordinary deployment subject to its checks. |
| `pgreact.export` | `name text`, `kind text DEFAULT NULL`, `version text DEFAULT NULL` | `jsonb`; export a declaration document. |
| `pgreact.import` | `document jsonb`, `preconditions jsonb DEFAULT '{}'` | `jsonb`; import through the public declaration workflow. |

A review token is evidence of a reviewed plan, not a password or authorization grant. Deployment still checks ownership, source identity, current declarations, work, and barriers. For standalone rule and decision previews, operation intent is `ADD`, `KEEP`, or `REPLACE`; a command replacement with eligible old work requires `old_work` to be `DRAIN_OLD` or `CANCEL_OLD`. A changed policy set uses its own new immutable version. See [Changing policies safely](changing-policies.md) for the full procedure.

## Inspect and coordinate

| Function | Arguments | Purpose |
| --- | --- | --- |
| `pgreact.status` | `name text`, `options jsonb DEFAULT '{}'` | Inspect the uniquely named target. |
| `pgreact.explain` | `name text`, `subject jsonb DEFAULT NULL`, `options jsonb DEFAULT '{}'` | Explain a target or business subject. |
| `pgreact.doctor` | No arguments | Diagnose the environment and runtime. |
| `pgreact.doctor` | `name text`, `options jsonb DEFAULT '{}'` | Diagnose one deployed target. |
| `pgreact.run` | `sampled_time timestamptz DEFAULT clock_timestamp()` | Perform explicit coordination; may create durable work. It is not a wait for every consequence to complete. |
| `pgreact_api.managed_status` | No arguments | Inspect managed-worker configuration, process state, heartbeat, and detail. |

These calls return `jsonb`. Name-based inspection fails closed for missing, ambiguous, changed, or unauthorized identities. `pgreact.run()` is an intentional runtime operation rather than a read-only health check; use doctor, status, health, and public views when collecting a baseline before upgrade or recovery.

## Current public views

Select explicit columns in application queries so future additive columns do not change your result shape. The following are the ordinary inspection views used throughout these guides; the installed catalog remains the exact source for types and additional advanced projections.

| View | Fields used for ordinary inspection | Question answered |
| --- | --- | --- |
| `pgreact.rules` | `name`, `kind`, `version`, `state`, `source_view_name`, `key_column`, `declaration_digest`, `created_at` | What rule is deployed? |
| `pgreact.matches` | `name`, `semantic_key`, `bindings`, `active`, `generation`, `revision`, `activation_id` | What currently matches, and in which lifecycle? |
| `pgreact.decisions` | `name`, `state`, `version_no`, `candidate_relation`, `subject_key_column`, `candidate_key_column`, `priority_column` | What decision is deployed? |
| `pgreact.policy_sets` | `name`, `set_name`, `owner`, `created_at` | What policy sets exist? |
| `pgreact.work` | `kind`, `name`, `version`, `work_id`, `state`, `claimable`, `updated_at` | What durable work exists? |
| `pgreact.attempts` | `execution_id`, `episode_id`, `attempt_no`, `status`, `error_code`, `error_message`, `event_kind`, `name`, `started_at`, `finished_at` | What happened during execution? |
| `pgreact.health` | `code`, `severity`, `target`, `field`, `message`, `hint`, `details`, `blocking` | What needs attention? |

`pgreact.work.claimable` is advisory because another transaction may claim the work after your read. Its `updated_at` records actual agenda activity for new transitions; it may be `NULL` for pre-0.43.3 history whose transition time was never recorded. Do not infer creation time from that field. Decision results are available through the additional public `pgreact.decision_winners` view, as shown in the [order-review tutorial](order-review-tutorial.md).

## Compare current and proposed behavior

```sql
pgreact_api.target(
    kind text,
    name text,
    version text DEFAULT NULL
) RETURNS pgreact_api.target

pgreact.compare(
    proposed pgreact_api.declaration,
    deployed pgreact_api.target,
    options jsonb DEFAULT '{}'
) RETURNS jsonb
```

Comparison target kinds are `rule`, `decision_program`, and `policy_set`. Proposal and target must have the same kind and name. For non-policy targets the supported target version is `NULL` or `'1'`; policy sets can name their deployed immutable version. Rule comparison requires exactly one non-null unique `bigint` key. Evaluated sources require caller access, and RLS-protected sources are rejected.

| Option or result | Meaning |
| --- | --- |
| `evidence_limit` | Default `100`, minimum `1`, maximum `1000`. Bounds evidence returned. |
| `sampled_time` | Optional timestamp string that must match the authoritative frontier accepted by the comparison. |
| `why_changed` | Optional `true` for supported bounded explanation of changed outcomes. |
| `current`, `proposed` | Evaluated outcomes for each declaration over the same facts. |
| `delta` | `ADDED`, `REMOVED`, `CHANGED`, or `UNCHANGED` outcomes. |
| `lifecycle`, `work` | Would-be lifecycle and work evidence; no durable execution is created. |
| `state = 'ready'` | Complete within the operation's supported model and bounds. |
| `state = 'partial'` | Bounded evidence is incomplete; do not treat displayed arrays or counts as an exhaustive answer. |

Use `pgreact.compare_results(proposed, deployed, options)` for relational rows with `result_set`, `kind`, `name`, `subject_key`, `result_key`, `state`, `delta`, `current_value`, `proposed_value`, `evidence`, `complete`, `sampled_time`, `source_frontier`, and `declaration_digest`. It exposes the same bounded evidence as the JSON result; it is not pagination, and there is no continuation token.

Comparison has no deployment, lifecycle mutation, work creation, attempt, consequence, or delivery effect. Its selected-state checksum is narrower than a database checksum. Read [Changing policies safely](changing-policies.md) for the exact boundary and interpretation of cost fields. Hypothetical changes, replay, and backtesting use additional overloads and finite caller-supplied inputs described in [Advanced use](explanation/advanced-use.md).

## Advanced and administrative

| Task | Public entry point |
| --- | --- |
| Pause or resume a rule | `pgreact.pause_rule(rule_name text)`, `pgreact.resume_rule(rule_name text)` |
| Reconcile a standalone rule | `pgreact.reconcile_rule(rule_name text, mode text)` |
| Recover expired leases across authorized active, paused, and draining versions | `pgreact.sweep_expired_leases(rule_name text)`, returning `bigint` |
| Requeue terminal rule work | `pgreact.requeue_episode(rule_name text, work_id text)` or `pgreact.requeue_episode(episode_id bigint)`; the ID comes from `pgreact.work`, not the business semantic key. |
| Set application role mapping | `pgreact_api.configure_roles(author, operator, worker, reader, advanced_reader)` |
| Prepare an explicit recovery barrier | `pgreact.prepare_recovery()` |
| Inspect missing or causal results | `pgreact.explain` with documented `why_not` or `causal_path` options |

Use these operations with the [operations](operations.md), [security](security.md), and [recovery](backup-restore.md) procedures. There is no universal retry, pause, or resume function for every declaration family. A rule-specific operation does not establish the correct recovery procedure for a policy package, derivation program, or temporal declaration.

Installed advanced families include derived facts and programs, recursion and stratification, temporal and effective-dated policy, shared conditions, parameter families, simulation, provenance, evidence snapshots, and decision analysis. Their function-level reference records remain linked through [History](history.md). The ordinary constructors above are the recommended starting point; earlier compatibility wrappers remain available where their own contract applies. `pgreact_internal` and `pgreact_runtime` are implementation schemas and are not application APIs.

## Verify an installed signature

In `psql`, inspect a function or view before adapting an example to a different release:

```text
\df+ pgreact.rule
\df+ pgreact.deploy
\df+ pgreact_api.configure_roles
\d+ pgreact.work
```

The [machine-readable inventory](api-inventory.json), [release identity reference](reference/release-identity.md), and [packaged 0.46.0 SQL](../sql/pg_react--0.46.0.sql) provide the corresponding repository records.
