# M26 readiness record

M26 is the `0.23.0` decision-table milestone. These documents define its
contract and release evidence; they do not certify an implementation. Tag and
push `v0.23.0` only after every M26 exit gate and the inherited M0–M25 gates
pass on the release image.

Run the fast validation first:

```text
cargo fmt --check
cargo test --no-default-features
cargo check --features pg18
docker compose config --quiet
docker build --tag pg-react:v0.23.0 .
tests/m26.sh fast pg-react:v0.23.0
```

Run the complete release gate:

```text
cargo fmt --check
cargo test --no-default-features
cargo check --features pg18
docker compose config --quiet
docker build --tag pg-react:v0.23.0 .
tests/m26.sh complete pg-react:v0.23.0
```

The complete profile must cover one, many, no, and tied candidates; candidate
mutation; priority and result changes; parameter-driven candidates;
effective-dated versions; concurrent transitions; scheduled and immediate
maintenance; pause/resume; replacement; reconciliation; retention; physical
and logical recovery; standby promotion; security; performance; inherited
compatibility; and the populated direct `0.22.0 -> 0.23.0` upgrade.

The release archive must also verify checksums, SBOM, provenance, OCI digest,
documentation, and usability evidence. The gate is not complete when a test
passes only because it checks counts: each frozen case must compare the exact
public winner, ambiguity, no-candidate, never-observed, lifecycle, work,
support, provenance, diagnostic, explanation, and final result.

The logical next milestone is M27 — Decision coverage and conflict analysis.
It should inspect supported programs before deployment for ties, forbidden
overlap, missing defaults, unreachable candidates, uncovered populations, and
material winner-distribution changes.
