# M43 qualification evidence

The executable gate is `tests/m43.sh complete`. Its static lane checks the
versioned SQL, exact concatenation, API and finding inventories, contract,
examples, compatibility, benchmark, migration, release notes, limitations,
reference corpus, and checklist. Its database lane checks all three supported
declaration kinds, every change kind, normalization equivalence, opaque object
evidence, limits, authorization, read-only checks, and the populated upgrade.

The reference corpus records three production-shaped policy reviews: a
financial exception, access drift, and policy-set applicability. It records
the complete declarations, modeled differences, opaque boundaries, findings,
digests, costs, checksums, and questions that remain outside M43. It is a
deterministic repository fixture, not evidence supplied by an external
reviewer.

## External entry-gate status

Pending. The M43 plan requires one externally supplied financial-exception or
access-drift policy change with its review question, existing M34–M39 outputs,
manual comparisons, and minimum approval differences. No such external review
is present in this repository, so the fixture must not be presented as proof of
external use. Record that review here before freezing the contract or
publishing `v0.40.0`.

The complete profile runs a fresh `0.40.0` installation and a populated
`0.39.0 -> 0.40.0` upgrade. The migration lane has no in-place downgrade;
rollback is verified by restoring the source backup.
