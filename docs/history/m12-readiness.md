# M12 readiness

The `0.9.0` repository candidate implements the complete M12 database-time
deadline contract. The immutable and checksummed `v0.8.0` release entry gate
is recorded in [m12-entry.md](m12-entry.md).

The candidate has one declaration and one monotone clock, reuses the inherited
incremental stream and lifecycle engine, indexes deadline state, preserves
atomic barriers and asynchronous consequences, exposes name-first evidence,
and adds no recurrence, window, event-time, immediate-execution, scheduler, or
worker-protocol surface.

Release qualification is `tests/m12.sh pg-react:v0.9.0` on the exact
`linux/amd64` image plus the Rust, pgrx, Compose, checksum, and workflow gates.
After those pass on the commit intended for release, tag that commit `v0.9.0`
and push the tag. The release workflow must rebuild the image, rerun M12,
publish the archive and checksum manifest, and record the immutable OCI digest.

M13 remains a proposed planning label, not an active commitment. After M12 is
published, its logical next scope is richer strictly lower-stratum,
non-recursive aggregation: `COUNT(expression)`, then `SUM`, `MIN`, and `MAX`
one bounded function at a time with exact PostgreSQL null, overflow,
retraction, explanation, and recovery behavior. Promote it only after a frozen
entry fixture and executable evidence are credible.
