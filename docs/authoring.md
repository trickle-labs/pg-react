# Authoring rules and policies

[How-to guides](how-to/index.md) · [SQL reference](api-reference.md)

Use this guide when you are ready to turn an application requirement into a pg-react declaration. It assumes the **0.46.0 core profile** is installed and that you have completed [Your first rule](getting-started.md), or already have equivalent condition relations and permissions. The ordinary workflow is to construct a declaration, validate it, preview the proposed operation, deploy the reviewed result, and inspect the public state. You can use that same workflow for rules, decisions, and policy sets.

## Choose the right kind of declaration

Start by writing the question your policy answers. A rule answers whether a condition is true for each business subject. A decision chooses among candidate results for a subject. A policy set defines which subjects participate in a related group of rules or decisions. These questions complement one another: an order may be eligible for a policy, fail to match its review condition, and still have routing candidates available.

| You need to… | Use |
| --- | --- |
| Retain which subjects currently satisfy a condition | A `CONSTRAINT` rule. |
| Create durable work when a condition activates, changes, or deactivates | A `COMMAND` rule with typed consequences. |
| Choose a result from relational candidates | A decision declaration. |
| Apply related declarations to an eligible population | A versioned policy set. |

## Define a stable condition and identity

Give the condition a schema-qualified relation name and project the values your consequence needs. For the ordinary rule path, use one non-null, unique `bigint` semantic key. Choose a business identifier that remains stable when ordinary attributes change; using a changing amount or status as identity would make the same business subject appear to be a different match.

The first tutorial's `rule_def.high_value_risky_order` is a complete example. Inspect it directly while developing a policy, and verify the key assumptions with queries such as these:

```sql
SELECT order_id, customer_id, amount
FROM rule_def.high_value_risky_order
ORDER BY order_id;

SELECT order_id, count(*)
FROM rule_def.high_value_risky_order
GROUP BY order_id
HAVING order_id IS NULL OR count(*) > 1;
```

The second query must return no rows. A join can accidentally multiply keys even when the underlying table has a primary key, so check the result of the condition rather than relying only on its source table's constraints. Advanced typed-key interfaces have a different boundary; they do not widen the ordinary rule codec or rule comparison.

## Record a condition without executing consequences

A constraint declaration needs only a name, condition, and semantic key. It records match state but has no consequence functions. The word constraint here describes policy state; it does not mean that PostgreSQL will reject an application write as a `CHECK` constraint would.

```sql
SELECT pgreact.validate(pgreact.rule(
    name         => 'risk-observation',
    condition    => 'rule_def.high_value_risky_order'::regclass,
    semantic_key => 'order_id'::name,
    kind         => 'CONSTRAINT'
));
```

Expect a `ready` validation result before previewing and deploying this declaration. If validation returns `attention`, inspect the findings and fix the named field or source first. Constructing and validating a declaration does not create a running rule.

## Attach typed consequences to a command

Set `kind => 'COMMAND'` whenever a declaration names a consequence. Activation and deactivation functions take the activation context and one condition row; change functions take the context, the old row, and the new row. PostgreSQL checks those types through the exact `regprocedure` identity, so use the row type of the condition relation in the declaration.

| Event | Function arguments | Typical application effect |
| --- | --- | --- |
| Activation | `pgreact.activation_context`, condition row | Open a review task or write an outbox request. |
| Change | `pgreact.activation_context`, old condition row, new condition row | Revise the task while retaining the same activation generation. |
| Deactivation | `pgreact.activation_context`, condition row | Close or withdraw the task according to your application's rules. |

The first tutorial supplies `rule_action.open_review`. To update that same task on a watched change, you can add this database-local function after completing the tutorial:

```sql
CREATE FUNCTION rule_action.update_review(
    context pgreact.activation_context,
    old_match rule_def.high_value_risky_order,
    new_match rule_def.high_value_risky_order
)
RETURNS void
LANGUAGE SQL
BEGIN ATOMIC
    SELECT rule_action.open_review(context, new_match);
END;
```

Now validate a proposal that watches the amount and attaches the change function. This is a replacement proposal for the tutorial's existing rule, so use [Changing policies safely](changing-policies.md) to compare and deploy it rather than editing the active rule's stored definition.

```sql
SELECT pgreact.validate(pgreact.rule(
    name         => 'manual-review-required',
    condition    => 'rule_def.high_value_risky_order'::regclass,
    semantic_key => 'order_id'::name,
    kind         => 'COMMAND',
    on_activate  =>
      'rule_action.open_review(pgreact.activation_context,rule_def.high_value_risky_order)'::regprocedure,
    on_change    =>
      'rule_action.update_review(pgreact.activation_context,rule_def.high_value_risky_order,rule_def.high_value_risky_order)'::regprocedure,
    change_columns => ARRAY['amount']::name[],
    max_attempts => 3,
    initial_backoff_seconds => 1
));
```

