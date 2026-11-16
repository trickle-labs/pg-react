# Support matrix

[Reference](reference/index.md) · [Versions and release identity](reference/release-identity.md)

The current core adoption boundary recorded by the repository is **pg-react 0.46.0 / R0**. Use the tuple below when following the main user guides or assessing the core release's qualification. A runtime accepting an extension version, a source tree containing a maintenance script, and a workload being qualified on that combination are different observations.

## Qualified environment

| Component or setting | Qualified value |
| --- | --- |
| Core extension | `0.46.0` |
| PostgreSQL | `18.3` |
| pg_trickle | `0.108.0` |
| Operating system and architecture | Linux `amd64` |
| Transaction isolation | `READ COMMITTED` |
| Runtime | PostgreSQL-managed workers |
| Change capture | Trigger CDC |
| pg_trickle independent scheduler | Off |
| Differential change ratio | `pg_trickle.differential_max_change_ratio = 1.0` |
| Coordination | Explicit pg-react coordination |

The recorded build facts are pgrx `0.18.0` and Rust `1.89.0`; they are not additional promises that arbitrary builds on other platforms are qualified. The pinned upstream image reports PostgreSQL `18.3`. Exact artifact identity and qualification metadata live in the [current release manifest](current-release.json), with installation commands in [Installation](installation.md).

## Feature boundaries

| Feature | Supported use in this profile | Boundary |
| --- | --- | --- |
| Ordinary declarations | Validate, preview, review, deploy, and inspect rules, decisions, and policy sets. | Use the documented public interfaces. |
| Replacement | Reviewed stable-name replacement with stale-plan rejection. | Explicit old-work disposition is required for eligible command work. |
| Command work | Durable work, attempts, retry waits, lease recovery, and execution. | External effects remain at least once. |
| Policy packages | Versioned members, support, dependencies, and relational applicability. | Membership, payload, graph, and evidence are bounded. |
| Comparison | Bounded current and proposed outcomes. | Ordinary rule comparison requires one non-null unique `bigint` key. |
| Evaluated source access | Authorized caller-readable relations. | RLS-protected evaluated sources are rejected. |
| Recovery | Public barriers, reconciliation, backup, and restore procedures. | Live private catalogs are not a portable logical backup format. |
| External delivery | Transactional outbox intent with consumer deduplication. | Exactly-once external delivery is unsupported. |
| pg_trickle integration | Trigger CDC with explicit coordination. | Upstream Graph V1.2 and Delta V1.1 are available but unused by this core profile; WAL CDC and independent scheduling are not its qualified path. |

## Source maintenance and optional integration

The source tree's default extension version is `0.46.2`, while the main user guides and Compose initializer intentionally select `0.46.0`. Maintenance scripts have their own focused evidence and should be assessed through their associated records. The managed runtime also accepts certain older versions and historical candidate identifiers, but acceptance alone does not establish a supported new adoption profile.

The R0 manifest leaves the optional MDM stewardship adapter disabled. The separately versioned [0.50.0 adapter release](https://github.com/trickle-labs/pg-react/releases/tag/v0.50.0) is a synthetic demonstration with `release_qualified: false`, not a production-supported real-workload release. Its [local exercise](v0.50.0-operations.md#synthetic-local-exercise) has its own exact stack and no live operator effects. Do not infer adapter readiness from the success of the ordinary first-rule tutorial, or infer a new core version from an adapter release tag.
