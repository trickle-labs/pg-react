# M29 evidence map

The release-blocking executable gate is `tests/m29.sh`.

| Requirement | Evidence |
| --- | --- |
| Policy-set declaration, normalization, and findings | `sql/m29.sql`; `tests/m29.sql` |
| Typed, finite, non-null, unique applicability | `pgreact_internal.m29_validate`; duplicate and drift cases in `tests/m29.sql` |
| Atomic immutable deployment and stale preview protection | `pgreact_api.deploy`; preview digest in `tests/m29.sql` |
| Effective bounds and removal | `policy_set_versions`; `pgreact_api.run` and `remove` façade paths |
| Relation-backed inspection and bounded evidence | `pgreact.policy_set_*` views; `tests/m29.sql` |
| Existing M0–M28 behavior | complete profile reruns the immutable `v0.25.0` M28 gate |
| Direct upgrade | `tests/m29-upgrade-before.sql`, `tests/m29-upgrade-after.sql`, complete profile |
| Release identity and documentation | `tests/m29.sh` audits; `docs/m29-readiness.md` |

The complete profile also builds the exact `linux/amd64` image, checks the
direct `0.25.0 -> 0.26.0` migration, and emits the evidence logs consumed by
the release workflow. Artifact checksums, SBOM, OCI digest, provenance, and
signed attestations are produced by `.github/workflows/release.yml` after the
complete gate passes.

Known boundary: M29 deliberately stores applicability truth and evidence; it
does not duplicate member evaluation. Member lifecycle and work semantics
remain owned by the existing M0–M28 engines and are inherited unchanged.
