# M37 qualification evidence

The release gate is `tests/m37.sh complete`. Its static lane checks the
versioned SQL composition, public metadata, inventories, finding registry,
upgrade pair, shell syntax, and no-mutation SQL boundary. Its packaged lane
checks equal and changed policy results, shared replay inputs, relational
results, bounded evidence, rejection behavior, no-effect checksums, and the
populated `0.33.0 -> 0.34.0` upgrade.

The three workload shapes and their declared budgets are recorded in
`m37-benchmark.md`. The exact fixture uses a candidate declaration with a
different decision output, so the comparison proves both unchanged-input
alignment and an observable policy difference without changing the source.
