# M13 readiness

The `0.10.0` repository candidate implements the complete M13 core PostgreSQL
ergonomics contract. The immutable and checksummed `v0.9.0` entry release is
recorded in [m13-entry.md](m13-entry.md).

The candidate adds explicit-schema named action resolution, context-optional
typed adapters, one dependency-ordered database run, friendly inspection
language, and four exact role grants. It reuses the existing durable lifecycle,
program, deadline, worker, drift, retry, recovery, and external-effect paths and
adds no new engine or protocol.

Release qualification is `tests/m13.sh pg-react:v0.10.0` on the exact
`linux/amd64` image plus Rust, pgrx, Compose, checksum, and workflow gates.
After those pass on the intended commit, tag it `v0.10.0` and push the tag. The
release workflow must rebuild the image, rerun M13, publish the archive and
checksum manifest, and record the immutable OCI digest.

M14 is already defined as **Explainability and reasoning UX**. Its logical
scope is one common `doctor`/`explain` envelope and PostgreSQL-native derived
program authoring with deterministic dependency, component, and stratum
inference. Begin it only after immutable `v0.10.0` artifacts and frozen M14
entry fixtures satisfy the entry gate; do not pull M15 managed-worker work into
M14.
