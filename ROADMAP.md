# pg-react roadmap

> **Status:** Living delivery plan  
> **Last updated:** 2026-09-01
> **Current release:** `0.43.0` (M54)

## Product goal

Make changing PostgreSQL facts into durable, inspectable policy state and work
with a small ordinary path and explicit advanced surfaces. PostgreSQL remains
authoritative; rules remain inspectable; safe change beats speculative breadth.

## Current priorities

M54 hardens adoption: current documentation, ordinary watched/conflict fields,
stable-name replacement, reviewed deployment, names-first recovery, and one
canonical qualification lane. `1.0.0` is postponed indefinitely; adjacent 0.x
releases preserve valid ordinary calls by project policy.

## Selection rules

Choose the next milestone from evidence collected against the ordinary path.
Safety evidence overrides product expansion. Do not begin a semantic milestone
until the current release is qualified and its operating boundary is clear.

| Candidate | Choose when |
|---|---|
| M59 — Supported-scale qualification | Throughput, WAL, storage, retention, recovery, or bounded-cost uncertainty blocks adoption |
| M58 — Authorization alignment | Grants, security context, or RLS blocks a real supported workload |
| M45 — Rolling/hopping windows | Missing event-time windows block an otherwise suitable policy |
| M55 — Schema-change safety | Ordinary DDL cannot be shown safe |
| M56 — Rebuild/reconciliation safety | Restore, rebuild, failover, or reconciliation cannot be shown safe |

M55 and M56 take priority immediately when their safety evidence requires it.
M45, M58, and M59 remain candidates rather than commitments.

## Explicit non-goals

The roadmap does not promise a policy DSL, client SDK, visual or AI authoring,
cross-database deployment, approval routing, exactly-once external delivery,
general workflow orchestration, or a new scheduler.

Completed milestone detail through M53 is preserved in
[roadmap-through-m53.md](docs/history/roadmap-through-m53.md). Release
contracts and qualification evidence are indexed by [History](docs/history.md).
