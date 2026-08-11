# M10 entry fixture and release evidence

M10 begins from the immutable `v0.6.0` M9 release:

- tag commit: `c9ffb833487c17019aa7a216c645e1d61bca650d`;
- successful release workflow: [31399001634](https://github.com/trickle-labs/pg-react/actions/runs/31399001634);
- archive: `pg-react-v0.6.0-linux-amd64.tar.gz` with SHA-256
  `fc246a90ad2ecfd1a62c2256709a14b80c3a517c7f752a8b49ff5b0460651a59`;
- OCI image: `ghcr.io/trickle-labs/pg-react:v0.6.0@sha256:8c7ca63200fc27e82bd4dcb38fbb240e0f68f51708203278b5db03a96e5d33fe`.

The release workflow runs `tests/m9.sh`, including the direct `0.5.0 -> 0.6.0`
upgrade. The tag, archive, checksum manifest, image digest, support boundary,
and upgrade documentation are public, so the M10 entry gate is satisfied.

## Frozen M10 reference

`tests/m10-slice1.sql` freezes two source groups and one aggregate rule:
`m10_slice1.group_source(id)` derives `alert(id)` when
`COUNT(*) FROM m10_slice1.item_source WHERE id = group_key >= 2`.

The exact sequence is:

| Frontier | Group 7 count | Alert(7) | Downstream event |
|---:|---:|---|---|
| 1 | 1 | absent | none |
| 2 | 2 | present | `ACTIVATE` |
| 3 | 3 | present | none |
| 4 | 2 | present | none |
| 5 | 1 | absent | `DEACTIVATE` |

Group 8 remains at count zero throughout. The fixture asserts every visible
fact, evidence record, stratum, lower frontier, and event rather than merely
counting rows.
