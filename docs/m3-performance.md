# M3 performance budget

The RC baseline is a Docker-backed PostgreSQL 18.3/pg_trickle 0.81.0 run on the supported `linux/amd64` image. `tests/m3.sh` checks the shape rather than a host-dependent wall-clock promise.

| Workload | RC budget | Evidence |
| --- | --- | --- |
| No-change refresh | No lifecycle or agenda writes | `tests/m3.sql` |
| Activation burst | 128 changed semantic keys create 128 episodes, with no unrelated historical scan | `tests/m3.sql` plus `agenda_m2_claim_idx` |
| High-volume event backlog | Refresh rejects atomically at the configured pending limit | `tests/m3.sql` |
| Many rules / replacement | Existing M1 scale smoke remains required | `tests/m1-scale.sh` |
| Claims | Bound of 100 and group lease budget enforced | `tests/m3.sql` |
| Payload retention | Terminal payload cleanup is audited and preserves ledger identity | `tests/m3.sql` |
| Reconciliation / consequence | M2 integration gate remains required | `tests/m2.sh` |

The release regression threshold is semantic: an M3 run may not create lifecycle work for unchanged membership, may not scan unrelated historical agenda rows for a claim, and may not exceed configured claim/backlog/group limits. Record elapsed times for the pilot workload, but do not promote a laptop timing into a production SLO.
