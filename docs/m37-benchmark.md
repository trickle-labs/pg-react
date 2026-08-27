# M37 benchmark and budget record

M37 publishes bounded work rather than promising an unmeasured performance
target. The semantic counters are deterministic for fixed inputs; elapsed time
is recorded separately.

| Workload | Shape | Declared limits |
|---|---|---|
| Small order review | 100 snapshot rows, 10 replay steps | 1,000 evidence rows, 1,000 changes |
| Daily policy migration | 10,000 snapshot rows, 100 replay steps | 100,000 snapshot rows, 100,000 changes |
| Candidate selection | 1,000 subjects with up to 20 candidates | 1,000 evidence rows, 100,000 changes |

For every workload record the baseline and candidate declaration digests, the
shared snapshot and replay digests, both side costs, comparison counts, public
SQL task time, writes, WAL, memory, temporary storage, and recovery-to-
authoritative-state checks. The caller can lower every limit through `options`.
