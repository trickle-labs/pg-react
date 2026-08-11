# M10 readiness

The `0.7.0` repository candidate implements M10's bounded keyed `COUNT(*)`
threshold slice. It preserves the M0–M9 support boundary and adds aggregate
catalogs, validation, deterministic strata, lower-frontier evidence, exact
threshold maintenance, explanation, reconciliation, direct upgrade, and a
Docker-backed full gate.

The M10 entry gate is complete: the immutable public `v0.6.0` tag, successful
release workflow, checksummed archive, immutable Linux/amd64 image digest,
documented direct upgrade, and M9 qualification are recorded in
[m10-entry.md](m10-entry.md).

Publish the exact `v0.7.0` tag only after the release workflow rebuilds
`tests/m10.sh`, publishes its archive and checksum manifest, and records the
new immutable OCI digest. That publication is release qualification, not a
blocker to the implemented M10 repository candidate.
