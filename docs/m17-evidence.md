# M17 evidence

`tests/m17.sh pg-react:v0.14.0` is the release-blocking M17 repository gate.

| Requirement | Exact automated evidence |
|---|---|
| Window boundaries and every F1–F9 aggregate state | Reference semantic fixture |
| Replay/idempotency and ordered corrections/lifecycle | Reference semantic fixture |
| Concurrent/equal/backward watermark requests | Concurrent watermark fixture |
| Bounded batching, finalization, injected failure rollback | Reference and resource fixtures |
| Correctably late and finalized input, repair, unrecoverable history | Late-input fixture |
| Retention and bounded cursor history | Late-input fixture |
| Public inventory, permissions, diagnostics, invalid declarations | API fixture |
| `max_facts`, event-time failures, batch limits, indexed boundary plan | Resource fixture |
| Crash/restart, standby, promotion, physical restore | M17 recovery fixture |
| Logical dump/restore and continued execution | M17 logical recovery fixture |
| Populated `0.13.0 -> 0.14.0` preservation | M17 upgrade fixture |
| Every inherited M0–M16 gate | M16 compatibility runner; M16 carries M0–M15 |

Passing fixtures compare complete ordered rows or normalized state objects.
They do not replace equality with counts, accept alternate output, or mutate
private state to make a failed semantic assertion pass.
