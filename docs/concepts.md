# Concepts

[Explanation](explanation/index.md) · [Your first rule](getting-started.md)

pg-react adds policy state and durable work to facts that already live in PostgreSQL. The central idea is straightforward: describe the rows that currently satisfy a condition, give each row a stable business identity, and let the runtime track how that set changes. This page explains the **0.46.0 core profile** in terms of those ordinary objects before introducing the advanced capabilities built around them.

## Ordinary concepts

### Authoritative PostgreSQL facts

Your application tables remain the source of truth. An order update is an ordinary PostgreSQL transaction, and pg-react evaluates committed data rather than asking you to maintain a second in-memory representation of the same facts. This gives policy queries the same relational foundation as the rest of your application, while leaving the application responsible for its own business data model.

### Condition relations

A condition relation answers what is true now. In the first tutorial, `rule_def.high_value_risky_order` contains an order only while it is high risk and above the chosen amount threshold. A row is therefore a current match, not an event by itself. The runtime uses pg_trickle through its supported coordinated refresh boundary to maintain eligible conditions and determine how their result changes.

### Declarations

A declaration is a typed `pgreact_api.declaration` value returned by a constructor such as `pgreact.rule`, `pgreact.decision`, or `pgreact.policy_set`. It describes intended behavior without installing that behavior merely by existing. Validation checks it, preview describes the planned operation, and deployment applies the authorized reviewed result. Keeping these steps separate lets you inspect a proposed policy before it becomes part of the running system.

### Semantic identity

A semantic key answers which business subject a match represents. For an order policy, `order_id` is stable even when the amount or risk level changes. That stability allows pg-react to distinguish a changed match from a new one, and to recognize a subject that leaves the condition and later returns. A changing attribute is usually a poor key because it changes identity at the same time as the policy's evidence.

Key support belongs to an interface, not to the product as a single undifferentiated capability. The ordinary rule constructor and rule comparison use one non-null, unique `bigint` key. Separate advanced typed-key authoring supports one to four ordered `bigint`, `uuid`, or `text` components, with deterministic `C` collation for text. A broader advanced authoring boundary does not widen comparison automatically.

### Current matches

`pgreact.matches` records how the deployed rule understands its source condition, including current bindings, active state, generation, and revision. The condition relation remains the source truth, while match state records its policy lifecycle. When debugging, query both: a source row may already have changed while the asynchronous runtime has not yet coordinated the next frontier.

### Activation lifecycle

When a key enters the condition, it activates. While it remains active, a change to watched values increments its revision. Leaving the condition deactivates it, and returning later starts a new generation. A revision belongs to one continuous active generation, so it answers a different question from generation identity. The [lifecycle and delivery explanation](explanation/lifecycle-and-delivery.md) follows an order through those transitions.

By default, all projected non-key columns are watched. `change_columns` can narrow that set, and an explicit empty array watches none. Unwatched changes can update current bindings without producing a change event. This distinction lets a condition carry useful context without making every contextual update trigger application work.

### Constraint and command rules

`pgreact.rule()` defaults to `CONSTRAINT`, which records current match state without consequence functions. A `COMMAND` rule can attach typed functions for activation, change, and deactivation, and those lifecycle transitions can create durable work. A pg-react constraint is policy state; it is not a PostgreSQL `CHECK` constraint that synchronously rejects a source write. Choose a command only when a transition should lead to an effect.

### Work and attempts

A work item is the durable request to execute an eligible consequence. An attempt records one try at that execution, including its status and error details. The distinction is useful whenever an attempt fails: the original work can remain waiting for retry even though one attempt has ended. `pgreact.work` and `pgreact.attempts` expose these observations separately, and an application task written by a consequence is a third object with your own business meaning.

### Transaction boundaries

A source change commits normally, then managed evaluation and work execution observe that committed state. A database-local consequence and its recorded execution use PostgreSQL transaction boundaries, so the runtime does not report a failed database effect as a successful execution. This transactional behavior does not make evaluation synchronous with the original application write; a match can be current while its consequence is still waiting.

For external delivery, a transactional outbox can commit the request with database state, but it cannot make a remote system participate in that same local transaction. Delivery is at least once, and external consumers must deduplicate stable identities. Independent policies do not gain a global delivery order merely because their state lives in one database.

### Deployment and change

