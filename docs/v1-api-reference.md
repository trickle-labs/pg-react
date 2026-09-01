# v1 API reference

This is the canonical human reference for public surfaces classified from the
installed `1.0.0-rc.1` (and baseline `0.31.0`) SQL. It is intentionally non-exhaustive: exact
classification of every installed public function, including `export`,
`import`, legacy worker/recovery routines, and some advanced entries, remains
open. The M33 machine inventories are not regenerated here.

## Choose an API by task

| Role or use case | Start with |
| --- | --- |
| Author a rule | `pgreact.rule`, then `validate`, `preview`, `deploy` |
| Author a decision | `pgreact.decision`, then `validate`, `preview`, `deploy` |
| Group rules and decisions | `pgreact.policy_set`, then `validate`, `preview`, `deploy` |
| Compare before replacing | `pgreact.compare` or `pgreact.compare_results` |
| Run or inspect production | `pgreact.run`, `status`, public views |
| Explain behavior | `pgreact.explain` |
| Check the installation/runtime | `pgreact.doctor`, `pgreact.health` |
| Remove a deployed object | `pgreact.remove` |
| Use advanced capabilities | Use the installed advanced family explicitly; do not substitute a legacy ordinary wrapper |
| Operate workers or recovery | Use documented administrative routines only |

## Ordinary declaration constructors

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

Builds an API-version-1 rule declaration. `CONSTRAINT` is the default.
Consequences belong to a `COMMAND` rule; validation rejects consequences on a
constraint rule. Comparison of a rule is narrower than general runtime key
support: it requires one non-null, unique `bigint` semantic key.

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

Builds a `decision_program` declaration. The lowest priority wins; equal best
priorities produce ambiguity rather than an arbitrary winner.

### `pgreact.policy_set`

For complete package declarations, use the additional `support` and
`dependencies` parameters described in [the M53 package reference](m53-api-reference.md).

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

Builds a policy-set declaration. Installed ordinary members are typed
`pgreact.rule` or `pgreact.decision` declarations.

## Ordinary verbs

All ordinary verbs return structured `jsonb` envelopes. Findings use `code`,
`severity`, `blocking`, `target`, `field`, `message`, `hint`, and `details`.

| Function | Signature | Use |
| --- | --- | --- |
| `pgreact.validate` | `(declaration pgreact_api.declaration) RETURNS jsonb` | Validate and normalize without deployment. |
| `pgreact.preview` | `(declaration, options jsonb DEFAULT '{}') RETURNS jsonb` | Review validation, normalized evidence, and create/replacement intent. |
| `pgreact.deploy` | `(declaration, preconditions jsonb DEFAULT '{}') RETURNS jsonb` | Deploy after satisfying preview/precondition checks. |
| `pgreact.remove` | `(name text, preconditions jsonb DEFAULT '{}') RETURNS jsonb` | Remove the uniquely named deployed ordinary object. |
| `pgreact.run` | `(sampled_time timestamptz DEFAULT clock_timestamp()) RETURNS jsonb` | Run one coordinated production cycle; this may create or execute work. |
| `pgreact.status` | `(name text, options jsonb DEFAULT '{}') RETURNS jsonb` | Inspect one uniquely named deployed object. |
| `pgreact.explain` | `(name text, subject jsonb DEFAULT NULL, options jsonb DEFAULT '{}') RETURNS jsonb` | Explain an object or subject; add `{"why_not": {...}}` for a bounded missing-result answer. See [Explain an Outcome](explaining-outcomes.md). |
| `pgreact.doctor` | `() RETURNS jsonb` | Diagnose the installation and managed runtime. |
| `pgreact.doctor` | `(name text, options jsonb DEFAULT '{}') RETURNS jsonb` | Diagnose one deployed object. |

`status`, `explain`, `doctor(name)`, and `remove(name)` resolve a stable name
to one deployed ordinary object and reject ambiguous names.

## Current public views

| View | Current installed columns |
| --- | --- |
| `pgreact.rules` | `rule_id`, `rule_name`, `rule_version_id`, `owner`, `source_view_name`, `key_column`, `consequence_identity`, `bootstrap_policy`, `state`, `created_at`, `name`, `kind`, `version`, `declaration_digest` |
| `pgreact.matches` | `name`, `rule_name`, `rule_version_id`, `activation_id`, `semantic_key`, `bindings`, `active`, `generation`, `first_seen_at`, `last_seen_at`, `deactivated_at`, `revision` |
| `pgreact.decisions` | `program_id`, `name`, `program_name`, `owner`, `state`, `version_id`, `version_no`, `candidate_relation`, `subject_key_column`, `candidate_key_column`, `priority_column`, `result_columns`, `result_types`, `max_candidates`, `valid_from`, `valid_to`, `source_signature`, `source_definition_digest`, `version_state`, `deployed_at` |
| `pgreact.policy_sets` | `policy_set_id`, `set_name`, `owner`, `created_at`, `name` |
| `pgreact.work` | `kind`, `name`, `version`, `work_id`, `state`, `claimable`, `updated_at` |
| `pgreact.attempts` | `execution_id`, `episode_id`, `attempt_no`, `worker_id`, `started_at`, `finished_at`, `status`, `error_message`, `error_code`, `event_kind`, `name` |
| `pgreact.health` | `code`, `severity`, `target`, `field`, `message`, `hint`, `details`, `blocking` |

