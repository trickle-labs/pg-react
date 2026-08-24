# M30 readiness record

M30 is the `0.27.0` applicability-foundation candidate. It freezes typed
identities, explicit scope modes, relational eligibility, migration states,
barrier inspection, and exact foundation fixtures.

Run the fast checks first:

```text
cargo fmt --check
cargo test --no-default-features
docker compose config --quiet
docker build --tag pg-react:v0.27.0 .
tests/m30.sh fast pg-react:v0.27.0
```

The complete release gate is:

```text
cargo fmt --check
cargo test --no-default-features
docker compose config --quiet
docker build --tag pg-react:v0.27.0 .
tests/m30.sh complete pg-react:v0.27.0
```

The complete profile must verify the populated `0.26.0 -> 0.27.0` upgrade and
the inherited M0–M29 evidence. Passing the local fast profile is not
publication. Publish only after the release workflow also verifies the image,
checksums, SBOM, provenance, OCI digest, and evidence archive.

M30 does not yet claim that eligibility changes authoritative lifecycle or
work. The logical next milestone is **M31 — Authoritative runtime**, which must
consume this frozen schema and prove those transitions, locking, recovery, and
truthful ordinary verbs.
