# M28 upgrade

The supported direct upgrade is `0.24.0 -> 0.25.0`:

```sql
ALTER EXTENSION pg_react UPDATE TO '0.25.0';
```

The migration adds declaration and target types, façade metadata, public
inspection, and ordinary verb overloads. It does not rewrite existing rules,
derived facts, temporal state, decision programs, analyses, grants, or work.

Take the normal verified backup first. After upgrading, run the complete M28
gate and compare the M0–M27 inventory and representative specialized results.
Downgrade is not supported; restore the pre-upgrade backup if rollback is
needed.
