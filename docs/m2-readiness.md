# M2 readiness

**Status: complete, constrained by M1's coordinator-owned boundary.**

M2 inherits PostgreSQL 18.3, pg_trickle 0.81.0, `READ COMMITTED`, explicit `DIFFERENTIAL` command refresh, scheduler disabled, RLS rejection, and non-null `bigint` codec v1. It must not enable `AUTO`, `FULL`, `IMMEDIATE`, uncoordinated refresh, additional key codecs, or RLS sources without new compatibility evidence.

Start with these closed implementation boundaries:

- Add `CHANGE` and `DEACTIVATE` events with immutable old/new payloads and deterministic revision identities.
- Extend the current lease protocol with heartbeat, bounded multi-worker claims, retry classification/backoff, withdrawal, terminal failure, and stale-worker rejection.
- Specify and test conflict ordering, replacement cutover, reconciliation audit/event emission, feedback-loop controls, and the transactional outbox envelope before exposing each feature.
- Preserve one episode per transaction and the fresh eligibility/fingerprint/lease check immediately before invocation.

The executable M2 evidence is [`m2-evidence.md`](m2-evidence.md). It covers complete lifecycle payloads, retry/heartbeat/stale-lease handling, bounded claims, transactional outbox enqueue, and reconciliation audit. The supported boundary remains explicit `DIFFERENTIAL` refresh under `READ COMMITTED`; M3 begins only after its operational/recovery gates are implemented.
