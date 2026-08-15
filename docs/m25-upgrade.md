# M25 upgrade

Install the `0.22.0` extension files, then run:

```sql
ALTER EXTENSION pg_react UPDATE TO '0.22.0';
```

The supported direct path is `0.21.0 -> 0.22.0`. The migration creates the
parameter-family catalogs, public views, validation and authorization APIs,
and does not invent families or parameter rows for existing M24 policies.

To adopt M25, declare a family over an existing ordinary table, grant value
editors if needed, and bind or author a policy version through the public API.
Existing rules continue unchanged until an operator explicitly creates and
binds a parameterized policy version.
