# M5 evidence

The M5 implementation is extension `0.2.0` over the unchanged v1 compatibility boundary, worker protocol `1`, and outbox envelope `1`. `tests/m5.sh` is the complete executable artifact gate.

| Requirement | Authoritative evidence |
|---|---|
| Versioned pack over v1 constraint and command rules | `sql/pg_react--0.1.1--0.2.0.sql`; exact typed, constraint, and outbox manifests in `tests/m5-setup.sql` |
| Non-mutating validation and preview of actions, dependencies, incompatibility, generated objects, and lifecycle risk | `pgreact.validate_pack`, `pgreact.preview_pack`; exact outputs and error-code sets in `tests/m5-promotion.sql` and `tests/m5.sql` |
| Atomic catalog/generated-object/version deployment | Four injected phases (`catalog`, `rules`, `removals`, `activation`) compare exact public history and generated runtime object sets in `tests/m5.sql` |
| Missing, cyclic, invalidly ordered, unsafe, and incompatible definitions fail before durable mutation | Exact diagnostic arrays in `tests/m5.sql`; stale or failed attempts leave history unchanged |
| Apply-time revalidation | View DDL after preview produces the exact stale-plan error, followed by successful re-preview/deploy in `tests/m5.sql` |
| Concurrent deployment, source DDL, and consequence DDL | Lock-timeout races in `tests/m5-hold-deploy.sql`, `tests/m5-racing-deploy.sql`, and `tests/m5.sh`; exact committed history in `tests/m5-concurrency-result.sql` |
| Declared replacement/removal policy and immutable old binding | A leased v1 episode survives `DRAIN_OLD`, executes the exact v1 result after v2 activation, while new work executes v2; `CANCEL_OLD` removal is recorded exactly in `tests/m5.sql` |
| Portable second-environment promotion without private identifiers | One unchanged manifest deploys with `m5_dev` and `m5_prod` mappings in separate databases; public `definition_digest` values must match in `tests/m5.sh` |
| Public history, diagnostics, and recovery workflow | Exact `pack_history`/`explain_pack` assertions in `tests/m5.sql`; public-only workflow in `docs/m5-rule-packs.md` |
| Existing v1 behavior and direct upgrade | M0–M3 suites, v1 reference, physical recovery pilot, exact API inventory, and `0.1.1 -> 0.2.0` fixture all run in `tests/m5.sh` |

Local validation on 2026-08-09 passed:

```text
M0, M1, M1 scale, M2, M3 compatibility
M5 public API inventory
v1 reference and physical recovery pilot
M5 direct upgrade
M5 atomic acceptance and concurrency
M5 development-to-production promotion
```

The plan's external entry gate is not repository evidence. GitHub currently has no published `v0.1.1` release and no release-workflow run, so M5 cannot be declared release-ready or merged until that publication is completed and verified. See `docs/m5-readiness.md`.
