# M17 readiness

The `0.14.0` repository candidate implements fixed-duration event-time windows,
durable monotone watermarks, ordered corrections, late-input barriers,
finalization, bounded retention, and physical/logical recovery while preserving
the complete M0–M16 contract.

On 2026-08-13, `tests/m17.sh pg-react:v0.14.0` passed every M17 fixture and the
unchanged inherited M16 compatibility runner on `linux/amd64`, completing the
repository milestone. Tagging and publishing `v0.14.0` remain separate release
steps.
