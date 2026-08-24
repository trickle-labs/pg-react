# M10 evidence

`tests/m10.sh pg-react:v0.7.0` is the repository gate. It runs M0–M9 first,
then verifies the frozen aggregate fixture, direct `0.6.0 -> 0.7.0` upgrade,
crash restart, physical restore, and exact fresh-install composition.

| Requirement | Executable evidence |
|---|---|
| Stable aggregate graph and strict strata | `aggregate_input` validation plus the `AGGREGATE` edge and strata asserted by `m10-slice1.sql` |
| Exact threshold lifecycle | Counts `1 → 2 → 3 → 2 → 1` with exact evidence/frontiers and only `ACTIVATE`, then `DEACTIVATE` |
| No false transition on non-flips | `m10-slice1.sql` requires no extra event at counts 3 or 2 |
| Durable finite evidence | `pgreact.aggregate_dependency_evidence` is asserted with group, count, comparison, threshold, strata, and lower frontier |
| Atomic recovery and inherited compatibility | `tests/m9.sh` and `tests/m6-recovery.sh` run from `tests/m10.sh` |
| Exact upgrade preservation | `m9-upgrade.sql` followed by `m10-upgrade.sql` snapshots and compares M9 programs, components, facts, supports, graph, and evidence |

The release workflow rebuilds this exact suite from the `v0.7.0` tag before it
publishes the archive checksum and OCI image digest.
