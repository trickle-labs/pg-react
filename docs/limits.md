# Limits

The current release is pg-react `0.44.0`. Current bounded defaults include a
maximum review-token size of 4096 bytes, up to 32 ordinary watched or conflict
columns, 64 package members, 64 package support declarations, 256 dependency
edges, and 1 MiB canonical declaration bytes. Runtime-specific limits are
reported by validation and preview.

M59's measured adoption envelope is the pinned Linux/amd64 runner with the
manifest's baseline profile, a 100,000-row retained-history comparison sweep,
and a 10,000-match hot-conflict backlog. The acceptance ceilings are 250 ms
p95 for comparison and 2,500 ms p95 for expired-lease recovery; the backlog
must drain without residual pending work.

The following remain unavailable or outside the envelope: comparison
dependency fan-out, reevaluation cost, cascade depth, faithful process memory,
temporary-storage cost, and 100,000-match throughput.
