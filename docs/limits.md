# Limits

The current release is pg-react `0.43.1`. Current bounded defaults include a
maximum review-token size of 4096 bytes, up to 32 ordinary watched or conflict
columns, 64 package members, 64 package support declarations, 256 dependency
edges, and 1 MiB canonical declaration bytes. Runtime-specific limits are
reported by validation and preview.

The following values are unavailable because this release has no faithful
measurement for them: comparison dependency fan-out, reevaluation cost,
cascade depth, memory, and temporary-storage cost.
