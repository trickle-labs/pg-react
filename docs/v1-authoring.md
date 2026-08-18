# Authoring Rules and Policies

The ordinary v1 workflow is:

```text
construct declaration -> validate -> preview -> deploy -> inspect
```

Use the `pgreact` constructors and verbs for new ordinary code. They accept
stable names and typed PostgreSQL identities and return declarations or
`jsonb` operation results.

`validate`, `preview`, `deploy`, `remove`, `run`, `status`, `explain`,
`doctor`, and `compare` return `jsonb`. `compare_results` returns relational
rows.

## Rule declarations

```sql
SELECT pgreact.rule(
    name         => 'manual-review-required',
    condition    => 'rule_def.high_value_risky_order'::regclass,
    semantic_key => 'order_id'::name
);
```

`pgreact.rule()` returns `pgreact_api.declaration`. Its fields are:

- `name`, `condition`, and `semantic_key`;
- `kind`, defaulting to `CONSTRAINT`;
- `on_activate`, `on_deactivate`, and `on_change`;
- `bootstrap_policy`, plus signature-level `change_columns`;
- `salience`, `agenda_group`, plus signature-level
  `conflict_key_columns`;
- retry settings: `max_attempts`, `initial_backoff_seconds`,
  `backoff_multiplier`, and `max_backoff_seconds`.

Use a schema-qualified condition relation. Its semantic key must be non-null
and unique in the result.

### Constraint versus command

A constraint rule has no consequences:

```sql
SELECT pgreact.rule(
    name         => 'manual-review-required',
    condition    => 'rule_def.high_value_risky_order'::regclass,
    semantic_key => 'order_id'::name,
    kind         => 'CONSTRAINT'
);
```

A rule with any consequence must explicitly be a command:

```sql
SELECT pgreact.rule(
    name         => 'manual-review-required',
    condition    => 'rule_def.high_value_risky_order'::regclass,
    semantic_key => 'order_id'::name,
    kind         => 'COMMAND',
    on_activate  =>
      'rule_action.open_review(pgreact.activation_context,rule_def.high_value_risky_order)'::regprocedure
);
```

The installed validation rejects consequences on `CONSTRAINT` rules.

## Typed consequences

Activation and deactivation:

```text
(pgreact.activation_context, condition_row) RETURNS void
```

Change:

```text
(pgreact.activation_context, old_condition_row, new_condition_row) RETURNS void
```

The function and condition ownership requirements are enforced during
validation/deployment. A database consequence may be retried. Use
`context.idempotency_key` or the activation/generation/revision identity to
make repeated execution safe.

Do not make irreversible network calls from a typed consequence. Use a
transactional outbox and accept at-least-once external delivery.

## Semantic keys

The ordinary constructor names one semantic-key column. The ordinary
`0.31.0` rule path and comparison fixtures are qualified with a non-null,
unique `bigint`.

Separate installed advanced typed-key authoring accepts one to four ordered
components of `bigint`, `uuid`, or `text`; text requires deterministic `C`
collation. That advanced surface has different constructors and classification.
It does not widen rule comparison: `pgreact.compare()` accepts rule proposals
with exactly one `bigint` key.

## Activation, change, and deactivation

For a stable key:

- entering the condition creates an activation generation;
- watched-column changes increment the revision in that generation;
- leaving the condition deactivates it;
- returning later starts the next generation.

If no watched-column subset is configured, all projected non-key columns are
watched. Installed `0.31.0` exposes `change_columns` and
`conflict_key_columns` in the ordinary constructor signature, but the generic
declaration validator/adapter does not currently accept and pass through
non-null values for those fields. Leave them `NULL` in ordinary declarations.
Specialized compatibility surfaces retain watched-column behavior; the
names-first declaration-facade gap requires qualification before it can be
recommended here.

`SEED_CURRENT` is the default bootstrap policy. Existing matches are seeded as
current state without being treated as newly entered command work.

## Validate and preview

```sql
WITH declaration AS (
    SELECT pgreact.rule(
        name         => 'manual-review-required',
        condition    => 'rule_def.high_value_risky_order'::regclass,
        semantic_key => 'order_id'::name,
        kind         => 'COMMAND',
        on_activate  =>
          'rule_action.open_review(pgreact.activation_context,rule_def.high_value_risky_order)'::regprocedure
    ) AS value
)
SELECT pgreact.validate(value), pgreact.preview(value)
FROM declaration;
```

Both operations return `jsonb` and are read-only. Validation reports structured
findings. Preview adds a digest, create/replacement intent, current state, and
the current declaration digest where one exists.

