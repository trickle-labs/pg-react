# Practical Rule-Engine Features That Solve Real Business Problems

## A product-design note for pg-react

Related vision documents: [Product thesis](pg-react_product_thesis.md) · [30-milestone vision](pg-react_30_milestone_vision.md)

A rule engine becomes valuable when it moves business policy out of scattered application branches and turns that policy into something people can inspect, change, test, explain, and operate independently of the code paths that happen to enforce it. The most useful features are therefore not necessarily the most academically powerful reasoning features. They are the capabilities that let a team say, “this is our policy,” “this is when it applies,” “this is why this decision was made,” and “this is what would happen if we changed it,” without hiding the answer inside a maze of application code.

pg-react already has an unusually strong foundation for this style of system. Its central idea is PostgreSQL-native: SQL and PostgreSQL relations describe truth, typed keys give business facts stable identity, pg-react records lifecycle and durable work, and public inspection and explanation APIs make the resulting state visible. Later milestones add derivation, negation, aggregation, typed keys, managed execution, and event-time semantics while deliberately keeping the public model smaller than the machinery underneath it. This document looks beyond that foundation and describes eight capabilities that are likely to solve ordinary, recurring business problems rather than exotic reasoning problems.

The eight capabilities are **decision tables and winner semantics, effective-dated rules, parameterized rule families, what-if evaluation, historical replay and backtesting, reusable shared conditions, practical temporal rules, and explainable provenance**. None of these requires pg-react to become a no-code platform, a general workflow engine, or a proprietary expert-system language. In fact, the most promising implementation approach is the opposite: keep SQL authoritative and add first-class semantics only where SQL alone does not provide durable identity, policy versioning, deterministic selection, temporal behavior, simulation isolation, or causal explanation.

This document treats the post-M18 architecture as the target baseline. API sketches are illustrative rather than proposed contracts. Any real milestone should follow pg-react's existing discipline: freeze a reference program and exact outputs first, write the contract second, implement one narrow vertical slice third, and only widen the feature after correctness, recovery, security, explainability, and upgrade behavior are executable.

---

## At a glance

| Capability | Typical user question | Business value | Natural pg-react foundation | Relative implementation lift |
|---|---|---|---|---|
| Decision tables | “Which policy wins?” | Very high | Views, typed keys, lifecycle, explain | Medium |
| Effective-dated rules | “Which version applies on this date?” | Very high | Immutable versions, database-time deadlines | Medium |
| Parameterized rule families | “Can one policy vary by tenant/product/region?” | Very high | Relational inputs, typed keys, deployment manifests | Medium |
| What-if evaluation | “What would happen if these facts changed?” | Very high | Validation/preview, reference semantics, explain | High |
| Backtesting | “What would this policy have done last quarter?” | Very high in regulated/risk domains | What-if engine, lifecycle oracle, event-time semantics | High |
| Shared conditions | “Can many rules reuse this concept?” | High | Maintained relations, dependency graph, immutable versions | Medium |
| Practical temporal rules | “Has this stayed true long enough?” | Very high | Database-time deadlines, M17 windows/watermarks | Medium to high |
| Explainable provenance | “Why exactly is this true or did this fire?” | Very high | Supports, finite evidence, unified explain | Medium to high |

The important point is that these are not eight unrelated features. Several reinforce one another. Shared conditions make large policy sets easier to structure. Parameterized rules and effective dates make policy change manageable. Decision tables give a natural shape to classifications and eligibility. What-if evaluation becomes the foundation for backtesting. Temporal rules build naturally on the deadline and event-time machinery already planned or implemented. Richer provenance makes all of the other features safer to adopt because users can see why the system reached a result.

---

# 1. Decision tables and deterministic winner semantics

## The problem users actually have

A large percentage of “rules” in business software are not open-ended inference problems. They are classification and selection problems. A customer belongs in one risk class. An order receives one shipping policy. A loan application maps to one underwriting tier. A support ticket goes to one routing queue. A promotion engine chooses one discount. A claims system selects one deductible rule. In application code, these policies often begin life as an innocent `if / else if / else` block and gradually become a brittle collection of conditions whose precedence is encoded only by statement order.

The difficulty is rarely writing an individual predicate. SQL is already excellent at predicates. The difficulty is making the **selection semantics** explicit. If three policies match, should the highest priority win? Should overlapping policies be rejected as configuration errors? Is it legal for no policy to match? If two rules have the same priority, is that an error or is there a deterministic tie-breaker? When an operator asks why a customer was assigned “Enhanced Review” rather than “Standard Review,” can the system show both the winning policy and the other candidates that were considered?

This is exactly where a rule engine can add value without becoming exotic. The useful abstraction is not “a language for writing conditions.” It is **a durable, versioned, explainable decision over SQL-produced candidates**.

## A practical example

