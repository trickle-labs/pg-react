# M18 contract — production usability and hardening

M18 preserves every M0–M17 truth, support, lifecycle, frontier, watermark,
correction, ordering, delivery, retry, retention, recovery, security, and
external-effect guarantee. It adds no rule semantics, synchronous path,
aggregate/window kind, provenance model, automatic repair, or worker protocol.

Backward-compatible diagnostic labels and summaries, remediation text,
documentation, instrumentation, packaging, testability, and measured
implementation performance are allowed. Existing repair and reconciliation
operations remain authoritative; diagnostics never mutate state.

Ordinary workflows use stable public names and domain values. Advanced evidence
is opt-in, role-checked, bounded, and exposed only through existing public
boundaries. Performance is valid only inside the published fixture envelope.

`tests/m18-public-matrix.sql` verifies the name-first diagnostic additions;
`tests/m18-authoring.sql` verifies the exact public rows, jobs, facts,
aggregates, windows, explanations, and cleanup transcript.
