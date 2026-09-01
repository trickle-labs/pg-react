# v1 deprecations

> Historical record for the prepared v1 candidate. Use current
> [Deprecations](deprecations.md) for pg-react `0.43.0`.

No installed public routine is scheduled for removal in `1.0.0` merely to
reduce the API surface. The exact routine-by-routine classification is not yet
complete, so this page does not invent deprecation status from naming alone.

| Surface | Current status | Guidance |
| --- | --- | --- |
| Ordinary constructors, verbs, views | Current, not deprecated | Use for new application code. |
| `pgreact.compare`, `compare_results`, `pgreact_api.target` | Current, not deprecated | Use to compare a proposal with a deployed target. |
| Supported advanced families | Current advanced | Use only with their advanced contracts and role requirements. |
| Older `pgreact_api` facades and legacy public wrappers | Compatibility candidates; installed and retained | Existing callers may continue; new ordinary code should use `pgreact`. |
| Worker, recovery, reconciliation, retention, and repair routines | Administrative, not deprecated merely because they are uncommon | Invoke only through the documented operational procedure. |
| `pgreact.export` and `pgreact.import` | Classification unresolved | Do not present as ordinary until RC classification is complete. |
| Private schemas, catalogs, generated dispatchers | Non-API | Never use for application integration or manual repair. |
| Historical milestone and `0.1.1` “v1” documents | Historical | Do not interpret as the `1.0.0` API contract. |

## Deprecation policy

A future deprecation must:

1. identify the exact typed function, view, type, field, or behavior;
2. provide a supported replacement and migration guidance;
3. preserve the old surface for an announced transition period;
4. state the earliest release in which removal may occur;
5. update the exact installed inventory and qualification tests.

Removal or incompatible ordinary semantic change requires a future major
release unless required to correct a security or data-integrity defect. A
contract-affecting correction must be disclosed and requalified.

Until exhaustive RC classification is complete, “legacy” means “not the
recommended ordinary teaching path”; it does not by itself mean “formally
deprecated” or “scheduled for removal.”