Imagine an insurer deciding the review tier for a new commercial policy. The facts include annual revenue, jurisdiction, prior claims, industry code, and whether the applicant is already a customer. Several policy rules may match:

```text
Priority 10: sanctioned jurisdiction                      -> REJECT
Priority 20: high-risk industry and revenue > 10M         -> SENIOR_REVIEW
Priority 30: claims in last 24 months >= 3                -> SENIOR_REVIEW
Priority 40: revenue > 2M                                 -> STANDARD_REVIEW
Priority 50: otherwise                                    -> FAST_TRACK
```

The business does not merely care that several predicates are true. It cares about the **one authoritative decision**, why that decision won, and whether a future policy edit creates an accidental overlap that changes thousands of classifications.

The PostgreSQL-native way to model this could be a view that emits candidate decisions:

```sql
CREATE VIEW policy.review_candidates AS
SELECT applicant_id, 'sanctioned'::text AS policy, 10 AS priority, 'REJECT'::text AS result
FROM app.applicants
WHERE sanctioned_jurisdiction

UNION ALL

SELECT applicant_id, 'high_risk_industry', 20, 'SENIOR_REVIEW'
FROM app.applicants
WHERE high_risk_industry AND annual_revenue > 10000000

UNION ALL

SELECT applicant_id, 'large_account', 40, 'STANDARD_REVIEW'
FROM app.applicants
WHERE annual_revenue > 2000000;
```

SQL still expresses the policy predicates. pg-react would add a decision object that says how candidates are resolved: lowest numeric priority wins, ties are forbidden, and every applicant must have exactly one result. That small amount of first-class semantics turns a query into a policy system.

## Why it is useful

Decision tables make policy **reviewable**. A compliance officer can look at the candidate policies and precedence rather than reading control flow in a service. They make policy **testable** because overlap and coverage can become explicit validation gates. They make policy **explainable** because the engine can say “three policies matched; `sanctioned` won at priority 10.” They also make policy changes safer because preview can show which business keys would change winners before a deployment is committed.

This feature also fits pg-react's philosophy unusually well. PostgreSQL remains responsible for relational truth. pg-react does not need a mini-language containing `>`, `<`, `IN`, ranges, strings, dates, and custom functions. The candidate relation already contains the results of normal SQL. pg-react only needs to own the part SQL does not naturally preserve as a durable rule-engine contract: identity, versioning, deterministic winner selection, lifecycle transitions when the winner changes, and finite explanation.

## What it would take to support in pg-react

The safest first implementation would introduce an explicit **decision program** or a decision mode over a maintained candidate relation. A declaration would identify the subject semantic key, candidate identity, priority column, and result columns. The contract would freeze whether lower or higher numeric priority wins, whether ties are errors, whether a default candidate is required, and what happens when a previously valid decision becomes ambiguous. Ambiguity should almost certainly be a claim-barriered error rather than an arbitrary tie-break.

Internally, pg-react would maintain one winner identity and result per subject key at a complete frontier. A candidate appearing, disappearing, changing priority, or changing result would recompute only the affected subject. A winner change should be a normal durable lifecycle transition: old winner out, new winner in, with no false transition when candidate maintenance changes but the winner remains the same. `explain` should show the winner, its priority, the bounded set of competing candidates relevant to the result, and any rejected ambiguity. Preview should be able to compare current and proposed decision versions and report keys whose winners would change.

The hard parts are not the selection query; they are deployment and recovery semantics. The candidate schema and priority/result types must be fingerprinted. Replacement must not expose half-old, half-new decisions. Dump/restore and direct upgrade must preserve winner identity. Retention must preserve enough evidence to explain why a historical winner changed. Resource limits are needed if one subject can produce an unbounded number of candidates. The first milestone should therefore be deliberately narrow: one candidate relation, one subject key, one scalar priority, deterministic single-winner semantics, bounded explanation, no scoring ensembles, and no general decision-table expression language.

---

# 2. Effective-dated rules

## The problem users actually have

Business policy changes on business dates, not just on deployment dates. Tax rules begin on January 1. An insurance rate filing becomes effective on October 15. A promotional policy runs from Black Friday through Monday night. A regulation applies to transactions executed after a statutory deadline. An enterprise contract has one entitlement policy this year and another after renewal.

Without first-class effective dates, teams solve this in awkward ways. They deploy application code at midnight. They add `CURRENT_DATE` predicates to many SQL views. They keep future rules disabled and rely on an operator to flip a switch. They edit the existing rule in place, losing a clean distinction between “when we deployed this version” and “when the business says this version applies.” All of these approaches work until auditability, recovery, time zones, or delayed execution matter.

A mature rule engine should be able to answer two different questions precisely: **when was this rule version installed?** and **for what business-time interval is this rule version authoritative?**

## A practical example

