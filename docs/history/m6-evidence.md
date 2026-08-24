# M6 evidence

M6 is extension `0.3.0`. Worker protocol `2` is an explicit opt-in for audited
batch execution; protocol `1` and one episode per transaction remain the
default. `tests/m6.sh` is the complete repository gate.

| Requirement | Authoritative evidence |
|---|---|
| Immutable explicit declaration, typed-only boundary, bounded claim, and unchanged default | `declare_batch_safe`, `claim_batch`, catalog constraints, `tests/m6.sql`, and the exact API inventory in `tests/m6-api.sql` |
| Exact homogeneous signature and pre-invocation rejection | Frozen batch signature plus the transactional fault-injection matrix in `tests/m6.sql`: undeclared, oversized, mixed version/binding/event/role/policy/conflict scope, duplicate conflict, stale lease, paused rule, and ineligible episode |
| Per-item failure, retry, idempotency, transaction abort, lease expiry, cancellation, and no duplicate effect | Exact successful/partial/rollback/expiry/singleton cases in `tests/m6.sql`; terminated-backend rollback and retry in `tests/m6-concurrency-result.sql` |
| Worker protocol opt-in and default fallback | Protocol handshake, all three lifecycle event kinds, bound validation, and singleton protocol-1 fallback in `tests/m6-worker-setup.sql`, `tests/m6-worker-result.sql`, and `tests/m6.sh` |
| Source, pause, replacement, consequence, dispatcher, and recovery serialization | Active-execution lock-timeout races in `tests/m6.sh`; durable result in `tests/m6-concurrency-result.sql` |
| Public per-episode attempts and batch diagnostics | Exact `batch_history` item/signature output and `explain_episode` links in `tests/m6.sql` and `tests/m6-worker-result.sql` |
| Direct upgrade and compatibility | Exact `0.2.0 -> 0.3.0` preservation/continuation in `tests/m6-upgrade.sql`; complete M0–M5 gate and exact default worker workflow rerun by `tests/m6.sh` |
| Crash restart and physical recovery | Byte-for-byte public episode, attempt, batch, and effect snapshots plus continued batch execution in `tests/m6-recovery.sh` |
| Throughput, default regression, WAL, durable bytes, normalized equivalence, and connection budget | Five cloned samples of the frozen 4,096-episode workload in `tests/m6-benchmark.sh` |
| Public-only user workflow | Declaration, claim, execute, inspect, retry, and disable instructions in `docs/m6-contract.md` |

The entry benchmark in `tests/m6-entry.sh` already proved that execution
overhead was material on the frozen `0.2.0` workload. The implementation
benchmark and full gate remain authoritative across machines; the latest local
medians are recorded in `docs/m6-readiness.md`.
