# Why pg-react Should Exist

## A product thesis for a PostgreSQL-native rule and reaction engine

Modern applications already contain rule engines. Most of them simply do not call themselves that.

They live in `if` statements scattered across services, scheduled jobs that wake up every few minutes, triggers that encode one narrow reaction, background workers that retry failed work, and SQL queries that identify exceptional states someone must remember to watch. A customer crosses a risk threshold. An invoice becomes overdue. An employee changes role and should lose one entitlement while gaining another. A payment fails to reconcile with a settlement. A security exception expires. A contractual obligation passes its deadline. A legal hold appears and data that was eligible for deletion must suddenly be retained.

The business logic in these cases is often easy to express. The hard part is turning changing truth into durable, explainable, operational behavior.

That is why pg-react should exist.

pg-react can become the layer between **what PostgreSQL knows to be true** and **what an organization needs to do about it**. Its value is not that it invents another rule language. PostgreSQL already has one of the most expressive and widely understood languages for describing relational truth: SQL. pg-react should add the things a query alone does not provide—stable identity, lifecycle, refraction, retries, durable work, reasoning state, time, recovery, versioning, and explanation—while keeping PostgreSQL authoritative.

A query can tell you that an invoice is overdue now. It does not remember when the invoice first became overdue, whether an escalation was already created, whether the invoice briefly became current and later became overdue again, or whether a worker crashed after claiming the escalation. A query can show that a user has conflicting roles. It does not, by itself, maintain the durable history of that conflict, reopen the finding when it returns, or explain which policies produced the decision.

pg-react should turn those fleeting query results into durable business state without forcing every application to build its own policy runtime.

## The real product is durable truth in motion

The strongest pg-react use-cases share the same shape. Something in the database becomes true, remains true for a while, changes in an important way, or stops being true. That truth has business meaning, and the organization needs its lifecycle remembered.

Consider reconciliation. An order exists, a payment exists, a bank settlement arrives, and the ledger records an entry. Usually they agree. Sometimes they do not. A conventional system runs reconciliation SQL, writes mismatches into an exception table, has another job age them, another process escalate old exceptions, and still another path close them when the underlying data changes. The difficult part is not the join. It is preserving the identity and lifecycle of the mismatch.

With pg-react, the mismatch itself can remain relational truth. When it appears, pg-react creates one durable activation. While it remains unresolved, its age and severity can change without creating duplicate cases. When the data reconciles, the condition disappears and the activation closes. If the mismatch returns later, that is a new lifecycle generation rather than an accidental resurrection of stale work.

The same pattern applies to data-quality defects, financial controls, SLA breaches, security drift, identity deprovisioning failures, and expired policy exceptions. This is a much more interesting product than “database triggers, but nicer.” It is a durable reaction layer for relational state.

## PostgreSQL should remain the authority

Traditional rule engines often require applications to extract facts from their database, translate them into another representation, submit them to a separate runtime, and synchronize the result back into operational state. That can make sense when facts live across many systems, but when PostgreSQL already contains the authoritative facts, a second truth store creates costs that are easy to underestimate.

Data must be copied. Identity must be translated. Types lose fidelity. Permissions need to be recreated. Transactions acquire awkward boundaries. Recovery now has to reconcile two durable systems. The rule engine may think a decision is true while PostgreSQL has already committed something different.

pg-react should make the opposite bet: **if PostgreSQL owns the facts, keep the rules close to the facts.**

Conditions should remain ordinary PostgreSQL relations. Keys should be typed PostgreSQL values. Actions should be explicit PostgreSQL functions or transactional outbox operations. Time should be represented through durable database-time and event-time contracts rather than hidden process clocks. Explanations should use business keys rather than opaque engine identifiers. Security should inherit PostgreSQL ownership, schemas, roles, and execution semantics.

This makes the system easier to trust because developers can still inspect it with ordinary database tools. Sophisticated reasoning does not require abandoning the PostgreSQL mental model.

## The best use-cases are operational, not exotic

pg-react does not need exotic inference to justify its existence. Some of the most valuable applications are ordinary business controls.

A finance team needs to detect duplicate invoices, out-of-period journals, approval-limit violations, and segregation-of-duties breaches. A privacy team needs to know when customer data becomes eligible for deletion, except while a legal hold is active. An IAM system needs to derive what access an employee should have from employment status, role, region, contract, and separation-of-duties policy, then create provisioning or revocation work when reality diverges from desired state. A security team needs to detect configuration drift, respect approved exceptions, expire those exceptions, and reopen findings when systems regress. An operations team needs to track contractual deliverables and escalate obligations that remain missing beyond a deadline.

