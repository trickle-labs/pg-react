# pg-react 0.42.0: put a policy change in one safe package

This release gives you one named version for a group of rules and decisions.
You can check the whole change, see what will happen, deploy it as one unit,
and move it between databases without losing its meaning.

## What you can do now

- Group rules, decisions, shared conditions, and parameter definitions in one
  policy set.
- Give every package a stable name, immutable version, canonical digest, and
  explicit applicability period.
- Declare dependencies and get clear errors for missing endpoints, duplicates,
  self-links, cycles, and oversized packages.
- Preview `ADD`, `KEEP`, `REPLACE`, `ADOPT`, and `REMOVE` actions before a write.
- Deploy or remove the package atomically with a stale-plan check.
- Inspect package contents and dependencies with ordinary SQL views.
- Export a portable package and import it only when its digest matches.
- Use the names-first explanation helpers for why-not, trace, comparison,
  semantic difference, evidence, summaries, and capabilities.

## What stays the same

Existing rule, decision, work, evidence, validation, comparison, and
explanation calls keep their compatibility contracts. Package metadata never
replaces authoritative source rows or evidence rows.

## Upgrade

Back up the database, install `0.42.0`, and run:

```sql
ALTER EXTENSION pg_react UPDATE TO '0.42.0';
```

The adjacent supported upgrade is `0.41.0` to `0.42.0`. Restore a verified
`0.41.0` backup if you need to roll back. See [the migration guide](m53-migration.md).

## Next decision

The next milestone is chosen from the adoption blocker found in release use:
rolling or hopping windows (M45), authorization alignment (M58), or supported
scale qualification (M59). M55 schema-change safety and M56 rebuild safety
take priority if either is found to be unsafe.
