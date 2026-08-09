# M1 readiness

**Status: complete on the restricted coordinator-owned boundary.**

M0 passes its Rust and Docker-backed evidence gates against PostgreSQL 18.3 and pg_trickle 0.81.0 at `ba41c9c2e2bbf2195917fcdcc89efa8ab3089dcb`. The roadmap decision gate selects option 2: a deliberately smaller maintenance subset rather than an unavailable upstream observer.

M1 inherits these non-negotiable limits:

- `pg-reactd` owns the proven begin-refresh / explicit `DIFFERENTIAL` refresh / barrier-clear / lock-release sequence.
- Command refresh runs only under `READ COMMITTED` with `pg_trickle.user_triggers=auto`, `pg_trickle.differential_max_change_ratio=1.0`, and the automatic scheduler disabled on the pinned tuple.
- Automatic pg_trickle scheduler command refresh, `AUTO`, `FULL`, `IMMEDIATE`, early `SET CONSTRAINTS`, and uncoordinated refresh calls remain rejected or claim-barriered.
- The trigger/deferred-finalizer path remains compatibility code. A public critical observer replaces it only after the same M0 gates pass.
- The starting key-codec matrix is only non-null `bigint` codec v1. Each added type needs equality-edge and cross-restore fixtures under a new immutable codec contract.
- RLS-protected sources remain unsupported and must be rejected by M1 registration before activation.

The executable M1 evidence is in [`m1-evidence.md`](m1-evidence.md). M2 may build complete lifecycle and reliability features without reopening M0/M1 semantics or widening the maintenance matrix.
