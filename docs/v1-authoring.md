# v1 rule authoring

This guide describes the frozen `1.0.0` ordinary interface. The `0.1.1`
references in historical M4 evidence are not the current release contract.

v1 rules use an ordinary PostgreSQL view as the condition and optional typed PostgreSQL functions as consequences. The release supports constraint and command rules only; derivations, raw-query authoring, reusable conditions, and synchronous firing remain post-GA work. Extension `0.2.0` groups existing v1 rules into portable atomic deployments through the separate [M5 rule-pack contract](m5-rule-packs.md). See the [v1 contract](v1-contract.md) for the frozen single-rule signatures.

## 1. Create a condition view

The rule author must own the view. It must project exactly one semantic key column that is a non-null, unique `bigint`; the other projected columns are the consequence payload.

```sql
CREATE SCHEMA rule_def;
CREATE SCHEMA rule_action;

CREATE VIEW rule_def.overdue_invoice AS
SELECT i.id AS invoice_id, i.account_id, i.balance
FROM app.invoices AS i
WHERE i.status = 'OVERDUE';
```

Use a normal view, not a table or materialized view. RLS-protected sources and non-built-in executable dependencies are rejected. The query must also be maintainable by the pinned pg_trickle release in explicit `DIFFERENTIAL` mode.

## 2. Create typed consequences

Activation and deactivation functions receive `(pgreact.activation_context, view_row)`. Change functions receive `(pgreact.activation_context, old_view_row, new_view_row)`. They must be owned by the view owner and return `void`.

```sql
CREATE FUNCTION rule_action.open_collection(
    context pgreact.activation_context,
    match rule_def.overdue_invoice
) RETURNS void LANGUAGE SQL BEGIN ATOMIC
    INSERT INTO app.collection_tasks (activation_id, invoice_id, balance, active)
    VALUES ((context).activation_id, (match).invoice_id, (match).balance, true)
    ON CONFLICT (activation_id) DO UPDATE
      SET balance = EXCLUDED.balance, active = true;
END;

CREATE FUNCTION rule_action.update_collection(
    context pgreact.activation_context,
    old_match rule_def.overdue_invoice,
    new_match rule_def.overdue_invoice
) RETURNS void LANGUAGE SQL BEGIN ATOMIC
    UPDATE app.collection_tasks
    SET balance = (new_match).balance
    WHERE activation_id = (context).activation_id;
END;

CREATE FUNCTION rule_action.close_collection(
    context pgreact.activation_context,
    match rule_def.overdue_invoice
) RETURNS void LANGUAGE SQL BEGIN ATOMIC
    UPDATE app.collection_tasks
    SET active = false
    WHERE activation_id = (context).activation_id;
END;
```

Database consequences run in the episode transaction and may be retried. Make them idempotent using `(context).idempotency_key` or the stable activation/generation/revision fields. Never perform irreversible network work in a consequence.

## 3. Preview, validate, and register

```sql
SELECT * FROM pgreact.preview_rule(
  'rule_def.overdue_invoice'::regclass,
  ARRAY['invoice_id']
);

SELECT * FROM pgreact.validate_rule(
  'rule_def.overdue_invoice'::regclass,
  ARRAY['invoice_id'],
  'rule_action.open_collection(pgreact.activation_context,rule_def.overdue_invoice)'::regprocedure
);

SELECT pgreact.create_rule(
  name                 => 'overdue-invoice',
  definition           => 'rule_def.overdue_invoice'::regclass,
  key_columns          => ARRAY['invoice_id'],
  kind                 => 'COMMAND',
  on_activate          => 'rule_action.open_collection(pgreact.activation_context,rule_def.overdue_invoice)'::regprocedure,
  on_deactivate        => 'rule_action.close_collection(pgreact.activation_context,rule_def.overdue_invoice)'::regprocedure,
  on_change            => 'rule_action.update_collection(pgreact.activation_context,rule_def.overdue_invoice,rule_def.overdue_invoice)'::regprocedure,
  bootstrap_policy     => 'SEED_CURRENT',
  change_columns       => ARRAY['balance'],
  salience             => 0,
  agenda_group         => 'billing',
  conflict_key_columns => ARRAY['account_id'],
  max_attempts         => 3
) AS rule_version_id;
```

`SEED_CURRENT` records existing matches as active without firing consequences. Use `REQUIRE_EMPTY` when deployment must fail if the view already contains rows. If `change_columns` is omitted, every projected non-key column is watched. Salience affects selection order, but the fairness window prevents indefinite starvation; it is not a global execution order.

For a constraint rule, pass `kind => 'CONSTRAINT'` and no consequence functions. It exposes current matches but creates no worker work.

## 4. Inspect and exercise

Run the coordinator/worker from the [installation guide](v1-installation.md), then inspect only public APIs:

```sql
SELECT * FROM pgreact.current_matches('overdue-invoice');
SELECT * FROM pgreact.rule_status();
SELECT * FROM pgreact.agenda_status();
SELECT * FROM pgreact.execution_history();
SELECT pgreact.explain_rule('RULE_VERSION_UUID'::uuid);
```

Treat a deployed version as immutable. To change its view or functions, use `pgreact.replace_rule(..., 'DRAIN_OLD')` or `'CANCEL_OLD'`; do not edit private catalogs or mutate an active binding. Operational cutover procedures are in the [operations runbook](m3-operations.md).

## External effects

For a rule version created without a typed consequence for that event, create an idempotent transactional outbox function with signature `(pgreact.activation_context, jsonb) RETURNS void`, then bind it before the event occurs:

```sql
SELECT pgreact.bind_outbox_consequence(
  'RULE_VERSION_UUID'::uuid,
  'ACTIVATE',
  'app.enqueue_pgreact(pgreact.activation_context,jsonb)'::regprocedure
);
```

The sink insert and episode completion commit atomically. Delivery outside PostgreSQL remains at least once: consumers must deduplicate `idempotency_key`, tolerate replay, and must not assume ordering across independent rules or workers.
