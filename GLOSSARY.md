# pg-react Glossary

This is the shared ubiquitous language for pg-react. Use these terms in code,
SQL names, documentation, tests, diagnostics, and operational conversations.
The glossary owns the names and their practical meanings. It is written for the
moment when a reader encounters a term in a SQL function, a catalog view, or an
operations message and needs to understand what that term commits the system
to mean.

[CONTEXT.md](CONTEXT.md) owns the detailed lifecycle contract, and
[docs/concepts.md](docs/concepts.md) explains the user-facing model. Those
documents can go deeper, but they should use the names defined here rather than
creating a parallel vocabulary.

When a public API uses a different word for compatibility, document the
canonical term beside it. Do not introduce a synonym when the term below
already exists.

## System and truth

pg-react starts with facts that already live in PostgreSQL. A condition relation
turns those facts into a maintained statement about what is true now, and a
current match is one row in that statement. This distinction matters because a
row in a condition relation is not automatically a historical event, a request
for work, or proof that a consequence has run.

**Authoritative fact**

A committed row or result in an application-owned PostgreSQL table or view is an
authoritative fact. PostgreSQL remains the source of truth: pg-react observes
the committed state and builds lifecycle state around it, but it does not move
the application facts into a separate in-memory working store. When the source
transaction commits, the fact is available for the normal pg-react evaluation
boundary.

**Condition relation**

An ordinary PostgreSQL relation or view that describes what is true now. It can
be a table, a view, or another supported maintained relation, depending on the
authoring surface. Every row says that one condition currently holds; it does
not, by itself, say when the condition became true or ask a worker to do
anything.

**Condition view**

A named PostgreSQL view used as the condition source for a rule. The view is a
useful authoring boundary because PostgreSQL gives it a stable composite row
type, native dependency tracking, and ordinary SQL behavior that authors can
inspect with `SELECT` and `EXPLAIN`. The deployed rule uses a snapshotted
meaning of the view, so changing the view later does not silently rewrite the
rule that is already running.

**Current match**

One row that is currently present in a deployed condition relation for a
semantic subject. The row supplies the current bindings that pg-react uses to
understand the subject and, when appropriate, to invoke a typed consequence. A
match is current truth, not historical work; its later activation, change, or
deactivation is what creates lifecycle history.

**Declaration**

A typed `pgreact_api.declaration` produced by a constructor such as
`pgreact.rule()`, `pgreact.decision()`, or `pgreact.policy_set()`. It is the
portable description of proposed behavior, including the condition, identity,
and policy choices that the selected constructor accepts. A declaration can be
validated and previewed before deployment, which lets an author inspect a
change without mutating installed state or creating work.

**Deployed behavior**

The immutable behavior installed for a stable rule, decision, or policy-set
name. Deployment turns a validated declaration into behavior that the runtime
can evaluate and audit, but it does not make that behavior mutable in place. A
changed declaration is a proposal for a new version, so history continues to
refer to the exact meaning that produced earlier state and work.

**Semantic key**

The typed column or columns that identify the logical subject of a match. The
key gives pg-react a durable way to distinguish a new match, a changed active
match, and the return of a previously inactive match, even when the physical
maintenance relation is rebuilt. It expresses the business identity of the
condition row and is not necessarily a primary key from one of the base tables
used by the query.

**Source drift**

A difference between the deployed source definition or row shape and the
current PostgreSQL object. Drift can arise when someone changes a condition
view after a rule version has been deployed, or when its projected columns no
longer have the recorded shape. pg-react detects the difference and requires an
explicit replacement, because silently changing an active version would make
its existing lifecycle history difficult to interpret.

## Rules and lifecycle

Rules describe durable meaning, while activations describe what that meaning is
doing for one subject right now. The runtime compares successive current
matches under one immutable rule version and records the transitions it sees.
That gives users a history they can inspect without pretending that every
physical row update is a separate business event.

**Rule**

A stable named policy whose condition may create lifecycle state and optional
work. The name gives operators and other declarations something durable to
refer to, while the deployed rule version fixes the condition, identity, and
consequence contract that gives the rule its meaning. A rule can describe
current truth without requesting any work at all.

Avoid: *job*, *workflow*.

**Rule version**

An immutable meaning of a rule for one condition, semantic key, consequence
contract, and policy configuration. A new version is the place where a changed
condition or changed execution policy becomes explicit. Keeping versions
immutable means that an activation or work item can always be understood in the
context that created it.

Avoid: *revision* when referring to a deployed rule definition.

**Constraint rule**

