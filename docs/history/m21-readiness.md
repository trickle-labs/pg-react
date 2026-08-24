# M21 readiness record

M21 is implemented as the `0.18.0` repository candidate. It has a direct
`0.17.0 -> 0.18.0` migration and the public retention contract with disabled-
by-default policy, operator-only mutation/preview/apply/audit, bounded
idempotent batches, protected current/executable state, active supports/open
windows, pending work, and exact loss-of-detail diagnostics.

See the [M21 evidence record](m21-evidence.md) for the executable gate and
the inherited-release boundary.

Before tagging, run:

```text
tests/m21.sh fast pg-react:v0.18.0
tests/m21.sh complete pg-react:v0.18.0
```

Then verify the inherited M0–M20 artifacts and publish `v0.18.0`. The next
defined milestone is M22 — Bounded support provenance.
