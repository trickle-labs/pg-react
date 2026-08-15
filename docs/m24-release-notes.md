# pg-react 0.21.0 - policy changes that start on the right date

Version `0.21.0` adds effective-dated policy versions.

In everyday terms, a business rule can now be prepared before it is needed.
For example, you can deploy next quarter's pricing rule today, set its start
date to July 1, and check that it is ready. It stays asleep until pg-react's
committed database clock reaches July 1. The old rule then stops and the new
one starts at one recorded boundary.

The release also:

- uses `[valid_from, valid_to)` intervals, so a rule starts exactly at its
  start date and stops just before its end date;
- rejects overlapping, empty, backwards, infinite, and retroactive intervals
  instead of guessing which rule should win;
- keeps future versions out of active matches and executable work;
- supports complete derivation-program definitions as dormant policy versions,
  materializing them through the existing program coordinator at the boundary;
- records which policy version created each lifecycle event and work item;
- preserves the existing PostgreSQL-native rule, worker, retry, recovery,
  security, retention, and at-least-once delivery contracts.

Upgrade directly from `0.20.0`:

```sql
ALTER EXTENSION pg_react UPDATE TO '0.21.0';
```

The logical next milestone is M25 — Parameterized policy families. It should
let one policy version use typed PostgreSQL parameter rows for tenants,
regions, products, or customer tiers without copying the rule.
