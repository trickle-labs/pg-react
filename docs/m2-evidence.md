# M2 evidence

| M2 requirement | Executable evidence |
| --- | --- |
| `ACTIVATE`, revisioned `CHANGE`, and `DEACTIVATE` with immutable old/new payloads | `tests/m2.sql` |
| Bounded claims, conflict leases, heartbeats, expiry reclamation, and stale-worker rejection | `tests/m2.sql` |
| Retry backoff, terminal failure state, and append-only attempts | `tests/m2.sql` |
| Typed consequence completion and transactional outbox-sink completion | `tests/m2.sql` |
| Fresh event eligibility and source/function/lease checks before invocation | `tests/m2.sql`, `pgreact.execute_claimed_episode()` |
| Blue/green old-work policy and audited reconciliation modes | `pgreact.replace_rule()`, `pgreact.reconcile_rule()` |
| Coordinator-owned `DIFFERENTIAL` boundary, key safety, and M1 compatibility | `tests/m0.sh`, `tests/m1.sh` |

Run the full local evidence from a clean Compose database with:

```sh
bash tests/m0.sh && bash tests/m1.sh && bash tests/m1-scale.sh && bash tests/m2.sh
cargo test --no-default-features
```

The M2 worker remains stateless: `bin/pg-reactd` polls PostgreSQL, can reserve a bounded `MAX_CLAIMS` set, and executes every episode in a separate transaction. No pg-react relay or delivery-state table is introduced; outbox delivery remains owned by the registered sink.
