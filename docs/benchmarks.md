# 0.44.0 benchmark contract

The reproducible workload manifest is
`tests/fixtures/m55/workloads.json`. It fixes seeds, timestamps, PostgreSQL
settings, warm-up count, measured repetitions, and the required workload names.
Run the static contract with `bash tests/qualification.sh fast`; run the
database profile with `bash tests/qualification.sh complete IMAGE`.

The repository records the matrix and acceptance ceilings before a measurement
run. A case is supported only when its raw transcript, sample count, p50, p95,
p99 where available, failures, and image identity are retained. No case is
treated as measured merely because a command was skipped or timed out.

The current release publishes the comparison-cost subset and artifact checks.
The scale, sustained-overload, memory, WAL, retention-growth, and recovery
percentiles remain unmeasured until a pinned Linux/amd64 runner records them.
Those are explicit limits, not production guarantees.
