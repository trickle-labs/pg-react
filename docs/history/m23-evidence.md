# M23 evidence

Run the release gate before tagging:

```text
tests/m23.sh fast pg-react:v0.20.0
tests/m23.sh complete pg-react:v0.20.0
```

| Requirement | Executable evidence |
| --- | --- |
| Exact temporal states and boundaries | `m23.sql` |
| Duration cancellation and recurrence | `m23.sql` |
| Absence before/equal/after deadline | `m23.sql` |
| Cooldown and hysteresis | `m23.sql` |
| Public validation, preview, status, history, explanation, doctor | `m23.sql` |
| Direct populated upgrade | `m23-upgrade-before.sql`, `m23-upgrade-after.sql` |
| Documentation and release identity | `m23.sh` |
| Inherited correctness, recovery, security, and worker behavior | nested M22 and prior gates |

The complete profile is the release blocker. Tag and push `v0.20.0` only after
both profiles pass on the release image.
