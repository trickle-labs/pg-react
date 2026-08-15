# pg-react 0.17.0 — shared conditions

M20 adds explicitly named, versioned shared SQL conditions over the existing
keyed derived-relation and derivation-program engine. Conditions have typed
keys, immutable versions, source fingerprints, owners, explicit consumers,
bounded status/cost/explanation output, and removal blocking while in use.

Upgrade directly from `0.16.0`:

```sql
ALTER EXTENSION pg_react UPDATE TO '0.17.0';
```

Existing rules and programs remain scheduled unless explicitly deployed with
the M19 immediate contract. Automatic sharing and retention changes are not
included.
