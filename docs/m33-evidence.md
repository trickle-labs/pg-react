# M33 qualification evidence

**Purpose:** show that the exact packaged `0.30.0` artifact is ready to begin
the numbered `1.0.0-rc.1` cycle.

| Area | Evidence |
| --- | --- |
| Installed reality | `tests/m33.sh` compares the generated inventory with `docs/v1-api-inventory.json` and the finding registry |
| Compatibility | `tests/m33.sh` checks the `0.29.0 -> 0.30.0` SQL pair and the inherited direct-upgrade lane |
| Recovery | restart, physical restore, logical-restore, PITR, and promotion procedures are explicit in `docs/v1-backup-restore.md` |
| Security | `tests/m33-security.sql` checks grants, roles, fixed search paths, identity, RLS rejection, and redaction |
| Limits | `docs/v1-limits.md` and the M33 SQL fixture exercise bounded failure |
| Documentation | examples are executed by the packaged-candidate lane |
| Packaging | the release workflow creates an image, source/package checksum, SBOM, and provenance |
| Usability and pilots | human records are required inputs; CI does not invent participant or pilot results |

The evidence directory is produced by the release workflow from the exact
candidate image. A passing developer-tree test is not sufficient for GA.