A rule that records current truth and exposes matches without consequences or
durable work. It is useful when the maintained relation itself is the product,
such as a relation of orders that currently need review. `pgreact.rule()`
defaults to this kind, so authors must opt into command behavior deliberately.

**Command rule**

A rule that may bind activation, change, or deactivation consequences and can
create durable work. The consequence is scheduled from a lifecycle event and
executes after the source state has committed, which keeps application writes
separate from arbitrary user code or external delivery. A rule with
consequences must explicitly use `kind => 'COMMAND'`.

**Activation**

The lifecycle state of one semantic match under one rule version. It begins when
the key enters the condition and ends when the key leaves it. While the
activation is active, pg-react keeps the current bindings and can observe
watched changes without treating each refresh as a new activation.

Avoid: *episode*, *task*.

**Activation generation**

One continuous interval during which an activation remains true. A reactivation
of the same key starts a new generation, even though the semantic key is the
same. The generation separates two distinct periods of truth so that their
events, consequences, and retries remain unambiguous.

Avoid: *attempt*, *revision*.

**Revision**

A monotonically increasing change number within one activation generation. It
starts at zero for a generation and advances when watched values change. The
revision belongs to the activation's changing payload; it does not replace the
rule version and does not mean that the rule definition itself was redeployed.

Avoid: *rule version*.

**Watched values**

The projected values whose change produces a change lifecycle event. All
projected non-key columns are watched by default, because a changed binding may
matter to a consequence; `change_columns` can narrow the set when only part of
the projection carries lifecycle meaning. An unwatched value can still update
the current binding, but its change does not create a change event or new work.

**Lifecycle event**

An immutable activation, change, or deactivation transition. The event records
what changed in the lifecycle and carries the generation and revision needed to
interpret that transition later. It is recorded whether or not a consequence
is bound, because lifecycle history should not disappear merely because a rule
was configured as a constraint.

Avoid: *episode*, *callback*.

**Reactivation**

A new activation of a key after its previous activation ended. Reactivation
starts a new activation generation rather than continuing the old one, which
lets an operator distinguish a condition that stayed true from one that became
false and later became true again.

**Consequence**

The declared response bound to one kind of lifecycle event. A command rule may
bind separate responses for activation, change, and deactivation, and each
response has its own durable execution history. Database consequences use typed
PostgreSQL functions; external responses use a transactional outbox boundary so
the request is durable even though delivery happens outside PostgreSQL.

Avoid: *event*, *rule*.

## Durable work

An event explains why something happened; work records what the system has been
asked to execute because of it. That separation allows an event to remain part
of the audit trail even when its work is withdrawn, completed, or retried, and
it prevents cleanup of current activation state from erasing execution history.

**Work**

A durable request to execute a consequence or other lifecycle response. Public
work is exposed through `pgreact.work`, where operators can inspect whether the
request is pending, leased, retrying, completed, failed, or withdrawn. Work is
historical state associated with an event; it is not another name for the
condition row that caused the event.

**Episode**

One durable agenda item created from one lifecycle or decision event that has a
consequence. The episode points back to the immutable event that requested it,
so a retry can create another attempt without creating another lifecycle
transition. Use *work* when discussing the public projection; use *episode*
when distinguishing the item from the event that created it.

Avoid: *lifecycle event*.

**Agenda**

The collection of work items and their execution state. The agenda is the
runtime's durable queue, but it is richer than an event log because each item
also carries eligibility, lease, retry, and completion information. It records
requested execution without claiming that execution has already happened.

Avoid: *event log*, *workflow*.

**Attempt**

One execution record for a work item. Retries create additional attempts so an
operator can see each execution outcome, delay, and error, but they do not
create additional lifecycle events or duplicate the reason the work was
requested.

**Lease**

Temporary authority granted to a worker to execute a claimed work item. The
lease prevents two workers from treating the same item as theirs at the same
time, while its expiry provides recovery when a worker disappears. Once the
lease expires, eligible work can be claimed again under the retry rules.

**Managed worker**

The PostgreSQL-managed runtime that coordinates maintenance and drains eligible
work for a configured database. It operates after source transactions commit,
so a worker can make decisions from durable PostgreSQL state rather than from a
caller that may still be rolling back. The companion `pg-reactd` process is a
compatibility path, not the ordinary runtime.

**Outbox**

A PostgreSQL transaction boundary that records a request for external delivery.
The outbox lets pg-react commit the delivery request with the local state that
made it necessary, while a separate delivery system owns transport, retries,
and deduplication. It is a durable handoff, not a claim that the remote system
has already accepted or processed the message.

**At-least-once delivery**

