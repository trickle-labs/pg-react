# M32 readiness

**Status: implementation metadata and documentation prepared; not release
ready.**

The package candidate is `0.29.0`, directly after M31 `0.28.0`. The CI and
release workflow keeps the inherited M31 complete lane while adding M32
identity, migration, API-inventory, and finding-inventory checks.

## Ready in this lane

- package and container defaults consistently identify `0.29.0`;
- the README teaches one names-first, task-first workflow;
- M32 contract, API reference, migration, support, evidence, and release
  records exist;
- machine-readable API classifications and stable finding codes exist;
- historical M31 documents are preserved;
- external usability and runtime qualification are explicitly marked pending.

## Required before publication

- the SQL/tests implementation and M32 executable fixtures;
- inherited M31 and all required regression, recovery, security, and artifact
  checks;
- the five-person external usability exercise and its recorded results;
- independent review of the final packaged artifact and documentation examples.

Do not tag or push `v0.29.0` until those gates are evidenced.
