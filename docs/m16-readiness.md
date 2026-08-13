# M16 readiness

The `0.13.0` repository candidate implements typed `COUNT`, `SUM`, `MIN`, and
`MAX` aggregate dependencies while preserving inherited `COUNT(*)`, strict
strata, finite evidence, recovery, and the M15 public boundary. Run
`tests/m16.sh pg-react:v0.13.0`, then tag and push `v0.13.0`; the release
workflow rebuilds and publishes the archive, checksum manifest, and OCI digest.

M17 remains a proposed event-time-windows milestone and is not part of this
candidate.
