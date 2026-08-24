# M25 evidence

The executable M25 gate is `tests/m25.sh`. It checks the release identity and
documentation, then exercises typed declaration, invalid declarations,
parameterized rule and program authoring, dependency rejection, insert/update/delete
maintenance, preview, explanation, editor-role membership, redaction, trigger
integrity, effective-dated coexistence, atomic seed data, doctor output, and the
populated `0.21.0 -> 0.22.0` upgrade.

The complete profile also runs the inherited M24 complete gate. Its artifact
directory contains the individual logs and the release-state fixture used by
the release workflow.

This is a repository candidate, not a publication claim. The local gate does
not create or verify remote release artifacts, concurrent crash/recovery
interleavings, standby promotion, retention/restore, or a hypothetical
`match_after` result for arbitrary joined views. Those remain release-workflow
and follow-up evidence requirements; do not tag or push `v0.22.0` until they
are attached to the complete evidence archive.

The supported performance boundary is 100,000 rows per family. Admission is
rejected before declaration beyond that bound; scale beyond it requires a
future milestone with a new published budget.
