# M33 readiness

> [!NOTE]
> Historical `0.30.0` readiness record, retained as qualification evidence.
> It does not establish current RC readiness or sequencing. See
> [`history.md`](history.md).

**Status: implementation and automated qualification lane prepared.**

The candidate is extension `0.30.0`. It freezes the v1 ordinary API and
documents the supported boundary, compatibility rules, recovery model,
security checks, limits, operations, and release artifacts.

The next release is **`1.0.0-rc.1`**, not `1.0.0`. The RC must use the exact
packaged artifact and rerun the complete applicable M33 suite.

## Required before the RC tag

- the complete `tests/m33.sh complete` result from the packaged image;
- inherited M0–M32 gates and the populated `0.26.0` direct-upgrade rehearsal;
- recorded independent usability results from five PostgreSQL developers;
- two controlled pilot records;
- no unresolved P0 or P1 findings.

The first logical post-v1 feature milestone is **M34 — deployment-impact
simulation**. It must compare proposed and deployed policy behavior without
changing authoritative state, executing work, or creating external effects.
