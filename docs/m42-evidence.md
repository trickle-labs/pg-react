# M42 qualification evidence

The executable gate is `tests/m42.sh complete`. Its static checks verify the
versioned SQL, exact concatenation, contract files, inventories, release notes,
and shell syntax. Its database fixture checks capture, retry, historical read,
eligibility, delete, tombstone, audit, and the no-opt-in default.

The fixture keeps the complete nested M41 answer unchanged. It checks the public
identity, declaration and policy digests, times, owner, payload bytes, source
read counter, and one storage write. It also checks that the M21 family reports
the snapshot and that deletion leaves a tombstone.

The complete profile runs a fresh `0.39.0` installation and a populated
`0.38.0 -> 0.39.0` upgrade. The migration lane has no in-place downgrade.
Restore the verified `0.38.0` backup to roll back.

The release workflow runs the same gate against the candidate image and stores
the logs with the release evidence.
