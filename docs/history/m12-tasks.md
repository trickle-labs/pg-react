# M12 deadline tasks

In `0.9.0`, describe candidates with a normal view whose deadline is a direct
stored `timestamptz` value:

```sql
CREATE VIEW rule_def.invoice_deadline AS
SELECT invoice_id, due_at, account_id, amount
FROM billing.invoice
WHERE state = 'OPEN';

SELECT code, severity, message, hint
FROM pgreact_api.validate_deadline_rule(
    condition => 'rule_def.invoice_deadline'::regclass,
    semantic_key => 'invoice_id',
    deadline_column => 'due_at',
    on_activate => 'rule_action.mark_overdue(
        pgreact.activation_context,rule_def.invoice_deadline)');

SELECT pgreact_api.author_deadline_rule(
    rule_name => 'invoice-overdue',
    condition => 'rule_def.invoice_deadline'::regclass,
    semantic_key => 'invoice_id',
    deadline_column => 'due_at',
    kind => 'COMMAND',
    on_activate => 'rule_action.mark_overdue(
        pgreact.activation_context,rule_def.invoice_deadline)');
```

Run `pg-reactd` through its existing coordinator connection. Each pass samples
PostgreSQL time, atomically advances the durable clock, refreshes the selected
rule through explicit differential maintenance, then claims and executes work.
Downtime delays observation; the next pass catches up without duplicating it.

After inserting, deleting, advancing, or postponing a source deadline, refresh
the named rule. Pause, resume, repair, replace, remove, observe, and explain by
name:

```sql
SELECT pgreact_api.run_rule('invoice-overdue');
SELECT pgreact_api.pause_rule('invoice-overdue');
SELECT pgreact_api.resume_rule('invoice-overdue');
SELECT pgreact_api.reconcile_rule('invoice-overdue');
SELECT pgreact_api.rule_status('invoice-overdue');
SELECT pgreact_api.deadline_history('invoice-overdue');
SELECT pgreact_api.explain_rule('invoice-overdue');
SELECT pgreact_api.health();
```

Postponing an active deadline produces a deactivation. If the new deadline is
later reached, a new activation generation begins. Pausing preserves current
truth and work; resuming catches up at the committed database clock.

Use `replace_deadline_rule` to change the condition or deadline declaration.
Pause a drained constraint rule before `remove_rule`. For command rules, follow
the existing drain-or-cancel work policy. Retain all returned diagnostic
fields when a declaration or operation is rejected.

For recovery, stop coordinators and workers, take the tested physical backup,
restore or promote it with the unchanged supported tuple, verify `health()`,
then resume. Do not run a coordinator on a standby. External consumers must
continue deduplicating the at-least-once idempotency key.
