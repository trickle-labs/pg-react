# M20 readiness record

M20 is implemented as the `0.17.0` repository candidate. It has a direct
`0.16.0 -> 0.17.0` migration, fresh-install SQL, named immutable shared
conditions, explicit consumer tracking, public inspection, drift diagnostics,
and an executable fast/complete evidence gate.

Before tagging, run:

```text
tests/m20.sh complete pg-react:v0.17.0
```

Then verify the inherited M0–M19 artifacts and publish `v0.17.0`. The next
defined milestone is M21 — Retention and catalog scale.
