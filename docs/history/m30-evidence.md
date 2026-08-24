# M30 evidence map

The release-blocking executable gate is `tests/m30.sh`.

| Requirement | Evidence |
| --- | --- |
| Canonical identities and codec v2 | `sql/m30.sql`; exact identity assertions in `tests/m30.sql` |
| Frozen kind disposition and scope mode | `docs/m30-support-matrix.md`; `pgreact_internal.m30_validate` |
| Relational eligibility | `pgreact_internal.policy_set_eligibility`; public eligibility view |
| Scope-support schema | `pgreact_internal.policy_set_scope_supports`; public support view |
| Invalid source findings | duplicate, null, unsupported, RLS, privilege, and limit checks in `m30_validate` |
| Migration classification | `pgreact_internal.declaration_migrations`; populated upgrade fixture |
| Bounded inspection | status, explain, doctor, and five public relational views |
| No snapshot rewrite before refresh | exact row-preservation assertion in `tests/m30.sql` |
| Direct upgrade | `tests/m30-upgrade-before.sql`, `tests/m30-upgrade-after.sql`, complete profile |
| Release identity and documentation | audits in `tests/m30.sh` |

M30 does not claim authoritative member lifecycle or work. Those are M31
acceptance gates and must be added without changing this applicability contract.
