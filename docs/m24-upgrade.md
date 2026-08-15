# M24 upgrade

Install the `0.21.0` extension files, then run:

```sql
ALTER EXTENSION pg_react UPDATE TO '0.21.0';
```

The supported direct path is `0.20.0 -> 0.21.0`. The migration adds the
effective-policy catalogs, public views, validation and transition APIs, and
does not invent policy versions for existing M23 rules. Existing rules keep
their current state and history until an operator explicitly schedules a new
effective policy version.
