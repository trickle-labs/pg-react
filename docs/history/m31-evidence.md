# M31 evidence map

**Status: local executable evidence is green; release evidence is not yet
complete.**

| Requirement | Evidence in the current tree | Status |
| --- | --- | --- |
| Authoritative adapters | `tests/m31.sql` exercises rule, decision-program, and policy-set façade paths and rejects unsupported metadata-only behavior before mutation | Green in complete lane |
| Match versus subject identity | Entry, exit, return, expiry, removal, and overlapping-set assertions | Green |
| Scope supports | Support transition, deduplication, restart, and two-session race fixtures | Green in complete lane |
| Atomic truth | Runtime, lifecycle, support, work, frontier, and façade checksums in the main and retention fixtures | Green for covered fixtures |
| Claimed-work revalidation | Stale batch and episode claims are withdrawn or skipped without effects; race/lease fixture passes | Green in complete lane |
| Fail-closed safety | Invalid, unauthorized, RLS-protected, malformed, incomplete, drifted, duplicate, and over-limit source cases | Green |
| Truthful façade | `validate`, `preview`, `deploy`, `run`, `remove`, `status`, `explain`, and `doctor` assertions | Green for covered fixtures |
| Generic removal | Rule, decision, and policy-set removal plus stale-work withdrawal | Green |
| M29 migration | Populated `0.26.0 -> 0.27.0` upgrade and no-silent-gating assertions | Green in complete lane |
| M31 migration | Populated direct `0.27.0 -> 0.28.0` upgrade and no-silent-gating assertions | Green in complete lane |
| Recovery | M31 crash/restart, logical restore, standby promotion, physical restore, and post-restore eligibility | Green in complete lane |
| Security | Role isolation, grants, protected-source, RLS rejection, and safe public barriers | Green for executable matrix; independent review found no blocker |
| Performance and limits | Bounded 1,000-row workload with an explicit ten-second ceiling | Green for the checked profile; broader published benchmark record remains |
| Documentation | Contract, API reference, migration, release notes, inventory, and selected executable examples | Audit passes; full example inventory remains |
| Coordinator and lock order | Documented lock order plus two-session race/lease qualification | Green in complete lane |
| Global execution and frontiers | Global run, sampled frontier, failed-refresh barrier, and post-restore reconciliation assertions | Green for covered fixtures |
| Continuous qualification | Fresh install, populated upgrade, role isolation, packaged SQL, recovery, and inherited M0–M30 lane | Green for the current lane; rollback record remains |
| Independent review | Required review scope and disposition in [m31-independent-review.md](m31-independent-review.md) | Green; no unresolved blocker |
| M32 cohort | Required five-person protocol is recorded in [m31-usability.md](m31-usability.md) | Pending external evidence |
| Inherited gates | M31 complete lane runs the inherited M30 complete and M17 recovery checks | Green locally |

## Evidence rule

Green rows describe what the current executable fixtures actually prove. They
do not replace the independent review, usability record, or release-artifact
qualification. M31 is not release-ready until the pending rows and the
remaining qualification records are complete.