Suppose a lending company changes its affordability policy on January 1, 2027. Applications submitted before that instant use the 2026 policy; applications submitted after it use the 2027 policy. The company wants to deploy and validate the new rule in December, run what-if analysis against recent applications, and be confident that the old rule remains authoritative until the effective boundary.

The desired model is conceptually simple:

```text
affordability_policy v12
valid: [-infinity, 2027-01-01T00:00:00Z)

affordability_policy v13
valid: [2027-01-01T00:00:00Z, +infinity)
```

At the boundary, pg-react should move from one version to the next deterministically. Restarting PostgreSQL at 00:00:03 must not change the result. A physical restore performed later must reproduce the same business-time decision. Preview should detect if the two intervals overlap or leave a gap.

## Why it is useful

Effective dating makes rule changes **planned rather than operationally timed**. Teams can deploy future policy safely during business hours, review the exact definition, and let a durable logical clock determine when it becomes applicable. It provides a clean audit trail: “this was the version deployed on December 10, but it became business-effective on January 1.” It also enables backtesting and what-if analysis because rule versions have an explicit temporal scope rather than merely a Git commit or deployment timestamp.

This is especially valuable in regulated environments, but it is not a niche feature. Pricing, entitlements, promotions, SLAs, tax, fraud thresholds, staffing rules, and customer contracts all have effective periods. The alternative is usually application-specific date logic repeated across policies, which is precisely the sort of policy complexity users expect a rule engine to manage.

## What it would take to support in pg-react

pg-react already has two foundations that make this feature much less exotic than it might appear: immutable rule/program versions and a database-time deadline model. The clean implementation would use a **monotone logical database-time frontier**, not ad hoc calls to wall-clock time scattered through rule evaluation. Each version could declare a canonical half-open validity interval such as `[valid_from, valid_to)`. Deployment would validate that intervals for the same logical policy obey the chosen overlap and gap rules.

The first contract decision is whether effective time applies to **evaluation time** or to an event's business timestamp. Those are different features and should not be conflated. A simple first milestone should use pg-react's database-time frontier: when the complete logical time reaches `valid_from`, the version becomes eligible; when it reaches `valid_to`, it becomes ineligible. Event-time policy selection for historical events can be layered later with backtesting or window semantics.

Version transitions must be atomic with lifecycle state. If version A stops being effective and version B begins, the engine needs a frozen policy for existing active matches and pending work. A sensible default is that truth is re-evaluated under the newly effective version, while already-created external work retains the immutable version identity under which it was requested. That matches pg-react's existing emphasis on immutable work and honest delivery guarantees.

Public APIs should make the distinction visible. `status` should show deployed version, current effective version, next transition, and any gap/overlap error. `preview` should show the future schedule and the keys that would change if a version became effective at a supplied logical time. `explain` should include the rule version and effective interval that governed the result.

Recovery tests are essential. A crash immediately before and after the effective boundary, a delayed coordinator run, a physical restore, and a direct upgrade must all converge to the same effective state. This should be a relatively contained feature if it stays focused on version eligibility and does not expand into arbitrary event-time retroactivity.

---

# 3. Parameterized rule families

## The problem users actually have

Real policies repeat. A fraud threshold differs by country. A credit limit depends on customer tier. A reorder point differs by warehouse and SKU class. An SLA varies by support plan. A compliance threshold changes by legal entity. The underlying logic is often identical; only a small set of values changes.

Without parameterized rules, users either duplicate rule definitions or hide parameters in arbitrary application tables that the rule engine does not understand. Duplication causes a management problem: one policy change becomes 300 edits, rule counts explode, explanations become noisy, and accidental divergence is almost guaranteed. Treating parameters as ordinary data is better, but users still want the rule engine to understand that “these 500 tenant thresholds are instances of the same policy family,” especially for validation, preview, explanation, and deployment.

The useful feature is therefore not text substitution or a template language. It is **one typed rule definition evaluated against a versioned or authoritative parameter relation**.

## A practical example

Consider suspicious payment detection. The company uses one conceptual rule:

```text
flag a transfer when amount > threshold for the customer's risk segment
```

The thresholds are data:

```text
LOW       25,000
MEDIUM    10,000
HIGH       2,500
```

A PostgreSQL-native definition can already express this with a join:

```sql
CREATE VIEW rule_def.suspicious_transfer AS
SELECT t.id, t.customer_id, t.amount, p.threshold
FROM app.transfers t
JOIN policy.risk_thresholds p
  ON p.segment = t.risk_segment
WHERE t.amount > p.threshold;
```

That is good. A first-class rule-family feature should **preserve exactly that relational character** rather than replace it with placeholders like `${threshold}`. The added value is to declare `policy.risk_thresholds` as a typed parameter source whose keys, values, versioning, ownership, and policy-family relationship are visible to pg-react.

## Why it is useful

