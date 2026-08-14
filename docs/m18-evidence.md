# M18 evidence

`tests/m18.sh fast pg-react:v0.15.0` is the ordinary-CI correctness gate.
`tests/m18.sh complete pg-react:v0.15.0` adds the named benchmark matrix and
machine-readable regression budget. Both run the inherited M0–M17 gate on the
`0.15.0` candidate, start clean supported instances, and compare exact public
transcripts.

| Requirement | Executable evidence |
|---|---|
| Five-workload public authoring and cleanup | `m18-authoring.sql` and the frozen small transcript |
| Name-first health, program status, explanation, watermark, and remediation | `m18-public-matrix.sql` |
| Direct upgrade and continued input | populated `m17-smoke.sql` plus `m18-upgrade.sql` |
| Worker loss, restart, reconciliation, and continued execution | `m18-day2.sql` plus the orchestrated worker stop/resume |
| Crash/restart, physical/logical restore, recovery, and all inherited contracts | unchanged `tests/m17.sh` gate |
| Benchmark warmups, samples, budgets, and exact cases | `m18-benchmark.sh`, case runner, manifest, and baseline |
| Documentation, release identity, pinned automation, SBOM, and signed provenance attestations | repository audit phases in `tests/m18.sh` and the release workflow |

The complete run writes the host, image inspection, exact transcript, benchmark
result, and checksums to `M18_ARTIFACT_DIR`. Publication and the separately
observed human usability record remain release actions, not claims made by a
shell assertion.

Run the manual `M18 complete evidence` workflow before tagging. It publishes a
checksummed complete-profile archive from the pinned Ubuntu 24.04 amd64 runner.
Record the independent observation as `tests/fixtures/m18/human-usability.json`;
`tests/m18-human-evidence.sh` checks its environment, role, elapsed time, exact
transcript, cleanup state, and deviations. The tag workflow refuses publication
until that record exists and passes.
