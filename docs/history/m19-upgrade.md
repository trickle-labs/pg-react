# M19 upgrade

Install the `0.16.0` extension files, then run:

```sql
ALTER EXTENSION pg_react UPDATE TO '0.16.0';
```

The supported direct path is `0.15.0 -> 0.16.0`. Existing rules and programs
remain `SCHEDULED`; no declaration is automatically converted to immediate
maintenance. Validate and explicitly opt in through the M19 public APIs after
the upgrade.

The executable populated path is `tests/m19-upgrade-before.sql` followed by
`tests/m19-upgrade-after.sql`, orchestrated by
`tests/m19.sh complete pg-react:v0.16.0`.
