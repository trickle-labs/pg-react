# M16 entry record

M16 starts from immutable `v0.12.0` at commit
`e8c94a4d8de277425c150c14efa3be6268413417`.

The successful release run is
`https://github.com/trickle-labs/pg-react/actions/runs/31669730148`. The published
`pg-react-v0.12.0-linux-amd64.tar.gz` SHA-256 is
`e8f521d4efd9ef9ea366fe20bf341de4e40883694231bc262e57fda34880acb7`.
Its published OCI identity is
`ghcr.io/trickle-labs/pg-react:v0.12.0@sha256:7bd40bf9ed6b5be7df4c9c9a3c4dae3be3398e7e800f93e7458a7687704a30f2`.
The GitHub release published both archive and checksum manifest at
`https://github.com/trickle-labs/pg-react/releases/tag/v0.12.0`.

The frozen M16 task fixture is `tests/m16.sh`: inherited `COUNT(*)`, typed
`COUNT`, `SUM`, `MIN`, and `MAX`; null and empty inputs; supported types and
collations; rejection without mutation; threshold crossings and non-crossings;
reconciliation, replacement, recovery, logical restore, and populated `0.12.0 -> 0.13.0`
upgrade. Rollback remains restoring the verified pre-upgrade physical backup;
extension downgrade is unsupported.
