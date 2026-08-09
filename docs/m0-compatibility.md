# M0 compatibility contract

M0 supports exactly this restricted compatibility tuple and coordinator protocol. It is not a broader M1 compatibility promise.

| Component | M0 value | Evidence |
| --- | --- | --- |
| PostgreSQL / pg_trickle image | PostgreSQL 18.3, `ghcr.io/trickle-labs/pg_trickle@sha256:998ab948555e990dcffc9464f316b3abe6b05f9ebc8bd50f16d3bc5bf88ca65d` | published v0.81.0 image; its [`Dockerfile.ghcr`](https://github.com/trickle-labs/pg-trickle/blob/ba41c9c2e2bbf2195917fcdcc89efa8ab3089dcb/Dockerfile.ghcr) pins the PostgreSQL 18.3 base |
| pg_trickle | v0.81.0, source `ba41c9c2e2bbf2195917fcdcc89efa8ab3089dcb` | its pinned [`Cargo.toml`](https://github.com/trickle-labs/pg-trickle/blob/ba41c9c2e2bbf2195917fcdcc89efa8ab3089dcb/Cargo.toml) |
| pgrx / cargo-pgrx | 0.18.0 | the same `Cargo.toml` and Dockerfile |
| pgrx CI builder | `ghcr.io/trickle-labs/pg-trickle/builder@sha256:8d0446c21ab3273b55c045a39c49120e9d7cde8e970954c3f81e7bee194fad95` | runs `cargo check --features pg18` without relying on host PostgreSQL |
| Rust | edition 2024; upstream `stable` channel | no exact Rust release is specified by the pinned upstream source, so none is invented here |
| refresh | scheduled, explicitly `DIFFERENTIAL`; adaptive threshold `1.0` | `assert_m0_compatibility()` rejects a lower threshold, preventing trigger-suppressing `FULL` fallback |
| transaction isolation | `READ COMMITTED` | `docker-compose.yml`; tests must state it explicitly when opening a transaction |
| user triggers | `pg_trickle.user_triggers=auto` | upstream documents the `auto`/`off` setting; Compose fixes M0 at `auto` |
| automatic scheduler | `pg_trickle.enabled=off` | manual refresh remains available; only the coordinator may enter the command refresh path |

## Image pin note

The requested PostgreSQL 18.4 digest is **not discoverable in the upstream `pg_trickle` Dockerfiles** at the pinned revision or current `main`: both pin PostgreSQL 18.3. The environment therefore uses the upstream-authoritative published PostgreSQL 18.3 image digest above. Do not relabel it as 18.4. Moving to 18.4 requires an upstream-published digest plus a fresh M0 compatibility run.

## Adapter v1 boundary

`pg_react` may depend only on documented PostgreSQL/extension SQL behavior at this boundary. The SQL adapter functions `pgreact_internal.create_m0_stream`, `refresh_rule`, and `assert_m0_compatibility` own every cross-extension call:

- create and refresh a generated `pg_trickle` stream table in explicitly selected `DIFFERENTIAL` mode;
- observe only the resulting match relation through ordinary PostgreSQL SQL and supported user-trigger behavior;
- read public extension metadata only when its API is documented for the pinned version.

It must not link to `pg_trickle` Rust code, read private catalogs or `__pgt_*` relations, infer its row hashes, or treat trigger firing as a final semantic refresh callback. This is adapter v1: one module owns these calls and is the only permitted integration point.

## Observation finding

Source inspection at `ba41c9c2e2bbf2195917fcdcc89efa8ab3089dcb` found documented `DIFFERENTIAL` user-trigger support, but no public `register_refresh_observer` API or equivalent critical callback. M0 therefore proves a smaller boundary: only a coordinator-wrapped explicit refresh is eligible. Its committed pre-refresh barrier and session lock exclude claims; pinned explicit DML feeds a deferred finalizer that reads final match state and can abort the refresh transaction; barrier clearing commits before lock release.

`tests/m0.sh` proves that activation state, lifecycle ledger, agenda work, and a supported refresh commit or roll back together in this subset. Automatic scheduler refreshes and user-controllable early deferred-trigger firing are rejected as compatibility promises; a public critical observer is still required before broadening the subset.
