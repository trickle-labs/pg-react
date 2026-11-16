# Limits

[Reference](reference/index.md) · [SQL API](api-reference.md)

The **pg-react 0.46.0 core profile** uses bounded declarations, work processing, and returned evidence. A validation or preview finding is the authoritative response for the specific declaration you submit. The table below collects limits that are easy to encounter in ordinary authoring and review; specialized families add their own constraints in the [advanced API records](reference/advanced-apis.md).

| Boundary | Value |
| --- | --- |
| Review token | At most `4096` bytes. |
| Ordinary watched columns | Up to `32`. |
| Ordinary conflict-key columns | Up to `32`. |
| Policy package members | Up to `64`. |
| Policy package support declarations | Up to `64`. |
| Package dependency edges | Up to `256`. |
| Canonical declaration payload | At most `1 MiB`. |
| Current-fact comparison evidence | Default `100`, allowed `1`–`1000`. |
| Decision constructor candidate bound | Default `1000`; declarations must satisfy the installed validator's bound. |
| Ordinary rule identity | One non-null unique `bigint` key. |
| Rule comparison identity | One non-null unique `bigint` key. |

A returned-evidence limit is not a throughput or database-size guarantee. If comparison is `partial`, displayed counts and arrays are incomplete; there is no continuation token, and `compare_results()` presents the same bounded evidence. Causal explanations have additional node, edge, depth, path, fanout, and payload bounds, described in [the advanced reference](reference/advanced-apis.md#explanations-and-retained-evidence).

Managed polling and batch limits are listed in [Configuration](reference/configuration.md). Their defaults govern worker behavior, not the supported size of an arbitrary policy. For example, increasing the pending-job threshold permits a larger backlog but does not make a slow consequence execute faster.

## Measured workload envelope

The recorded M59 adoption envelope uses the pinned Linux/amd64 runner and baseline profile, a 100,000-row retained-history comparison sweep, and a 1,000-match hot-conflict backlog. Its acceptance ceilings are `250 ms` p95 for comparison and `2,500 ms` p95 for expired-lease recovery, with the backlog draining without residual pending work. Read these as acceptance criteria for that measured profile, not service-level guarantees for a different deployment.

Comparison dependency fan-out, reevaluation cost, cascade depth, faithful process-memory cost, temporary-storage cost, and 100,000-match throughput remain outside that measured envelope. The [benchmark record](benchmarks.md) provides the evidence context, and [Known limitations](known-limitations.md) describes the broader product boundaries.
