# M21 upgrade

Install the `0.18.0` extension files, then run:

```sql
ALTER EXTENSION pg_react UPDATE TO '0.18.0';
```

The supported direct path is `0.17.0 -> 0.18.0`. Retention remains disabled
by default after upgrade. Review status and diagnostics before configuring a
policy or applying any batch.
