# M25 readiness record

M25 is implemented as the `0.22.0` repository candidate. It adds typed
parameter-family declarations, separate value-editor authorization, atomic
parameterized authoring, relational maintenance, public preview and
explanation, drift diagnostics, and a populated direct upgrade from `0.21.0`.

Run the fast gate first:

```text
tests/m25.sh fast pg-react:v0.22.0
```

The release gate is:

```text
tests/m25.sh complete pg-react:v0.22.0
```

The complete profile includes the inherited M24 gate and the populated direct
`0.21.0 -> 0.22.0` upgrade. Tag and push `v0.22.0` only after the complete
profile passes on the release image and the release workflow has verified the
image digest, SBOM, provenance, checksums, and evidence archive.

The logical next milestone is M26 — Decision tables. It remains a proposed
planning label until the M25 evidence and entry fixture are credible.
