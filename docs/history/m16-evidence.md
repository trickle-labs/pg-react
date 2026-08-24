# M16 evidence

`tests/m16.sh pg-react:v0.13.0` is the M16 repository gate.

| Requirement | Executable evidence |
|---|---|
| Typed declaration and exact validation | M16 aggregate API fixture |
| Every supported aggregate/type and PostgreSQL special value | M16 aggregate matrix fixture |
| Null, empty, equivalent-order, crossing, and non-crossing behavior | M16 aggregate and matrix fixtures |
| Evidence, explanation, and complete frontiers | M16 aggregate API fixture |
| Reconciliation, replacement, removal, and role grants | M16 aggregate and replacement fixtures |
| Recovery and logical restore | M16 recovery and logical-restore fixtures |
| Populated `0.12.0 -> 0.13.0` preservation | M16 upgrade fixture |
| Inherited M0–M15 contract | M15 compatibility runner; M15 carries M0–M14 |

The release workflow reruns this gate, publishes the archive and checksum
manifest, and records the immutable `linux/amd64` OCI digest.
