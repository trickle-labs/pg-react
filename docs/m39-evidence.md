# M39 qualification evidence

The release gate is `tests/m39.sh complete`. Its static lane checks the
metadata-only migration, full SQL composition, versioned inventories, contract,
compatibility matrix, corpus, benchmark, release notes, shell syntax, and
no-write boundary.

Its packaged lane runs the inherited M34–M38 fixtures and the M39 conformance
fixture against the exact `0.36.0` candidate. It checks current versus
empty-change equivalence, replay and backtest identity, why-changed
propagation, relational/JSON agreement, canonical digest stability, exact
partial bounds, operation-specific findings, authorization and RLS rejection,
and unchanged source and pg-react checksums.

The complete profile also installs a populated `0.35.0` database, applies the
adjacent update, restores the pre-update backup into a `0.35.0` container, and
checks that the public simulation surface survives. The release workflow runs
the inherited M38 qualification against the published `v0.35.0` artifact and
packages M39 evidence with the image, SBOM, provenance, and checksums.

The corpus names three production-shaped workflows. The M39 fixture uses the
public production run interface in a disposable database as its oracle and
compares the stored production winners with the simulation result. Wall-clock
measurements are recorded separately from reproducible semantic counters.
