# M22 evidence

The fast profile checks the release identity, documentation, typed binding
capture, exact bounded explanation shape, continuation, validation, doctor,
reader access, and advanced-reader access. The complete profile adds a
populated direct `0.18.0 -> 0.19.0` upgrade and verifies that existing derived
support is backfilled into the new provenance table.

```text
tests/m22.sh fast pg-react:v0.19.0
tests/m22.sh complete pg-react:v0.19.0
```

The release runner must attach the exact fixture logs plus inherited M0–M21
artifacts, checksums, OCI digest, SBOM, provenance, and the independent
usability record before publishing `v0.19.0`.
