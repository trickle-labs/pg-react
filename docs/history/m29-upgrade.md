# M29 upgrade

The supported direct upgrade is `0.25.0 -> 0.26.0`:

```sql
ALTER EXTENSION pg_react UPDATE TO '0.26.0';
```

The migration adds policy-set catalogs, façade dispatch for `policy_set`, and
public inspection views. It does not rewrite existing rules, derived facts,
decision state, work, or applicability sources. Take the normal verified backup
first, then run the complete M29 gate and the inherited M0–M28 gates.
