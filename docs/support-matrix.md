# Support Matrix

The current adoption boundary is pg-react `0.43.0` on PostgreSQL 18.3,
pg_trickle 0.81.0, pgrx 0.18.0, Rust 1.89.0, Linux `amd64`, `READ COMMITTED`,
and the PostgreSQL-managed runtime.

The managed runtime still accepts the historical adjacent 0.x versions and
historical release-candidate identifiers where the installed code supports
them. “Accepted by the runtime” is not the same as “qualified current
adoption boundary.” The [current release manifest](current-release.json) and
qualification workflow define the current boundary.