Additional public views support advanced and administrative capabilities. They
are not all ordinary v1 views.

## Comparison

### `pgreact_api.target`

```sql
pgreact_api.target(
    kind text,
    name text,
    version text DEFAULT NULL
) RETURNS pgreact_api.target
```

Comparison supports target kinds `rule`, `decision_program`, and `policy_set`.
The proposed declaration must have the same kind and name. Non-policy target
versions are null or `'1'`; policy sets may name a deployed policy-set
version.

### `pgreact.compare`

```sql
pgreact.compare(
    proposed pgreact_api.declaration,
    deployed pgreact_api.target,
    options jsonb DEFAULT '{}'
) RETURNS jsonb
```

Recognized comparison options:

| Option | Installed behavior |
| --- | --- |
| `evidence_limit` | Default `100`; minimum `1`; maximum `1000`. |
| `sampled_time` | RFC3339 timestamp string; must equal the current authoritative frontier. |

A ready or partial comparison envelope contains `contract_version`,
`operation`, `target`, `state`, `summary`, `evidence`, `cost`, `findings`,
`current`, `proposed`, `delta`, `lifecycle`, `work`, and `truncated`.
Validation failures return an `attention` envelope with findings and empty
result arrays rather than comparison evidence.

`delta[].change` is `ADDED`, `REMOVED`, `CHANGED`, or `UNCHANGED`.
`lifecycle` contains changed subjects. `work` contains would-be work only; it
is not durable work and no consequence is executed.

Complete output has `state = 'ready'`, `evidence.complete = true`,
`summary.counts_exact = true`, and `truncated = false`. Bounded output has
`state = 'partial'`, incomplete counts, and
`M34_COMPARISON_INCOMPLETE`. There is no continuation token.

Rule comparison requires a non-null, unique `bigint` key. Decision comparison
requires non-null subject, candidate, and priority fields, unique
subject/candidate pairs, and compliance with `max_candidates`. RLS-enabled
sources and callers lacking target/source access are rejected rather than
redacted.

The selected before/after checksum covers the frontier, declarations, rule
versions, activation state, decision subject state, public work projection,
and policy-set versions. It is not a checksum of source tables, history,
attempts, or deliveries.

Measured/populated cost evidence includes rows considered, affected subjects
when complete, would-be work, and elapsed time. Fan-out, reevaluation, cascade,
memory, and temporary-storage fields are not all measured in `0.31.0`.

### `pgreact.compare_results`

```sql
pgreact.compare_results(
    proposed pgreact_api.declaration,
    deployed pgreact_api.target,
    options jsonb DEFAULT '{}'
) RETURNS TABLE (
    result_set text,
    kind text,
    name text,
    subject_key text,
    result_key text,
    state text,
    delta text,
    current_value jsonb,
    proposed_value jsonb,
    evidence jsonb,
    complete boolean,
    sampled_time timestamptz,
    source_frontier timestamptz,
    declaration_digest text
)
```

Returns the same bounded `current`, `proposed`, `delta`, `lifecycle`, and
`work` rows as `compare()`, in relational form for filtering and joins.

## Supported advanced families

The installed SQL includes public advanced families for:

- derived relations and derivation programs, including recursion and
  stratification diagnostics;
- temporal/deadline and window processing;
- shared conditions;
- retention and provenance inspection;
- effective-dated policies and parameter families;
- decision analysis;
- policy-set applicability and scope support;
- outbox binding and advanced explanation.

Representative installed views include `pgreact.derived_relations`,
`pgreact.derived_facts`, `pgreact.derivation_programs`,
`pgreact.window_evidence`, `pgreact.effective_policies`,
`pgreact.parameter_families`, `pgreact.decision_winners`,
`pgreact.decision_analyses`, and the `pgreact.policy_set_*` scope views.

These are supported advanced capabilities, not missing future functionality
and not the default ordinary workflow. Their complete function-by-function
classification is pending exact RC inventory work.

## Compatibility and administrative surfaces

Installed `pgreact_api` facades and earlier `pgreact.*_rule`,
claim/execute/recovery, worker-protocol, retention, and repair routines remain
present. Use them only where current compatibility, worker, recovery, or
advanced documentation calls for them. New ordinary application code should
prefer the constructors and verbs above.

`pgreact.export` and `pgreact.import` are installed but are not classified as
ordinary v1 calls by this reference. Their exact compatibility and support
status remains part of the exhaustive-classification qualification task.

`pgreact_internal` and `pgreact_runtime` are implementation schemas, not
application APIs, even where historical grants or generated dispatchers make
an object callable.

See [Compatibility](v1-compatibility.md),
[Deprecations](v1-deprecations.md), [Limits](v1-limits.md), and
[Troubleshooting](v1-troubleshooting.md).
