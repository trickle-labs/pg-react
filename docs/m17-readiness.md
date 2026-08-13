# M17 readiness

The `0.14.0` repository candidate implements fixed-duration event-time windows,
durable monotone watermarks, ordered corrections, late-input barriers,
finalization, bounded retention, and physical/logical recovery while preserving
the complete M0–M16 contract.

Run `tests/m17.sh pg-react:v0.14.0`. A release is eligible only when that command
passes every M17 fixture and the unchanged inherited M16 compatibility runner.
Then tag and push `v0.14.0`; the release workflow rebuilds the archive, checksum
manifest, and pinned `linux/amd64` OCI artifact.