Every attempt must be safe to repeat. Use the context's idempotency key or the appropriate activation/generation/revision identity, and keep irreversible network calls outside a typed database consequence. An outbox can commit a delivery request with the database transaction; the external consumer still needs to deduplicate delivery.

## Choose watched changes and bootstrap behavior

With `change_columns` omitted or `NULL`, all projected non-key columns are watched. A named subset limits which changes create change events; an explicit empty array watches no columns. Every named column must be projected by the condition, and the semantic key cannot also be a watched column. Unwatched values can still update the current bindings, so a newer binding alone does not prove that a change consequence ran.

`SEED_CURRENT`, the default bootstrap policy, records existing matches as current state without treating them as new activation work. Use `REQUIRE_EMPTY` when deployment should fail if the condition already contains rows. Neither option is an instruction to replay all existing business activity. If you need an initial migration of application tasks, plan that migration explicitly and verify its relationship to the rule's starting state.

## Preview and deploy the exact proposal

A preview tells you whether the operation will add, keep, or replace an object and which checks must pass. Extract the review token from a successful preview, retain it with the exact declaration you reviewed, and pass both to `pgreact.deploy`. The compact CTE pattern in [Your first rule](getting-started.md#6-validate-preview-and-deploy-the-rule) demonstrates the call shape, while [Changing policies safely](changing-policies.md) explains comparison and replacement.

For a declaration with default time arguments, choose and retain an explicit `valid_from` before reviewing it. Reconstructing a decision with a new `clock_timestamp()` can change the declaration even when its visible business fields look unchanged. A stale or mismatched token is a reason to review the new proposal; it is not a reason to bypass the precondition.

A command replacement with eligible old work requires an explicit `DRAIN_OLD` or `CANCEL_OLD` choice. Draining and cancelling answer different business questions, so decide what should happen to already-created work before deployment. Immutable policy-set versions likewise need a deliberate new version identity when their declaration changes.

## Choose among candidates with a decision

A decision's source relation projects a subject, candidate identity, numeric priority, and result columns. The lowest priority wins. Equal best priorities produce `AMBIGUOUS`, and a previously tracked subject that loses its candidates can remain visible as `NO_CANDIDATE`. These states are useful policy outcomes to handle in your application, rather than errors to hide by arbitrarily selecting a row.

The order-review package creates `rule_def.review_candidates`. With that package's schema loaded, this declaration describes its routing decision:

```sql
SELECT pgreact.validate(pgreact.decision(
    name               => 'order-review-route',
    candidate_relation => 'rule_def.review_candidates'::regclass,
    subject_key        => 'order_id'::name,
    candidate_key      => 'reviewer_id'::name,
    priority           => 'priority'::name,
    results            => ARRAY['queue_name']::name[],
    valid_from         => '2026-08-20 12:00:00+00'::timestamptz,
    max_candidates     => 1000
));
```

Use a deliberate effective time for your own policy, then validate, preview, and deploy the same declaration. Follow the complete [decision chapter](order-review-tutorial.md#8-route-reviews-with-a-decision) to see winner, ambiguity, and no-candidate behavior with known fixture rows.

## Group declarations with applicability

A policy set combines rule and decision members with a relation describing eligible subjects. Its immutable version belongs to the policy package, and its applicability is a separate question from each member's match condition. For example, an open customer may be eligible for a review policy while none of that customer's orders currently requires review.

Use typed `pgreact_api.declaration[]` values for members and explicit `subject_keys` for the applicability relation. Packages can also include shared-condition and parameter-family support declarations plus declared dependencies. If a package adopts an already-deployed child, inspect the preview's `ADOPT` result and supply the required exact child identity; pg-react does not silently take ownership of an unrelated deployment.

The [policy applicability chapter](order-review-tutorial.md#9-limit-the-policy-with-applicability) includes a complete working declaration. The [SQL reference](api-reference.md#pgreactpolicy_set) gives both the basic and package signatures, and [Advanced use](explanation/advanced-use.md) explains when a package is worth introducing.

## Inspect the result and continue

After deployment, check the named target and the view appropriate to its kind. For command rules, inspect work and attempts as well as matches; the condition becoming true and its consequence finishing are separate observations. The [operations guide](operations.md) provides the queries and recovery procedures you will use once the policy is running.

```sql
SELECT pgreact.status('manual-review-required');
SELECT pgreact.explain('manual-review-required');
SELECT * FROM pgreact.work
WHERE name = 'manual-review-required'
ORDER BY updated_at DESC NULLS LAST, work_id;
```

Keep declaration specifications and consequence definitions under version control. They are reviewable application assets and part of your recovery plan. Private `pgreact_internal` and `pgreact_runtime` objects remain implementation details; use [Reference](reference/index.md) when you need a documented administrative or advanced surface.