The external-delivery guarantee. A consumer may receive the same request more
than once because a worker or relay can fail after the remote side accepts a
request but before local completion is recorded. Consumers must deduplicate by
the supplied idempotency key. pg-react does not promise exactly-once delivery
or global ordering across independent policies.

**Idempotency key**

The deterministic identity of an event or external delivery request. It lets
workers and consumers recognize a retry as the same logical request, even when
the transport or execution record is new. Idempotency is the consumer's
responsibility at the external boundary; the key gives that responsibility a
stable value to use.

**Reconciliation**

An explicit comparison that restores agreement between current matches and
activation state after initialization, full refresh, restore, or uncertain
recovery. Reconciliation checks the maintained present against the durable
lifecycle interpretation and repairs the difference under the runtime's normal
guards. It is a correctness operation, not merely a request to recompute a
relation.

Avoid: *refresh*.

**Frontier**

The progress boundary through source changes represented by a completed
matching or derivation refresh. A frontier tells the runtime how far the
maintained result has incorporated committed input, which lets lifecycle and
reasoning work refer to a known point of progress. It is a progress boundary,
not just a timestamp copied from a source row.

Avoid: *timestamp*, *version*.

## Decisions and policy sets

Rules answer whether a condition is true and what lifecycle follows from that
truth. Decisions answer a different question: among the candidates available
for one subject, which result should win, and what should the system say when
the answer is tied or empty? Policy sets add another boundary by deciding which
subjects are eligible to use a versioned group of rules or decisions in the
first place.

**Decision**

A declaration that evaluates candidates for each subject and records a winner,
ambiguity, or no-candidate result. The decision state is durable and
inspectable, so a consumer can distinguish a clear selection from a conflict or
from the absence of any eligible option. A decision has its own lifecycle
history even when the candidate relation is maintained like an ordinary
condition.

**Candidate**

One row eligible to compete for a subject in a decision. Its subject, result,
and priority columns provide the values used to compare it with other rows for
the same subject. The lowest numeric priority is best, so a candidate with
priority `1` outranks one with priority `2`.

**Winner**

The single best candidate for a subject when no candidate shares its priority.
Winner state identifies the selected result and keeps enough generation,
revision, competitor, and explanation information to show how the selection
was reached. If another candidate ties at the best priority, the state is not a
winner.

**Ambiguous**

A decision state in which two or more best candidates tie at the lowest
priority. Ambiguity is a meaningful result, not an implementation failure: it
tells the caller that the available declarations do not select one candidate
unambiguously and that the competitors should be inspected.

**No candidate**

A decision state in which a subject has no eligible candidates. It differs from
ambiguity because there is nothing to compare, and it differs from a winner
because no result can be selected from the current candidate relation.

**Policy set**

A versioned group of rule or decision declarations with a relational
applicability source. The set gives related behavior one named unit for
deployment and inspection, while its members retain their own rule or decision
identity and lifecycle semantics.

**Applicability**

The relation that determines which typed subjects are eligible for a policy
set. Applicability is distinct from membership and from whether a member rule
currently matches: a subject may belong to an applicable set while none of its
member conditions are true, or a member condition may be true for a subject
that is not currently eligible for the set.

**Policy-set version**

An immutable version of a policy set, including its membership, applicability,
effective interval, and declaration meaning. Replacing the membership or the
eligibility rules creates a new version so that historical decisions can still
be interpreted against the policy set that was active at the time.

## Reasoning and derived facts

The reasoning vocabulary describes facts that are supported by rules rather
than commands that happen to run. A derived fact remains visible while at
least one valid support justifies it, and provenance explains that support back
to the source bindings that grounded the derivation. This makes a reasoning
result inspectable in the same database that stores the authoritative facts.

**Derivation rule**

A rule whose activation provides logical support for a derived fact instead of
creating consequence work. Its output is a statement that can participate in
further derivation, not an instruction for a worker to perform an imperative
side effect. A derivation rule may therefore support a fact that another rule
uses without turning every logical step into an agenda item.

Avoid: *command rule*, *trigger*.

**Derived relation**

A named, typed collection of derived facts that share one schema and semantic
key contract. The relation is a durable truth boundary for reasoning results,
with the same kind of inspectable rows and keys that make ordinary condition
relations useful. It is not a cache whose contents can be discarded without
changing the meaning of the program.

Avoid: *fact table*, *cache*.

**Derived fact**

One current keyed value in a derived relation. It remains true while at least
one valid logical support exists, even if several different rules or source
bindings justify the same value. Removing the final support retracts the fact;
removing one of several supports does not.

