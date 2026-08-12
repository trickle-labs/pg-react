# M13 ergonomic tasks

Create four deployment roles, then configure their exact facade grants as the
extension owner:

```sql
SELECT pgreact_api.configure_roles(
    'rule_author', 'rule_operator', 'rule_worker', 'rule_reader');
```

An author defines a normal condition view and a typed action in one explicit
application schema. Context is optional:

```sql
CREATE VIEW rule_def.open_invoice AS
SELECT invoice_id, account_id, amount
FROM billing.invoice
WHERE state = 'OPEN';

CREATE FUNCTION rule_action.notify(candidate rule_def.open_invoice)
RETURNS void LANGUAGE SQL AS $$
  INSERT INTO billing.notification(invoice_id, account_id, amount)
  VALUES (candidate.invoice_id, candidate.account_id, candidate.amount)
$$;

SELECT code, severity, message, hint
FROM pgreact_api.validate_rule(
    condition => 'rule_def.open_invoice'::regclass,
    semantic_key => 'invoice_id',
    action_schema => 'rule_action',
    on_activate => 'notify');

SELECT pgreact_api.author_rule(
    rule_name => 'notify-open-invoice',
    condition => 'rule_def.open_invoice'::regclass,
    semantic_key => 'invoice_id',
    action_schema => 'rule_action',
    on_activate => 'notify');
```

For a constraint, omit action arguments. For lifecycle commands, pass
`on_activate`, `on_deactivate`, and `on_change` names to the lifecycle overload;
use `NULL::name` for an unused slot. Change actions receive the old and new
condition rows. Use the explicit advanced overload only for uncommon bootstrap,
watch, agenda, conflict, or retry policy.

An operator runs every affected source, program, downstream rule, and deadline
through one call made as its own transaction:

```sql
SELECT pgreact_api.run();
SELECT pgreact_api.status('notify-open-invoice');
SELECT pgreact_api.matches('notify-open-invoice');
SELECT pgreact_api.jobs('notify-open-invoice');
SELECT pgreact_api.attempts('notify-open-invoice');
SELECT pgreact_api.explain('notify-open-invoice');
```

Give `pg-reactd` a worker `DATABASE_URL` and a separate operator
`COORDINATOR_DATABASE_URL`. The positional rule-version argument remains
accepted for protocol-2 batch selection, but every coordinator pass is
database-wide. A successful run means jobs are durably queued, not that their
actions have completed.

Use `rule_status`, `explain_rule`, and `deadline_history` when exact engine
history is required. Stop coordinators and workers before upgrade or physical
recovery, verify `health()`, reapply `configure_roles`, then resume. External
consumers must continue deduplicating the stable at-least-once idempotency key.
