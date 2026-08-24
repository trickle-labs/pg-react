# M6 readiness

## Repository state

The `0.3.0` implementation, direct `0.2.0 -> 0.3.0` migration, protocol-2
worker opt-in, public batch diagnostics, documentation, recovery workflow, and
complete Docker-backed gate are implemented. The inherited support boundary is
unchanged: `linux/amd64`, PostgreSQL 18.3, pg_trickle 0.81.0,
`READ COMMITTED`, coordinator-owned `DIFFERENTIAL`, one non-null `bigint` key,
physical recovery, and no RLS source views.

`tests/m6.sh pg-react:v0.3.0` reruns M0–M5 before the exact M6 API, rejection,
failure, worker, concurrency, disconnect, upgrade, restart, physical restore,
and five-sample benchmark gates. On 2026-08-09, the benchmark medians were
159.47 protocol-1 baseline, 154.84 protocol-1 candidate, and 1,469.02
audited-batch episodes per second: 9.49x throughput, a 0.971 default-regression
ratio, 1.040 batch/single WAL ratio, and 1.247 durable-byte ratio. Normalized
state was exactly identical and both paths used one connection per benchmark
worker. The executable ratios, rather than host speed, remain authoritative.

## External entry gate — invalid release

As verified on 2026-08-09, GitHub tag `v0.2.0` points to M6 commit `ba3f184`,
whose package and extension versions are `0.3.0`, rather than the `0.2.0`
release-prep commit `7bc6c04`. The published archive and OCI image therefore
cannot satisfy M6's exact M5 release gate. Moving the public tag or replacing
published assets requires an explicit maintainer remediation decision.

After remediation, rerun `tests/m6-entry.sh` against the exact release bytes,
record the archive checksum and OCI digest in `docs/m6-entry.md`, run the full
`tests/m6.sh` gate from this commit, and only then treat the M6 gate as met.
