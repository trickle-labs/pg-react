# M22 operations

Use `pgreact_api.provenance_status()` for bounded catalog and missing-binding
state, `provenance_validate(relation_version_id)` after reconciliation or
restore, and `provenance_doctor()` for release and maintenance diagnostics.

`explain_provenance` is finite by construction. A non-null continuation is tied
to the exact active support-id digest; changed or expired state fails with a
snapshot diagnostic instead of silently skipping or duplicating proof entries.
If a requested fact has no retained current proof, restore the verified backup
covering the M21 explanation horizon or reconcile the derived relation.