Parameterized families reduce both operational and conceptual scale. Five hundred customer-specific policies can remain one rule definition plus five hundred parameter rows. The policy's logic can be reviewed once. Parameter values can be changed with normal PostgreSQL data operations and audited independently. `explain` can say “this rule matched because tenant 42's configured threshold was 7,500,” rather than merely showing that a generated copy of rule 317 matched.

This is also one of the best ways to make a rule engine useful to business-facing systems without becoming a no-code engine. The structure of the policy remains engineering-owned SQL. Business-specific variation can live in ordinary typed tables with normal permissions, constraints, review workflows, and audit history.

## What it would take to support in pg-react

The critical design decision is to treat parameters as **facts, not mutable hidden rule definition**. A parameter change should therefore participate in normal relational maintenance. If a threshold changes from 10,000 to 8,000, matches that cross the new threshold should activate or deactivate through the same lifecycle machinery as any other input change. pg-react should never silently mutate a compiled predicate in place.

A parameter-family declaration could identify a parameter relation, its semantic key, required value columns and types, and the program or rule versions allowed to consume it. Validation would enforce key uniqueness, non-nullability where required, supported types, ownership, and dependency structure. The relation itself should remain ordinary PostgreSQL data so that users can join it naturally.

What pg-react adds is the policy envelope around that relation. `preview` could show which current matches would change for a proposed parameter update. `explain` could identify the exact parameter row and value that contributed to a decision. Rule packs could deploy a rule definition and an initial parameter dataset atomically when desired. Replacement semantics would distinguish a new definition version from ordinary parameter changes. Security would need to answer whether authors may change logic while a separate policy role may change parameter values.

A good first milestone should avoid a templating system, arbitrary JSON parameters, and per-instance generated rules. Start with typed relational parameters, one or more explicitly declared parameter inputs, normal PostgreSQL joins, and bounded evidence identifying the parameter keys used by a result. The implementation lift is mostly in validation, explanation, preview, deployment policy, and authorization rather than in a new inference algorithm.

---

# 4. What-if and hypothetical evaluation

## The problem users actually have

Once rules become important, users immediately want to ask questions without changing production truth. “Would this customer qualify if their income were 10% higher?” “If we lower this fraud threshold, how many additional transactions would be reviewed?” “What rules would fire if this inventory transfer were posted?” “What happens to derived facts if we remove this entitlement?”

Application code can answer such questions only if teams build a second, parallel implementation of the policy logic. That is dangerous: the simulator and the production engine drift apart. A rule engine becomes dramatically more valuable when the exact same semantics that make live decisions can also produce a **side-effect-free hypothetical result**.

The defining promise is simple: **evaluate a bounded set of hypothetical fact changes against a specific rule/program version and logical time, return the resulting matches, facts, decisions, and would-be lifecycle changes, but commit nothing and execute no consequences.**

## A practical example

A loan officer is reviewing an application that currently fails affordability. Before asking the customer for additional documentation, the officer wants to know what would happen if verified monthly income were 500 higher and one debt were removed.

A useful API might conceptually look like:

```sql
SELECT *
FROM pgreact_api.simulate(
    target       => 'policy.affordability',
    overrides    => :typed_fact_changes,
    sampled_time => '2027-02-03 12:00:00+00'
);
```

The result should not merely say `true` or `false`. It should show that the affordability fact would become true, that the application would move from `MANUAL_REVIEW` to `AUTO_APPROVE`, which supports would change, and which command rules *would* request work if this were a real transaction. No task should actually be queued and no action should run.

## Why it is useful

What-if evaluation turns the rule engine from a background automation mechanism into a **decision service that humans and applications can interrogate safely**. It supports customer-service tools, approval screens, policy design, debugging, automated tests, and impact analysis. It also makes policy changes less frightening: teams can preview concrete consequences rather than reasoning abstractly about a changed SQL predicate.

For pg-react specifically, simulation would strengthen one of the project's most compelling ideas: the deployed policy and the explanation tooling are two views of the same semantics. A simulator should not be a separate evaluator with “close enough” behavior. It should be an isolated execution of the same normalized program and transition rules.

## What it would take to support in pg-react

This is more difficult than the previous features because ordinary PostgreSQL views are wired to real relations. A hypothetical evaluator must give those views alternate facts without mutating authoritative tables or accidentally running application triggers. The project should resist the tempting but unsafe design of opening a transaction, modifying real tables, invoking arbitrary user code, and rolling everything back.

A safer first slice would define a **bounded simulation boundary**. Only declared authoritative fact interfaces or derived relations that pg-react knows how to shadow would be overridable. The simulator would create isolated temporary or internal shadow state, apply typed inserts/updates/deletes, run the same dependency-ordered evaluation logic against that state, and discard it. Command consequences would be represented only as deterministic “would activate/change/deactivate” intents.

