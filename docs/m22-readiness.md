# M22 readiness record

M22 is implemented as the `0.19.0` repository candidate. It adds typed,
trigger-maintained support provenance, bounded recursive proof nodes, snapshot-
checked continuation, reader/advanced-reader authorization, diagnostics, and a
direct `0.18.0 -> 0.19.0` migration.

Run the release gate before tagging:

```text
tests/m22.sh fast pg-react:v0.19.0
tests/m22.sh complete pg-react:v0.19.0
```

Also verify the inherited M0–M21 artifacts, checksums, OCI digest, SBOM,
provenance, and populated upgrade evidence. Only then tag and push `v0.19.0`.
The next defined milestone is M23 — Practical temporal conditions.
