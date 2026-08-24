# M15 evidence

`tests/m15.sh pg-react:v0.12.0` is the M15 repository gate.

| Requirement | Executable evidence |
|---|---|
| Managed startup, readiness, execution, backpressure, restart, coexistence | `m15-api.sql` plus managed-process restart checks |
| `bigint`, `uuid`, `text`, mixed tuples, exact failures | `m15-api.sql` |
| Matching, jobs, derivation, status, diagnostics, explanation | `m15-api.sql` |
| Exact final inventory and five-role grants | `m15-api.sql` and `m15-docs.sh` |
| Populated `0.11.0 -> 0.12.0` preservation | `m15-upgrade.sql` |
| Physical and logical recovery | `m15-recovery-*.sql` plus M15 dump/restore replay |
| Complete documented workflow | `m15-docs.sh` and clean usability replay |
| Inherited M0-M14 contract | M13 and M14 compatibility runners against the `0.12.0` image; M14 carries M0-M12 |

The release workflow reruns this gate, publishes the archive and checksum
manifest, and records the immutable `linux/amd64` OCI digest.
