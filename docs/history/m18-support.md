# M18 support and release state

The authoritative machine-readable support statement is
`tests/fixtures/m18/release-state.json`. It records PostgreSQL, `pg_trickle`,
OS/architecture, isolation, RLS, key-codec, deployment, measured-envelope,
known-cliff, recovery, and operator boundaries.

The release audit requires pinned actions/toolchains, locked dependencies,
least-privilege permissions, advisory checks, checksums, SPDX SBOM, and
GitHub/Sigstore-signed artifact, image, and SBOM attestations. Checksums and
the immutable OCI digest remain independent verification inputs.
