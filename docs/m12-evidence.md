# M12 evidence

`tests/m12.sh pg-react:v0.9.0` is the repository gate. It runs inherited
M0–M11 qualification, then the M12 fresh-install, reference, ordering,
failure, authorization, worker, direct-upgrade, crash/restart, and physical
recovery fixtures.

| Requirement | Executable evidence |
| --- | --- |
| Equality, overdue, no early or duplicate activation | `m12-reference.sql` freezes every activation, generation, event, agenda state, clock sample, status, and explanation |
| Indexed affected-key advancement | `m12-boundary.sql` asserts the `(deadline, semantic_key)` index and exact crossing-key results |
| Equivalent ordering and clean recomputation | `m12-order.sql` compares source-before-clock with clock-before-source and exact state-only repair |
| Atomic failure and resource safety | `m12-boundary.sql` injects post-lifecycle failure and a pass-limit failure, then proves the prior clock, complete state, barrier, and absence of partial work |
| Lifecycle operations | `m12-reference.sql` covers advancement, postponement, deletion, pause, and resume; `m12-order.sql` covers reconcile, replace, and remove |
| Validation and authorization | `m12-boundary.sql` freezes complete diagnostics for computed, negative, windowed, wrong-type, null, non-owned, and unauthorized declarations or operations |
| Worker and claim barrier | `m12-worker-*.sql` plus `m12.sh` exercise coordinator sampling, blocking, claim, exact execution, and protocols inherited from M11 |
| Direct populated upgrade | `m12-upgrade.sql` compares complete M11 durable rows across `0.8.0 -> 0.9.0`, proves negative-infinity initialization, and catches overdue/equal candidates on the first pass |
| Crash, restart, restore, promotion-style catch-up | `m12-recovery-*.sql` through `m6-recovery.sh` compares complete durable clock and lifecycle state before and after crash and checksummed physical restore |
| Inherited compatibility and external effects | `m11.sh` and its nested M0–M10 suites run against the `0.9.0` image |

The frozen 1,000-row smoke and indexed crossing plan are recorded by the
boundary gate; M12 does not publish a wall-clock firing-latency promise.
