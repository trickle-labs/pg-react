# M24 evidence

Run the release gate before tagging:

```text
tests/m24.sh fast pg-react:v0.21.0
tests/m24.sh complete pg-react:v0.21.0
```

| Requirement | Executable evidence |
| --- | --- |
| Interval validation and overlap rejection | `m24.sql` |
| Future versions stay dormant | `m24.sql` |
| Future derivation programs stay dormant and materialize at the boundary | `m24-program.sql` |
| Equality and exclusive-end boundaries | `m24.sql` |
| Explicit gaps and adjacent successors | `m24.sql` |
| Transition history, status, preview, explanation, doctor | `m24.sql` |
| Populated direct upgrade | `m24-upgrade-before.sql`, `m24-upgrade-after.sql` |
| Documentation and release identity | `m24.sh` |
| Inherited correctness, recovery, security, and worker behavior | nested M23 and prior gates |

The complete profile is the release blocker. Tag and push `v0.21.0` only after
both profiles pass on the release image.
