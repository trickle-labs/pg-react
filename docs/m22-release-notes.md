# pg-react 0.19.0 — bounded support provenance

M22 records the typed bindings that sustain each existing derived support and
exposes a finite, role-checked proof through `pgreact_api`. Proofs have stable
ordering, exact counts, grounded/cycle/truncated/unavailable markers, and
snapshot-checked continuation. Existing scheduled, immediate, retention,
recovery, and external-effect semantics are unchanged.

Upgrade directly from `0.18.0`:

```sql
ALTER EXTENSION pg_react UPDATE TO '0.19.0';
```

M23 — Practical temporal conditions — is the next planning milestone.
