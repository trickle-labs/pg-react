# pg-react 0.27.0 — make policy-set eligibility clear and durable

M30 is the applicability foundation. In ordinary language: it records **who a
policy set is meant for** in small, searchable PostgreSQL rows instead of one
large JSON list.

## What changed

- Policy matches and eligible subjects now have explicit, ordered identities.
  A rule can match an `order_id` while eligibility is decided by that order's
  `customer_id`.
- New declarations use `match_keys`, `subject_keys`, and the explicit
  `POLICY_SET_REQUIRED` scope mode.
- The supported key types are `bigint`, `uuid`, and `text` with the stable
  `C` collation. Composite keys of up to four parts are supported.
- Eligibility is stored relationally and indexed. Public views show the
  subject values, identity, source fingerprint, and complete frontier.
- Status, explanation, and diagnostics now show the foundation state,
  migration state, and runtime barriers.
- Existing M28 and M29 data is preserved and classified. Nothing becomes
  policy-set-gated just because the extension is upgraded.

## What this release does not do

M30 does not yet make eligibility create or remove rule activations, lifecycle
events, or work. It does not execute consequences. Those are the purpose of
M31 — Authoritative runtime — and must be proven before they are promised.
M30 also does not add simulation, replay, backtesting, nested policy sets, or
a new policy language.

## Upgrade

Upgrade directly from `0.26.0`:

```sql
ALTER EXTENSION pg_react UPDATE TO '0.27.0';
```

This repository commit prepares `v0.27.0`. After the complete M30 release gate
passes, push the commit to `main`, then create and push tag `v0.27.0` to start
the release workflow. Treat the release as published only after the workflow
verifies the packaged image, checksums, SBOM, provenance, OCI digest, and
upgrade evidence.

The next milestone is M31 — Authoritative runtime.