Treat deployed behavior as immutable. A changed rule or decision is a proposal for the same stable public name, while a changed policy set uses a new immutable version identity. Preview and deployment preconditions check whether the reviewed plan still matches the current source, declarations, work, and permissions. When executable old work exists, the choice to drain or cancel it is a business decision that belongs in the replacement plan.

Comparison helps you understand the consequences of a proposal, and a review token binds a successful preview to the exact intended operation. Neither comparison nor a token grants authority to deploy. See [Changing policies safely](changing-policies.md) for the practical workflow.

## Decisions and policy sets

### Decisions

A decision evaluates a relation of candidates for each subject. The lowest numeric priority wins; equal best priorities produce `AMBIGUOUS`, and a previously tracked subject that loses all candidates can retain a `NO_CANDIDATE` result. Exposing these states makes uncertainty visible to the application instead of choosing an arbitrary winner. The decision's result, lifecycle, and explanation evidence can then be inspected through its public interfaces.

### Policy sets and applicability

A policy set groups related declarations and identifies the subjects eligible to participate through an applicability relation. Eligibility is separate from matching: a customer can belong to a policy while none of its conditions is currently true. It is also separate from choosing a result: an eligible subject can still have an ambiguous decision or no candidate. Keeping those concepts apart makes it easier to explain why a policy did or did not act.

Policy-set versions have immutable identity and effective intervals. Packages can include bounded support declarations, such as shared conditions and parameter families, plus explicit dependencies. These features help keep related policies reviewable as a unit, but they also introduce lifecycle and applicability questions that a single standalone rule does not have.

## Advanced supported concepts

Derived facts remain present while their modeled logical supports justify them; removing one support need not remove a fact that still has another support. Bounded positive recursion can maintain grounded fixed-point results, while stratified negation and aggregation impose ordering constraints on dependencies and reject invalid cycles. These are specialized data-reasoning interfaces, not a change to the meaning of an ordinary condition row.

Shared conditions provide reusable truth boundaries, parameter families supply typed policy data, and temporal or effective-dated policies introduce explicit clock and interval semantics. Provenance, causal paths, and decision analysis answer bounded questions about those results. Each family has its own input shapes, resource limits, and recovery operations. [Advanced use](explanation/advanced-use.md) connects a practical need to the appropriate capability and reference record.

## Comparison concepts

Current-fact comparison evaluates the deployed declaration and a proposed declaration over the same authoritative facts at the accepted source frontier. It reports current outcomes, proposed outcomes, a delta, and would-be lifecycle and work. This is a policy review operation: it neither installs the proposal nor executes the work described in its result.

### Bounded evidence

An evidence bound controls how much can be returned. A `partial` result is an incomplete answer, so the displayed arrays and counts must not be treated as a complete inventory of affected subjects. `compare_results()` exposes the same evidence in relational form; it does not reveal omitted rows or provide pagination. Narrow the question or adjust a supported bound, and inspect completeness again before relying on the result.

### Read-only and no-effect

Comparison does not create a deployment, mutate lifecycle state, create durable work or attempts, execute a consequence, deliver a message, or advance the authoritative frontier. Its selected-state checksum covers specific pg-react state rather than every source table, historical row, or external effect. Equal checksum fields are useful evidence within that scope, not a proof that an entire distributed application is byte-for-byte unchanged.

Comparison uses dedicated read-only evaluation helpers with tested semantic outcomes. That supports a policy review without promising that every comparison shares the production evaluator's implementation path or measures every possible resource cost.

### Hypothetical changes and supplied history

Additional interfaces let you compare typed hypothetical inserts, updates, and deletes, replay a finite caller-supplied snapshot and history, or backtest at most two policy versions over the same history. These operations answer different questions from current-fact comparison. They do not discover missing history, create a durable simulation job, or execute the modeled source mutations. Their results remain bounded and must be interpreted within their supported input model.

## Not supported in the current release

The core contract does not include capturing history you did not supply, continuing through truncated simulation evidence, exactly-once remote delivery, arbitrary untrusted code, synchronous application write rejection, global ordering, cross-system atomic commit, or general workflow orchestration. Those boundaries are design inputs when you decide where pg-react fits in an application. Use [Known limitations](known-limitations.md) and the [support matrix](support-matrix.md) to check a proposed use, then turn to [Authoring](authoring.md) for the practical SQL.
