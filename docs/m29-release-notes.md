# pg-react 0.26.0 — put policies in a named population

M29 adds policy sets. A policy set is a named group of policies plus one list
of eligible subjects. This is useful when the same rule applies to, for
example, customers in Norway, accounts in a pilot group, or products in one
market.

What changed:

- Define a policy set with the existing `define → validate → preview → deploy`
  workflow.
- Use a normal PostgreSQL table or view, or an M20 shared condition, as the
  eligibility list.
- Require a typed subject key, one non-null row per subject, and a complete
  source snapshot. Invalid or unavailable sources fail closed.
- Keep set versions immutable and use explicit effective dates, so a new
  rollout does not silently change an old one.
- Inspect members, eligible subjects, source fingerprints, effective dates,
  and bounded evidence through ordinary SQL views and the common result
  envelope.

Example upgrade:

```sql
ALTER EXTENSION pg_react UPDATE TO '0.26.0';
```

Existing M0–M28 APIs and stored policy data remain available. M29 does not add
a new rule language, nested policy sets, simulation, replay, or backtesting.

This repository commit prepares `v0.26.0`. After this commit is pushed to
`main`, create and push the `v0.26.0` tag to start the release workflow. Treat
the release as published only after that workflow verifies the image,
checksums, SBOM, provenance, OCI digest, populated upgrade evidence, and
complete inherited gates.

The logical next milestone is M30 — Applicability foundation: typed identities,
relational eligibility, explicit scope modes, migration classification, and
inspection. Authoritative runtime transitions remain a later milestone.
