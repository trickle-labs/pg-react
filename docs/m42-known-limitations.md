# M42 known limitations

- M42 stores one `decision_result` root at a time.
- The subject key is one bigint value.
- Capture requires a complete current M41 path.
- Snapshot reads do not recompute the decision or reread source tables.
- M42 does not snapshot rule work or decision work.
- M42 has no snapshot enumeration, pagination, search, source history, or
  external archive.
- Deletion eligibility uses wall-clock time and the declared retention period.
- Payload size remains bounded by the M41 answer and is stored as one JSON value.