## Deploy

Use the preview digest so a changed declaration or source definition cannot be
silently deployed as the reviewed plan:

```sql
WITH declaration AS (
    SELECT pgreact.rule(
        name         => 'manual-review-required',
        condition    => 'rule_def.high_value_risky_order'::regclass,
        semantic_key => 'order_id'::name,
        kind         => 'COMMAND',
        on_activate  =>
          'rule_action.open_review(pgreact.activation_context,rule_def.high_value_risky_order)'::regprocedure
    ) AS value
),
preview AS (
    SELECT value, pgreact.preview(value) AS result
    FROM declaration
)
SELECT pgreact.deploy(
    value,
    jsonb_build_object(
        'preview_digest', result #>> '{summary,preview_digest}'
    )
)
FROM preview;
```

`pgreact.deploy()` returns `jsonb`. Treat deployed runtime versions as
immutable. To change a stable target, build a proposal, compare it, preview it
again, and use the qualified target-specific replacement procedure. Do not
edit a condition, consequence, or private catalog underneath an active
deployment.

See [Changing Policies Safely](changing-policies.md) for the review workflow
and [Operations](v1-operations.md) for qualified cutover and old-work policy.

The installed ordinary facade exposes create/replace preconditions and proves
stale replacement rejection. The repository does not yet prove one successful
names-first `pgreact.deploy()` replacement for an already deployed ordinary
rule or decision. This guide therefore does not invent that call. Policy sets
use a new immutable version; rule/decision cutover must follow the qualified
operations path until the facade gap is resolved.

## Decision declarations

A decision relation contains candidate rows:

```sql
SELECT pgreact.decision(
    name               => 'manual-review-route',
    candidate_relation => 'rule_def.review_candidates'::regclass,
    subject_key        => 'order_id'::name,
    candidate_key      => 'reviewer_id'::name,
    priority           => 'priority'::name,
    results            => ARRAY['queue_name']::name[],
    max_candidates     => 1000
);
```

The lowest numeric priority wins. Equal best priorities are `AMBIGUOUS`; a
subject with no candidates is `NO_CANDIDATE`. `valid_from` defaults to the
current time, and `valid_to` defaults to no end.

Use the same `validate`, `preview`, and `deploy` verbs. The constructor returns
a declaration whose kind is `decision_program`.

## Policy-set declarations

A policy set groups typed rule/decision declarations and a relational
applicability source:

```sql
WITH review_rule AS (
    SELECT pgreact.rule(
        name         => 'manual-review-required',
        condition    => 'rule_def.high_value_risky_order'::regclass,
        semantic_key => 'order_id'::name
    ) AS value
)
SELECT pgreact.policy_set(
    name           => 'order-review-policy',
    version        => '1',
    members        => ARRAY[value]::pgreact_api.declaration[],
    applicability  => 'rule_def.reviewable_orders'::regclass,
    subject_keys   => ARRAY['order_id']::name[],
    evidence_limit => 100
)
FROM review_rule;
```

Members must be rule or decision declarations. Policy-set version identity is
immutable: a changed declaration uses a new version. Applicability keys may be
typed and composite at their installed policy-set boundary.

## Remove and inspect

Ordinary operations use names:

```sql
SELECT pgreact.status('manual-review-required');
SELECT pgreact.explain('manual-review-required');
SELECT pgreact.remove('manual-review-required');
```

These return `jsonb`. Current relational projections include:

```text
pgreact.rules
pgreact.matches
pgreact.decisions
pgreact.policy_sets
pgreact.work
pgreact.attempts
pgreact.health
```

## Advanced supported declaration surfaces

The installed extension also exposes specialized public authoring for derived
relations/programs, positive recursive programs, stratified negation and
aggregation, shared conditions, temporal policies, effective-dated policies,
parameter families, deadline rules, provenance, and decision analysis.

These are supported advanced capabilities, not future placeholders and not
ordinary `pgreact.deploy()` kinds unless their adapter says so. Generic
deployment accepts `rule`, `decision_program`, and `policy_set`; use the
documented specialized API for other kinds. See
[API Reference](v1-api-reference.md) and
[Compatibility](v1-compatibility.md).

## Compatibility APIs

Older functions such as `pgreact.create_rule()`,
`pgreact.preview_rule()`, and `pgreact.validate_rule()` remain installed for
compatibility or specialized workflows. Do not choose them for new ordinary
code. They expose UUID-driven and generation-specific paths that the
declaration constructors and ordinary verbs avoid.
