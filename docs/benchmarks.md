# 0.44.0 benchmark contract

The reproducible workload manifest is
`tests/fixtures/m55/workloads.json`. It fixes seeds, timestamps, PostgreSQL
settings, warm-up count, measured repetitions, and the required workload names.
Run the static contract with `bash tests/qualification.sh fast`; run the
database profile with `bash tests/qualification.sh complete IMAGE`. Run the
M55 workload matrix directly with:

```bash
M55_BENCHMARK_OUTPUT=m55-evidence/m55-benchmark.json \
M55_ARTIFACT_DIR=m55-evidence \
bash tests/m55-benchmark.sh IMAGE complete
```

The runner builds a fresh benchmark database for each case, performs the
manifest's warm-up and measured repetitions, and retains one JSON result per
run. The complete qualification runs three one-factor profiles: the seven-case
baseline (1,000 matches and 10,000 history rows), a fixed-target comparison
with 100,000 retained-history rows, and the hot-conflict backlog with 10,000
matches. The aggregate includes p50, p95, p99, WAL bytes, database size, full
case results, correctness checksums, image identity, and source revision.
Memory is reported as unavailable unless a trustworthy container metric is
added. The aggregate also records Docker architecture/resources, free disk,
and selected PostgreSQL settings.

The repository records the matrix and acceptance ceilings before a measurement
run. A case is supported only when its raw transcript, sample count, p50, p95,
p99 where available, failures, and image identity are retained. No case is
treated as measured merely because a command was skipped or timed out.

M59 qualifies only this bounded envelope on the pinned Linux/amd64 runner:
comparison p95 no higher than 250 ms, expired-lease recovery p95 no higher
than 2,500 ms, and a 10,000-match hot-conflict backlog that drains completely.
The recovery case abandons a one-second lease; it does not claim a process-kill
or restart-time measurement.
Memory, WAL ceilings, retention beyond 100,000 rows, and 100,000-match
throughput remain explicit unsupported limits rather than production claims.
