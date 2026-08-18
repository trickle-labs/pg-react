# M31 versioning blocker

Status: package identity is resolved; publication remains gated.

The repository’s existing `v0.27.0` tag is the M30 release tag. M31’s release
target is now `0.28.0`; this documentation worktree does not move, delete, or
overwrite the existing tag.

## Consequence

The project cannot truthfully publish M31 by pushing another `v0.27.0` tag.
Moving the tag would rewrite the M30 release identity; reusing it would make
M30 and M31 indistinguishable to users and automation.

## Publication condition

The working tree now carries `0.28.0` package metadata, install SQL, direct
upgrade SQL, runtime checks, and CI/package audits while preserving M30
`0.27.0` artifacts. Until every M31 gate is green, M31 is not release-ready
and no version tag should be pushed for it.

M32 follows M31 at proposed extension version `0.29.0`; M33 follows at
`0.30.0`.
