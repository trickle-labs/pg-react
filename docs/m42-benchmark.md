# M42 benchmark

M42 keeps the M41 semantic limits. The snapshot adds one JSON write and one
retention-table row per successful capture.

| Measure | Limit or counter |
| --- | --- |
| Nested path | The complete M41 answer |
| Snapshot payload | `payload_bytes` |
| Source evidence reads | `source_evidence_read` |
| Snapshot writes | `storage_writes`, always `1` for a successful capture |
| Retention ordering | `captured_at`, then `snapshot_identity` |
| Retention batch | M21 batch size, 1 to 10000 |
| Policy retention | 1 second to 100 years |

The qualification fixture records the payload size and the three semantic cost
counters. Elapsed time remains outside the identity and may vary by machine.