These are rule-engine problems because the policy is relational, changes over time, and should be separated from the application code that happens to observe it.

The attractive thing is that the same pg-react primitives can serve all of them. A maintained condition represents current truth. A stable semantic key identifies the business entity. Lifecycle state remembers whether that condition is new, changed, resolved, or recurring. Derivation builds higher-level concepts from lower-level facts. Deadlines and event-time windows make time explicit. Durable jobs connect decisions to action. Explanation makes the result inspectable. Reconciliation and recovery keep the engine honest after crashes, restores, upgrades, and drift.

The product thesis is not “support every kind of rule.” It is “make this recurring operational pattern safe, composable, and understandable.”

## Policy should be easier to change than application code

One of the strongest reasons organizations adopt rule engines is that business policy changes on a different cadence than applications.

Thresholds change. Entitlements evolve. Contracts renew. Regulations become effective on specific dates. Finance introduces a new approval matrix. Security changes its baseline. Risk teams experiment with classifications. If every policy change requires editing application control flow, rebuilding services, coordinating deployment windows, and rediscovering hidden dependencies, the organization becomes afraid to change policy.

A useful rule engine makes policy a first-class artifact that can be validated, previewed, versioned, explained, tested, and deployed deliberately.

That is why features such as effective-dated rules, parameterized rule families, decision tables, what-if evaluation, and historical backtesting matter. They answer the questions people ask before changing policy: Which version applies on January 1? Which policy wins if several conditions match? What happens if we change this threshold? Which decisions would change under the proposed rule set? What would this policy have done against the last six months of data? Why did this customer receive this outcome?

A pg-react that can answer those questions using the same semantics that run in production becomes more than an automation engine. It becomes a policy operating layer inside PostgreSQL.

## Explanation is part of correctness

A rule engine that cannot explain itself becomes harder to trust as it becomes more capable.

If a financial control blocks a journal, someone should be able to see why. If an entitlement is revoked, the system should identify the policy and facts that caused it. If a reconciliation exception remains open, the operator should see the mismatch and its age. If a derived fact exists because of several lower-level facts, the engine should expose a bounded causal chain in business terms.

The key word is **bounded**. pg-react should not promise magical arbitrary SQL lineage or infinite proof trees. It should record and expose enough stable evidence to explain the semantics it supports: business keys, rule version, aggregate or window evidence, derived supports, absence conditions, deadlines, and lifecycle transitions.

This is not merely debugging. In financial controls, access governance, privacy, compliance, and customer support, explanation is part of the business requirement.

## pg-react must resist becoming everything

If the project succeeds, users will ask for synchronous authorization, workflow orchestration, arbitrary HTTP calls, optimization, complex-event processing, visual authoring, fuzzy logic, global ordering, and ever more powerful firing loops. Some requests may justify carefully bounded features. Many should remain outside the core.

pg-react should derive and maintain entitlement truth, but it does not need to become the network authorization proxy for every request. It can determine priority and eligibility for scarce inventory without becoming a mathematical optimization solver. It can request deletion after a retention rule becomes valid without hiding destructive external effects inside rule evaluation. It can support practical temporal rules without turning into an unrestricted CEP language. It can maintain durable business reactions without becoming a general human workflow platform.

The principle should be simple: **add semantics when they make relational business policy safer and more understandable; resist adjacent product categories when they blur that model.**

## The destination

The strongest version of pg-react would let a PostgreSQL developer describe business truth with normal SQL, promote important concepts into durable rules and derived facts, attach explicit actions when necessary, and trust the database to preserve the lifecycle correctly across concurrency, failure, recovery, and policy change.

A finance team could say, “these are our controls.” An IAM team could say, “this relation is the desired entitlement state, and pg-react keeps reality converging toward it.” A compliance team could ask why a case was flagged. A risk team could backtest a new policy before deployment. An operator could see that a condition has remained unresolved for three days and is now escalated. A developer could inspect the same facts and explanations with ordinary SQL.

The internal engine may eventually contain sophisticated machinery: dependency strata, supports, frontiers, corrections, windows, watermarks, workers, retries, and recovery state. The user should not need to think in those terms most of the time.

That is the real test of the product.

pg-react should exist because PostgreSQL already knows an enormous amount about the state of a business, but businesses need more than queries. They need changing truth to become **durable decisions, explainable state, and reliable work**.

If pg-react can provide that while remaining recognizably PostgreSQL, it occupies a rare and valuable place: not another workflow engine, not another stream processor, not another proprietary rules language, but a native way to make relational business policy live.
