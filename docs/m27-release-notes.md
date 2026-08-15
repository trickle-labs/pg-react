# pg-react 0.24.0 — review decisions before they go live

M27 adds a planned review step for M26 decision programs. Before a proposed
version is deployed, an operator can compare it with an explicitly declared
finite population and candidate catalog at one complete database frontier.

The review can point out:

- subjects that have no proposed candidate;
- candidates in the catalog that never apply;
- more than one candidate where overlap is forbidden;
- tied best candidates;
- required defaults that are missing; and
- a winner distribution that changes more than the configured limit.

Each finding includes its seriousness, whether it blocks deployment, the
affected count, a bounded sample of evidence, and a suggested remediation.
The report also shows exact current and proposed winner counts and changes by
candidate. Evidence is consistently ordered and says when it was shortened.

The review is a snapshot, not a prediction engine. It describes the recorded
frontier and fingerprints only; later data changes can make it stale. It does
not read SQL predicates, invent test facts, simulate every per-subject
lifecycle change, or analyze unrelated programs. Deployment must reject a
failed or stale blocking review before it changes durable policy or work state.

Upgrade directly from `0.23.0`:

```sql
ALTER EXTENSION pg_react UPDATE TO '0.24.0';
```

This documentation and release metadata do not certify the runtime
implementation. Publish `v0.24.0` only after the M27 readiness gates and all
inherited M0–M26 evidence pass. The next planned milestone is M28, which adds
policy-set gating.
