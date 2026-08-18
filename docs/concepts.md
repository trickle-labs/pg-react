# Concepts

pg-react adds policy lifecycle and durable work to PostgreSQL without creating
a second fact store.

```text
authoritative facts -> condition relations -> current results
                                      |
                                      v
                         lifecycle, decisions, work
```

## Ordinary concepts

### Authoritative PostgreSQL facts

Application tables and views are authoritative. pg-react observes their
committed state; it does not replace them with an in-memory working memory.

### Condition relations

A rule condition is an ordinary PostgreSQL relation or view describing what is
true now. pg_trickle maintains eligible conditions through the coordinated
refresh boundary. A row in the condition is a current match, not an event by
itself.

### Declarations

A declaration is a typed `pgreact_api.declaration` returned by constructors
such as:

- `pgreact.rule()`
- `pgreact.decision()`
- `pgreact.policy_set()`

Declarations can be validated and previewed without deployment. Deployment
installs the named behavior and returns a `jsonb` result envelope.

### Semantic identity

A semantic key identifies the logical subject of a match. Stable identity lets
pg-react distinguish a new match from an update to an existing match and from
the return of a previously inactive match.

Key support is surface-specific:

- the ordinary `pgreact.rule()` constructor names one key column;
- installed advanced typed-key authoring supports one to four `bigint`, `uuid`,
  or `text` components, with deterministic `C` collation for text;
- rule comparison supports exactly one `bigint` key.

Do not infer the limits of one surface from another.

### Current matches

`pgreact.matches` exposes current rule matches and their public lifecycle
state. The condition relation remains the source truth; match state records how
pg-react understands that truth for the deployed rule.

### Activation lifecycle

For one semantic key:

- **activation:** the key enters the condition;
- **change:** watched values change while the key remains active;
- **deactivation:** the key leaves the condition;
- **reactivation:** the same key later enters again.

A **generation** increments when an inactive key becomes active again. A
**revision** starts at zero for a generation and increments when watched values
change. Unwatched value changes update current bindings without creating a
change event.

All projected non-key columns are watched by default. `change_columns` can
narrow that set.

### Constraint and command rules

`pgreact.rule()` defaults to `CONSTRAINT`.

- A **constraint** records current truth and has no consequences.
- A **command** may bind typed activation, change, and deactivation
  consequences and therefore can create durable work.

Consequences are not allowed on a constraint declaration.

### Work and attempts

Lifecycle or decision state can request durable work. Work is claimable,
leased, retried, completed, failed, or withdrawn according to the installed
runtime. Attempts are execution records for that work. Current public
projections are `pgreact.work` and `pgreact.attempts`.

### Transaction boundaries

Source changes commit as normal PostgreSQL transactions. Managed evaluation
and work execution happen after that source state is committed. Database
consequences and pg-react state changes use PostgreSQL transaction boundaries,
so a failed database consequence does not masquerade as successful work.

An outbox can commit a delivery request transactionally, but delivery beyond
PostgreSQL is at least once. External consumers must deduplicate and must not
assume a global order across independent policies.

### Deployment and change

Deployed behavior is treated as immutable. A changed rule or decision is a new
proposal for the same stable name; a changed policy set uses a new immutable
policy-set version where its declaration changes. Preview and deployment
preconditions prevent accidental create/replace races.

Use [Changing Policies Safely](changing-policies.md) before replacement.

## Decisions and policy sets

### Decisions

A decision declaration names a candidate relation and its subject, candidate,
priority, and result columns. For each subject:

- the lowest numeric priority is best;
- one best candidate produces `WINNER`;
- tied best candidates produce `AMBIGUOUS`;
- losing all candidates produces `NO_CANDIDATE`.

Winner state has its own generation, revision, claimability, competitors, and
explanation evidence.

### Policy sets and applicability

A policy set is a versioned group of rule or decision declarations plus a
relational applicability source. Applicability answers which typed subjects
are eligible for the set. Membership and eligibility are distinct from whether
a member condition currently matches.

Policy-set versions have effective intervals and immutable version identity.
Applicability and member changes can alter which subjects are eligible even
when member declarations are unchanged.

## Advanced supported concepts

These capabilities are installed and public, but use specialized or advanced
APIs rather than the ordinary first-rule workflow:

- **Derived facts and logical support:** facts remain present while at least one
  active support exists; removing the final support retracts the fact.
- **Positive recursion:** versioned positive programs can maintain bounded,
  grounded least-fixed-point results, including cycles.
- **Stratified negation and aggregation:** negative or aggregate dependencies
  must remain in valid lower strata; cycles through negation or aggregation
  are rejected.
- **Shared conditions:** named, versioned reusable truth boundaries.
- **Temporal and effective-dated policy:** database-time/event-time conditions,
  bounded windows, deadlines, cooldown/hysteresis, and effective intervals at
  their installed contracts.
- **Parameterized policy families:** ordinary typed PostgreSQL parameter rows
  feed reusable policy definitions.
- **Provenance and decision analysis:** bounded support/explanation evidence and
  decision coverage/conflict analysis.

See the [API Reference](v1-api-reference.md) and
[Compatibility](v1-compatibility.md) before choosing an advanced surface.

## Comparison concepts

Comparison evaluates:

```text
current authoritative facts + deployed declaration
versus
current authoritative facts + proposed declaration
```

- **current:** bounded evidence for the deployed target;
- **proposed:** bounded evidence for the proposal;
- **delta:** `ADDED`, `REMOVED`, `CHANGED`, or `UNCHANGED`;
- **lifecycle:** changed delta rows that would affect lifecycle interpretation;
- **work:** rows labeled as would-be work, not durable agenda rows.

Comparison is separate from deployment. It does not install the proposal or
execute consequences.

### Bounded evidence

`evidence_limit` bounds returned evidence. A `partial` result means the
comparison cannot provide exact complete counts from the returned arrays.
There is no continuation token, and `compare_results()` exposes the same
bounded evidence rather than hidden remaining rows.

### Read-only and no-effect

Comparison SQL is read-only: it creates no deployment, lifecycle mutation,
durable work, attempt, consequence call, delivery, or frontier advancement.
The returned checksum covers selected pg-react state only; it does not prove
equality of source tables, lifecycle history, attempts, delivery state, or
external systems.

Comparison uses dedicated read-only evaluators with tested semantic results.
That does not promise the same implementation path as production evaluation.

## Not supported in v1

- changing, inserting, or deleting facts only for a comparison;
- historical replay, backtesting, or “what was true then” evaluation;
- continuation through truncated comparison evidence;
- exactly-once external delivery;
- arbitrary untrusted dynamic code;
- a synchronous application write-path hook;
- global ordering, cross-system atomic commit, or general workflow/BPM
  semantics.

See [Known Limitations](v1-known-limitations.md) for the qualified boundary and
[Authoring Rules and Policies](v1-authoring.md) for executable SQL.
