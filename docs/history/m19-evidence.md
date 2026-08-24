# M19 evidence

Fast evidence runs the public immediate fixture from a clean `0.16.0` image:

```text
tests/m19.sh fast pg-react:v0.16.0
```

Complete evidence adds the populated direct `0.15.0 -> 0.16.0` upgrade:

```text
tests/m19.sh complete pg-react:v0.16.0
```

The release runner must additionally verify and publish the complete inherited
M0–M18 artifact set, M19 exact transcripts, benchmark and recovery results, checksums,
OCI digest, SBOM, provenance, and independently observed usability evidence.
The checked-in release inventory is
`tests/fixtures/m19/release-state.json`; a candidate is not called complete
until those external artifacts are immutable and verified.
