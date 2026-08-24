# M18 benchmark and evidence

`tests/m18-benchmark.sh` runs the explicitly named matrix from the manifest.
Each case reports its exact correctness checksum, update and worker throughput,
p50/p95 update and worker latency, watermark latency, peak container memory, and
database size. Recovery correctness remains the inherited M17 drill; complete
release evidence records its wall time separately.

The named fact count is the loaded immutable corpus used for storage limits. The
window source deterministically selects the named number of rows from it.
The auxiliary rule-update table contains the exact named batch; the worker table
contains its minimum with the frozen 1,000-job cap. This keeps both phases from
invalidating event-time input. Four-worker cases drain one full configured
queue through repeated public 32-item claims; the 10,000-row dimension remains
an update batch, not a 10,000-job queue claim.

Update cases use 20 samples per run. The measured 1,000-rule cliff uses one
update per run and derives its conservative p95 from the five measured runs;
refreshing 1,000 maintained conditions twenty times would test repeated cliff
duration rather than add another scale point.
The watermark dimension is both the requested range in hours and the exact
number of windows finalized. The frozen profile uses `pg_react.batch_size=1000`;
the timed public maintenance loop must reach the exact complete frontier.
Managed-worker job claims retain the inherited public 100-item maximum; the
larger GUC value applies to maintenance such as window finalization.
For ranges above one batch, both window sources are disabled after identities
are materialized and retracted, so the timed loop isolates durable finalization
instead of repeatedly rescanning the source corpus.

Three warmups and five measurements produce the checked-in hardware-specific
baseline. Median throughput may fall 10%; p95 latency may rise 20%; peak memory
and database size may rise 15%. A breach receives one complete rerun, then
fails. Results outside `tests/fixtures/m18/release-state.json` make no SLA claim.

The complete profile also runs three warmup and five measured populated M17
recovery drills. Their worst measured crash-restart, logical-restore, and
physical-restore latency is the conservative five-sample p95 budget input.
