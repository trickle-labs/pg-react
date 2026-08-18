# v1 troubleshooting

Start with public diagnostics:

```sql
SELECT * FROM pgreact.health;
SELECT pgreact.doctor();
SELECT * FROM pgreact.rules ORDER BY name;
SELECT * FROM pgreact.work ORDER BY created_at DESC;
```

## Diagnose

- **Unsupported environment:** fix the PostgreSQL, pg_trickle, preload,
  isolation, architecture, or RLS condition named by `doctor()`.
- **Source or action drift:** restore the recorded object or deploy an
  explicit replacement; never edit the stored identity.
- **Blocked recovery:** keep workers stopped, complete the public
  reconciliation procedure, then verify health.
- **Failed work:** inspect `work`, `attempts`, and `explain`; repair the
  consequence and requeue only when replay is safe.
- **Stuck lease:** use the documented lease-recovery operation after verifying
  the worker is no longer running.

Every repair follows:

```text
observe -> diagnose -> repair prerequisite -> invoke public operation -> verify
```

Private catalog updates, deleting barriers, and manual UUID repair are never
supported fixes.
