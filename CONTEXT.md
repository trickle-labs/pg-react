# pg-react Rule Lifecycle

The shared vocabulary is in [GLOSSARY.md](GLOSSARY.md). This document records
the lifecycle-specific contract for changing relational conditions, durable
history, and optional work.

## Language

The terms below use the definitions in [GLOSSARY.md](GLOSSARY.md) and add
lifecycle-specific invariants.

**Rule**:
A stable named policy whose condition may create lifecycle events and consequences.
_Avoid_: Job, workflow

**Rule version**:
An immutable meaning of a rule for a particular condition, identity, consequence, and policy contract.
_Avoid_: Revision when referring to a deployed rule definition

**Condition view**:
The relational statement of what is true now; each keyed row is one current match.
_Avoid_: Trigger, pattern

**Activation**:
The lifecycle state of one semantic match under one rule version.
_Avoid_: Episode, task

**Activation generation**:
One continuous interval during which an activation remains true.
_Avoid_: Attempt, revision

**Lifecycle event**:
An immutable activation, change, or deactivation transition, recorded whether or not work is requested.
_Avoid_: Episode, callback

**Consequence**:
The declared response bound to a kind of lifecycle event.
_Avoid_: Event, rule

**Episode**:
One durable agenda item created when a lifecycle event has a consequence.
_Avoid_: Lifecycle event, activation

**Agenda**:
The collection of consequence episodes and their execution state.
_Avoid_: Event log, workflow

**Reconciliation**:
An explicit comparison that restores agreement between current matches and activation state.
_Avoid_: Refresh

**Frontier**:
The progress boundary through source changes that a completed match refresh represents.
_Avoid_: Timestamp, version

**Derivation rule**:
A rule whose current activation provides logical support for a derived fact instead of consequence work.
_Avoid_: Command rule, trigger

**Derived relation**:
A named, typed collection of derived facts that share one schema and semantic-key contract.
_Avoid_: Fact table, cache

**Derived fact**:
One current keyed value in a derived relation, true exactly while at least one logical support remains valid.
_Avoid_: Activation, consequence result

**Logical support**:
One current justification linking an exact derivation-rule activation to a derived fact.
_Avoid_: Episode, attempt

**Provenance**:
The recorded explanation path from a derived fact through its logical supports to exact rule versions and source bindings.
_Avoid_: Execution log, general tuple lineage

**Truth maintenance**:
The preservation or retraction of a derived fact as its set of valid logical supports changes.
_Avoid_: Consequence execution, refresh

**Positive dependency**:
A derivation dependency where adding input facts cannot invalidate an existing output match or support.
_Avoid_: Negated dependency

**Negative dependency**:
A derivation dependency satisfied only when no matching fact exists in its declared input at the current program frontier.
_Avoid_: Negative fact, retraction

**Aggregate dependency**:
A derivation dependency that summarizes a finite, stable lower-stratum input for one positively bound group before deciding higher-stratum support.
_Avoid_: Window, recursive aggregate

**Event time**:
The direct timestamp carried by authoritative or lower-stratum input that determines which event-time window receives that input.
_Avoid_: Processing time, ingestion time

**Event-time window**:
A fixed UTC-epoch-aligned interval that groups timed input for one aggregate dependency and is identified by its group key plus signed window ordinal.
_Avoid_: Calendar window, session window, timer

**Watermark**:
A monotone claim about event-time completeness for one timed input; the requested watermark is intent, while the complete watermark certifies committed finalization through that instant.
_Avoid_: Clock, observed maximum timestamp

**Correction**:
One immutable, frontier-identified change to a materialized event-time window's aggregate state.
_Avoid_: Input row, lifecycle event

**Final window**:
An event-time window whose lateness boundary has been reached by its complete watermark and whose aggregate state can no longer be corrected.
_Avoid_: Closed agenda, completed consequence

**Derivation program**:
A versioned dependency graph of derivation rules and derived relations maintained as one semantic unit.
_Avoid_: Rule pack

**Stratum**:
An ordered group of derivation components that reaches its positive least fixed point after every input reached through a negative dependency has stabilized in a lower group.
_Avoid_: Iteration, layer

**Stratified program**:
A derivation program whose strata order every negative dependency strictly downward, so no dependency cycle contains negation.
_Avoid_: Arbitrary negation

**Least fixed point**:
The smallest stable set of derived facts obtained by repeatedly applying a positive derivation program to authoritative input facts.
_Avoid_: Any stable state

**Grounded proof**:
A finite explanation that reaches authoritative input bindings rather than justifying a derived fact only through a cycle.
_Avoid_: Circular support
