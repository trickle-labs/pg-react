# M20 evidence

Fast evidence:

```text
tests/m20.sh fast pg-react:v0.17.0
```

Complete evidence adds the populated direct `0.16.0 -> 0.17.0` upgrade:

```text
tests/m20.sh complete pg-react:v0.17.0
```

The release runner must attach the exact fixture logs, inherited M0–M19
artifacts, checksums, OCI digest, SBOM, provenance, and independent usability
record before publishing `v0.17.0`.
