# M18 artifact inventory

The M18 candidate bundle is orchestrated only by `tests/m18.sh` (`fast` and
`complete`). Supporting artifacts are `tests/m18-authoring.sql`,
`tests/m18-public-matrix.sql`, `tests/m18-day2.sql`, `tests/m18-benchmark.sh`,
`tests/m18-benchmark-case.sh`, `tests/m18-benchmark-case.sql`, and
`tests/m18-upgrade.sql`, plus the
inherited M17 fixtures and `tests/fixtures/m18/*`.

The manifest, baseline, release-state JSON, and expected small transcript live
under `tests/fixtures/m18/`.
