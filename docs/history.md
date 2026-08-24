# Historical and milestone documentation

Milestone documents are retained as historical records and qualification
evidence. Older records may describe superseded APIs, runtime models, support
claims, or release sequencing.

Current users should start at [Documentation Home](index.md) and follow the
canonical v1 guides. Immutable historical records must not be interpreted as
current installation, authoring, upgrade, recovery, or operations
instructions.

## Milestone documentation

- M0-M30 records preserve the incremental delivery history under `docs/history/m*-*`.
- [M31 release notes](history/m31-release-notes.md) preserve the authoritative-runtime
  predecessor milestone.
- [M32 API reference](history/m32-api-reference.md) preserves the PostgreSQL-native
  interface milestone.
- [M33 release notes](history/m33-release-notes.md) preserve the `0.30.0`
  qualification baseline.
- [M34 release notes](m34-release-notes.md) and
  [contract](m34-contract.md) preserve the `0.31.0` comparison milestone.
- [`DESIGN.md`](../DESIGN.md) preserves the M13 architecture record.
- The old [`v1-release-notes.md`](history/v1-release-notes.md) and
  [`v1-upgrades.md`](history/v1-upgrades.md) preserve the historical M4 `0.1.1`
  release.

## Qualification evidence

- [M33 evidence](history/m33-evidence.md), [readiness](history/m33-readiness.md), and
  [final checklist](history/m33-final-checklist.md)
- [M34 evidence](m34-evidence.md), [readiness](m34-readiness.md), and
  [final checklist](m34-final-checklist.md)
- Preserved historical milestone inventories:
  - M33 / `0.30.0`: [API inventory](history/v1-api-inventory-m33-0.30.0.json), [Finding codes](history/v1-finding-codes-m33-0.30.0.json)
  - M34 / `0.31.0`: [API inventory](history/v1-api-inventory-m34-0.31.0.json), [Finding codes](history/v1-finding-codes-m34-0.31.0.json)

These records show what a milestone attempted or demonstrated. They do not
create an RC artifact, broaden support, or override installed behavior.
