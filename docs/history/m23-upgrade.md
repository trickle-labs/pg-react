# M23 upgrade

Install the `0.20.0` extension files, then run:

```sql
ALTER EXTENSION pg_react UPDATE TO '0.20.0';
```

The supported direct path is `0.19.0 -> 0.20.0`. The migration adds only the
temporal declaration, indexed state, history, trigger, and public API layer.
Existing rules, activations, episodes, attempts, provenance, retention state,
clock frontier, grants, and pending work remain in place. No temporal event is
created during upgrade; declare and reconcile new temporal rules after the
upgrade.