Avoid: *activation*, *consequence result*.

**Logical support**

One current justification linking an exact derivation-rule activation to a
derived fact. A support identifies the rule version and source bindings that
make the fact true, so the runtime can remove only the justification that has
become invalid. A fact supported by two independent derivations has two logical
supports, not one support with an opaque count.

Avoid: *episode*, *attempt*.

**Truth maintenance**

Preservation or retraction of a derived fact as its set of valid logical
supports changes. Truth maintenance is about keeping the derived relation in
agreement with its current proofs, not about invoking a consequence or merely
refreshing a materialized relation.

Avoid: *consequence execution*, *refresh*.

**Provenance**

The recorded explanation path from a derived fact through its logical supports
to exact rule versions and source bindings. Provenance answers why the fact is
currently present and gives an operator a route back to the authoritative input
that grounded the explanation. It is narrower and more purposeful than a log
of every tuple operation performed by the database.

Avoid: *execution log*, *general tuple lineage*.

**Positive dependency**

A dependency where adding input facts cannot invalidate an existing output match
or support. Positive dependencies can therefore be evaluated as facts
accumulate, subject to the program's other bounds and fixed-point rules.

**Negative dependency**

A dependency satisfied only when no matching fact exists in its declared input
at the current frontier. Because a newly discovered input can invalidate that
absence, negative dependencies must be ordered below the rules that depend on
them; arbitrary cycles through negation are not accepted.

**Aggregate dependency**

A dependency that summarizes a finite, stable lower-stratum input for one
positively bound group before deciding higher-stratum support. The lower input
must be stable before the aggregate can justify a higher-stratum result, which
keeps the meaning of a count or threshold independent of evaluation order.

**Derivation program**

A versioned dependency graph of derivation rules and derived relations
maintained as one semantic unit. The program gives related rules a shared
version, dependency order, and bounded evaluation contract instead of leaving
each derived relation to invent its own isolated semantics.

**Stratum**

An ordered group of derivation components whose positive fixed point is reached
after lower-stratum negative inputs have stabilized. A stratum is an evaluation
boundary: rules inside it may iterate through positive dependencies, while
negative inputs must already have a stable answer below it.

**Stratified program**

A derivation program in which every negative dependency points strictly to a
lower stratum, so no dependency cycle contains negation. Stratification makes
the order of negative evaluation explicit and rejects a program whose meaning
would depend on choosing an arbitrary point inside a negated cycle.

**Least fixed point**

The smallest stable set of derived facts obtained by repeatedly applying a
positive derivation program to authoritative input facts. The word *least*
rules out extra facts that have no grounded derivation, including facts that
would be supported only by a self-sustaining cycle.

**Grounded proof**

A finite explanation that reaches authoritative input bindings rather than
justifying a derived fact only through a cycle. Grounded proofs are what let an
operator follow a derived result back to facts that actually came from the
authoritative PostgreSQL state.

## Time and windows

Temporal reasoning adds a second kind of order to the relational model. The
database may process an input now even though the input belongs to an earlier
event-time window, so pg-react uses explicit watermarks and correction rules to
separate event completeness from the wall clock and from the order in which
transactions happen to arrive.

**Event time**

The timestamp carried by authoritative or lower-stratum input that determines
which event-time window receives that input. Event time describes when the
fact's subject event occurred, which can differ from the time PostgreSQL
received or processed the row. Keeping the distinction explicit is necessary
when late input can change a window that the runtime has already examined.

Avoid: *processing time*, *ingestion time*.

**Event-time window**

A fixed UTC-epoch-aligned interval that groups timed input for one aggregate
dependency. It is identified by its group key and signed window ordinal, which
gives the same event-time interval a stable identity across refreshes. The
window is a grouping boundary for timed facts, not a human calendar period or
an instruction to run a timer.

Avoid: *calendar window*, *session window*, *timer*.

**Watermark**

A monotone claim about event-time completeness for one timed input. The
requested watermark expresses intent, while the complete watermark certifies
that committed finalization has reached that instant. A watermark therefore
describes what the system is allowed to consider complete; it is not simply the
largest timestamp observed in the input.

Avoid: *clock*, *observed maximum timestamp*.

**Correction**

One immutable, frontier-identified change to a materialized event-time window's
aggregate state. A correction records the effect of late or newly incorporated
input on the aggregate represented by the window, so the history can explain
why a prior value changed. It is not itself an input row or a lifecycle event.

Avoid: *input row*, *lifecycle event*.

**Final window**

