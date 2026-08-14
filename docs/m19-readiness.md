# M19 readiness record

M19 is implemented as a release candidate, not declared complete in source.
The candidate has extension `0.16.0`, a direct `0.15.0 -> 0.16.0` migration,
fresh-install SQL, public validation/preview/status/doctor/explanation paths,
and an executable immediate constraint and derivation fixture.

Before tagging, run `tests/m19.sh complete pg-react:v0.16.0` on the pinned
release runner and attach its exact artifacts. Verify the inherited M0–M18
artifacts, checksums, OCI digest, SBOM, provenance, and independent usability
record required by the M19 entry gate. Then tag and publish `v0.16.0`.

The next defined milestone is M20 — Shared conditions. It should start only
after the immutable M19 artifacts and entry fixture are verified; no M20
implementation is included here.