The current validation and preview machinery can be reused, but simulation needs stronger isolation guarantees. It must never mutate durable pg-react catalogs, leases, attempts, watermarks, or external outboxes. Security checks must be at least as strict as live evaluation because hypothetical data may still expose sensitive derived information. Resource limits are important because users will naturally try large scenario sets.

Deterministic time must be explicit. For database-time rules, callers should supply a sampled logical time within allowed bounds. For event-time/windowed rules, a later version of simulation may need supplied watermarks and timed input. That should be added only after the simpler current-state simulation is exact.

The testing burden is significant but conceptually clean: for every supported simulation, applying the same fact changes to an isolated real database copy and running normal pg-react should produce byte-equivalent public truth, explanation, and would-be lifecycle state. The simulator itself must leave the original database unchanged.

---

# 5. Historical replay and backtesting

## The problem users actually have

What-if analysis asks, “what happens to this case if I change these facts?” Backtesting asks a broader and extremely practical question: **“what would this rule set have done over historical reality?”**

Fraud teams want to know how many past transactions a new rule would have flagged. Compliance teams want to test a proposed policy against last year's cases. Pricing teams want to measure how a new classification would have distributed customers. Operations teams want to know whether a new alert policy would have produced ten alerts a day or ten thousand. Without backtesting, a rule change is judged from hand-picked examples and intuition.

This is one of the strongest reasons organizations adopt dedicated rule systems. They want policy to be changeable, but safe change requires empirical impact analysis.

## A practical example

A fraud team proposes:

```text
flag if:
  amount > 5,000
  AND account age < 7 days
  AND at least 3 failed login attempts occurred in the previous hour
```

Before enabling it, they want to replay 90 days of historical events and compare the proposed version with the currently deployed version. Useful output includes how many additional cases would activate, which existing cases would disappear, the distribution by customer segment, and representative explanations for changed decisions.

A good backtest should be able to say:

```text
Current policy:   8,421 review activations
Proposed policy: 10,106 review activations
Added:            2,011
Removed:            326
Unchanged:        8,095
```

More importantly, a developer should be able to drill into one changed case and receive the same sort of explanation they would receive from the live engine.

## Why it is useful

Backtesting closes the loop between rule authoring and real-world consequences. It reduces rollout risk, gives stakeholders quantitative evidence, and creates a disciplined workflow for policy changes. In regulated settings it can become part of the approval record. In operational systems it prevents a seemingly harmless rule edit from creating a queue storm.

It also differentiates a real rule platform from “SQL plus triggers.” SQL can of course query historical data, but reproducing lifecycle semantics, recursion, negation, temporal windows, refraction, and rule-version behavior consistently across historical changes is much harder than running a query.

## What it would take to support in pg-react

Backtesting should be built **on top of a trustworthy simulation/replay kernel**, not as a separate evaluator. The first hard boundary must also be explicit: pg-react cannot replay history it never received or retained. It should not quietly become a CDC archive or event broker. Historical facts must come from a user-provided snapshot/event relation, retained application history, or a separately managed event source.

A backtest declaration would identify the rule/program version, initial fact snapshot, ordered historical deltas or snapshots, and the logical time/event-time schedule. Consequences must never execute. Instead, the engine records hypothetical lifecycle events and derived states in an isolated backtest namespace or returns them as a finite result.

For current-state rules, the simplest implementation can replay a deterministic sequence of inserts, updates, and deletes through the same transition planner used by live maintenance. For deadline rules, the replay must advance the sampled database-time frontier explicitly. For M17-style event-time rules, the fixture must include event timestamps and watermark progression; otherwise “late” versus “on-time” behavior cannot be reproduced honestly.

Performance matters much more here than for single-scenario simulation. A backtest over millions of events cannot return every internal support row to the client. The contract needs bounded result modes: aggregate comparison metrics, changed semantic keys, and on-demand explanation for selected cases. Exact reproducibility requires a frozen ordering contract, deterministic seeds where applicable, versioned normalized inputs, and checksummed output summaries.

The strongest correctness gate is again equivalence: replaying the same history through a clean isolated database using normal pg-react semantics should produce the same final state and lifecycle transcript as the backtest engine. No “fast approximate mode” should be presented as authoritative unless it has a separately named contract.

---

# 6. Reusable and shared conditions

## The problem users actually have

As a rule set grows, the same business concept appears everywhere. “High-risk customer” is used by fraud, payments, onboarding, and credit rules. “Inventory shortage” feeds replenishment, customer messaging, and escalation rules. “Account delinquent” affects billing, entitlements, collections, and support priority.

If each rule embeds its own copy of the condition, two problems emerge. First, teams duplicate computation. Second, and more importantly, they duplicate **meaning**. Six slightly different definitions of “high-risk customer” begin to drift, and no one knows which one is canonical.

Users naturally want to name these concepts once and make them first-class inputs to several rules.

