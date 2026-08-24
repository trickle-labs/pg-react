# M19 compact tasks

Author:

1. Run `validate_immediate_rule` or `validate_immediate_program`.
2. Record the preview and plan digest.
3. Call the matching explicit immediate author/deploy operation.
4. Use `matches`, `status`, and `explain` inside a `READ COMMITTED` transaction.

Operator:

1. Run `doctor()` after deployment and after restart or restore.
2. Keep rejected declarations scheduled and follow the returned hint.
3. Use the public replacement, reconciliation, recovery, and upgrade paths;
   never edit generated stream tables or private catalogs.
