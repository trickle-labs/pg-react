# M23 readiness record

M23 is implemented as the `0.20.0` repository candidate. It adds continuous
duration, absence by direct deadline, cooldown, arm/recovery hysteresis,
indexed durable per-key state, public temporal evidence, and direct
`0.19.0 -> 0.20.0` migration over the inherited coordinator and worker paths.

Run:

```text
tests/m23.sh fast pg-react:v0.20.0
tests/m23.sh complete pg-react:v0.20.0
```

Also verify the inherited M0–M22 artifacts, checksums, OCI digest, SBOM,
provenance, populated upgrade, and recovery evidence. Only then tag and push
`v0.20.0`. The logical next milestone is M24 — Effective-dated policy
versions; it remains planning-only until this evidence and its entry fixture
are credible.