## A practical example

A bank might define:

```sql
CREATE VIEW policy.high_risk_customer AS
SELECT customer_id, risk_score, country
FROM app.customer_risk
WHERE risk_score >= 80;
```

Then several rules want to use it:

```text
high-risk customer + transfer > 10,000       -> manual payment review
high-risk customer + new device              -> step-up authentication
high-risk customer + overdue loan            -> collections escalation
```

The important request is not merely “let three SQL views reference another SQL view.” PostgreSQL already does that. The request is to make `high_risk_customer` a **managed policy condition** with one identity, one maintenance lifecycle, one owner, one version history, one explanation boundary, and several explicit consumers.

## Why it is useful

Shared conditions make large rule systems comprehensible. They create a vocabulary of domain concepts instead of a forest of duplicated predicates. They can reduce maintenance work, but the bigger benefit is governance: “this is the canonical definition of a high-risk customer.”

They also improve explainability. A user can understand “payment review is active because `high_risk_customer` and `large_transfer` are true” far more easily than a single enormous SQL view containing all underlying predicates.

## What it would take to support in pg-react

The current roadmap already points toward explicit shared conditions, and the word **explicit** is important. pg-react should not begin by automatically detecting common SQL subplans and sharing them. Automatic common-subexpression discovery creates difficult ownership, lifecycle, cost, and upgrade questions. The safer model is a named maintained condition that authors intentionally declare and rules intentionally consume.

A shared condition needs immutable version identity, a schema and typed semantic key, source/dependency fingerprints, ownership and grants, maintenance status, and consumer references. Rules should depend on the condition's public relation rather than its private storage. Replacing a shared condition must atomically move compatible consumers or require an explicit pack deployment. Removing it must be blocked while active consumers depend on it unless the same atomic deployment removes or replaces them.

The dependency graph becomes more important. pg-react already has strata and program dependency ordering; shared conditions should fit into that graph rather than create a second scheduling mechanism. A condition's complete frontier must never outrun its inputs, and consuming rules must not observe partially replaced state.

`status` should show the condition and its consumers. `explain` should preserve the abstraction: “rule X is active because shared condition Y matched,” with optional deeper evidence when requested. Cost and resource diagnostics are also useful because one shared condition may fan out to hundreds of rules.

The first milestone should support explicit sharing only, one maintained condition version at a time, no automatic CSE, no cross-database sharing, and no hidden lifecycle effects of its own. It should remain a named truth relation that makes policy composition clearer.

---

# 7. Practical temporal rules

## The problem users actually have

Many business rules are not simply “is this true?” They are “has this been true long enough?”, “did this happen within a period?”, “has something failed to happen by a deadline?”, or “do not react again too soon.” These are ordinary operational policies, not exotic complex-event processing.

Examples appear everywhere:

- an invoice has been overdue for 7 days;
- a server has been unhealthy continuously for 10 minutes;
- a customer made 3 failed login attempts within an hour;
- no payment arrived within 30 days after invoice issue;
- a verification request was sent but no response arrived within 24 hours;
- after sending an alert, suppress another alert for 15 minutes;
- an account recovered for at least 5 minutes before closing the incident.

Without first-class temporal semantics, users hand-build timers, timestamp columns, scheduled jobs, and state flags around otherwise simple predicates. The result is often more complicated than the rule itself.

## A practical example

Consider alerting for an inventory shortage. Reacting the instant stock briefly dips below a threshold creates noise, so the business wants:

```text
If available stock remains below reorder level for 10 continuous minutes,
create a replenishment escalation.

If stock recovers, close the condition.

After an escalation, do not create another escalation for the same SKU
for 30 minutes.
```

The current truth `available_stock < reorder_level` is easy SQL. The value of the rule engine is to add **duration and refraction over time** without forcing the author to build a timer subsystem.

A second example is absence:

```text
When an invoice is issued, payment must arrive within 30 days.
If no qualifying payment exists by the deadline, derive overdue(invoice_id).
```

Again, SQL can say whether payment exists. The difficult part is the durable transition at the correct logical time, including restart and recovery.

## Why it is useful

Practical temporal rules eliminate a large class of ad hoc background jobs and application schedulers. They make time-based policy explicit and explainable. Instead of an operator asking “which cron job marks invoices overdue?”, the answer becomes “this rule has a 30-day deadline and the payment condition remained absent.”

This feature also makes pg-react substantially more attractive for monitoring, fraud, billing, SLA, entitlement, and compliance systems. These domains often need modest temporal reasoning, but they do not need a general CEP language.

## What it would take to support in pg-react

The best strategy is to **split temporal semantics into a few small, composable primitives** rather than announce “CEP support.”

