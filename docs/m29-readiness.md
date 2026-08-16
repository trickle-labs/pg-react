# M29 readiness record

M29 is the `0.26.0` policy-set gating candidate. The candidate includes the
typed applicability catalog, immutable members, common façade dispatch,
inspection views, migration, focused correctness fixture, and release metadata.

Run the fast checks first:

```text
cargo fmt --check
cargo test --no-default-features
docker compose config --quiet
docker build --tag pg-react:v0.26.0 .
tests/m29.sh fast pg-react:v0.26.0
```

The complete release gate is:

```text
cargo fmt --check
cargo test --no-default-features
docker compose config --quiet
docker build --tag pg-react:v0.26.0 .
tests/m29.sh complete pg-react:v0.26.0
```

The complete profile must verify the populated `0.25.0 -> 0.26.0` upgrade,
inherited M0–M28 evidence, security and recovery behavior, and the release
workflow’s artifact checks. Passing the local fast profile is not publication.

The logical next milestone is M30 — Hypothetical fact simulation. It is not
part of M29 and should begin only after the immutable `v0.26.0` evidence is
published.
