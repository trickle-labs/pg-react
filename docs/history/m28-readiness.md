# M28 readiness record

M28 is implemented as the `0.25.0` public API convergence candidate. The
release identity, additive SQL façade, machine-readable inventory, focused
fixture, migration, documentation, and release workflow are checked in.

Run the fast validation first:

```text
cargo fmt --check
cargo test --no-default-features
cargo check --features pg18
docker compose config --quiet
docker build --tag pg-react:v0.25.0 .
tests/m28.sh fast pg-react:v0.25.0
```

Run the complete release gate before publishing:

```text
cargo fmt --check
cargo test --no-default-features
cargo check --features pg18
docker compose config --quiet
docker build --tag pg-react:v0.25.0 .
tests/m28.sh complete pg-react:v0.25.0
```

The complete profile must also verify the populated direct
`0.24.0 -> 0.25.0` upgrade and all inherited M0–M27 evidence, security,
recovery, usability, and artifact checks. Do not claim the release is
published merely because the local fast profile passes.

The next milestone is M29 — Policy-set gating, defined in the current roadmap.
