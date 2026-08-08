# pg-react Rule Lifecycle

The project turns changing relational conditions into durable lifecycle history and optional work. These terms are canonical across design, code, APIs, and operations.

## Language

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
