# Support Matrix

The current adoption boundary is pg-react `0.43.1` on PostgreSQL 18.3,
pg_trickle 0.81.0, pgrx 0.18.0, Rust 1.89.0, Linux `amd64`, `READ COMMITTED`,
and the PostgreSQL-managed runtime.

The managed runtime still accepts the historical adjacent 0.x versions and
historical release-candidate identifiers where the installed code supports
them. “Accepted by the runtime” is not the same as “qualified current
adoption boundary.” The [current release manifest](current-release.json) and
qualification workflow define the current boundary.

| Feature | Qualified support | Boundary |
| --- | --- | --- |
| Ordinary deployment | Rule, decision, and policy-set validate, preview, review, deploy, and inspect | Public ordinary APIs only |
| Replacement | Reviewed stable-name replacement with stale-plan rejection | Explicit old-work policy is required when command work exists |
| Command work | Pending, leased, retry-wait, retry, and at-least-once delivery | Consumers must deduplicate external effects |
| Policy packages | Versioned policy sets with bounded applicability | Package members, support, dependencies, and evidence are bounded |
| RLS | Rejected for evaluated sources | No row-redacted comparison substitute is qualified |
| Comparison | Bounded current and proposed evidence | One non-null, unique `bigint` key for ordinary rules |
| Recovery | Public barriers, reconciliation, backup, and restore procedures | Private catalog restore is not portable logical backup |
| Delivery | Transactional outbox with at-least-once delivery | Exactly-once external effects are unsupported |