The first primitive is **duration / stable-for** using the database-time frontier already established by deadline semantics. When a keyed condition becomes true, pg-react can record a due time such as `activated_at + 10 minutes`. If the condition remains true when the monotone logical clock reaches the due time, a derived temporal condition becomes true. If the underlying condition retracts first, the pending deadline disappears. This is essentially a disciplined combination of lifecycle identity and deadlines.

The second primitive is **absence by a deadline**. A triggering fact establishes a deadline; a lower-stratum positive relation represents the thing that would satisfy it. At the deadline, pg-react may derive an “absent” condition only if the satisfying fact remains absent. This can reuse stratified negation and deadline machinery, but it needs an exact race contract for a payment arriving at the same logical boundary.

The third primitive is **cooldown / temporal refraction**. After an activation or completed consequence, a semantic key is ineligible for another activation of a particular policy until a durable logical time. This sounds simple but must be distinguished from the existing continuous-truth generation model. The engine needs to specify whether changes during cooldown are ignored, coalesced, or remembered for reevaluation when the cooldown ends.

The fourth primitive is **rolling frequency**, such as “3 failures in an hour.” M17's fixed tumbling windows do not fully solve rolling windows, so this likely requires hopping/sliding windows or another bounded window representation. That should be a separate milestone with explicit state and resource bounds.

Only after those foundations are proven should pg-react consider a bounded **sequence** primitive such as “A then B within 10 minutes.” Sequence semantics introduce durable partial matches and begin to resemble CEP. They can still be kept understandable if restricted to a small finite state machine over named conditions, with one semantic key, fixed deadlines, bounded history, and no arbitrary pattern language.

Across all of these features, pg-react must make the time domain explicit. Database-time deadlines, event-time windows, and wall-clock execution latency are different things. The public API and explanations should say which clock governs a temporal rule, what frontier is complete, what deadline/window applies, and why a transition happened. That precision is more important than having many temporal operators.

---

# 8. Explainable provenance: “why is this true?”

## The problem users actually have

A rule engine earns trust when it can answer **why**. Not merely “rule `fraud_review` is active,” but “it is active because this transfer is above the threshold, the customer is in the high-risk segment, that segment came from these derived facts, and this exact rule version was effective when the decision was made.”

As rule sets grow, ordinary SQL visibility is not enough. A user may be able to inspect every table and view, but reconstructing the causal chain manually is slow and error-prone. This matters in debugging, but it matters even more in customer support, audits, compliance review, policy design, and incident response.

The most useful provenance is not an infinite proof tree. It is a **bounded, typed explanation of the supports that actually made a durable fact or decision true**.

## A practical example

Suppose a customer is denied an automatic refund. The decision is derived from several layers:

```text
refund_requires_review(customer, order)
    because high_value_order(order)
    and high_risk_customer(customer)

high_risk_customer(customer)
    because chargeback_count_90d(customer) >= 3

chargeback_count_90d(customer) = 4
    based on windowed aggregate evidence
```

A useful explanation should let an operator traverse that chain without exposing private internal identifiers:

```text
Decision: MANUAL_REVIEW

Why:
- Order 8127 is high value: amount 4,850 > threshold 4,000.
- Customer 42 is high risk.
- Customer 42 is high risk because chargeback_count_90d = 4.
- The policy threshold is 3.
- The relevant aggregate window is complete through 2026-08-13T18:00Z.
- Policy version: refund_policy/v7.
```

That is far more useful than dumping every internal support row, component ID, frontier, and correction identity.

## Why it is useful

Explainability is a reason to use a rule engine rather than simply a debugging feature added afterward. When policy is explicit, people expect the system to explain decisions in policy terms. Better provenance reduces support time, makes audits tractable, and makes complicated rule sets safer to change.

It also improves developer experience. If a derived fact unexpectedly disappears after a rule edit, a bounded explanation showing which support vanished is often enough to find the problem immediately.

## What it would take to support in pg-react

pg-react already has much of the conceptual foundation: durable supports, finite evidence, stable semantic keys, aggregate evidence, and unified explanation APIs. The next step should be **bounded support provenance**, not arbitrary SQL lineage.

For authoritative source relations, evidence should identify the relation version and stable business key, not physical tuple locations such as `ctid`. For derived facts, evidence can point to the support identity and the semantic keys of the contributing lower facts. For negation, evidence should explain the tested absence and the stable lower stratum/frontier at which it was valid. For aggregates and windows, evidence should remain summarized: group key, aggregate value, threshold, window bounds, completeness/finality, and correction frontier rather than a list of every contributing row.

The hardest contract is cardinality. A fact may have thousands of valid supports, and recursive programs may contain cycles. Explanation must therefore be explicitly bounded: perhaps the first N canonical supports, a count of additional supports, stable cycle markers, maximum depth, and a continuation token for advanced inspection. “Finite” should remain a product guarantee.

