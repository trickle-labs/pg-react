# v1 security

M33 freezes the security boundary. `PUBLIC` receives no unintended execution
privileges, private schemas remain inaccessible, and every security-definer
routine fixes its `search_path` to trusted schemas.

## Roles

- **Reader:** reads documented views and diagnostics.
- **Author:** owns the condition views and typed action functions it deploys.
- **Worker:** claims and executes already-authorized work; it cannot deploy
  arbitrary rules.
- **Operator:** performs documented coordination, recovery, and retention.

Authors cannot claim worker authority. Workers cannot deploy rules. Readers
cannot mutate state. Operators receive only the documented operational
authority.

## Required checks

The M33 security suite checks:

- exact function identity and schema-qualified object resolution;
- safe `SECURITY DEFINER` paths;
- owner checks through both ordinary and compatibility wrappers;
- no unintended `PUBLIC` grants;
- reader and worker mutation rejection;
- explanation and error redaction for protected evidence;
- explicit RLS rejection;
- declaration input cannot execute arbitrary SQL.

Use `pgreact.doctor()` and the public health views to diagnose a failed check.
Do not grant access to `pgreact_internal` or `pgreact_runtime`, and do not
repair a finding by editing either schema.
