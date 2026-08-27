# M35 known limitations

- A change set can name only direct tables or partitioned tables. Views and
  indirect dependencies fail closed.
- The identity is one non-null `bigint` column. Composite and non-`bigint`
  identities are not part of this release.
- Row images must contain every visible source column. M35 does not execute
  defaults, generated columns, triggers, cascades, volatile functions, or DML.
- Evidence is bounded. A partial result does not report exact delta counts.
- Source relation checksums detect a changed source during the call. M35 does
  not lock the source for a long-running simulation.
- M35 does not read or rebuild historical source data. M36 defines a separate
  caller-supplied historical replay boundary.
