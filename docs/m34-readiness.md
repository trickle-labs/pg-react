# M34 readiness

> [!NOTE]
> Historical `0.31.0` readiness record. The current roadmap postpones `1.0.0`
> and advances one milestone at a time from M35. This file remains qualification
> evidence, not current release instructions. See [`history.md`](history.md).

**Status: M34 implementation and packaged qualification complete.**

The M34 candidate is extension `0.31.0`. It adds a bounded, read-only
comparison surface and preserves the M33 runtime and compatibility contract.

`tests/m34.sh complete` passed against the exact candidate image, including the
populated upgrade, rollback-by-restore, no-effect checks, and inherited M33
qualification from the recorded M33 baseline. Tag `v0.31.0`; this release is
not a v1 release candidate.

The logical next milestone is **M35 — hypothetical fact simulation**. It is
already defined in the roadmap and should extend `compare()` with typed
insert, update, and delete declarations. Once M35 and all inherited gates
pass, begin the final qualification cycle and tag `v1.0.0-rc.1`.
