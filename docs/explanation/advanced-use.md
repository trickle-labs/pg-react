# Grow into advanced use

[Explanation](index.md) · [Advanced API guide](../reference/advanced-apis.md)

Advanced use begins when you can explain one rule's source, lifecycle, and work without guessing. The next step is to introduce a capability because it solves a specific problem in your application. pg-react 0.46.0 contains more than the ordinary first-rule interface, but each family has its own supported inputs, evidence bounds, and recovery contract. This guide helps you choose a path and understand what you are taking on.

## First, make a policy change reviewable

Before introducing more kinds of reasoning, learn to compare a replacement over current facts. [Changing policies safely](../changing-policies.md) continues the first tutorial, lowers its review threshold, introduces an order that only the proposal matches, and shows the current, proposed, delta, lifecycle, and would-be work evidence. This is an immediately useful advanced habit: it lets you assess a change before its effects become real.

A good checkpoint is being able to explain which subjects are added or removed, whether evidence is complete, which work would be created, and what happens to already-created work at cutover. If you cannot answer those questions yet, a larger policy package will multiply the uncertainty rather than resolve it.

## Choose results and scope related policies

When a condition only tells you that a review is needed, a decision can answer which queue or outcome should be chosen. Its explicit `WINNER`, `AMBIGUOUS`, and `NO_CANDIDATE` states make candidate conflicts visible. The [order-review tutorial](../order-review-tutorial.md) gives you a complete example with stable fixture rows, so you can see each state before adapting the relation to your own routing problem.

A policy set becomes useful when several rules and decisions should share applicability, versioning, and review. Its eligible population is separate from each member's condition, and its support declarations and dependencies make reusable inputs explicit. Packages introduce adoption, immutable version identity, and old-work decisions, so inspect their preview as a plan rather than treating them as a convenient array of independent deployments.

## Reuse truth and parameterize policy

A shared condition gives related declarations a named reusable truth boundary. A parameter family lets typed PostgreSQL rows supply policy parameters rather than embedding every threshold in a separate hand-edited declaration. These are useful when duplication makes a policy hard to review, but they also make dependency identity part of the design: you must know which declarations consume which support objects and how a replacement affects them.

The [advanced API guide](../reference/advanced-apis.md#packages-shared-conditions-and-parameters) links the exact package constructors and dependency contracts. Begin with a small package, inspect its public contents and dependencies, export the reviewed declaration, and verify that a change to one support object has only the intended consumers.

## Derive facts with explicit support

Derived facts are useful when the policy result should itself become maintained relational input. A fact can have more than one logical support, so removing one justification should not retract a fact that another support still justifies. Once this model is clear, bounded positive recursion can express grounded fixed-point reasoning, and stratified negation or aggregation can express additional forms of dependency with stricter ordering rules.

The design question is no longer only which rows match; it is which supports keep each fact true and how those supports change. Begin with two independent supports for one fact, remove them one at a time, and inspect the public explanation at each step. The [derived-fact contracts](../reference/advanced-apis.md#derived-facts-and-programs) describe the supported models and limits. The order-review fixture does not qualify this scenario, so its successful transcript should not be treated as proof of a derivation workload.

## Introduce time deliberately

A deadline, a time window, and an effective-dated policy answer different questions. A deadline asks whether a configured time boundary has been crossed. A window reasons over a bounded temporal set. An effective interval chooses which policy version applies at a time. Database time, event time, watermarks, late data, and sampled evaluation time cannot be substituted for one another without changing the meaning of the result.

Choose the time model first, then test the points immediately before, at, and after its boundaries, along with the documented late-data and recovery behavior. Use the [temporal reference records](../reference/advanced-apis.md#time-and-effective-policy) for the exact family you adopt. Do not put a moving clock expression into an ordinary condition and assume it gains the guarantees of a specialized temporal API.

## Ask stronger questions before deployment

Current-fact comparison varies the declaration while holding facts fixed. A hypothetical comparison also supplies a finite typed change set without applying its inserts, updates, or deletes. Replay evaluates one declaration over a caller-supplied snapshot and history, while backtesting compares at most two policy versions over that same history. These operations help you investigate a policy, but they do not collect missing historical data on your behalf.

Before using replay or backtesting, establish where the initial snapshot, row images, schema fingerprints, time frontiers, and step ordering come from. A convincing result depends on those inputs as well as the evaluator. Read [Simulation interfaces](../reference/advanced-apis.md#hypothetical-comparison-replay-and-backtesting) for their exact shapes and limits, and treat a `partial` result as incomplete evidence rather than an exhaustive prediction.

## Explain outcomes and preserve evidence

Start with the business question: why is this result present, why is an expected result absent, or why did a comparison change? [Explain an outcome](../explaining-outcomes.md) provides concrete calls and shows how to interpret completeness and boundaries. Causal paths can connect a supported decision or work root to public facts, while a semantic diff describes modeled declaration changes. A changed declaration field is review evidence; it does not by itself prove causation for a particular result.

A retained evidence snapshot preserves an earlier supported causal answer for later review. It is historical evidence, even if you read it today. Its outer state describes snapshot availability, and its nested answer describes the completeness of the captured explanation. Keep its identity, capture key, retention policy, and authorization context with the review record, and use the [evidence reference](../reference/advanced-apis.md#explanations-and-retained-evidence) when designing capture and deletion.

## Make the advanced capability operable

For any new family, finish by answering four practical questions: how do you inspect its current state, what bounds stop it from growing without limit, which public operation repairs it after drift or restore, and which application result proves that it recovered? Those answers belong beside the declaration and its tests. A standalone rule reconciliation does not automatically repair a policy package, derivation program, or temporal workload.

Use [Operations](../operations.md), [Backup and restore](../backup-restore.md), and the family's versioned reference together. The goal is a policy you can explain and recover, not simply a successful constructor call.
