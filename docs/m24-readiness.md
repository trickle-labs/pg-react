# M24 readiness record

M24 is implemented as the `0.21.0` repository candidate. It adds durable
business-effective intervals, committed-frontier authority changes, explicit
overlap and gap diagnostics, transition history, and fresh work eligibility.

Run:

```text
tests/m24.sh fast pg-react:v0.21.0
tests/m24.sh complete pg-react:v0.21.0
```

The complete profile includes the inherited M23 gate and a populated direct
`0.20.0 -> 0.21.0` upgrade. Tag and push `v0.21.0` only after the complete
profile passes on the release image.

The logical next milestone is M25 — Parameterized policy families.
