# M44 benchmark

M44 adds no evaluator or database write path. Its cost is the cost of the
originating operation plus any existing snapshot read.

| Area | Evidence to record |
|---|---|
| Target lookup | Target and subject lookup counters from the origin |
| Source reads | Current source and authoritative-evidence counters |
| Cause discovery | M38 why-changed or M40 why-not counters |
| Graph expansion | M41 node, edge, path, depth, and fan-out counters |
| Serialization | Returned bytes and payload-limit findings |
| Hashing | Semantic digest inputs and digest cost |
| Snapshot access | M42 read cost, payload bytes, and retained state |
| Resource use | Latency, memory, and temporary storage for the profile |

The representative corpus contains financial-exception, access-drift, and
retained-decision workflows. The supported-limit profile uses the limits
published by each origin. Measured elapsed time stays outside semantic identity.