Security is equally important. Provenance can leak values the caller is not otherwise allowed to see. Public explanation should respect the existing reader/advanced-reader boundaries and should reveal stable domain values only when authorized. The implementation must also decide what evidence retention is necessary for historical explanation and which pruning operations are forbidden while evidence remains within the published recovery/explanation horizon.

A useful staged approach is to prioritize **why true** and **why changed** before attempting general **why not**. “Why is this fact absent?” can require exploring a huge search space of missing joins and unsatisfied alternatives. A bounded why-not facility may eventually be valuable, but it is a much more ambitious feature than recording the actual supports of facts that exist.

---

# How these features should fit the pg-react philosophy

The easiest way to damage pg-react would be to add these features by building a second language on top of PostgreSQL. Decision tables could become an expression DSL. Parameterized rules could become string templates. Temporal rules could become a bespoke pattern syntax. Simulation could become a separate evaluator. Provenance could expose a private internal graph as the normal API. Each of those choices would solve an immediate feature request at the cost of the project's most distinctive advantage: a PostgreSQL developer can still understand what is true by reading SQL and inspecting normal typed objects.

A better design rule is:

> **SQL should continue to produce facts, candidates, and relationships. pg-react should add durable semantics where SQL alone does not define enough behavior.**

For decision tables, that means SQL produces candidates while pg-react owns winner identity and ambiguity policy. For effective dates, SQL definitions stay unchanged while pg-react owns version eligibility over a monotone time frontier. For parameterized families, parameters remain typed rows and joins rather than template substitutions. For simulation and backtesting, the live normalized semantics are executed in isolation rather than reimplemented. For shared conditions, PostgreSQL relations remain the reusable truth boundary. For temporal features, small explicit timing contracts extend existing lifecycle and window semantics. For provenance, pg-react records bounded support evidence in business-key terms instead of promising magical arbitrary-query lineage.

Several cross-cutting requirements should remain non-negotiable for every feature. A new capability must have stable semantic identity, deterministic behavior across equivalent input orderings, atomic replacement, exact failure rollback, recovery and dump/restore behavior, direct-upgrade evidence, bounded resource use, role-checked public inspection, and a finite explanation. If a feature cannot satisfy those properties yet, it should remain a roadmap direction rather than become production code.

---

# A practical implementation sequence

These capabilities do not all need to arrive at once, and some have natural dependencies. A sensible sequence would optimize for useful business-policy features while keeping each semantic jump narrow.

### Phase 1: make policy reusable and governable

Start with **shared conditions**, **parameterized rule families**, and **effective-dated versions**. These solve ordinary policy-management problems without introducing a new inference model. They also make later capabilities easier: a decision table can consume shared conditions and parameters, and backtesting becomes much more meaningful when rule versions have explicit effective intervals.

### Phase 2: make policy decisions first-class

Add **decision tables / deterministic winner semantics** using SQL-produced candidate relations. This gives pg-react a powerful and familiar business-rule abstraction while remaining PostgreSQL-native. The key is to own precedence, ambiguity, lifecycle, and explanation rather than predicate syntax.

### Phase 3: make policy safe to change

Build **what-if evaluation** and then **historical backtesting** on the same isolated evaluation kernel. These capabilities should be treated almost as correctness features: if users can safely see the consequences of a policy change before deployment, the system becomes much easier to trust.

### Phase 4: deepen explanation

Add **bounded support provenance** as a natural extension of the existing support/evidence model. This can happen earlier if real users demand it, because better explanation amplifies the value of every other feature.

### Phase 5: widen temporal semantics carefully

Expand from existing deadlines and event-time windows into **stable-for duration, absence-by-deadline, cooldown, rolling frequency, and only then bounded sequences**. Avoid presenting this as “general CEP.” Every temporal primitive should have one clear clock, one bounded state model, and one understandable explanation.

---

# What success would look like

A strong future pg-react should let an ordinary PostgreSQL team tell a story like this:

> “Our eligibility policy is a versioned PostgreSQL program. The rule becomes effective next month. Thresholds vary by customer segment through a typed policy table. Several rules reuse the same maintained concept of an active customer. A decision table chooses one eligibility class when multiple candidates match. Before deploying a change we simulate representative cases and backtest it over six months of historical data. When support asks why a customer was rejected, `explain` shows the winning decision and the bounded chain of facts that supported it. Time-based rules such as ‘unpaid for 30 days’ or ‘three failures within an hour’ use explicit database-time or event-time semantics rather than hidden cron jobs.”

That is recognizable as a rule engine, but it still sounds like PostgreSQL. There is no mysterious agenda language, no second truth store, no opaque policy bytecode, and no requirement that ordinary users understand internal frontiers, support IDs, worker protocols, or correction machinery.

That is the direction in which these features are most valuable. They are not impressive because they make pg-react more theoretically expressive. They are impressive because they make real policy **easier to state, safer to change, possible to test, and straightforward to explain**.
