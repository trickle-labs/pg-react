# M4 readiness: v1 general availability

M4 freezes and publishes the first supported contract; it does not widen M3's compatibility matrix. The release candidate is extension and crate version `0.1.1`, with worker protocol `1` and an immutable `0.1.0 -> 0.1.1` migration.

## Gate assessment

| GA requirement | Current evidence | Status |
| --- | --- | --- |
| M3 gates pass continuously | CI runs the Rust, M0, M1, scale, M2, M3, and upgrade suites | Ready for release-artifact rerun |
| Compatibility policy | [`m3-compatibility.md`](m3-compatibility.md) fixes one supported tuple | Ready to freeze |
| Catalog migration policy | Historical `0.1.0`, current `0.1.1`, and the tested upgrade script are separate | Ready to document |
| SQL API and worker protocol | Public SQL functions exist and protocol `1` is checked at startup | Inventory and guarantees not yet published |
| Task-oriented documentation | The README and [`m3-operations.md`](m3-operations.md) cover the example and core operations | Installation, authoring, security, backup/restore, upgrade, and troubleshooting guides remain |
| Release artifacts | The Docker base and dependency tuple are pinned | Build/publish workflow, artifact checksum, upgrade notes, and known limitations remain |
| Release-artifact reference test | Development-image integration tests exist | Exact README workflow must run against the packaged artifact |
| Production exercise | The internal fixture covers load and recovery mechanics | A pilot deployment must complete install, normal operation, failure, restore, and upgrade |
| GA correctness audit | Lifecycle, concurrency, recovery, dispatch, and operational suites exist | Rerun the full requirement-by-requirement audit on the packaged artifact |

## Required order

1. Freeze the public SQL signature inventory, worker protocol semantics, migration window, compatibility policy, and external-delivery guarantees.
2. Produce one versioned image/package, checksum it, and run every existing gate plus the exact README example against that artifact.
3. Finish the six task-oriented guides and publish upgrade notes and known limitations beside the artifact.
4. Complete and record the production pilot exercise.
5. Audit every GA requirement against direct evidence, then tag and publish v1 only if no correctness blocker remains.

No M4 work should add a maintenance mode, RLS support, key codec, PostgreSQL version, operating system, or architecture without its own compatibility evidence.
