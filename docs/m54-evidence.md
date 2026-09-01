# M54 qualification evidence

M54 evidence is produced by the canonical
`.github/workflows/qualification.yml` workflow for the exact candidate commit.
The lane runs the current-doc audit, API inventory audit, Rust checks, candidate
image build, fresh-install SQL, ordinary facade fixtures, standalone rule and
decision replacement, reviewed deployment, names-first recovery, and the
adjacent migration/rollback checks.

The release bundle contains `evidence-manifest.json`. Each inherited milestone
is recorded either as `executed` with its workflow/artifact digest or as
`inherited` with the immutable release and evidence artifact digest. Missing
evidence is a qualification failure; the release workflow does not synthesize
placeholder evidence.

This repository record describes the evidence contract. The generated manifest
and command output are the authoritative run-specific record attached to the
release.
