# M24 contract - effective-dated policy versions

M24 is extension `0.21.0`, with a direct upgrade from `0.20.0`. It gives one
named policy immutable rule or complete derivation-program versions with
business-effective intervals. The
interval is canonical half-open `[valid_from, valid_to)`: the start belongs to
the new version and the end does not.

## Public API

```sql
pgreact_api.validate_effective_policy(
    policy_name text, rule_version_id uuid,
    valid_from timestamptz, valid_to timestamptz DEFAULT NULL
) RETURNS TABLE (...)

pgreact_api.author_effective_rule(
    policy_name text, rule_name text, condition regclass, semantic_key name,
    valid_from timestamptz, valid_to timestamptz DEFAULT NULL,
    ... inherited rule and retry options ...
) RETURNS uuid

pgreact_api.author_effective_policy(
    policy_name text, rule_name text, condition regclass, semantic_key name,
    valid_from timestamptz, valid_to timestamptz DEFAULT NULL,
    ... inherited rule and retry options ...
) RETURNS uuid

pgreact_api.validate_effective_program(
    policy_name text, definition jsonb,
    valid_from timestamptz, valid_to timestamptz DEFAULT NULL
) RETURNS TABLE (...)

pgreact_api.author_effective_program(
    policy_name text, definition jsonb,
    valid_from timestamptz, valid_to timestamptz DEFAULT NULL
) RETURNS uuid

pgreact_api.deploy_effective_policy(
    policy_name text, rule_version_id uuid,
    valid_from timestamptz, valid_to timestamptz DEFAULT NULL
) RETURNS uuid

pgreact_api.effective_policy_status(name text DEFAULT NULL) RETURNS jsonb
pgreact_api.effective_policy_preview(name text DEFAULT NULL) RETURNS jsonb
pgreact_api.effective_policy_history(name text) RETURNS jsonb
pgreact_api.effective_policy_explain(name text, semantic_key bigint) RETURNS jsonb
pgreact_api.effective_policy_doctor() RETURNS jsonb
pgreact_api.reconcile_effective_policy(name text) RETURNS bigint
pgreact_api.pause_effective_policy(name text) RETURNS void
pgreact_api.resume_effective_policy(name text) RETURNS void
pgreact_api.remove_effective_policy(name text) RETURNS void
```

`author_effective_rule` creates an ordinary immutable pg-react rule version,
keeps it dormant, and schedules it. `author_effective_program` validates and
stores an immutable derivation-program definition without activating it;
the existing derivation coordinator materializes its program version only at
the effective boundary. `deploy_effective_policy` schedules an already-created
rule version. A future version has no active matches, derived facts, or
executable work before `valid_from`.

The coordinator samples the committed database-time frontier once. At the
first frontier equal to `valid_from`, the new version becomes authoritative.
At `valid_to`, it stops being authoritative. Adjacent versions share the
boundary without a gap. Overlaps, empty intervals, inverted intervals,
non-finite timestamps, and retroactive proposals are rejected.

When authority changes, old active matches are withdrawn and pending old work
is marked `SUPERSEDED`; leased work remains subject to the existing fresh
eligibility check. New matches and work are created in the same transaction.
Completed work keeps its original immutable rule-version identity.

M24 does not rewrite historical facts, redo completed consequences, infer
priorities for overlapping intervals, or add a calendar, timer service,
template language, decision table, parameter family, or policy-set DSL.
