# pg-react 0.22.0 — one rule, different values

M25 makes it easier to run the same business rule for many tenants, regions,
products, or customer tiers.

In everyday terms, you can keep the rule itself in one SQL view and keep the
changing values in a normal PostgreSQL table. For example, a pricing view can
join an order to a `pricing_parameters` table. Changing one customer's limit
changes that customer's match through the normal pg-react lifecycle; it does
not copy the rule or rewrite its SQL.

This release adds:

- typed parameter-family declarations with a stable `bigint` key;
- required scalar value columns, uniqueness checks, row limits, and schema-drift diagnostics;
- separate authorization for policy logic and parameter values;
- atomic authoring of a policy version together with its initial parameter rows;
- side-effect-free preview, public explanation, status, history, and doctor APIs;
- ordinary insert, update, and delete auditing, with inherited refresh, lifecycle, agenda, worker, and recovery behavior;
- a direct populated upgrade from `0.21.0`.

M25 intentionally does not add templates, placeholder substitution, generated
per-tenant rules, arbitrary JSON parameters, decision tables, or a new client
language. PostgreSQL still owns the condition, and pg-react still owns durable
state and asynchronous work.

Upgrade directly from `0.21.0`:

```sql
ALTER EXTENSION pg_react UPDATE TO '0.22.0';
```

Tag and publish `v0.22.0` only after the complete M25 release gate passes.
The logical next planning milestone is M26 — Decision tables.