An event-time window whose lateness boundary has been reached by its complete
watermark and whose aggregate state can no longer be corrected. Finality is a
durable semantic boundary: after it, a later input is outside the installed
contract rather than an ordinary correction to the same window.

Avoid: *closed agenda*, *completed consequence*.

**Effective-dated policy**

A policy whose applicability or behavior is selected by an explicit effective
interval rather than by deployment time alone. The interval is part of the
policy meaning, so a subject can be eligible under one effective period and
ineligible under another without changing the identity of the policy itself.

## Comparison and change safety

Change safety depends on keeping evaluation separate from installation. A
comparison runs the deployed and proposed declarations against the same current
authoritative facts, so the result describes how the declaration changes the
interpretation of the present. It does not simulate a hypothetical fact change,
replay history, or quietly perform the work that a deployment might later
request.

**Proposal**

A declaration evaluated as a possible replacement or addition. A proposal is
not deployed and cannot create lifecycle state, durable work, an attempt, a
consequence call, or an external delivery. It is a candidate meaning that can
be inspected before the operator accepts the change.

**Comparison**

A read-only evaluation of current authoritative facts with the deployed
declaration versus the same facts with a proposed declaration. It varies the
declaration, not the facts, which makes the result useful for reviewing a rule
change without introducing a second hypothetical database state. Comparison is
bounded and is separate from deployment, so it cannot install the proposal or
advance the runtime frontier.

**Comparison evidence**

The bounded `current`, `proposed`, `delta`, `lifecycle`, and would-be `work`
results returned by comparison. These fields let a reader move from the
deployed interpretation, to the proposed interpretation, to the rows whose
meaning would change, and finally to the lifecycle or work consequences that
would follow. The evidence describes what would happen; it is not itself
durable runtime state.

**Delta**

The classification of a comparison row as `ADDED`, `REMOVED`, `CHANGED`, or
`UNCHANGED`. The classification is relative to the deployed and proposed
declarations over the same facts, so `ADDED` means that the proposed condition
would include a row that the deployed condition does not, not that a PostgreSQL
insert has occurred.

**Partial comparison**

A comparison whose returned evidence is limited by `evidence_limit`. It has no
continuation token and does not imply hidden exact counts, so a consumer should
report the result as bounded evidence rather than presenting the returned array
as a complete census. The limit is part of the result's interpretation, not
merely a display preference.

**Preview**

A validation-oriented, read-only inspection of a declaration before deployment.
Preview is the early check for shape, identity, dependencies, and other
preconditions; comparison is the read-only check for the declaration's effect
on current facts. Preview does not install behavior, execute consequences, or
create durable work.

## Names and boundaries

The project name and the installed names are related, but they are not
interchangeable. Use the branded spelling in prose, and use the exact SQL or
Rust spelling when giving a command, referring to a schema, or pointing at an
implementation surface. Private schemas and generated objects may be useful to
maintainers, but they are not promises made by the ordinary public API.

**pg-react**

The project and product name. Use this spelling in prose, headings, and user
guidance, including when describing the PostgreSQL-native rule and policy
engine.

**`pg_react`**

The PostgreSQL extension name and Rust crate identifier. Install it with
`CREATE EXTENSION pg_react`; use the underscore form when referring to the
extension or crate in technical identifiers.

**`pgreact`**

The public SQL schema for ordinary pg-react functions and views. It is the
namespace users normally query for installed rule, decision, policy-set, match,
and work surfaces.

**`pgreact_api`**

The typed public SQL surface used for declarations, constructors, and related
API types. It is where the structured authoring contract lives, while
`pgreact` is the ordinary public namespace used to inspect and operate the
installed behavior.

**`pgreact_runtime`**

The generated runtime schema used by installed behavior. It contains machinery
created for a deployed declaration and is not the normal authoring surface;
authors should use the public functions and projections instead of coupling
their application to generated objects.

**`pgreact_internal`**

The private catalog schema. Its tables, columns, and identifiers support the
implementation and may change as the extension evolves, so they are not part of
the ordinary public API and should not be used as application integration
points.

**`pg-reactd`**

The optional companion worker process. It is retained for compatibility and can
call the public runtime API, but the PostgreSQL-managed worker is the normal
runtime for a configured database.

These names also mark explicit product boundaries. pg-react is not a
synchronous application write-path hook, a global-ordering service, a
distributed transaction coordinator, an exactly-once external-delivery system,
or a general workflow/BPM engine. Those boundaries protect the meaning of the
terms above: facts remain authoritative in PostgreSQL, external effects remain
at least once, and durable lifecycle state remains queryable instead of being
hidden inside an unrelated orchestration abstraction.
