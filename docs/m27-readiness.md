# M27 readiness record

M27 is implemented as the `0.24.0` decision coverage and conflict-analysis
candidate. The local fast and complete gates pass, including the inherited M26
gate and the populated `0.23.0 -> 0.24.0` upgrade. Tag and push `v0.24.0`
only after the release workflow has produced and verified its checksums, SBOM,
provenance, OCI digest, and publication artifacts.

The release gate must cover the explicit population and candidate catalog,
complete-frontier fingerprints, ties, forbidden and allowed overlap, missing
and present required defaults, reachable and unreachable candidates, covered
and uncovered subjects, distribution limits at their boundaries, stale
analysis, deployment admission, concurrent changes, maintenance, pause and
resume, replacement, reconciliation, retention, physical and logical
recovery, standby promotion, authorization, performance, and the populated
direct `0.23.0 -> 0.24.0` upgrade.

The complete evidence must compare exact public declarations, frontier and
fingerprints, requirements, findings, severities, blockers, evidence and
truncation, distributions and deltas, support, provenance, diagnostics,
authorization results, remediation, deployment state, and final checksums.
It must also verify the release archive's checksums, SBOM, provenance, OCI
digest, documentation, and usability record.

The logical next milestone is M28 — Policy-set gating. M28 is already named in
the roadmap, but its implementation contract is not part of M27.
